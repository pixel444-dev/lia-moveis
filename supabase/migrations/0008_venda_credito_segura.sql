-- ============================================================================
-- Move a criação de venda (crédito e à vista) e a decisão de autorização de
-- inadimplente para dentro do backend.
--
-- Motivo: hoje `salvarVenda()` no app faz o insert de vendas/parcelas/itens
-- direto via `sb.from(...)`, e as policies de RLS de `vendas`/`parcelas` são
-- `for all to authenticated using (true)` (mesmo diagnóstico documentado no
-- comentário da migration 0006) — ou seja, qualquer usuário autenticado
-- consegue inserir uma venda ou uma parcela direto pelo DevTools, sem passar
-- por nenhuma validação. O bloqueio de cliente inadimplente hoje é só uma
-- flag em memória do navegador (`window._clienteInadimplente`), e
-- `autorizarVenda`/`negarVenda` fazem UPDATE direto em `autorizacoes_venda`
-- sem checar no servidor se quem chama é gestor.
--
-- Esta migration:
--   1) cria `cliente_bloqueado_por_atraso()`, que troca a regra atual
--      ("1 parcela atrasada já bloqueia") por "bloqueado só a partir de 1
--      mês (30 dias corridos) de atraso na parcela mais antiga em aberto";
--   2) cria `criar_venda()`, que faz a venda inteira (venda + parcelas +
--      itens + totais de equipe + baixa de estoque do caminhão) numa única
--      transação atômica, com o bloqueio de inadimplência crônica
--      verificado no servidor (gestor continua podendo vender pra
--      inadimplente sem bloqueio, igual hoje);
--   3) cria `autorizar_venda()`/`negar_venda()`, que passam a exigir
--      `meu_perfil() = 'gestor'` no servidor;
--   4) revoga INSERT/UPDATE/DELETE direto em `vendas`/`parcelas` do papel
--      `authenticated` — só as funções abaixo (security definer) conseguem
--      escrever nessas tabelas a partir de agora.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, confira no Studio (Database → Functions) que
-- `criar_venda`, `autorizar_venda` e `negar_venda` estão com "Security:
-- Definer". Sem isso elas não conseguem escrever nas tabelas travadas pelo
-- REVOKE do passo 4.
--
-- ⚠️ IMPORTANTE — pontos que não dá pra confirmar só lendo o frontend, por
-- isso pedem sua validação manual no Studio antes de rodar em produção:
--   - Nomes/tipos exatos das colunas de `vendas`, `parcelas`, `venda_itens`
--     e `equipes` usados abaixo foram inferidos dos `insert`/`update` do
--     app (docs/index.html), não de um schema versionado. Se algum nome
--     estiver diferente no banco real, a criação da função vai falhar com
--     erro claro de "column does not exist" — ajuste antes de seguir.
--   - `autorizacoes_venda` já deve ter RLS com alguma policy hoje (não
--     versionada). Este script adiciona uma policy nova de INSERT e revoga
--     UPDATE/DELETE do client, mas não sabe o nome de policies antigas — dê
--     uma olhada em Database → Policies depois de rodar pra confirmar que
--     não sobrou nenhuma policy antiga liberando UPDATE direto.
--   - Cálculo de data de vencimento das parcelas: mantive paridade exata
--     com o `Date.setMonth()` do JS de hoje (inclusive o "estouro de mês",
--     ex.: 31/jan + 1 mês vira 3/mar), via `add_months_like_js()` abaixo.
--     Se preferir vencimento fixo no dia do mês com clamping (padrão do
--     Postgres, mais comum em cobrança parcelada), troque a chamada dentro
--     de `criar_venda()`.
-- ============================================================================

-- 1) Helper: soma N meses a uma data reproduzindo o comportamento de
--    overflow do Date.setMonth() do JavaScript (ex.: 31/jan + 1 mês = 3/mar,
--    porque fevereiro não tem dia 31 e o excedente "vaza" pro mês seguinte).
create or replace function public.add_months_like_js(p_data date, p_meses int)
returns date
language sql
immutable
as $$
  select (date_trunc('month', p_data) + (p_meses || ' months')::interval)::date
         + (extract(day from p_data)::int - 1);
$$;

-- 2) Regra de inadimplência crônica: bloqueado só a partir de 1 mês
--    (30 dias corridos) de atraso na parcela mais antiga em aberto.
drop function if exists public.cliente_bloqueado_por_atraso(uuid);

create function public.cliente_bloqueado_por_atraso(p_cliente_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from parcelas
    where cliente_id = p_cliente_id
      and not pago
      and coalesce(status, '') <> 'devolvida'
      and data_vencimento <= current_date - interval '30 days'
  );
$$;

-- 3) Criação atômica de venda (à vista ou a crédito).
--    p_itens: jsonb array de objetos {"produto": text, "quantidade": numeric,
--    "produto_id": uuid|null}, no mesmo formato que `coletarItensVenda()`
--    já monta hoje no frontend.
drop function if exists public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb);

create function public.criar_venda(
  p_cliente_id uuid,
  p_vendedor_id uuid,
  p_equipe_id uuid,
  p_tipo text,
  p_produto text,
  p_valor numeric,
  p_num_parcelas int,
  p_entrada numeric,
  p_data_primeira_parcela date,
  p_observacao text,
  p_itens jsonb
)
returns vendas
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_venda vendas%rowtype;
  v_codigo text;
  v_tentativas int := 0;
  v_saldo numeric;
  v_valor_parcela numeric;
  v_item jsonb;
  v_caminhao_id uuid;
  v_qtd_atual numeric;
  v_qtd_nova numeric;
  v_produto_id uuid;
begin
  if v_perfil is null then
    raise exception 'Usuário não identificado ou sem perfil ativo.';
  end if;

  -- Gate de inadimplência crônica: só pra vendedor. Gestor sempre pode
  -- vender pra inadimplente sem autorização, igual ao comportamento atual.
  if v_perfil = 'vendedor' and public.cliente_bloqueado_por_atraso(p_cliente_id) then
    raise exception 'Cliente com atraso de mais de 1 mês. Solicite autorização do gestor antes de vender.';
  end if;

  if p_tipo = 'entrada' then
    if p_num_parcelas is null or p_num_parcelas < 1 or p_num_parcelas > 12 then
      raise exception 'Número de parcelas inválido (deve ser entre 1 e 12).';
    end if;
    if p_data_primeira_parcela is null then
      raise exception 'Data da primeira parcela é obrigatória para venda a crédito.';
    end if;
  end if;

  -- Geração de código com retry em colisão, mesma lógica de hoje
  -- (proximo_codigo_venda() já existe e continua sendo a fonte do código).
  loop
    v_tentativas := v_tentativas + 1;
    v_codigo := public.proximo_codigo_venda();
    begin
      insert into vendas (codigo, cliente_id, vendedor_id, tipo, produto, valor, num_parcelas, entrada, observacao, equipe_id)
      values (v_codigo, p_cliente_id, p_vendedor_id, p_tipo, p_produto, p_valor, p_num_parcelas, p_entrada, p_observacao, p_equipe_id)
      returning * into v_venda;
      exit;
    exception when unique_violation then
      if v_tentativas >= 3 then
        raise exception 'Não foi possível gerar um código de venda único após % tentativas.', v_tentativas;
      end if;
    end;
  end loop;

  -- Parcelas: só para venda a crédito. Divisão com o resto absorvido pela
  -- última parcela (corrige a sobra de centavos que a divisão simples de
  -- hoje deixa sem tratamento).
  if p_tipo = 'entrada' then
    v_saldo := p_valor - coalesce(p_entrada, 0);
    v_valor_parcela := round(v_saldo / p_num_parcelas, 2);

    insert into parcelas (venda_id, cliente_id, numero, total_parcelas, valor, data_vencimento, pago, status, cobrador_id)
    select
      v_venda.id,
      p_cliente_id,
      gs,
      p_num_parcelas,
      case when gs = p_num_parcelas
           then v_saldo - v_valor_parcela * (p_num_parcelas - 1)
           else v_valor_parcela
      end,
      public.add_months_like_js(p_data_primeira_parcela, gs - 1),
      false,
      'aberta',
      null
    from generate_series(1, p_num_parcelas) as gs;
  end if;

  -- Itens da venda.
  if p_itens is not null then
    for v_item in select * from jsonb_array_elements(p_itens) loop
      insert into venda_itens (venda_id, produto, quantidade, produto_id)
      values (
        v_venda.id,
        v_item ->> 'produto',
        (v_item ->> 'quantidade')::numeric,
        nullif(v_item ->> 'produto_id', '')::uuid
      );
    end loop;
  end if;

  -- Totais da equipe: incremento atômico em vez de recalcular todas as
  -- vendas da equipe e sobrescrever (elimina a race condition de hoje).
  if p_equipe_id is not null then
    update equipes set
      total_vendas  = coalesce(total_vendas, 0) + 1,
      total_valor   = coalesce(total_valor, 0) + p_valor,
      total_avista  = coalesce(total_avista, 0) + (case when p_tipo = 'avista' then p_valor else 0 end),
      total_credito = coalesce(total_credito, 0) + (case when p_tipo = 'entrada' then p_valor else 0 end)
    where id = p_equipe_id;
  end if;

  -- Baixa de estoque do caminhão: só quando é o próprio vendedor
  -- registrando (mesma condição de hoje). Lock de linha (for update) evita
  -- o read-then-write não atômico que existe hoje no JS.
  if v_perfil = 'vendedor' and p_itens is not null and p_equipe_id is not null then
    select caminhao_id into v_caminhao_id from equipes where id = p_equipe_id;
    if v_caminhao_id is not null then
      for v_item in select * from jsonb_array_elements(p_itens) loop
        v_produto_id := nullif(v_item ->> 'produto_id', '')::uuid;
        if v_produto_id is not null then
          select quantidade into v_qtd_atual
            from caminhao_estoque
            where caminhao_id = v_caminhao_id and produto_id = v_produto_id
            for update;

          v_qtd_nova := greatest(0, coalesce(v_qtd_atual, 0) - (v_item ->> 'quantidade')::numeric);

          update caminhao_estoque
            set quantidade = v_qtd_nova, atualizado_em = now()
            where caminhao_id = v_caminhao_id and produto_id = v_produto_id;

          insert into movimentacoes_estoque
            (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
          values
            ('venda', v_produto_id, (v_item ->> 'quantidade')::numeric, v_caminhao_id, p_equipe_id, v_venda.id,
             public.meu_funcionario_id(), 'Venda ' || v_venda.codigo);
        end if;
      end loop;
    end if;
  end if;

  return v_venda;
end;
$$;

revoke all on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb) from public;
grant execute on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb) to authenticated;

-- 4) Autorização de venda para cliente inadimplente / venda sem CPF: a
--    decisão (autorizar/negar) passa a exigir gestor no servidor. A
--    solicitação em si continua sendo um INSERT direto do vendedor (não dá
--    pra centralizar isso numa função sem saber o formato exato usado hoje
--    para o código de 6 dígitos), mas a policy nova abaixo impede que o
--    próprio vendedor insira já com status diferente de 'pendente'.
drop function if exists public.autorizar_venda(uuid);
drop function if exists public.negar_venda(uuid);

create function public.autorizar_venda(p_autorizacao_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode autorizar vendas.';
  end if;
  update autorizacoes_venda set status = 'autorizado' where id = p_autorizacao_id;
end;
$$;

create function public.negar_venda(p_autorizacao_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode negar vendas.';
  end if;
  update autorizacoes_venda set status = 'negado' where id = p_autorizacao_id;
end;
$$;

revoke all on function public.autorizar_venda(uuid) from public;
grant execute on function public.autorizar_venda(uuid) to authenticated;
revoke all on function public.negar_venda(uuid) from public;
grant execute on function public.negar_venda(uuid) to authenticated;

-- 5) Tranca as tabelas: a partir daqui só as funções acima escrevem em
--    vendas/parcelas. SELECT continua liberado do jeito que já está hoje
--    (não mexemos nas policies de leitura).
revoke insert, update, delete on vendas from authenticated;
revoke insert, update, delete on parcelas from authenticated;

-- autorizacoes_venda: o vendedor ainda pode criar a solicitação (INSERT),
-- mas só com status 'pendente' — e não pode mais fazer UPDATE direto
-- (aprovação/negação só via autorizar_venda/negar_venda acima).
drop policy if exists autorizacoes_venda_insert_pendente on autorizacoes_venda;
create policy autorizacoes_venda_insert_pendente on autorizacoes_venda
  for insert to authenticated
  with check (status = 'pendente');

revoke update, delete on autorizacoes_venda from authenticated;

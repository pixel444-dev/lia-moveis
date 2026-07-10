-- ============================================================================
-- Bloqueio real de venda pra cliente inadimplente crônico + criação atômica
-- de venda a crédito.
--
-- ⚠️ REVISADO depois de inspecionar o schema real em produção (a versão
-- anterior deste arquivo assumia, com base só no comentário da migration
-- 0006, que `vendas`/`parcelas` tinham RLS `for all using(true)` — não é
-- mais verdade. O RLS real de hoje já é bem mais maduro:
--   - `vendas_insert`/`parcelas_insert` já restringem por dono
--     (`minhas_equipes()` / `clientes_da_minha_equipe()`);
--   - `autoriz_update_gestor` já exige gestor pra aprovar/negar autorização
--     (então as funções `autorizar_venda`/`negar_venda` que eu ia criar
--     eram redundantes — não entraram nesta versão);
--   - só falta uma coisa: NENHUMA dessas policies verifica inadimplência.
-- Por isso a versão anterior fazia `REVOKE INSERT/UPDATE/DELETE` inteiro em
-- `vendas`/`parcelas`, o que ia quebrar o cadastro de venda de todo
-- vendedor no minuto em que a migration rodasse (forçando um cutover
-- sincronizado com o frontend). A versão abaixo é cirúrgica: adiciona uma
-- policy `restrictive` que só barra a inserção quando o cliente está
-- bloqueado — o resto do acesso direto continua funcionando exatamente
-- como hoje.
--
-- Esta migration:
--   1) cria `cliente_bloqueado_por_atraso()` — bloqueado só a partir de 1
--      mês (30 dias corridos) de atraso na parcela mais antiga em aberto
--      (troca a regra atual de "1 parcela atrasada já bloqueia", que hoje
--      só existe como flag em memória do navegador,
--      `window._clienteInadimplente`, driblável via DevTools);
--   2) adiciona policies `restrictive` em `vendas` e `parcelas` que aplicam
--      esse bloqueio no INSERT pra qualquer usuário que não seja gestor —
--      protege tanto o fluxo atual (insert direto do JS) quanto qualquer
--      chamada futura;
--   3) cria `criar_venda()`, um caminho atômico opcional (venda + parcelas
--      + itens + totais de equipe + baixa de estoque numa transação só,
--      com o mesmo bloqueio verificado de novo — necessário porque essa
--      função roda `security definer` e portanto NÃO passa pelas policies
--      de RLS, inclusive as novas do passo 2) — corrige de quebra a sobra
--      de centavos na divisão de parcelas e as duas race conditions de
--      hoje (totais de equipe recalculados do zero, baixa de estoque
--      read-then-write);
--   4) fecha uma lacuna em `autorizacoes_venda`: hoje `autoriz_insert` não
--      restringe o campo `status`, então um vendedor mal-intencionado
--      poderia inserir a própria solicitação já com `status: 'autorizado'`
--      pelo DevTools, pulando a aprovação do gestor.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, confira no Studio (Database → Functions) que
-- `criar_venda` está com "Security: Definer".
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

-- 3) Aplica o bloqueio direto no RLS de vendas/parcelas (protege o insert
--    direto que o app já faz hoje, sem precisar trocar nada no frontend
--    imediatamente). `as restrictive` significa que esta policy só pode
--    NEGAR — ela é combinada com "E" às policies permissivas já existentes
--    (`vendas_insert`, `parcelas_insert`), nunca abre acesso novo.
drop policy if exists vendas_bloquear_inadimplente_cronico on vendas;
create policy vendas_bloquear_inadimplente_cronico on vendas
  as restrictive
  for insert to authenticated
  with check (
    public.meu_perfil() = 'gestor' or not public.cliente_bloqueado_por_atraso(cliente_id)
  );

drop policy if exists parcelas_bloquear_inadimplente_cronico on parcelas;
create policy parcelas_bloquear_inadimplente_cronico on parcelas
  as restrictive
  for insert to authenticated
  with check (
    public.meu_perfil() = 'gestor' or not public.cliente_bloqueado_por_atraso(cliente_id)
  );

-- 4) Criação atômica de venda (à vista ou a crédito) — caminho opcional,
--    recomendado, mas o insert direto continua funcionando (protegido
--    pelas policies do passo 3).
--    p_itens: jsonb array de objetos {"produto": text, "quantidade": int,
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
  v_qtd_atual int;
  v_qtd_nova int;
  v_produto_id uuid;
begin
  if v_perfil is null then
    raise exception 'Usuário não identificado ou sem perfil ativo.';
  end if;

  -- Gate de inadimplência crônica: só pra vendedor. Gestor sempre pode
  -- vender pra inadimplente sem autorização, igual ao comportamento atual.
  -- Necessário aqui além da policy do passo 3 porque esta função roda
  -- security definer (bypassa RLS).
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

  -- Itens da venda (venda_itens.quantidade é integer).
  if p_itens is not null then
    for v_item in select * from jsonb_array_elements(p_itens) loop
      insert into venda_itens (venda_id, produto, quantidade, produto_id)
      values (
        v_venda.id,
        v_item ->> 'produto',
        (v_item ->> 'quantidade')::int,
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

  -- Baixa de estoque do caminhão (caminhao_estoque.quantidade e
  -- movimentacoes_estoque.quantidade são integer): só quando é o próprio
  -- vendedor registrando (mesma condição de hoje). Lock de linha
  -- (for update) evita o read-then-write não atômico que existe hoje no JS.
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

          v_qtd_nova := greatest(0, coalesce(v_qtd_atual, 0) - (v_item ->> 'quantidade')::int);

          update caminhao_estoque
            set quantidade = v_qtd_nova, atualizado_em = now()
            where caminhao_id = v_caminhao_id and produto_id = v_produto_id;

          insert into movimentacoes_estoque
            (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
          values
            ('venda', v_produto_id, (v_item ->> 'quantidade')::int, v_caminhao_id, p_equipe_id, v_venda.id,
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

-- 5) Fecha a lacuna em autorizacoes_venda: `autoriz_insert` (já existente)
--    não restringe `status`, então esta policy restritiva garante que
--    qualquer INSERT feito por quem não é gestor só pode entrar como
--    'pendente' — a aprovação continua exigindo gestor via
--    `autoriz_update_gestor` (já existente, não mexemos nela).
drop policy if exists autorizacoes_venda_insert_apenas_pendente on autorizacoes_venda;
create policy autorizacoes_venda_insert_apenas_pendente on autorizacoes_venda
  as restrictive
  for insert to authenticated
  with check (public.meu_perfil() = 'gestor' or status = 'pendente');

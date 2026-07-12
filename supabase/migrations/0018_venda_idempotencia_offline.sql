-- ============================================================================
-- Idempotência de criar_venda() — evita duplicar venda na sincronização
-- offline.
--
-- Contexto (ver MOBILE_SETUP.md, "Limitações conhecidas" da Fase 2): o
-- vendedor pode registrar uma venda sem internet — ela fica na fila local
-- (`fila_operacoes`, tipo `venda_criar`) e o app tenta de novo sozinho
-- quando a conexão volta. Se a resposta da RPC se perder DEPOIS do servidor
-- já ter gravado a venda (ex.: rede caiu bem na hora da resposta), o app
-- não sabe que deu certo e tenta de novo — hoje isso criaria uma SEGUNDA
-- venda (com código novo, parcelas novas e uma SEGUNDA baixa de estoque do
-- caminhão), porque `criar_venda()` não tinha nenhuma forma de reconhecer
-- "essa operação específica já rodou".
--
-- Esta migration:
--   1) adiciona `vendas.idempotency_key` (uuid, opcional, único quando
--      preenchido) — o app gera um uuid ao montar os parâmetros da venda
--      (tanto no caminho online quanto no enfileiramento offline) e reusa
--      o MESMO valor em cada tentativa de sincronização daquela operação;
--   2) `criar_venda()` ganha o parâmetro opcional `p_idempotency_key`: se
--      já existir uma venda com essa chave, devolve ela direto (sem inserir
--      de novo, sem gerar parcelas/itens/baixa de estoque de novo) — só
--      então segue o fluxo normal de criação.
--
-- Retrocompatível: parâmetro novo tem default null, então RPCs antigas (sem
-- mandar p_idempotency_key) continuam funcionando exatamente como hoje —
-- só não ganham a proteção. Nada muda no comportamento pra quem manda a
-- chave (ela é opcional; venda sem chave nunca colide/retorna outra venda).
--
-- Rode este script no SQL Editor do Supabase (depois do 0017).
-- ============================================================================

alter table public.vendas add column if not exists idempotency_key uuid;

drop index if exists public.vendas_idempotency_key_key;
create unique index vendas_idempotency_key_key on public.vendas (idempotency_key)
  where idempotency_key is not null;

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
  p_itens jsonb,
  p_idempotency_key uuid default null
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

  -- Reenvio de uma operação que já rodou (retry de sincronização offline
  -- após perder a resposta original): devolve a venda já criada em vez de
  -- duplicar código, parcelas, itens, totais de equipe e baixa de estoque.
  if p_idempotency_key is not null then
    select * into v_venda from vendas where idempotency_key = p_idempotency_key;
    if found then
      return v_venda;
    end if;
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
      insert into vendas (codigo, cliente_id, vendedor_id, tipo, produto, valor, num_parcelas, entrada, observacao, equipe_id, idempotency_key)
      values (v_codigo, p_cliente_id, p_vendedor_id, p_tipo, p_produto, p_valor, p_num_parcelas, p_entrada, p_observacao, p_equipe_id, p_idempotency_key)
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
  -- total_avista = caixa (à vista cheio + entrada das vendas a crédito);
  -- total_credito = só o saldo financiado (valor - entrada) — mesmo
  -- critério de calcularTotaisEquipe() no frontend.
  if p_equipe_id is not null then
    update equipes set
      total_vendas  = coalesce(total_vendas, 0) + 1,
      total_valor   = coalesce(total_valor, 0) + p_valor,
      total_avista  = coalesce(total_avista, 0) + (case when p_tipo = 'avista' then p_valor when p_tipo = 'entrada' then coalesce(p_entrada, 0) else 0 end),
      total_credito = coalesce(total_credito, 0) + (case when p_tipo = 'entrada' then p_valor - coalesce(p_entrada, 0) else 0 end)
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

revoke all on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) from public;
grant execute on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) to authenticated;

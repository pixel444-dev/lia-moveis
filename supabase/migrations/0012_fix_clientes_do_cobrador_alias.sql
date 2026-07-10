-- ============================================================================
-- Corrige "column \"id\" does not exist" em fichas_do_ciclo() e
-- autorizar_caixa() (0009/0010), reportado pelo cobrador ao tentar abrir
-- as fichas de cobrança.
--
-- Causa: `clientes_do_cobrador()` retorna `setof uuid` — um tipo escalar,
-- não uma tabela com colunas nomeadas. Ao chamar essa função dentro de um
-- `FROM` sem alias de coluna, o Postgres nomeia a única coluna do
-- resultado igual ao nome da função (`clientes_do_cobrador`), não `id`.
-- As duas CTEs `clientes_cobrador as (select id from
-- public.clientes_do_cobrador(...))` em `fichas_do_ciclo()` e
-- `autorizar_caixa()` estavam sem o alias `as id` depois da chamada da
-- função, então o `select id` não encontrava a coluna.
--
-- Rode este script no SQL Editor do Supabase, depois da 0011.
-- Como não muda a assinatura de nenhuma das duas funções, é um simples
-- `CREATE OR REPLACE` — não precisa de DROP antes.
-- ============================================================================

create or replace function public.fichas_do_ciclo(p_caixa_id uuid, p_ciclo_chave text)
returns table (
  parcela_id uuid,
  cliente_id uuid,
  cliente_nome text,
  cliente_codigo text,
  cliente_foto_casa text,
  cliente_telefone text,
  localidade_id uuid,
  venda_id uuid,
  numero int,
  total_parcelas int,
  valor numeric,
  valor_pago numeric,
  data_vencimento date,
  data_efetiva date,
  tipo text,
  nova_venda boolean
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_perfil text := public.meu_perfil();
begin
  select * into v_caixa from caixa_cobrador where id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;

  if v_perfil = 'cobrador' then
    if v_caixa.cobrador_id is distinct from public.meu_funcionario_id() then
      raise exception 'Cobrador só pode consultar a própria caixa.';
    end if;
  elsif v_perfil <> 'gestor' then
    raise exception 'Perfil sem acesso a fichas de cobrança.';
  end if;

  return query
  with clientes_cobrador as (
    select id from public.clientes_do_cobrador(v_caixa.cobrador_id) as id
  ),
  parcelas_abertas as (
    select p.*
    from parcelas p
    join clientes_cobrador cc on cc.id = p.cliente_id
    where not p.pago and coalesce(p.status, '') <> 'devolvida'
  ),
  remarques as (
    select distinct on (parcela_id) parcela_id, data_agendada
    from visitas_agendadas
    where cobrador_id = v_caixa.cobrador_id and not concluida
    order by parcela_id, criado_em desc
  ),
  vendas_interagidas as (
    select distinct venda_id from (
      select p.venda_id
      from parcelas p
      where p.venda_id in (select pa.venda_id from parcelas_abertas pa where pa.venda_id is not null)
        and (p.pago or coalesce(p.valor_pago, 0) > 0)
      union
      select p.venda_id
      from visitas_agendadas v
      join parcelas p on p.id = v.parcela_id
      where p.venda_id in (select pa.venda_id from parcelas_abertas pa where pa.venda_id is not null)
    ) x
    where venda_id is not null
  ),
  classificadas as (
    select
      pa.id as parcela_id,
      pa.cliente_id,
      pa.venda_id,
      pa.numero,
      pa.total_parcelas,
      pa.valor,
      pa.valor_pago,
      pa.data_vencimento,
      coalesce(rq.data_agendada, pa.data_vencimento) as data_efetiva,
      case
        when rq.data_agendada is not null then 'remarcada'
        when pa.data_vencimento >= v_caixa.ciclo_inicio then 'normal'
        else 'atrasada'
      end as tipo
    from parcelas_abertas pa
    left join remarques rq on rq.parcela_id = pa.id
  )
  select
    c.parcela_id, c.cliente_id, cl.nome, cl.codigo, cl.foto_casa, cl.telefone, cl.localidade_id,
    c.venda_id, c.numero, c.total_parcelas, c.valor, c.valor_pago,
    c.data_vencimento, c.data_efetiva, c.tipo,
    (c.venda_id is not null and c.venda_id not in (select vi.venda_id from vendas_interagidas vi)) as nova_venda
  from classificadas c
  join clientes cl on cl.id = c.cliente_id
  where c.tipo = 'atrasada'
     or (
       c.data_efetiva between v_caixa.ciclo_inicio and v_caixa.ciclo_fim
       and (select cd.chave from public.ciclo_do_dia(extract(day from c.data_efetiva)::int) cd) = p_ciclo_chave
     );
end;
$$;

create or replace function public.autorizar_caixa(p_caixa_id uuid, p_saldo_entregue numeric)
returns caixa_cobrador
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_gestor_id uuid := public.meu_funcionario_id();
  v_snapshot_pendentes jsonb;
  v_snapshot_remarcados jsonb;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode autorizar prestação de contas.';
  end if;

  select * into v_caixa from caixa_cobrador where id = p_caixa_id for update;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;
  if v_caixa.status = 'aprovado' then
    raise exception 'Caixa já foi prestada.';
  end if;

  insert into movimentacoes_cobranca (ciclo_id, cobrador_id, cliente_id, tipo, valor, forma_pagamento)
  select p_caixa_id, cobrador_id, cliente_id, 'cobranca', valor_recebido, forma_pagamento
  from baixas_pendentes
  where caixa_id = p_caixa_id and status in ('pendente', 'corrigida');

  update baixas_pendentes set status = 'aprovada'
  where caixa_id = p_caixa_id and status in ('pendente', 'corrigida');

  with clientes_cobrador as (
    select id from public.clientes_do_cobrador(v_caixa.cobrador_id) as id
  ),
  parcelas_abertas as (
    select p.*
    from parcelas p
    join clientes_cobrador cc on cc.id = p.cliente_id
    where not p.pago and coalesce(p.status, '') <> 'devolvida'
  ),
  remarques as (
    select distinct on (parcela_id) parcela_id, data_agendada, motivo, observacao, criado_em
    from visitas_agendadas
    where cobrador_id = v_caixa.cobrador_id and not concluida
    order by parcela_id, criado_em desc
  ),
  classificadas as (
    select
      pa.*,
      rq.data_agendada, rq.motivo, rq.observacao,
      case
        when rq.data_agendada is not null then rq.data_agendada
        when pa.data_vencimento < current_date then current_date
        else pa.data_vencimento
      end as data_efetiva,
      (rq.parcela_id is not null and rq.criado_em >= v_caixa.ciclo_inicio) as remarcado_neste_ciclo
    from parcelas_abertas pa
    left join remarques rq on rq.parcela_id = pa.id
  )
  select
    jsonb_agg(jsonb_build_object(
      'nome', cl.nome, 'numero', c.numero, 'total', c.total_parcelas,
      'venc', c.data_vencimento, 'valor', c.valor - coalesce(c.valor_pago, 0)
    )) filter (where not c.remarcado_neste_ciclo and c.data_efetiva between v_caixa.ciclo_inicio and v_caixa.ciclo_fim),
    jsonb_agg(jsonb_build_object(
      'nome', cl.nome, 'motivo', c.motivo, 'data', c.data_agendada, 'obs', c.observacao
    )) filter (where c.remarcado_neste_ciclo)
  into v_snapshot_pendentes, v_snapshot_remarcados
  from classificadas c
  join clientes cl on cl.id = c.cliente_id;

  update caixa_cobrador set
    status = 'aprovado',
    saldo_entregue = p_saldo_entregue,
    autorizado_por = v_gestor_id,
    autorizado_em = now(),
    snapshot_pendentes = coalesce(v_snapshot_pendentes, '[]'::jsonb),
    snapshot_remarcados = coalesce(v_snapshot_remarcados, '[]'::jsonb)
  where id = p_caixa_id
  returning * into v_caixa;

  return v_caixa;
end;
$$;

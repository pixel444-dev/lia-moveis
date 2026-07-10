-- ============================================================================
-- Corrige "insert or update on table caixa_cobrador violates foreign key
-- constraint caixa_cobrador_autorizado_por_fkey" (23503) ao autorizar uma
-- prestação de contas.
--
-- Causa: `caixa_cobrador.autorizado_por` referencia `perfis(id)` (o
-- usuário autenticado, = auth.uid()) — não `funcionarios(id)` como os
-- outros campos `cobrador_id`/`responsavel_id` do sistema. `autorizar_caixa()`
-- estava gravando `meu_funcionario_id()` ali, que é um id de outra tabela
-- (`funcionarios`), violando a FK.
--
-- Confirmado rodando:
--   select kcu.column_name, ccu.table_name, ccu.column_name
--   from information_schema.table_constraints tc
--   join information_schema.key_column_usage kcu on tc.constraint_name = kcu.constraint_name
--   join information_schema.constraint_column_usage ccu on tc.constraint_name = ccu.constraint_name
--   where tc.constraint_name = 'caixa_cobrador_autorizado_por_fkey';
-- → autorizado_por referencia perfis(id).
--
-- Rode este script no SQL Editor do Supabase, depois da 0013.
-- Mesma assinatura de antes, então é um simples CREATE OR REPLACE.
-- ============================================================================

create or replace function public.autorizar_caixa(p_caixa_id uuid, p_saldo_entregue numeric)
returns caixa_cobrador
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_gestor_id uuid := auth.uid();
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

-- ============================================================================
-- Corrige "insert or update on table \"movimentacoes_cobranca\" violates
-- foreign key constraint \"movimentacoes_cobranca_ciclo_id_fkey\"" (23503)
-- ao autorizar uma prestação de contas (AUTORIZAR_CAIXA).
--
-- Causa: `autorizar_caixa()` (introduzida na 0010, mantida na 0012 e 0014)
-- gravava o id da CAIXA (`p_caixa_id`, um `caixa_cobrador.id`) na coluna
-- `movimentacoes_cobranca.ciclo_id`, baseado na suposição — documentada na
-- 0010 — de que "ciclo" seria sinônimo de "caixa" e de que não existiria uma
-- tabela de ciclos separada. A FK `movimentacoes_cobranca_ciclo_id_fkey`
-- prova o contrário em produção: `ciclo_id` NÃO referencia `caixa_cobrador`,
-- então um id de caixa nunca é um valor válido ali e o INSERT falha.
--
-- Por que só aparecia agora: o INSERT é um `INSERT ... SELECT` a partir de
-- `baixas_pendentes` com status 'pendente'/'corrigida'. Quando não há
-- nenhuma baixa de campo pendente no momento da autorização, zero linhas são
-- inseridas e a FK nunca chega a ser checada — por isso as correções
-- anteriores (0012/0014, que mexeram em outros erros) não esbarraram nisso.
-- Basta um cobrador ter registrado recebimento em campo para o fechamento
-- quebrar.
--
-- Correção: parar de gravar `ciclo_id`. As duas outras vias que escrevem em
-- `movimentacoes_cobranca` — a baixa online (`confirmarBaixa`,
-- docs/index.html) e a baixa offline (handler `baixa_parcela`,
-- docs/js/sync-handlers.js) — já inserem SEM `ciclo_id` (a coluna é anulável
-- e nenhuma parte do app lê `ciclo_id`). Deixar `ciclo_id` nulo aqui alinha
-- o ledger definitivo ao formato que essas vias já produzem e elimina a
-- violação de FK, sem perder informação: o vínculo com a caixa/ciclo continua
-- registrado nas próprias `baixas_pendentes` (que têm `caixa_id` e passam a
-- 'aprovada' logo abaixo).
--
-- Rode este script no SQL Editor do Supabase, depois da 0039.
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

  -- `ciclo_id` fica nulo de propósito: não referencia a caixa (ver cabeçalho)
  -- e nenhuma via de escrita/leitura do app o utiliza.
  insert into movimentacoes_cobranca (cobrador_id, cliente_id, tipo, valor, forma_pagamento)
  select cobrador_id, cliente_id, 'cobranca', valor_recebido, forma_pagamento
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

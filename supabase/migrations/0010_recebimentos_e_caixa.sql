-- ============================================================================
-- Recebimentos, caixa e prestação de contas — a parte que mais mexe com
-- dinheiro, movida pro backend de forma atômica.
--
-- Problemas de hoje que esta migration resolve:
--   - `confirmarRecebimento()` (docs/index.html:6820-6925) faz
--     *read-then-write* do saldo da caixa sem lock nenhum — duas baixas
--     quase simultâneas do mesmo cobrador podem se perder uma à outra.
--   - `autorizarCaixa()` (docs/index.html:7905-7954) faz um loop de
--     `await` por baixa pendente, sem transação — uma falha no meio deixa
--     o fechamento pela metade (algumas baixas aprovadas, outras não, ou
--     `caixa_cobrador` sem atualizar depois de já ter gravado o ledger).
--   - Existem hoje duas fontes de verdade paralelas pro "quanto dinheiro em
--     espécie o cobrador tem em mãos": `caixa_cobrador.saldo_esperado`
--     (mantido incrementalmente) e a soma recalculada de
--     `baixas_pendentes.valor_recebido`. As funções abaixo mantêm só a
--     primeira, sempre via UPDATE incremental dentro da mesma transação
--     que grava a baixa — vira a única fonte de verdade.
--   - O campo `visitas_agendadas.concluida` nunca era setado como `true`
--     por nenhum fluxo (campo morto) — `registrar_nao_recebi()` agora fecha
--     a remarcação anterior da mesma parcela ao criar uma nova.
--
-- Rode este script no SQL Editor do Supabase, depois da 0009.
--
-- ⚠️ Depois de rodar, confira no Studio que todas as funções novas abaixo
-- estão com "Security: Definer".
--
-- ⚠️ Mudança de fluxo no frontend que este backend exige: os comprovantes
-- (PIX, gasto, depósito) precisam ser enviados ao Storage do Supabase ANTES
-- de chamar a RPC (não depois, como é hoje) — a RPC recebe a URL já pronta
-- em `p_comprovante_url`, porque uma função SQL não consegue subir arquivo
-- pro Storage. Troque o nome do arquivo de "usa o id da linha recém-criada"
-- pra algo gerado no cliente (ex.: uuid aleatório) antes do upload.
--
-- ⚠️ O formato exato de `snapshot_pendentes`/`snapshot_remarcados` (jsonb)
-- montado em `autorizar_caixa()` é uma proposta razoável, não uma cópia
-- garantida do formato atual (não consegui confirmar o shape exato usado
-- por `verDetalheHistorico()` sem acesso ao Studio) — ajustaremos o
-- render do histórico no frontend pra casar com o shape novo.
-- ============================================================================

-- 1) Registrar recebimento (baixa pendente), atômico e com locks.
drop function if exists public.registrar_recebimento(uuid, text, numeric, text, text, text);

create function public.registrar_recebimento(
  p_parcela_id uuid,
  p_tipo text,               -- 'completo' | 'parcial'
  p_valor_recebido numeric,  -- ignorado se p_tipo = 'completo' (usa o saldo real da parcela)
  p_forma text,               -- 'dinheiro' | 'pix'
  p_observacao text,
  p_comprovante_url text
)
returns baixas_pendentes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_parcela parcelas%rowtype;
  v_caixa caixa_cobrador%rowtype;
  v_saldo_atual numeric;
  v_valor_real numeric;
  v_completo boolean;
  v_data_ciclo date;
  v_baixa baixas_pendentes%rowtype;
begin
  if public.meu_perfil() <> 'cobrador' or v_funcionario_id is null then
    raise exception 'Apenas cobrador pode registrar recebimento.';
  end if;
  if p_forma not in ('dinheiro', 'pix') then
    raise exception 'Forma de pagamento inválida.';
  end if;
  if p_forma = 'pix' and p_comprovante_url is null then
    raise exception 'Comprovante é obrigatório para recebimento via PIX.';
  end if;

  select * into v_parcela from parcelas where id = p_parcela_id for update;
  if not found then
    raise exception 'Parcela não encontrada.';
  end if;
  if v_parcela.pago then
    raise exception 'Parcela já está paga.';
  end if;

  v_saldo_atual := v_parcela.valor - coalesce(v_parcela.valor_pago, 0);
  v_completo := (p_tipo = 'completo');
  v_valor_real := case when v_completo then v_saldo_atual else p_valor_recebido end;

  if v_valor_real is null or v_valor_real <= 0 or v_valor_real > v_saldo_atual then
    raise exception 'Valor recebido inválido (deve ser maior que zero e não exceder o saldo da parcela).';
  end if;

  v_caixa := public.abrir_caixa_cobrador();

  -- mesma regra de resolverDataCobranca() (docs/index.html:6990-7001):
  -- visita não concluída mais recente > hoje (se já vencida) > vencimento.
  select data_agendada into v_data_ciclo
    from visitas_agendadas
    where parcela_id = p_parcela_id and not concluida
    order by criado_em desc
    limit 1;
  if v_data_ciclo is null then
    v_data_ciclo := case when v_parcela.data_vencimento < current_date then current_date else v_parcela.data_vencimento end;
  end if;

  insert into baixas_pendentes
    (caixa_id, parcela_id, cobrador_id, cliente_id, valor_recebido, forma_pagamento, observacao, tipo_baixa, status, data_ciclo, comprovante_pix)
  values
    (v_caixa.id, p_parcela_id, v_funcionario_id, v_parcela.cliente_id, v_valor_real, p_forma, p_observacao, p_tipo, 'pendente', v_data_ciclo,
     case when p_forma = 'pix' then p_comprovante_url else null end)
  returning * into v_baixa;

  update parcelas set
    pago = v_completo,
    valor_pago = coalesce(v_parcela.valor_pago, 0) + v_valor_real,
    forma_pagamento = p_forma,
    cobrador_id = v_funcionario_id,
    data_pagamento = case when v_completo then now() else null end,
    status = case when v_completo then 'paga' else 'aberta' end
  where id = p_parcela_id;

  if p_forma = 'dinheiro' then
    update caixa_cobrador set saldo_esperado = coalesce(saldo_esperado, 0) + v_valor_real
      where id = v_caixa.id;
  end if;

  return v_baixa;
end;
$$;

revoke all on function public.registrar_recebimento(uuid, text, numeric, text, text, text) from public;
grant execute on function public.registrar_recebimento(uuid, text, numeric, text, text, text) to authenticated;

-- 2) Registrar "não recebi" / remarcação.
drop function if exists public.registrar_nao_recebi(uuid, text, text, date);

create function public.registrar_nao_recebi(
  p_parcela_id uuid,
  p_motivo text,
  p_observacao text,
  p_data_remarcada date
)
returns visitas_agendadas
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_parcela parcelas%rowtype;
  v_visita visitas_agendadas%rowtype;
begin
  if public.meu_perfil() <> 'cobrador' or v_funcionario_id is null then
    raise exception 'Apenas cobrador pode registrar visita.';
  end if;
  if p_data_remarcada is null or p_data_remarcada < current_date + 1 then
    raise exception 'Data remarcada deve ser no mínimo amanhã.';
  end if;

  select * into v_parcela from parcelas where id = p_parcela_id;
  if not found then
    raise exception 'Parcela não encontrada.';
  end if;

  update visitas_agendadas set concluida = true
    where parcela_id = p_parcela_id and not concluida;

  insert into visitas_agendadas (cobrador_id, cliente_id, parcela_id, motivo, observacao, data_agendada, concluida)
  values (v_funcionario_id, v_parcela.cliente_id, p_parcela_id, p_motivo, p_observacao, p_data_remarcada, false)
  returning * into v_visita;

  return v_visita;
end;
$$;

revoke all on function public.registrar_nao_recebi(uuid, text, text, date) from public;
grant execute on function public.registrar_nao_recebi(uuid, text, text, date) to authenticated;

-- 3) Gasto e depósito do cobrador.
drop function if exists public.registrar_gasto(text, text, numeric, text);

create function public.registrar_gasto(
  p_categoria text,
  p_descricao text,
  p_valor numeric,
  p_comprovante_url text
)
returns movimentacoes_caixa
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_caixa caixa_cobrador%rowtype;
  v_total_alimentacao_hoje numeric;
  v_mov movimentacoes_caixa%rowtype;
begin
  if public.meu_perfil() <> 'cobrador' or v_funcionario_id is null then
    raise exception 'Apenas cobrador pode registrar gasto.';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Valor do gasto deve ser maior que zero.';
  end if;
  if coalesce(trim(p_descricao), '') = '' then
    raise exception 'Descrição do gasto é obrigatória.';
  end if;

  v_caixa := public.abrir_caixa_cobrador();

  if p_categoria = 'alimentacao' then
    select coalesce(sum(valor), 0) into v_total_alimentacao_hoje
      from movimentacoes_caixa
      where caixa_id = v_caixa.id and tipo = 'gasto' and categoria = 'alimentacao'
        and criado_em >= current_date;
    if v_total_alimentacao_hoje + p_valor > 40 then
      raise exception 'Limite diário de R$40 em alimentação excedido.';
    end if;
  elsif p_comprovante_url is null then
    raise exception 'Comprovante é obrigatório para este tipo de gasto.';
  end if;

  insert into movimentacoes_caixa (caixa_id, cobrador_id, tipo, categoria, descricao, valor, foto_comprovante)
  values (v_caixa.id, v_funcionario_id, 'gasto', p_categoria, p_descricao, p_valor, p_comprovante_url)
  returning * into v_mov;

  return v_mov;
end;
$$;

revoke all on function public.registrar_gasto(text, text, numeric, text) from public;
grant execute on function public.registrar_gasto(text, text, numeric, text) to authenticated;

drop function if exists public.registrar_deposito(numeric, text);

create function public.registrar_deposito(
  p_valor numeric,
  p_comprovante_url text
)
returns movimentacoes_caixa
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_caixa caixa_cobrador%rowtype;
  v_mov movimentacoes_caixa%rowtype;
begin
  if public.meu_perfil() <> 'cobrador' or v_funcionario_id is null then
    raise exception 'Apenas cobrador pode registrar depósito.';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Valor do depósito deve ser maior que zero.';
  end if;
  if p_comprovante_url is null then
    raise exception 'Comprovante é obrigatório para depósito.';
  end if;

  v_caixa := public.abrir_caixa_cobrador();

  insert into movimentacoes_caixa (caixa_id, cobrador_id, tipo, descricao, valor, foto_comprovante)
  values (v_caixa.id, v_funcionario_id, 'deposito', 'Depósito', p_valor, p_comprovante_url)
  returning * into v_mov;

  return v_mov;
end;
$$;

revoke all on function public.registrar_deposito(numeric, text) from public;
grant execute on function public.registrar_deposito(numeric, text) to authenticated;

-- 4) Correção e cancelamento de baixa (gestor, na prestação de contas).
drop function if exists public.corrigir_baixa(uuid, numeric, text, text);

create function public.corrigir_baixa(
  p_baixa_id uuid,
  p_valor_recebido numeric,
  p_tipo_baixa text,
  p_forma_pagamento text
)
returns baixas_pendentes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_baixa baixas_pendentes%rowtype;
  v_parcela parcelas%rowtype;
  v_delta_dinheiro numeric := 0;
  v_novo_valor_pago numeric;
  v_completo boolean;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode corrigir baixa.';
  end if;

  select * into v_baixa from baixas_pendentes where id = p_baixa_id for update;
  if not found then
    raise exception 'Baixa não encontrada.';
  end if;
  if v_baixa.status = 'aprovada' then
    raise exception 'Baixa já aprovada não pode ser corrigida.';
  end if;

  select * into v_parcela from parcelas where id = v_baixa.parcela_id for update;

  v_novo_valor_pago := coalesce(v_parcela.valor_pago, 0) - v_baixa.valor_recebido + p_valor_recebido;
  v_completo := (p_tipo_baixa = 'completo') or (v_novo_valor_pago >= v_parcela.valor);

  update parcelas set
    valor_pago = v_novo_valor_pago,
    pago = v_completo,
    status = case when v_completo then 'paga' else 'aberta' end,
    forma_pagamento = p_forma_pagamento,
    data_pagamento = case when v_completo then coalesce(data_pagamento, now()) else null end
  where id = v_parcela.id;

  if v_baixa.forma_pagamento = 'dinheiro' then
    v_delta_dinheiro := v_delta_dinheiro - v_baixa.valor_recebido;
  end if;
  if p_forma_pagamento = 'dinheiro' then
    v_delta_dinheiro := v_delta_dinheiro + p_valor_recebido;
  end if;
  if v_delta_dinheiro <> 0 then
    update caixa_cobrador set saldo_esperado = greatest(0, coalesce(saldo_esperado, 0) + v_delta_dinheiro)
      where id = v_baixa.caixa_id;
  end if;

  update baixas_pendentes set
    valor_recebido = p_valor_recebido,
    tipo_baixa = p_tipo_baixa,
    forma_pagamento = p_forma_pagamento,
    status = 'corrigida'
  where id = p_baixa_id
  returning * into v_baixa;

  return v_baixa;
end;
$$;

revoke all on function public.corrigir_baixa(uuid, numeric, text, text) from public;
grant execute on function public.corrigir_baixa(uuid, numeric, text, text) to authenticated;

drop function if exists public.cancelar_baixa_prestacao(uuid);

create function public.cancelar_baixa_prestacao(p_baixa_id uuid)
returns baixas_pendentes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_baixa baixas_pendentes%rowtype;
  v_parcela parcelas%rowtype;
  v_novo_valor_pago numeric;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode cancelar baixa.';
  end if;

  select * into v_baixa from baixas_pendentes where id = p_baixa_id for update;
  if not found then
    raise exception 'Baixa não encontrada.';
  end if;
  if v_baixa.status = 'aprovada' then
    raise exception 'Baixa já aprovada não pode ser cancelada.';
  end if;
  if v_baixa.status = 'cancelada' then
    return v_baixa;
  end if;

  select * into v_parcela from parcelas where id = v_baixa.parcela_id for update;

  v_novo_valor_pago := greatest(0, coalesce(v_parcela.valor_pago, 0) - v_baixa.valor_recebido);

  update parcelas set
    valor_pago = v_novo_valor_pago,
    pago = false,
    status = 'aberta',
    forma_pagamento = case when v_novo_valor_pago = 0 then null else forma_pagamento end,
    cobrador_id = case when v_novo_valor_pago = 0 then null else cobrador_id end,
    data_pagamento = null
  where id = v_parcela.id;

  if v_baixa.forma_pagamento = 'dinheiro' then
    update caixa_cobrador set saldo_esperado = greatest(0, coalesce(saldo_esperado, 0) - v_baixa.valor_recebido)
      where id = v_baixa.caixa_id;
  end if;

  update baixas_pendentes set status = 'cancelada' where id = p_baixa_id returning * into v_baixa;

  return v_baixa;
end;
$$;

revoke all on function public.cancelar_baixa_prestacao(uuid) from public;
grant execute on function public.cancelar_baixa_prestacao(uuid) to authenticated;

-- 5) Fechamento/autorização definitiva da caixa (prestação de contas),
--    tudo-ou-nada.
drop function if exists public.autorizar_caixa(uuid, numeric);

create function public.autorizar_caixa(p_caixa_id uuid, p_saldo_entregue numeric)
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

  insert into movimentacoes_cobranca (cobrador_id, cliente_id, tipo, valor, forma_pagamento)
  select cobrador_id, cliente_id, 'cobranca', valor_recebido, forma_pagamento
  from baixas_pendentes
  where caixa_id = p_caixa_id and status in ('pendente', 'corrigida');

  update baixas_pendentes set status = 'aprovada'
  where caixa_id = p_caixa_id and status in ('pendente', 'corrigida');

  with clientes_cobrador as (
    select c.id, c.nome
    from clientes c
    where c.cobrador_id = v_caixa.cobrador_id
    union
    select c.id, c.nome
    from clientes c
    join rotas_municipios rm on rm.municipio_id = c.municipio_id
    join rotas r on r.id = rm.rota_id and r.ativa = true and r.cobrador_id = v_caixa.cobrador_id
    where c.cobrador_id is null
  ),
  parcelas_abertas as (
    select p.*
    from parcelas p
    join clientes_cobrador cc on cc.id = p.cliente_id
    where not p.pago and coalesce(p.status, '') <> 'devolvida'
  ),
  remarques as (
    select distinct on (parcela_id) parcela_id, data_agendada, motivo
    from visitas_agendadas
    where cobrador_id = v_caixa.cobrador_id and not concluida and criado_em >= v_caixa.ciclo_inicio
    order by parcela_id, criado_em desc
  )
  select
    jsonb_agg(jsonb_build_object(
      'cliente_id', pa.cliente_id, 'cliente_nome', cc.nome, 'parcela_id', pa.id,
      'valor', pa.valor - coalesce(pa.valor_pago, 0), 'data_vencimento', pa.data_vencimento
    )) filter (where rq.parcela_id is null and pa.data_vencimento between v_caixa.ciclo_inicio and v_caixa.ciclo_fim),
    jsonb_agg(jsonb_build_object(
      'cliente_id', pa.cliente_id, 'cliente_nome', cc.nome, 'parcela_id', pa.id,
      'data_agendada', rq.data_agendada, 'motivo', rq.motivo
    )) filter (where rq.parcela_id is not null)
  into v_snapshot_pendentes, v_snapshot_remarcados
  from parcelas_abertas pa
  join clientes_cobrador cc on cc.id = pa.cliente_id
  left join remarques rq on rq.parcela_id = pa.id;

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

revoke all on function public.autorizar_caixa(uuid, numeric) from public;
grant execute on function public.autorizar_caixa(uuid, numeric) to authenticated;

-- 6) Tranca as tabelas: escrita só pelas funções acima a partir de agora.
revoke insert, update, delete on caixa_cobrador from authenticated;
revoke insert, update, delete on baixas_pendentes from authenticated;
revoke insert, update, delete on movimentacoes_caixa from authenticated;
revoke insert, update, delete on visitas_agendadas from authenticated;
revoke insert, update, delete on movimentacoes_cobranca from authenticated;

-- SELECT: cobrador só vê o que é seu; gestor vê tudo. Não sabemos os nomes
-- de policies de SELECT que já existem hoje nessas tabelas (não
-- versionadas) — depois de rodar, confira em Database → Policies que não
-- sobrou nenhuma policy antiga liberando SELECT geral pra qualquer
-- autenticado (o que tornaria esta restrição inócua).
drop policy if exists caixa_cobrador_select_proprio_ou_gestor on caixa_cobrador;
create policy caixa_cobrador_select_proprio_ou_gestor on caixa_cobrador
  for select to authenticated
  using (cobrador_id = public.meu_funcionario_id() or public.meu_perfil() = 'gestor');

drop policy if exists baixas_pendentes_select_proprio_ou_gestor on baixas_pendentes;
create policy baixas_pendentes_select_proprio_ou_gestor on baixas_pendentes
  for select to authenticated
  using (cobrador_id = public.meu_funcionario_id() or public.meu_perfil() = 'gestor');

drop policy if exists movimentacoes_caixa_select_proprio_ou_gestor on movimentacoes_caixa;
create policy movimentacoes_caixa_select_proprio_ou_gestor on movimentacoes_caixa
  for select to authenticated
  using (cobrador_id = public.meu_funcionario_id() or public.meu_perfil() = 'gestor');

drop policy if exists visitas_agendadas_select_proprio_ou_gestor on visitas_agendadas;
create policy visitas_agendadas_select_proprio_ou_gestor on visitas_agendadas
  for select to authenticated
  using (cobrador_id = public.meu_funcionario_id() or public.meu_perfil() = 'gestor');

drop policy if exists movimentacoes_cobranca_select_proprio_ou_gestor on movimentacoes_cobranca;
create policy movimentacoes_cobranca_select_proprio_ou_gestor on movimentacoes_cobranca
  for select to authenticated
  using (cobrador_id = public.meu_funcionario_id() or public.meu_perfil() = 'gestor');

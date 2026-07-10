-- ============================================================================
-- Recebimentos, caixa e prestação de contas — a parte que mais mexe com
-- dinheiro, movida pro backend de forma atômica.
--
-- ⚠️ REVISADO depois de inspecionar o schema e o RLS reais em produção.
-- Achados que mudaram o escopo desta migration em relação à primeira
-- versão:
--   - `caixa_select`, `baixa_select`, `movcx_select`, `vis_select` e
--     `movcob_select` JÁ EXISTEM e já implementam exatamente "cobrador vê
--     só o próprio, gestor vê tudo" — não recriamos essas policies aqui
--     (a versão anterior deste arquivo ia adicionar policies de SELECT
--     redundantes, coexistindo com as reais sob nomes diferentes).
--   - `baixa_update_gestor` e `movcx_update_gestor` já exigem gestor pro
--     UPDATE — então o "gap" que eu ia fechar em `movimentacoes_caixa` já
--     não existe; não mexemos no grant dessa tabela.
--   - Achado à parte: como o UPDATE de `movimentacoes_caixa` já era
--     gestor-only antes desta migration, o fluxo atual de
--     `confirmarGasto()`/`confirmarDeposito()` no app — que faz INSERT e
--     só DEPOIS faz UPDATE de `foto_comprovante` — já deveria estar
--     falhando silenciosamente pra quem é cobrador. As funções novas
--     abaixo (`registrar_gasto`/`registrar_deposito`) resolvem isso ao
--     receber a URL do comprovante já pronta, num único INSERT.
--   - `caixa_update` e `baixa_insert`/`caixa_insert` de hoje são mais
--     permissivos do que parecia à primeira vista: um cobrador pode dar
--     UPDATE em QUALQUER coluna da própria `caixa_cobrador` (inclusive
--     `status` e `saldo_entregue` — ou seja, hoje um cobrador mal-
--     intencionado pode se autoaprovar direto pelo DevTools), e o INSERT
--     de `caixa_cobrador`/`baixas_pendentes` não restringe o `status`
--     inicial. Por isso, diferente da 0008 (onde trocamos REVOKE por
--     policy cirúrgica), aqui mantemos um REVOKE — mas só nas 2 tabelas
--     onde o gap é real e só nos comandos necessários (INSERT/UPDATE, não
--     DELETE, que já é gestor-only nas duas). Isso EXIGE que o frontend
--     passe a chamar as funções abaixo antes ou junto desta migration ir
--     pra produção — sem isso, cobrador para de conseguir abrir caixa ou
--     registrar recebimento.
--
-- Rode este script no SQL Editor do Supabase, depois da 0009.
--
-- ⚠️ Depois de rodar, confira no Studio que todas as funções novas abaixo
-- estão com "Security: Definer".
--
-- ⚠️ Mudança de fluxo no frontend que este backend exige: os comprovantes
-- (PIX, gasto, depósito) precisam ser enviados ao Storage do Supabase ANTES
-- de chamar a RPC (não depois, como é hoje) — a RPC recebe a URL já pronta
-- em `p_comprovante_url`. Troque o nome do arquivo de "usa o id da linha
-- recém-criada" pra algo gerado no cliente (ex.: uuid aleatório) antes do
-- upload.
--
-- ⚠️ O formato exato de `snapshot_pendentes`/`snapshot_remarcados` (jsonb)
-- montado em `autorizar_caixa()` é uma proposta razoável, não uma cópia
-- garantida do formato atual — ajustaremos o render do histórico no
-- frontend pra casar com o shape novo.
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

  -- fecha qualquer remarque anterior em aberto da mesma parcela (o campo
  -- `concluida` nunca era setado antes — campo morto até agora).
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

-- 3) Gasto e depósito do cobrador. `movimentacoes_caixa` já tem RLS
--    adequado hoje (insert: dono ou gestor; update: só gestor) — estas
--    funções são um caminho conveniente e atômico, não uma correção de
--    segurança; não mexem em grants.
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
--    tudo-ou-nada. `movimentacoes_cobranca.ciclo_id` referencia a própria
--    caixa (confirmado no schema real: a tabela usa "ciclo" como sinônimo
--    de "caixa", não existe uma tabela `ciclos` separada).
drop function if exists public.autorizar_caixa(uuid, numeric);

create function public.autorizar_caixa(p_caixa_id uuid, p_saldo_entregue numeric)
returns caixa_cobrador
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  -- caixa_cobrador.autorizado_por referencia perfis(id) (= auth.uid(), o
  -- usuário autenticado), não funcionarios(id) como cobrador_id/
  -- responsavel_id em outras tabelas — meu_funcionario_id() aqui violava
  -- a FK.
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

  -- Shape do snapshot alinhado com o que a tela de histórico já lê hoje
  -- (docs/index.html, montarHistoricoHtml: p.nome/p.numero/p.total/p.venc/
  -- p.valor e v.nome/v.motivo/v.data/v.obs) — replica também a distinção
  -- fina que calcularPendentesRemarcados() já faz: uma parcela só entra em
  -- "remarcados" se a remarcação foi CRIADA dentro deste ciclo; se a
  -- remarcação é antiga (de um ciclo anterior) mas a data agendada cai
  -- dentro deste ciclo, ela conta como "pendente" (não duplica o
  -- "remarcados"), e o campo `venc` mostrado é sempre o vencimento
  -- original da parcela, não a data remarcada.
  with clientes_cobrador as (
    -- mesmo detalhe de clientes_do_cobrador() retornar `setof uuid`
    -- escalar — precisa do "as id" pra nomear a coluna (ver 0009).
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

revoke all on function public.autorizar_caixa(uuid, numeric) from public;
grant execute on function public.autorizar_caixa(uuid, numeric) to authenticated;

-- 6) Equivalente gestor de abrir_caixa_cobrador(): porta de
--    `salvarCaixaManual()` (docs/index.html:7167-7221), usada na tela
--    "Gerenciar caixa" pra criar ou estender manualmente a caixa de um
--    cobrador específico. Sem esta função, o REVOKE do passo 7 deixaria
--    até o gestor sem conseguir abrir/estender caixa manualmente.
drop function if exists public.gestor_abrir_ou_estender_caixa(uuid, date, date);

create function public.gestor_abrir_ou_estender_caixa(
  p_cobrador_id uuid,
  p_ciclo_inicio date,
  p_ciclo_fim date
)
returns caixa_cobrador
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode gerenciar caixa de cobrador.';
  end if;
  if p_ciclo_inicio is null or p_ciclo_fim is null then
    raise exception 'Início e fim do ciclo são obrigatórios.';
  end if;

  select * into v_caixa from caixa_cobrador
    where cobrador_id = p_cobrador_id and status = 'aberto'
    limit 1;

  if found then
    update caixa_cobrador set ciclo_inicio = p_ciclo_inicio, ciclo_fim = p_ciclo_fim
      where id = v_caixa.id
      returning * into v_caixa;
    return v_caixa;
  end if;

  begin
    insert into caixa_cobrador (cobrador_id, ciclo_inicio, ciclo_fim, status)
    values (p_cobrador_id, p_ciclo_inicio, p_ciclo_fim, 'aberto')
    returning * into v_caixa;
  exception when unique_violation then
    -- Corrida com abrir_caixa_cobrador() do próprio cobrador: atualiza a
    -- que acabou de ser criada em vez de falhar (mesmo tratamento do
    -- salvarCaixaManual() atual, linhas 7188-7196).
    update caixa_cobrador set ciclo_inicio = p_ciclo_inicio, ciclo_fim = p_ciclo_fim
      where cobrador_id = p_cobrador_id and status = 'aberto'
      returning * into v_caixa;
  end;

  return v_caixa;
end;
$$;

revoke all on function public.gestor_abrir_ou_estender_caixa(uuid, date, date) from public;
grant execute on function public.gestor_abrir_ou_estender_caixa(uuid, date, date) to authenticated;

-- 7) Tranca só as 2 tabelas onde o RLS de hoje tem um gap real de
--    autoaprovação (ver cabeçalho). DELETE não é tocado (já é gestor-only
--    nas duas, via `caixa_delete_gestor`/`baixa_delete_gestor`).
--    Nenhuma outra tabela desta migration tem grants alterados.
revoke insert, update on caixa_cobrador from authenticated;
revoke insert, update on baixas_pendentes from authenticated;

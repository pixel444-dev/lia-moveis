-- ============================================================================
-- Permite ao gestor lançar um recebimento (baixa de parcela, em dinheiro ou
-- pix) direto na caixa de um cobrador, pela tela de Prestação de contas —
-- mesmo cenário de gestor_registrar_gasto/gestor_registrar_deposito
-- (migration 0036): o gestor recebeu pessoalmente de um cliente, ou precisa
-- lançar algo que o cobrador esqueceu de registrar no app.
--
-- registrar_recebimento() (migration 0033) é cobrador-only por design — usa
-- meu_funcionario_id() como "o próprio cobrador logado" e abre/usa a
-- PRÓPRIA caixa ativa via abrir_caixa_cobrador(). Em vez de sobrecarregar
-- essa função com um branch de perfil, seguimos o mesmo padrão já usado
-- pras outras ações gestor_*: função separada, que recebe o caixa_id
-- explicitamente (não há "a própria caixa" pro gestor) e não reaplica
-- travas de uso normal do cobrador.
--
-- Diferenças em relação a registrar_recebimento():
--   - p_caixa_id explícito em vez de abrir_caixa_cobrador() — mesma trava de
--     "não lançar em caixa já aprovada" usada em
--     gestor_registrar_gasto/gestor_registrar_deposito/
--     excluir_movimentacao_caixa.
--   - cobrador_id gravado em baixas_pendentes/parcelas é o DONO da caixa
--     (v_caixa.cobrador_id), não quem está logado — senão a parcela mudaria
--     de dono pro gestor.
--   - Valida que a parcela é de um cliente deste cobrador (mesma
--     lógica de "cobrador vê só o próprio" aplicada aqui como proteção
--     contra passar o parcela_id errado — a tela só deve listar parcelas
--     da carteira do cobrador da caixa em questão).
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, confira no Studio que `gestor_registrar_recebimento`
-- está com "Security: Definer".
-- ============================================================================

create or replace function public.gestor_registrar_recebimento(
  p_caixa_id uuid,
  p_parcela_id uuid,
  p_tipo text,               -- 'completo' | 'parcial'
  p_valor_recebido numeric,  -- ignorado se p_tipo = 'completo' (usa o saldo real da parcela)
  p_forma text,              -- 'dinheiro' | 'pix'
  p_comprovante_url text
)
returns baixas_pendentes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_parcela parcelas%rowtype;
  v_saldo_atual numeric;
  v_valor_real numeric;
  v_completo boolean;
  v_data_ciclo date;
  v_baixa baixas_pendentes%rowtype;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode usar esta função.';
  end if;
  if p_forma not in ('dinheiro', 'pix') then
    raise exception 'Forma de pagamento inválida.';
  end if;
  if p_forma = 'pix' and p_comprovante_url is null then
    raise exception 'Comprovante é obrigatório para recebimento via PIX.';
  end if;

  select * into v_caixa from caixa_cobrador where id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;
  if v_caixa.status = 'aprovado' then
    raise exception 'Não é possível lançar recebimento numa caixa já aprovada.';
  end if;

  select * into v_parcela from parcelas where id = p_parcela_id for update;
  if not found then
    raise exception 'Parcela não encontrada.';
  end if;
  if v_parcela.pago then
    raise exception 'Parcela já está paga.';
  end if;
  if not exists (
    select 1 from clientes where id = v_parcela.cliente_id and cobrador_id = v_caixa.cobrador_id
  ) then
    raise exception 'Esta parcela não pertence a um cliente deste cobrador.';
  end if;

  v_saldo_atual := v_parcela.valor - coalesce(v_parcela.valor_pago, 0);
  v_completo := (p_tipo = 'completo');
  v_valor_real := case when v_completo then v_saldo_atual else p_valor_recebido end;

  if v_valor_real is null or v_valor_real <= 0 or v_valor_real > v_saldo_atual then
    raise exception 'Valor recebido inválido (deve ser maior que zero e não exceder o saldo da parcela).';
  end if;

  -- mesma regra de registrar_recebimento(): visita não concluída mais
  -- recente > hoje (se já vencida) > vencimento.
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
    (v_caixa.id, p_parcela_id, v_caixa.cobrador_id, v_parcela.cliente_id, v_valor_real, p_forma, 'Lançado pelo gestor', p_tipo, 'pendente', v_data_ciclo,
     case when p_forma = 'pix' then p_comprovante_url else null end)
  returning * into v_baixa;

  update parcelas set
    pago = v_completo,
    valor_pago = coalesce(v_parcela.valor_pago, 0) + v_valor_real,
    forma_pagamento = p_forma,
    cobrador_id = v_caixa.cobrador_id,
    data_pagamento = case when v_completo then now() else null end,
    status = case when v_completo then 'paga' else 'aberta' end,
    comprovante_pix = case when p_forma = 'pix' then p_comprovante_url else comprovante_pix end
  where id = p_parcela_id;

  if p_forma = 'dinheiro' then
    update caixa_cobrador set saldo_esperado = coalesce(saldo_esperado, 0) + v_valor_real
      where id = v_caixa.id;
  end if;

  return v_baixa;
end;
$$;

revoke all on function public.gestor_registrar_recebimento(uuid, uuid, text, numeric, text, text) from public;
grant execute on function public.gestor_registrar_recebimento(uuid, uuid, text, numeric, text, text) to authenticated;

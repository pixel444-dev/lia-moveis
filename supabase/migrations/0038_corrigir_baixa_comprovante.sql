-- ============================================================================
-- corrigir_baixa() deixava trocar dinheiro↔pix mas não tinha como anexar o
-- comprovante da correção — uma baixa corrigida pra pix ficava sem
-- comprovante pra sempre, mesmo com a tela de Prestação de contas já dando
-- baixa em espécie com o comprovante certinho.
--
-- p_comprovante_url é opcional (default null) e usa coalesce: se o gestor
-- não escolher um arquivo novo, o comprovante que a baixa já tinha
-- permanece intacto — mesma regra de "só mexe se veio algo novo" já usada
-- em movimentacoes_caixa (edição de gasto/depósito).
--
-- Precisa dropar a assinatura antiga (4 args) antes de recriar com 5: como
-- muda a lista de parâmetros, "create or replace" criaria uma sobrecarga
-- nova em vez de substituir, e aí uma chamada sem p_comprovante_url ficaria
-- ambígua entre as duas. Mesmo padrão já usado quando corrigir_baixa() foi
-- criada (migration 0010).
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

drop function if exists public.corrigir_baixa(uuid, numeric, text, text);

create function public.corrigir_baixa(
  p_baixa_id uuid,
  p_valor_recebido numeric,
  p_tipo_baixa text,
  p_forma_pagamento text,
  p_comprovante_url text default null
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
    comprovante_pix = coalesce(p_comprovante_url, comprovante_pix),
    status = 'corrigida'
  where id = p_baixa_id
  returning * into v_baixa;

  return v_baixa;
end;
$$;

revoke all on function public.corrigir_baixa(uuid, numeric, text, text, text) from public;
grant execute on function public.corrigir_baixa(uuid, numeric, text, text, text) to authenticated;

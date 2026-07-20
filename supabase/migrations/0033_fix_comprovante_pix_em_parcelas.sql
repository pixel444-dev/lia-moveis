-- ============================================================================
-- Bug real reportado em produção: "o app dos cobradores não está registrando
-- nenhum comprovante — nem PIX, nem gasto — nada chega no Supabase".
--
-- Causa raiz do lado do PIX: `registrar_recebimento()` (migration 0010)
-- grava a URL do comprovante só em `baixas_pendentes.comprovante_pix`. O
-- upload pro Storage acontece, a RPC não dá erro, o cobrador vê "Recebimento
-- registrado!" — mas todo tela que mostra "📎 Ver comprovante PIX" lê o
-- campo `comprovante_pix` direto da linha de `parcelas` (docs/index.html:
-- renderParcelasMobileUnificado, verDetalhesParcela, _htmlParcelasCobrador,
-- e a ficha unificada de cobranças) — campo que a 0010 nunca preencheu.
-- Resultado: o comprovante É enviado, mas nenhuma dessas telas jamais mostra
-- o link, dando a impressão de que "nada foi registrado".
--
-- `add column if not exists` deixa esta migration segura de rodar mesmo se
-- a coluna já existir na base real (schema anterior às migrations, criado
-- direto no Studio) ou não.
--
-- Rode este script no SQL Editor do Supabase, depois da 0032.
-- ============================================================================

alter table public.parcelas add column if not exists comprovante_pix text;

create or replace function public.registrar_recebimento(
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
    status = case when v_completo then 'paga' else 'aberta' end,
    -- ⚠️ fix: sem isto, o comprovante PIX nunca aparece em nenhuma tela que
    -- lê `parcelas.comprovante_pix` (era o único campo que faltava gravar).
    comprovante_pix = case when p_forma = 'pix' then p_comprovante_url else comprovante_pix end
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

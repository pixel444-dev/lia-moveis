-- ============================================================================
-- Dashboard: troca o filtro dos KPIs de vendas de "vendedor_id is not null"
-- para "equipe_id is not null".
--
-- Motivo: vendedor_id sozinho não é confiável — um gestor pode cadastrar uma
-- venda escolhendo o nome de um vendedor no formulário sem selecionar a
-- equipe. Já equipe_id só é preenchido automaticamente quando é o próprio
-- vendedor logado que registra a venda (o app bloqueia o vendedor de vender
-- sem estar em uma equipe ativa), então é um sinal mais confiável de "venda
-- real, feita pelo vendedor".
--
-- Rode este script no SQL Editor do Supabase (depois do 0003).
--
-- ⚠️ Mesma observação do script anterior: confira no Studio se
-- dashboard_resumo está com Security = "Definer" e, se estiver, descomente
-- a linha `-- security definer` abaixo.
-- ============================================================================

create or replace function public.dashboard_resumo(p_inicio date, p_fim date)
returns jsonb
language plpgsql
-- security definer
as $$
declare r jsonb;
begin
  if public.meu_perfil() is distinct from 'gestor' then raise exception 'Apenas gestor.'; end if;
  select jsonb_build_object(
    'recebido_periodo', coalesce((select sum(valor_pago) from parcelas where pago and data_pagamento::date between p_inicio and p_fim),0),
    'recebido_hoje',    coalesce((select sum(valor_pago) from parcelas where pago and data_pagamento::date = current_date),0),
    'em_maos',          coalesce((select sum(saldo_esperado) from caixa_cobrador where status='aberto'),0),
    'a_receber',        coalesce((select sum(valor - coalesce(valor_pago,0)) from parcelas where not pago and coalesce(status,'')<>'devolvida'),0),
    'atrasado_valor',   coalesce((select sum(valor - coalesce(valor_pago,0)) from parcelas where not pago and coalesce(status,'')<>'devolvida' and data_vencimento::date < current_date),0),
    'atrasado_clientes',(select count(distinct cliente_id) from parcelas where not pago and coalesce(status,'')<>'devolvida' and data_vencimento::date < current_date),
    'vendas_qtd',       (select count(*) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null),
    'vendas_valor',     coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null),0),
    'vendas_avista_valor',    coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null and tipo='avista'),0),
    'vendas_crediario_valor', coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null and tipo='entrada'),0)
  ) into r;
  return r;
end;
$$;

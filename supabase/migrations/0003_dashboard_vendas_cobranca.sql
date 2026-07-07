-- ============================================================================
-- Dashboard: separa métricas de Vendas (vendedores) das de Cobrança
-- (cobradores) e adiciona quebra à vista / crediário.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ IMPORTANTE antes de rodar: abra Database → Functions no Studio, clique em
-- "dashboard_resumo" (e depois em "dashboard_equipes") e veja o campo
-- "Security". Se estiver como "Definer", descomente a linha
-- `-- security definer` correspondente abaixo antes de executar — do
-- contrário a função pode parar de enxergar dados de outros usuários por
-- causa das políticas de RLS.
-- ============================================================================

-- 1) dashboard_resumo: mesma assinatura e retorno (jsonb), só muda o corpo.
--    - vendas_qtd / vendas_valor agora só contam vendas com vendedor_id
--      preenchido (exclui importação do sistema antigo e vendas cadastradas
--      pelo gestor sem vendedor vinculado).
--    - novas chaves vendas_avista_valor / vendas_crediario_valor.
--    - recebido_periodo / recebido_hoje / em_maos / a_receber / atrasado_*
--      continuam sem filtro (dívida real do cliente, independe de quem
--      cadastrou a venda).
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
    'vendas_qtd',       (select count(*) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and vendedor_id is not null),
    'vendas_valor',     coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and vendedor_id is not null),0),
    'vendas_avista_valor',    coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and vendedor_id is not null and tipo='avista'),0),
    'vendas_crediario_valor', coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and vendedor_id is not null and tipo='entrada'),0)
  ) into r;
  return r;
end;
$$;

-- 2) dashboard_equipes: muda a lista de colunas retornadas (adiciona 2), por
--    isso precisa DROP + CREATE em vez de CREATE OR REPLACE. Usa %type pra
--    não precisar adivinhar o tipo exato de equipes.id / equipes.meta.
--    Os totais vendas_qtd/vendas_valor por equipe continuam com a MESMA
--    base de dados de hoje (sem filtro de vendedor_id) — só as duas colunas
--    novas de quebra à vista/crediário foram adicionadas.
drop function if exists public.dashboard_equipes();

create function public.dashboard_equipes()
returns table(
  id equipes.id%type,
  rota text,
  chefe text,
  meta equipes.meta%type,
  vendas_qtd bigint,
  vendas_valor numeric,
  vendas_avista_valor numeric,
  vendas_crediario_valor numeric
)
language plpgsql
-- security definer
as $$
begin
  if public.meu_perfil() is distinct from 'gestor' then raise exception 'Apenas gestor.'; end if;
  return query
  select e.id, e.rota::text, f.nome::text, e.meta,
    count(v.id),
    coalesce(sum(v.valor),0),
    coalesce(sum(v.valor) filter (where v.tipo='avista'),0),
    coalesce(sum(v.valor) filter (where v.tipo='entrada'),0)
  from equipes e
  left join funcionarios f on f.id = e.chefe_id
  left join vendas v on v.equipe_id = e.id and coalesce(v.status,'')<>'devolvida'
  where coalesce(e.encerrada,false) = false
  group by e.id, e.rota, f.nome, e.meta
  order by 6 desc;
end;
$$;

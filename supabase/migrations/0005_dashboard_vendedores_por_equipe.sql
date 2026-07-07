-- ============================================================================
-- Ranking de Vendedores no dashboard: aplica a mesma regra do 0004 — só conta
-- venda que também tem equipe_id preenchido (sinal de venda registrada pelo
-- próprio vendedor, não pelo gestor escolhendo o nome dele no formulário).
--
-- Rode este script no SQL Editor do Supabase (depois do 0003 e 0004).
--
-- ⚠️ Mesma observação dos scripts anteriores: confira no Studio se
-- dashboard_vendedores está com Security = "Definer" e, se estiver,
-- descomente a linha `-- security definer` abaixo.
--
-- Usa DROP + CREATE (em vez de CREATE OR REPLACE) porque a função original
-- provavelmente tem valor padrão nos parâmetros, assim como dashboard_resumo
-- tinha — evita o erro "cannot remove parameter defaults" visto antes.
-- ============================================================================

drop function if exists public.dashboard_vendedores(date, date);

create function public.dashboard_vendedores(p_inicio date, p_fim date)
returns table(
  id funcionarios.id%type,
  nome text,
  qtd bigint,
  total numeric,
  ticket_medio numeric
)
language plpgsql
-- security definer
as $$
begin
  if public.meu_perfil() is distinct from 'gestor' then raise exception 'Apenas gestor.'; end if;
  return query
  select f.id, f.nome::text, count(v.id),
    coalesce(sum(v.valor),0),
    case when count(v.id)>0 then round(coalesce(sum(v.valor),0)/count(v.id),2) else 0 end
  from funcionarios f
  left join vendas v on v.vendedor_id=f.id
    and v.data_venda::date between p_inicio and p_fim
    and coalesce(v.status,'')<>'devolvida'
    and v.equipe_id is not null
  where f.tipo='vendedor' and coalesce(f.ativo,true)
  group by f.id, f.nome
  order by 4 desc;
end;
$$;

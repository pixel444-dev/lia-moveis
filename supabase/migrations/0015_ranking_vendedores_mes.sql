-- ============================================================================
-- Ranking de vendedores por semana + total do mês, pra aba "Ranking" (tela do
-- vendedor, mas o gestor também acessa).
--
-- Regra de privacidade: o vendedor só vê o PRÓPRIO valor em R$ vendido em
-- crediário; dos colegas, só a posição no ranking (1º, 2º, 3º...) — o valor
-- de terceiros nunca é incluído na resposta, então não dá pra "vazar" nem
-- inspecionando a rede. O gestor vê o valor de todo mundo (ele já tem essa
-- visão completa em "Desempenho").
--
-- Reaproveita a mesma regra dos scripts 0004/0005: só conta venda em
-- crediário (tipo='entrada') que também tem equipe_id preenchido (sinal de
-- venda registrada pelo próprio vendedor via uma equipe da semana, não pelo
-- gestor digitando o nome dele no formulário).
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

drop function if exists public.ranking_vendedores_mes(uuid);

create function public.ranking_vendedores_mes(p_mes_id uuid default null)
returns table(
  escopo text,           -- 'semana' | 'mes'
  semana_id uuid,        -- null quando escopo='mes'
  semana_numero int,     -- null quando escopo='mes'
  semana_inicio date,
  semana_fim date,
  funcionario_id uuid,
  nome text,
  posicao int,
  valor numeric,         -- null quando o chamador é vendedor e a linha não é a dele
  eh_voce boolean
)
language plpgsql
security definer
as $$
declare
  v_perfil text := public.meu_perfil();
  v_meu_id uuid := public.meu_funcionario_id();
  v_mes_id uuid := p_mes_id;
begin
  if v_perfil not in ('gestor', 'vendedor') then
    raise exception 'Acesso negado.';
  end if;

  if v_mes_id is null then
    select m.id into v_mes_id from meses_referencia m
      where current_date between m.data_inicio and m.data_fim
      limit 1;
  end if;

  if v_mes_id is null then
    return;
  end if;

  return query
  with semanas as (
    select s.id, s.numero, s.data_inicio, s.data_fim
    from semanas_venda s
    where s.mes_id = v_mes_id
  ),
  vendas_credito as (
    select v.vendedor_id, e.semana_id, v.valor
    from vendas v
    join equipes e on e.id = v.equipe_id
    where v.tipo = 'entrada'
      and coalesce(v.status, '') <> 'devolvida'
      and e.semana_id in (select id from semanas)
  ),
  totais_semana as (
    select s.id as semana_id, f.id as funcionario_id, f.nome::text as nome,
           coalesce(sum(vc.valor), 0) as valor
    from semanas s
    join equipes e on e.semana_id = s.id
    join equipe_membros em on em.equipe_id = e.id
    join funcionarios f on f.id = em.funcionario_id and f.tipo = 'vendedor'
    left join vendas_credito vc on vc.semana_id = s.id and vc.vendedor_id = f.id
    group by s.id, f.id, f.nome
  ),
  rank_semana as (
    select ts.semana_id, ts.funcionario_id, ts.nome, ts.valor,
           rank() over (partition by ts.semana_id order by ts.valor desc) as posicao
    from totais_semana ts
  ),
  totais_mes as (
    select ts.funcionario_id, ts.nome, sum(ts.valor) as valor
    from totais_semana ts
    group by ts.funcionario_id, ts.nome
  ),
  rank_mes as (
    select tm.funcionario_id, tm.nome, tm.valor,
           rank() over (order by tm.valor desc) as posicao
    from totais_mes tm
  ),
  resultado as (
    select 'semana'::text as escopo, rs.semana_id, s.numero as semana_numero, s.data_inicio as semana_inicio, s.data_fim as semana_fim,
           rs.funcionario_id, rs.nome, rs.posicao::int as posicao,
           case when v_perfil = 'gestor' or rs.funcionario_id = v_meu_id then rs.valor else null end as valor,
           rs.funcionario_id = v_meu_id as eh_voce
    from rank_semana rs
    join semanas s on s.id = rs.semana_id
    union all
    select 'mes'::text, null::uuid, null::int, null::date, null::date,
           rm.funcionario_id, rm.nome, rm.posicao::int,
           case when v_perfil = 'gestor' or rm.funcionario_id = v_meu_id then rm.valor else null end,
           rm.funcionario_id = v_meu_id
    from rank_mes rm
  )
  select * from resultado
  order by semana_numero nulls last, posicao;
end;
$$;

grant execute on function public.ranking_vendedores_mes(uuid) to authenticated;

-- ============================================================================
-- Nova aba do gestor: "Cobranças do mês" — visão consolidada dos ciclos de
-- cobrança de um cobrador em qualquer mês (passado, atual ou futuro), sem
-- depender de uma caixa_cobrador já ter sido aberta pro período.
--
-- Hoje a separação de fichas por ciclo (fichas_do_ciclo, migration 0009) só
-- funciona em cima de uma caixa_cobrador existente — o gestor não tem como
-- enxergar "quantas vendas o ciclo 20 de agosto vai ter pra cobrar" antes
-- (ou muito depois) de uma caixa real cobrir aquele período. As funções
-- abaixo reaproveitam a MESMA classificação de ficha de fichas_do_ciclo
-- (atrasada / remarcada / normal), só que recebendo cobrador + intervalo de
-- datas direto, em vez de ler ciclo_inicio/ciclo_fim de uma caixa:
--
--   - intervalo_ciclo_mes(ano, mes, chave): as mesmas 6 faixas fixas de
--     ciclo_do_dia (migration 0009), devolvendo o intervalo de datas
--     concreto pra um mês específico — porta server-side de
--     intervaloCicloNoMes() (docs/index.html), incluindo a virada de mês
--     dos ciclos "30" (termina no mês seguinte) e "05" (cai inteiro no mês
--     seguinte).
--   - fichas_do_periodo(cobrador, inicio, fim, chave): mesmo corpo de
--     fichas_do_ciclo, parametrizado por intervalo em vez de caixa_id.
--     Gestor-only — é uma ferramenta de acompanhamento/relatório, não a
--     tela de trabalho do cobrador (que continua em fichas_do_ciclo).
--     Diferença deliberada: fichas_do_ciclo sempre inclui as atrasadas
--     (pra elas seguirem o cobrador em qualquer ciclo que ele esteja
--     olhando na caixa aberta); aqui uma ficha pertence só ao ciclo em que
--     sua data efetiva realmente cai — faz mais sentido pra um relatório
--     onde o gestor navega por mês/ciclo livremente, inclusive períodos
--     passados.
--   - resumo_ciclos_mes(cobrador, ano, mes): os 6 ciclos do mês já com
--     contagem (vendas/parcelas/atrasadas/remarcadas) e valor em aberto,
--     pra popular os cards da tela sem precisar buscar linha a linha.
--
-- Rode este script no SQL Editor do Supabase, depois da 0029.
-- ============================================================================

-- 1) Intervalo de datas de UM ciclo dentro de um mês específico.
drop function if exists public.intervalo_ciclo_mes(int, int, text);

create function public.intervalo_ciclo_mes(p_ano int, p_mes int, p_chave text)
returns table(data_inicio date, data_fim date)
language plpgsql
immutable
as $$
declare
  v_base date := make_date(p_ano, p_mes, 1);
begin
  case p_chave
    when '10' then data_inicio := v_base + 9;  data_fim := v_base + 13;
    when '15' then data_inicio := v_base + 14; data_fim := v_base + 18;
    when '20' then data_inicio := v_base + 19; data_fim := v_base + 23;
    when '25' then data_inicio := v_base + 24; data_fim := v_base + 28;
    when '30' then data_inicio := v_base + 29; data_fim := (v_base + interval '1 month')::date + 3;
    when '05' then data_inicio := (v_base + interval '1 month')::date + 4; data_fim := (v_base + interval '1 month')::date + 8;
    else raise exception 'Chave de ciclo inválida: %', p_chave;
  end case;
  return next;
end;
$$;

grant execute on function public.intervalo_ciclo_mes(int, int, text) to authenticated;

-- 2) Fichas de um cobrador dentro de um intervalo de datas arbitrário —
--    versão "relatório" de fichas_do_ciclo, sem exigir caixa_cobrador.
drop function if exists public.fichas_do_periodo(uuid, date, date, text);

create function public.fichas_do_periodo(
  p_cobrador_id uuid,
  p_ciclo_inicio date,
  p_ciclo_fim date,
  p_ciclo_chave text
)
returns table (
  parcela_id uuid,
  cliente_id uuid,
  cliente_nome text,
  cliente_codigo text,
  cliente_foto_casa text,
  cliente_telefone text,
  localidade_id uuid,
  venda_id uuid,
  numero int,
  total_parcelas int,
  valor numeric,
  valor_pago numeric,
  data_vencimento date,
  data_efetiva date,
  tipo text,
  nova_venda boolean
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Perfil sem acesso a este relatório de cobrança.';
  end if;

  return query
  with clientes_cobrador as (
    select id from public.clientes_do_cobrador(p_cobrador_id) as id
  ),
  parcelas_abertas as (
    select p.*
    from parcelas p
    join clientes_cobrador cc on cc.id = p.cliente_id
    where not p.pago and coalesce(p.status, '') <> 'devolvida'
  ),
  remarques as (
    select distinct on (va.parcela_id) va.parcela_id, va.data_agendada
    from visitas_agendadas va
    where va.cobrador_id = p_cobrador_id and not va.concluida
    order by va.parcela_id, va.criado_em desc
  ),
  vendas_interagidas as (
    select distinct x.venda_id from (
      select p.venda_id
      from parcelas p
      where p.venda_id in (select pa.venda_id from parcelas_abertas pa where pa.venda_id is not null)
        and (p.pago or coalesce(p.valor_pago, 0) > 0)
      union
      select p.venda_id
      from visitas_agendadas v
      join parcelas p on p.id = v.parcela_id
      where p.venda_id in (select pa.venda_id from parcelas_abertas pa where pa.venda_id is not null)
    ) x
    where x.venda_id is not null
  ),
  classificadas as (
    select
      pa.id as parcela_id,
      pa.cliente_id,
      pa.venda_id,
      pa.numero,
      pa.total_parcelas,
      pa.valor,
      pa.valor_pago,
      pa.data_vencimento,
      coalesce(rq.data_agendada, pa.data_vencimento) as data_efetiva,
      case
        when rq.data_agendada is not null then 'remarcada'
        when pa.data_vencimento < current_date then 'atrasada'
        else 'normal'
      end as tipo
    from parcelas_abertas pa
    left join remarques rq on rq.parcela_id = pa.id
  )
  select
    c.parcela_id, c.cliente_id, cl.nome, cl.codigo, cl.foto_casa, cl.telefone, cl.localidade_id,
    c.venda_id, c.numero, c.total_parcelas, c.valor, c.valor_pago,
    c.data_vencimento, c.data_efetiva, c.tipo,
    (c.venda_id is not null and c.venda_id not in (select vi.venda_id from vendas_interagidas vi)) as nova_venda
  from classificadas c
  join clientes cl on cl.id = c.cliente_id
  where c.data_efetiva between p_ciclo_inicio and p_ciclo_fim
    and (select cd.chave from public.ciclo_do_dia(extract(day from c.data_efetiva)::int) cd) = p_ciclo_chave;
end;
$$;

revoke all on function public.fichas_do_periodo(uuid, date, date, text) from public;
grant execute on function public.fichas_do_periodo(uuid, date, date, text) to authenticated;

-- 3) Resumo dos 6 ciclos de um mês pra um cobrador — alimenta os cards da
--    tela "Cobranças do mês" sem precisar buscar ficha por ficha no cliente.
drop function if exists public.resumo_ciclos_mes(uuid, int, int);

create function public.resumo_ciclos_mes(p_cobrador_id uuid, p_ano int, p_mes int)
returns table (
  chave text,
  dia_inicio int,
  dia_fim int,
  data_inicio date,
  data_fim date,
  qtd_vendas int,
  qtd_parcelas int,
  qtd_atrasadas int,
  qtd_remarcadas int,
  valor_total numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_chaves text[] := array['10','15','20','25','30','05'];
  v_chave text;
  v_intervalo record;
  v_agg record;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Perfil sem acesso a este relatório de cobrança.';
  end if;

  foreach v_chave in array v_chaves loop
    select * into v_intervalo from public.intervalo_ciclo_mes(p_ano, p_mes, v_chave);

    select
      count(*)::int as total,
      count(distinct f.venda_id) filter (where f.venda_id is not null)::int as vendas,
      count(*) filter (where f.tipo = 'atrasada')::int as atrasadas,
      count(*) filter (where f.tipo = 'remarcada')::int as remarcadas,
      coalesce(sum(f.valor - coalesce(f.valor_pago, 0)), 0)::numeric as valor
    into v_agg
    from public.fichas_do_periodo(p_cobrador_id, v_intervalo.data_inicio, v_intervalo.data_fim, v_chave) f;

    chave := v_chave;
    dia_inicio := case v_chave when '10' then 10 when '15' then 15 when '20' then 20 when '25' then 25 when '30' then 30 else 5 end;
    dia_fim    := case v_chave when '10' then 14 when '15' then 19 when '20' then 24 when '25' then 29 when '30' then 4  else 9 end;
    data_inicio := v_intervalo.data_inicio;
    data_fim    := v_intervalo.data_fim;
    qtd_vendas     := v_agg.vendas;
    qtd_parcelas   := v_agg.total;
    qtd_atrasadas  := v_agg.atrasadas;
    qtd_remarcadas := v_agg.remarcadas;
    valor_total    := v_agg.valor;
    return next;
  end loop;
end;
$$;

revoke all on function public.resumo_ciclos_mes(uuid, int, int) from public;
grant execute on function public.resumo_ciclos_mes(uuid, int, int) to authenticated;

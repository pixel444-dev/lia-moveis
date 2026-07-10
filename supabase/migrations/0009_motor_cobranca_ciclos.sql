-- ============================================================================
-- Motor de ciclos de cobrança e atribuição de cobrador no backend.
--
-- ⚠️ REVISADO depois de inspecionar o schema real em produção: já existem
-- as funções `meus_clientes()` e `clientes_por_rota()` (security definer),
-- que implementam exatamente a regra de atribuição direta/rota que eu ia
-- reconstruir do zero — só que elas são "sem parâmetro" (sempre calculam
-- pra `meu_funcionario_id()`, ou seja, "meus clientes" do ponto de vista de
-- quem está chamando). Isso funciona pro cobrador ver a própria carteira,
-- mas não serve pro gestor consultar a carteira de UM cobrador específico
-- (ex.: no painel de acompanhamento ao vivo). Por isso criamos abaixo
-- `clientes_do_cobrador(p_cobrador_id)`, a versão parametrizada do mesmo
-- padrão — mesma lógica de `meus_clientes() UNION clientes_por_rota()`,
-- só que recebendo o cobrador como argumento em vez de assumir que é quem
-- está logado.
--
-- Formaliza em Postgres o resto do mecanismo que hoje só existe em JS:
--   - 6 ciclos fixos por mês (dia 10-14, 15-19, 20-24, 25-29, 30-04, 05-09),
--     hoje em `cicloDoDia()` (docs/index.html:6954-6961);
--   - classificação de fichas (nova / normal / remarcada / atrasada) por
--     ciclo, hoje calculada no cliente em `renderCicloSelecionado()`
--     (docs/index.html:5612-5749);
--   - abertura de caixa do cobrador (get-or-create do ciclo atual), hoje em
--     `obterCaixaAtiva()` (docs/index.html:7018-7056), sem nenhum lock —
--     hoje é possível (ainda que raro) duas caixas abertas em paralelo pro
--     mesmo cobrador se duas chamadas caírem ao mesmo tempo. Note também
--     que a policy real `caixa_insert` de hoje não restringe o `status` no
--     insert — a migration 0010 fecha essa lacuna revogando o INSERT
--     direto depois que `abrir_caixa_cobrador()` estiver no ar.
--
-- Rode este script no SQL Editor do Supabase, depois da 0008.
--
-- ⚠️ Depois de rodar, confira no Studio que `clientes_do_cobrador`,
-- `cobrador_do_cliente`, `fichas_do_ciclo` e `abrir_caixa_cobrador` estão
-- com "Security: Definer".
-- ============================================================================

-- 1) Ciclo do dia: mesma tabela de 6 faixas fixas do JS.
drop function if exists public.ciclo_do_dia(int);

create function public.ciclo_do_dia(p_dia int)
returns table(chave text, dia_inicio int, dia_fim int)
language plpgsql
immutable
as $$
begin
  if p_dia between 10 and 14 then chave := '10'; dia_inicio := 10; dia_fim := 14;
  elsif p_dia between 15 and 19 then chave := '15'; dia_inicio := 15; dia_fim := 19;
  elsif p_dia between 20 and 24 then chave := '20'; dia_inicio := 20; dia_fim := 24;
  elsif p_dia between 25 and 29 then chave := '25'; dia_inicio := 25; dia_fim := 29;
  elsif p_dia >= 30 or p_dia <= 4 then chave := '30'; dia_inicio := 30; dia_fim := 4;
  else chave := '05'; dia_inicio := 5; dia_fim := 9;
  end if;
  return next;
end;
$$;

grant execute on function public.ciclo_do_dia(int) to authenticated;

-- 2) Versão parametrizada de meus_clientes() ∪ clientes_por_rota(): todos
--    os clientes de UM cobrador específico (direto ou por rota), não só do
--    cobrador logado. Mesma regra, só generalizada.
drop function if exists public.clientes_do_cobrador(uuid);

create function public.clientes_do_cobrador(p_cobrador_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select id from clientes where cobrador_id = p_cobrador_id
  union
  select c.id
  from clientes c
  join rotas_municipios rm on rm.municipio_id = c.municipio_id
  join rotas r on r.id = rm.rota_id
  where c.cobrador_id is null
    and c.municipio_id is not null
    and r.cobrador_id = p_cobrador_id
    and r.ativa = true;
$$;

grant execute on function public.clientes_do_cobrador(uuid) to authenticated;

-- 3) Cobrador responsável por UM cliente: direto tem prioridade; senão,
--    cai pra rota ativa cujo conjunto de municípios cobre a cidade do
--    cliente. Retorna null se nenhuma das duas regras se aplica (cliente
--    "em limbo", mesma semântica de `clientes_em_limbo()`, já existente).
drop function if exists public.cobrador_do_cliente(uuid);

create function public.cobrador_do_cliente(p_cliente_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(
    (select c.cobrador_id from clientes c where c.id = p_cliente_id and c.cobrador_id is not null),
    (
      select r.cobrador_id
      from clientes c
      join rotas_municipios rm on rm.municipio_id = c.municipio_id
      join rotas r on r.id = rm.rota_id and r.ativa = true
      where c.id = p_cliente_id and c.cobrador_id is null
      limit 1
    )
  );
$$;

grant execute on function public.cobrador_do_cliente(uuid) to authenticated;

-- 4) Fichas de um ciclo, pra um cobrador e uma caixa específicos — porta
--    server-side de `renderCicloSelecionado()`. Recebe o id da caixa (não
--    recalcula ciclo_inicio/ciclo_fim: usa os valores já gravados na
--    própria caixa, que podem ter sido estendidos manualmente pelo gestor)
--    e a chave do ciclo sendo visualizado (relevante quando uma caixa
--    cobre mais de um ciclo).
--
--    Classificação (campo `tipo`, igual ao JS):
--      'atrasada'  — vencimento antes do início da caixa; SEMPRE aparece,
--                    não importa a chave de ciclo pedida.
--      'remarcada' — tem visita agendada não concluída; só aparece se a
--                    data remarcada cair dentro da caixa E no ciclo pedido.
--      'normal'    — vencimento dentro da caixa; só aparece se cair no
--                    ciclo pedido.
--    Campo `nova_venda` é independente do `tipo`: true quando nenhuma
--    parcela da venda foi paga (nem parcial) e nenhuma visita foi
--    registrada pra nenhuma parcela da venda ainda.
drop function if exists public.fichas_do_ciclo(uuid, text);

create function public.fichas_do_ciclo(p_caixa_id uuid, p_ciclo_chave text)
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
declare
  v_caixa caixa_cobrador%rowtype;
  v_perfil text := public.meu_perfil();
begin
  select * into v_caixa from caixa_cobrador where id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;

  if v_perfil = 'cobrador' then
    if v_caixa.cobrador_id is distinct from public.meu_funcionario_id() then
      raise exception 'Cobrador só pode consultar a própria caixa.';
    end if;
  elsif v_perfil <> 'gestor' then
    raise exception 'Perfil sem acesso a fichas de cobrança.';
  end if;

  return query
  with clientes_cobrador as (
    select id from public.clientes_do_cobrador(v_caixa.cobrador_id)
  ),
  parcelas_abertas as (
    select p.*
    from parcelas p
    join clientes_cobrador cc on cc.id = p.cliente_id
    where not p.pago and coalesce(p.status, '') <> 'devolvida'
  ),
  remarques as (
    select distinct on (parcela_id) parcela_id, data_agendada
    from visitas_agendadas
    where cobrador_id = v_caixa.cobrador_id and not concluida
    order by parcela_id, criado_em desc
  ),
  vendas_interagidas as (
    select distinct venda_id from (
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
    where venda_id is not null
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
        when pa.data_vencimento >= v_caixa.ciclo_inicio then 'normal'
        else 'atrasada'
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
  where c.tipo = 'atrasada'
     or (
       c.data_efetiva between v_caixa.ciclo_inicio and v_caixa.ciclo_fim
       and (select cd.chave from public.ciclo_do_dia(extract(day from c.data_efetiva)::int) cd) = p_ciclo_chave
     );
end;
$$;

grant execute on function public.fichas_do_ciclo(uuid, text) to authenticated;

-- 5) Abertura atômica da caixa do cobrador (get-or-create). Um índice único
--    parcial garante, a nível de banco, que nunca existam duas caixas
--    'aberto' pro mesmo cobrador ao mesmo tempo — mesmo sob concorrência.
create unique index if not exists caixa_cobrador_um_aberto_por_cobrador
  on caixa_cobrador (cobrador_id)
  where status = 'aberto';

drop function if exists public.abrir_caixa_cobrador();

create function public.abrir_caixa_cobrador()
returns caixa_cobrador
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_caixa caixa_cobrador%rowtype;
  v_hoje date := current_date;
  v_dia int := extract(day from v_hoje)::int;
  v_ciclo record;
  v_inicio date;
  v_fim date;
  v_mes_base date := date_trunc('month', v_hoje)::date;
begin
  if v_funcionario_id is null or public.meu_perfil() <> 'cobrador' then
    raise exception 'Apenas cobrador pode abrir a própria caixa.';
  end if;

  select * into v_caixa from caixa_cobrador
    where cobrador_id = v_funcionario_id and status = 'aberto'
    limit 1;
  if found then
    return v_caixa;
  end if;

  select * into v_ciclo from public.ciclo_do_dia(v_dia);

  if v_ciclo.chave = '30' then
    if v_dia <= 4 then
      v_inicio := (v_mes_base - interval '1 month')::date + 29;
      v_fim := v_mes_base + 3;
    else
      v_inicio := v_mes_base + 29;
      v_fim := (v_mes_base + interval '1 month')::date + 3;
    end if;
  else
    v_inicio := v_mes_base + (v_ciclo.dia_inicio - 1);
    v_fim := v_mes_base + (v_ciclo.dia_fim - 1);
  end if;

  begin
    insert into caixa_cobrador (cobrador_id, ciclo_inicio, ciclo_fim, status)
    values (v_funcionario_id, v_inicio, v_fim, 'aberto')
    returning * into v_caixa;
  exception when unique_violation then
    -- Perdeu a corrida pro índice único acima: outra chamada concorrente
    -- já criou a caixa. Só busca e devolve a que já existe.
    select * into v_caixa from caixa_cobrador
      where cobrador_id = v_funcionario_id and status = 'aberto'
      limit 1;
  end;

  return v_caixa;
end;
$$;

revoke all on function public.abrir_caixa_cobrador() from public;
grant execute on function public.abrir_caixa_cobrador() to authenticated;

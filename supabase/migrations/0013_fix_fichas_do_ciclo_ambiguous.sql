-- ============================================================================
-- Corrige "column reference \"parcela_id\" is ambiguous" em
-- fichas_do_ciclo(), reportado pelo cobrador logo depois da 0012.
--
-- Causa: `fichas_do_ciclo` usa `RETURNS TABLE(parcela_id uuid, venda_id
-- uuid, ...)`. Esse formato faz o Postgres declarar `parcela_id`,
-- `venda_id` etc. como variáveis da função (equivalente a parâmetros OUT)
-- — então qualquer referência a essas colunas DENTRO do corpo da função
-- sem qualificar com o alias da tabela (ex.: `parcela_id` solto em vez de
-- `va.parcela_id`) fica ambígua entre "a variável da função" e "a coluna
-- da tabela", e o Postgres recusa a rodar.
--
-- As CTEs `remarques` e `vendas_interagidas` tinham `parcela_id`/`venda_id`
-- soltos (sem alias). Esta migration qualifica todos.
--
-- Rode este script no SQL Editor do Supabase, depois da 0012.
-- Mesma assinatura de antes, então é um simples CREATE OR REPLACE.
-- ============================================================================

create or replace function public.fichas_do_ciclo(p_caixa_id uuid, p_ciclo_chave text)
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
    select id from public.clientes_do_cobrador(v_caixa.cobrador_id) as id
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
    where va.cobrador_id = v_caixa.cobrador_id and not va.concluida
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

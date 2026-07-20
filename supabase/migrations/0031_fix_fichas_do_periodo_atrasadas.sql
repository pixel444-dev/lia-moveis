-- ============================================================================
-- Corrige fichas_do_periodo() (migration 0030): a tela "Cobranças do mês"
-- do gestor não batia com o que o cobrador via de verdade no próprio app.
--
-- Causa: fichas_do_ciclo() (a função que o cobrador usa) sempre inclui as
-- parcelas atrasadas, não importa qual ciclo esteja selecionado — é assim
-- que o cobrador nunca perde de vista uma cobrança vencida, mesmo navegando
-- entre ciclos dentro da caixa aberta. fichas_do_periodo() tinha sido
-- escrita deliberadamente diferente: prendia cada parcela atrasada só ao
-- ciclo/mês em que ela originalmente venceu, então "quantas vendas o ciclo
-- X tem pra cobrar" no relatório do gestor ficava menor do que o cobrador
-- realmente via ao abrir aquele ciclo — as atrasadas de meses anteriores
-- simplesmente não apareciam.
--
-- Corrigido: mesma regra de fichas_do_ciclo (`c.tipo = 'atrasada' or (...)`).
-- Consequência esperada (não é bug): como uma atrasada não depende do ciclo
-- pedido, ela aparece repetida nos 6 cards do mês na tela do gestor — é o
-- reflexo correto de "essa cobrança vai aparecer pro cobrador não importa
-- qual desses ciclos ele abrir". qtd_atrasadas já é exibido separado do
-- resto na tela (badge próprio), então não deveria causar confusão.
--
-- Rode este script no SQL Editor do Supabase, depois da 0030.
-- Mesma assinatura de antes, então é um simples CREATE OR REPLACE.
-- ============================================================================

create or replace function public.fichas_do_periodo(
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
  where c.tipo = 'atrasada'
     or (
       c.data_efetiva between p_ciclo_inicio and p_ciclo_fim
       and (select cd.chave from public.ciclo_do_dia(extract(day from c.data_efetiva)::int) cd) = p_ciclo_chave
     );
end;
$$;

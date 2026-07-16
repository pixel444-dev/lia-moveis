-- ============================================================================
-- Enriquece a notificação de autorização pendente pro gestor: hoje só
-- mostrava um badge de tipo + o código de 6 dígitos + hora. Passa a mostrar
-- o vendedor que pediu, a data e hora completa, e — pra inadimplente — o
-- cliente (nome e código) e quantas parcelas em atraso.
--
-- O vendedor e o cliente são resolvidos no momento da exibição (join com
-- funcionarios/clientes, feito no app) — não precisam de coluna nova aqui,
-- já que são só nomes/ids que já existem. O que precisa ser gravado JUNTO
-- com a solicitação é a contagem de parcelas em atraso: é um retrato de
-- "por que o vendedor pediu isso", calculado no SERVIDOR (não confia num
-- número que o app do vendedor computou) na hora exata do pedido — se
-- ficasse recalculando toda vez que o gestor olha a lista, o número podia
-- mudar no meio da decisão (ex.: cliente pagou uma parcela nesse meio
-- tempo) e confundir mais do que ajudar.
--
-- Rode este script no SQL Editor do Supabase (depois do 0021).
-- ============================================================================

alter table public.autorizacoes_venda add column if not exists qtd_atrasadas int;
alter table public.autorizacoes_venda add column if not exists valor_atrasado numeric;

create or replace function public.solicitar_autorizacao_venda(
  p_tipo text,
  p_cliente_id uuid,
  p_equipe_id uuid,
  p_descricao text
)
returns public.autorizacoes_venda
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_vendedor_id uuid := public.meu_funcionario_id();
  v_codigo text;
  v_qtd_atrasadas int;
  v_valor_atrasado numeric;
  v_existente autorizacoes_venda%rowtype;
  v_nova autorizacoes_venda%rowtype;
begin
  if v_perfil <> 'vendedor' then
    raise exception 'Apenas vendedores solicitam autorização de venda.';
  end if;
  if p_tipo not in ('inadimplente', 'sem_cpf') then
    raise exception 'Tipo de autorização inválido: %', p_tipo;
  end if;
  if p_tipo = 'inadimplente' and p_cliente_id is null then
    raise exception 'Cliente é obrigatório para autorização de inadimplente.';
  end if;

  select * into v_existente from autorizacoes_venda
    where vendedor_id = v_vendedor_id
      and tipo = p_tipo
      and (p_tipo <> 'inadimplente' or cliente_id = p_cliente_id)
      and status in ('pendente', 'autorizado')
      and consumido_em is null
    order by criado_em desc
    limit 1;
  if found then
    return v_existente;
  end if;

  -- Mesma janela de 30 dias de cliente_bloqueado_por_atraso() — a
  -- notificação do gestor tem que descrever exatamente a mesma dívida que
  -- está bloqueando a venda, nunca um número diferente.
  if p_tipo = 'inadimplente' then
    select count(*), coalesce(sum(valor - coalesce(valor_pago, 0)), 0)
      into v_qtd_atrasadas, v_valor_atrasado
      from parcelas
      where cliente_id = p_cliente_id
        and not pago
        and coalesce(status, '') <> 'devolvida'
        and data_vencimento <= current_date - interval '30 days';
  end if;

  v_codigo := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

  begin
    insert into autorizacoes_venda (codigo, vendedor_id, equipe_id, status, tipo, cliente_id, descricao, qtd_atrasadas, valor_atrasado)
    values (v_codigo, v_vendedor_id, p_equipe_id, 'pendente', p_tipo, p_cliente_id, p_descricao, v_qtd_atrasadas, v_valor_atrasado)
    returning * into v_nova;
  exception when unique_violation then
    select * into v_nova from autorizacoes_venda
      where vendedor_id = v_vendedor_id
        and tipo = p_tipo
        and (p_tipo <> 'inadimplente' or cliente_id = p_cliente_id)
        and status in ('pendente', 'autorizado')
        and consumido_em is null
      order by criado_em desc
      limit 1;
  end;

  return v_nova;
end;
$$;

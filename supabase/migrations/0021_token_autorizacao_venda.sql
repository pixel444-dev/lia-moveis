-- ============================================================================
-- Reformula o sistema de autorização de venda (inadimplente + sem CPF).
--
-- Problemas do sistema atual (relatados em campo):
--   1) Se o vendedor clicar "pedir autorização" várias vezes, cada clique cria
--      uma linha nova em autorizacoes_venda — elas ficam acumulando.
--   2) O estado de "aguardando autorização" só existe na memória do
--      JavaScript (setInterval + variável). Se o vendedor sai do app (ex.:
--      pra ligar pro escritório avisando que pediu) e volta, esse estado se
--      perde — mesmo que o gestor já tenha autorizado, o vendedor precisa
--      pedir tudo de novo.
--   3) Bug real encontrado durante esta reformulação: cliente_bloqueado_por_
--      atraso() nunca soube nada sobre autorizacoes_venda — ela só olha
--      parcela em atraso. Ou seja, mesmo depois do gestor clicar "Autorizar",
--      a chamada de criar_venda() pro cliente inadimplente continuava
--      bloqueada de qualquer jeito. A "autorização" de hoje não desbloqueia
--      nada de verdade no banco.
--
-- Solução: a linha aprovada em autorizacoes_venda VIRA o token. Uma vez
-- autorizada, ela fica válida (consumido_em is null) até ser efetivamente
-- usada — o app redescobre esse estado consultando o banco (nunca mais só
-- memória), e tanto criar_venda() quanto o cadastro de cliente sem CPF
-- passam a checar e CONSUMIR esse token de verdade.
--
-- Rode este script no SQL Editor do Supabase (depois do 0020).
-- ============================================================================

-- 1) Colunas novas: consumido_em é a fonte da verdade de "este token ainda
--    vale" (nunca expira sozinho — só vira inválido quando usado, ou quando
--    negado). venda_id é só rastro de auditoria (qual venda usou o token do
--    inadimplente); fica null no caso de sem_cpf, onde o consumo acontece no
--    cadastro do cliente, antes de qualquer venda existir.
alter table public.autorizacoes_venda add column if not exists consumido_em timestamptz;
alter table public.autorizacoes_venda add column if not exists venda_id uuid references public.vendas(id);

-- 2) Nunca mais de uma solicitação PENDENTE acumulando pro mesmo vendedor
--    (+cliente, no caso de inadimplente). Índice único parcial — garantido
--    pelo banco, não só por uma checagem no app que um clique duplo rápido
--    poderia furar.
drop index if exists public.autorizacoes_venda_pendente_inadimplente_uk;
create unique index autorizacoes_venda_pendente_inadimplente_uk
  on public.autorizacoes_venda (vendedor_id, cliente_id)
  where status = 'pendente' and tipo = 'inadimplente';

drop index if exists public.autorizacoes_venda_pendente_semcpf_uk;
create unique index autorizacoes_venda_pendente_semcpf_uk
  on public.autorizacoes_venda (vendedor_id)
  where status = 'pendente' and tipo = 'sem_cpf';

-- 3) Solicitar autorização agora é idempotente: se já existe uma pendente ou
--    autorizada-mas-não-consumida pro mesmo vendedor (+cliente), devolve ela
--    em vez de criar outra. É a mesma linha que o app vai voltar a encontrar
--    depois de fechado e reaberto — não existe mais "esquecer" o pedido.
drop function if exists public.solicitar_autorizacao_venda(text, uuid, uuid, text);

create function public.solicitar_autorizacao_venda(
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

  v_codigo := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

  begin
    insert into autorizacoes_venda (codigo, vendedor_id, equipe_id, status, tipo, cliente_id, descricao)
    values (v_codigo, v_vendedor_id, p_equipe_id, 'pendente', p_tipo, p_cliente_id, p_descricao)
    returning * into v_nova;
  exception when unique_violation then
    -- corrida rara: duas solicitações praticamente simultâneas (ex.: duplo
    -- toque). O índice único barrou a segunda — devolve a que já existe.
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

revoke all on function public.solicitar_autorizacao_venda(text, uuid, uuid, text) from public;
grant execute on function public.solicitar_autorizacao_venda(text, uuid, uuid, text) to authenticated;

-- 4) Consulta o token ativo (pendente ou autorizado-não-consumido) pro
--    vendedor logado — é isso que o app chama toda vez que chega numa tela
--    que precisaria bloquear, ANTES de mostrar o botão de pedir autorização.
--    security definer pelo mesmo motivo do solicitar: não depende de RLS
--    específica de leitura em autorizacoes_venda pro vendedor enxergar só
--    o próprio pedido por vendedor_id/tipo (sem precisar já saber o id).
drop function if exists public.verificar_autorizacao_venda(text, uuid);

create function public.verificar_autorizacao_venda(p_tipo text, p_cliente_id uuid)
returns public.autorizacoes_venda
language sql
stable
security definer
set search_path = public, extensions
as $$
  select *
  from autorizacoes_venda
  where vendedor_id = public.meu_funcionario_id()
    and tipo = p_tipo
    and (p_tipo <> 'inadimplente' or cliente_id = p_cliente_id)
    and status in ('pendente', 'autorizado')
    and consumido_em is null
  order by criado_em desc
  limit 1;
$$;

revoke all on function public.verificar_autorizacao_venda(text, uuid) from public;
grant execute on function public.verificar_autorizacao_venda(text, uuid) to authenticated;

-- 5) criar_venda() passa a reconhecer e CONSUMIR o token do inadimplente —
--    até aqui, autorizar não desbloqueava nada de verdade. Mesma assinatura
--    do 0018 (só o corpo muda).
create or replace function public.criar_venda(
  p_cliente_id uuid,
  p_vendedor_id uuid,
  p_equipe_id uuid,
  p_tipo text,
  p_produto text,
  p_valor numeric,
  p_num_parcelas int,
  p_entrada numeric,
  p_data_primeira_parcela date,
  p_observacao text,
  p_itens jsonb,
  p_idempotency_key uuid default null
)
returns vendas
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_venda vendas%rowtype;
  v_codigo text;
  v_tentativas int := 0;
  v_saldo numeric;
  v_valor_parcela numeric;
  v_item jsonb;
  v_caminhao_id uuid;
  v_qtd_atual int;
  v_qtd_nova int;
  v_produto_id uuid;
  v_autorizacao_id uuid;
begin
  if v_perfil is null then
    raise exception 'Usuário não identificado ou sem perfil ativo.';
  end if;

  if p_idempotency_key is not null then
    select * into v_venda from vendas where idempotency_key = p_idempotency_key;
    if found then
      return v_venda;
    end if;
  end if;

  -- Gate de inadimplência crônica: só pra vendedor. Uma autorização do
  -- gestor ainda não usada (consumido_em is null) libera esta venda
  -- específica e é consumida na hora — não vale pra uma segunda venda
  -- futura, que precisaria de uma nova autorização.
  if v_perfil = 'vendedor' and public.cliente_bloqueado_por_atraso(p_cliente_id) then
    select id into v_autorizacao_id from autorizacoes_venda
      where vendedor_id = public.meu_funcionario_id()
        and tipo = 'inadimplente'
        and cliente_id = p_cliente_id
        and status = 'autorizado'
        and consumido_em is null
      order by criado_em desc
      limit 1;
    if v_autorizacao_id is null then
      raise exception 'Cliente com atraso de mais de 1 mês. Solicite autorização do gestor antes de vender.';
    end if;
  end if;

  loop
    v_tentativas := v_tentativas + 1;
    v_codigo := public.proximo_codigo_venda();
    begin
      insert into vendas (codigo, cliente_id, vendedor_id, tipo, produto, valor, num_parcelas, entrada, observacao, equipe_id, idempotency_key)
      values (v_codigo, p_cliente_id, p_vendedor_id, p_tipo, p_produto, p_valor, p_num_parcelas, p_entrada, p_observacao, p_equipe_id, p_idempotency_key)
      returning * into v_venda;
      exit;
    exception when unique_violation then
      if v_tentativas >= 3 then
        raise exception 'Não foi possível gerar um código de venda único após % tentativas.', v_tentativas;
      end if;
    end;
  end loop;

  if v_autorizacao_id is not null then
    update autorizacoes_venda set consumido_em = now(), venda_id = v_venda.id where id = v_autorizacao_id;
  end if;

  if p_tipo = 'entrada' then
    v_saldo := p_valor - coalesce(p_entrada, 0);
    v_valor_parcela := round(v_saldo / p_num_parcelas, 2);

    insert into parcelas (venda_id, cliente_id, numero, total_parcelas, valor, data_vencimento, pago, status, cobrador_id)
    select
      v_venda.id,
      p_cliente_id,
      gs,
      p_num_parcelas,
      case when gs = p_num_parcelas
           then v_saldo - v_valor_parcela * (p_num_parcelas - 1)
           else v_valor_parcela
      end,
      public.add_months_like_js(p_data_primeira_parcela, gs - 1),
      false,
      'aberta',
      null
    from generate_series(1, p_num_parcelas) as gs;
  end if;

  if p_itens is not null then
    for v_item in select * from jsonb_array_elements(p_itens) loop
      insert into venda_itens (venda_id, produto, quantidade, produto_id)
      values (
        v_venda.id,
        v_item ->> 'produto',
        (v_item ->> 'quantidade')::int,
        nullif(v_item ->> 'produto_id', '')::uuid
      );
    end loop;
  end if;

  if p_equipe_id is not null then
    update equipes set
      total_vendas  = coalesce(total_vendas, 0) + 1,
      total_valor   = coalesce(total_valor, 0) + p_valor,
      total_avista  = coalesce(total_avista, 0) + (case when p_tipo = 'avista' then p_valor when p_tipo = 'entrada' then coalesce(p_entrada, 0) else 0 end),
      total_credito = coalesce(total_credito, 0) + (case when p_tipo = 'entrada' then p_valor - coalesce(p_entrada, 0) else 0 end)
    where id = p_equipe_id;
  end if;

  if v_perfil = 'vendedor' and p_itens is not null and p_equipe_id is not null then
    select caminhao_id into v_caminhao_id from equipes where id = p_equipe_id;
    if v_caminhao_id is not null then
      for v_item in select * from jsonb_array_elements(p_itens) loop
        v_produto_id := nullif(v_item ->> 'produto_id', '')::uuid;
        if v_produto_id is not null then
          select quantidade into v_qtd_atual
            from caminhao_estoque
            where caminhao_id = v_caminhao_id and produto_id = v_produto_id
            for update;

          v_qtd_nova := greatest(0, coalesce(v_qtd_atual, 0) - (v_item ->> 'quantidade')::int);

          update caminhao_estoque
            set quantidade = v_qtd_nova, atualizado_em = now()
            where caminhao_id = v_caminhao_id and produto_id = v_produto_id;

          insert into movimentacoes_estoque
            (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
          values
            ('venda', v_produto_id, (v_item ->> 'quantidade')::int, v_caminhao_id, p_equipe_id, v_venda.id,
             public.meu_funcionario_id(), 'Venda ' || v_venda.codigo);
        end if;
      end loop;
    end if;
  end if;

  return v_venda;
end;
$$;

revoke all on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) from public;
grant execute on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) to authenticated;

-- 6) Trava real pro cadastro de cliente SEM CPF: hoje não existia nenhuma —
--    era só uma etapa visual no app, nada impedia um insert direto com CPF
--    em branco. Trigger BEFORE INSERT protege o insert direto que o app já
--    faz hoje (mesmo padrão de comentário usado em vendas_bloquear_
--    inadimplente_cronico, migration 0008): só entra em ação quando o CPF
--    vem vazio; gestor sempre pode; vendedor precisa de um token
--    autorizado-e-não-consumido, que é consumido aqui mesmo, na hora do
--    cadastro (o consumo não espera a venda, que ainda nem existe nesse
--    ponto do fluxo).
create or replace function public.verificar_cliente_sem_cpf()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_autorizacao_id uuid;
begin
  if coalesce(NEW.cpf, '') <> '' then
    return NEW;
  end if;
  if public.meu_perfil() = 'gestor' then
    return NEW;
  end if;

  select id into v_autorizacao_id from autorizacoes_venda
    where vendedor_id = public.meu_funcionario_id()
      and tipo = 'sem_cpf'
      and status = 'autorizado'
      and consumido_em is null
    order by criado_em desc
    limit 1;

  if v_autorizacao_id is null then
    raise exception 'CPF obrigatório. Solicite autorização do gestor para cadastrar cliente sem CPF.';
  end if;

  update autorizacoes_venda set consumido_em = now() where id = v_autorizacao_id;
  return NEW;
end;
$$;

drop trigger if exists trg_verificar_cliente_sem_cpf on public.clientes;
create trigger trg_verificar_cliente_sem_cpf
  before insert on public.clientes
  for each row execute function public.verificar_cliente_sem_cpf();

-- ============================================================================
-- Estoque "mesclado" entre equipes que viajam juntas.
--
-- Problema relatado em campo: às vezes dois (ou mais) caminhões saem juntos
-- na mesma viagem, e um vendedor pega um móvel do caminhão da outra equipe
-- (e vice-versa). Hoje isso não é refletido no sistema — o vendedor em campo
-- não consegue registrar essa movimentação, e depende do escritório corrigir
-- manualmente o estoque de cada caminhão depois.
--
-- Solução: no cadastro/edição da equipe, o gestor pode marcar quais outras
-- equipes estão "viajando junto" nesta viagem (equipes.grupo_id em comum).
-- Enquanto o vínculo existir, a venda de uma equipe do grupo pode ser
-- atendida pelo estoque de qualquer caminhão do grupo — baixa primeiro do
-- próprio caminhão e completa o restante nos caminhões parceiros. O gestor
-- concede o vínculo editando a equipe e selecionando a(s) parceira(s); revoga
-- do mesmo jeito, apenas desmarcando — não existe uma ação "revogar"
-- separada, o estado do grupo é sempre o que está salvo na equipe agora.
--
-- Equipes sem grupo (grupo_id nulo — o padrão de todas as equipes já
-- existentes) continuam se comportando exatamente como hoje.
--
-- Rode este script no SQL Editor do Supabase (depois do 0027).
-- ============================================================================

-- 1) Coluna de agrupamento. Nula por padrão — nenhuma equipe existente muda
--    de comportamento até o gestor associar alguma explicitamente.
alter table public.equipes add column if not exists grupo_id uuid;

create index if not exists idx_equipes_grupo_id
  on public.equipes (grupo_id)
  where grupo_id is not null;

-- 2) Função chamada pelo cadastro/edição de equipe para juntar ou separar
--    equipes de um grupo. Reaproveita o grupo_id já existente se algum dos
--    envolvidos já tiver um; cria um novo se nenhum tiver. Quem sai da lista
--    de parceiras é removido do grupo antigo. Um grupo que sobra com um só
--    membro é dissolvido (grupo de uma equipe só não significa nada).
--    security definer (mesmo padrão das outras funções de escrita deste
--    sistema) — só gestor pode chamar.
drop function if exists public.sincronizar_grupo_equipe(uuid, uuid[]);

create function public.sincronizar_grupo_equipe(
  p_equipe_id uuid,
  p_parceiros uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_grupo_antigo uuid;
  v_grupo_id uuid;
  v_membros uuid[];
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas o gestor pode agrupar equipes.';
  end if;

  select grupo_id into v_grupo_antigo from equipes where id = p_equipe_id;

  if p_parceiros is null then
    p_parceiros := array[]::uuid[];
  end if;
  v_membros := array(select distinct x from unnest(p_parceiros) x where x is not null and x <> p_equipe_id);
  v_membros := array_append(v_membros, p_equipe_id);

  if array_length(v_membros, 1) <= 1 then
    -- Nenhuma parceira selecionada: sai de qualquer grupo em que estivesse.
    update equipes set grupo_id = null where id = p_equipe_id;
  else
    select grupo_id into v_grupo_id
      from equipes
      where id = any(v_membros) and grupo_id is not null
      limit 1;

    if v_grupo_id is null then
      v_grupo_id := gen_random_uuid();
    end if;

    -- Quem estava no grupo antigo desta equipe mas não está na nova lista de
    -- parceiras sai do grupo.
    if v_grupo_antigo is not null then
      update equipes
        set grupo_id = null
        where grupo_id = v_grupo_antigo
          and id <> all(v_membros);
    end if;

    update equipes set grupo_id = v_grupo_id where id = any(v_membros);
  end if;

  -- Dissolve qualquer grupo (o que essa equipe deixou incluído) que tenha
  -- sobrado com um único membro.
  update equipes e
    set grupo_id = null
    where e.grupo_id is not null
      and (select count(*) from equipes e2 where e2.grupo_id = e.grupo_id) = 1;
end;
$$;

revoke all on function public.sincronizar_grupo_equipe(uuid, uuid[]) from public;
grant execute on function public.sincronizar_grupo_equipe(uuid, uuid[]) to authenticated;

-- 3) criar_venda() passa a reconhecer o grupo: se a equipe vendedora estiver
--    em um grupo e o próprio caminhão não tiver saldo suficiente, completa a
--    baixa nos caminhões parceiros (o de maior saldo primeiro). Equipes sem
--    grupo (grupo_id nulo) mantêm o comportamento idêntico ao de antes.
--    Mesma assinatura do 0021 (só o corpo muda).
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
  v_grupo_id uuid;
  v_qtd_atual int;
  v_qtd_nova int;
  v_qtd_restante int;
  v_qtd_baixa int;
  v_produto_id uuid;
  v_autorizacao_id uuid;
  v_parceiro record;
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
    select caminhao_id, grupo_id into v_caminhao_id, v_grupo_id from equipes where id = p_equipe_id;
    if v_caminhao_id is not null then
      for v_item in select * from jsonb_array_elements(p_itens) loop
        v_produto_id := nullif(v_item ->> 'produto_id', '')::uuid;
        if v_produto_id is not null then
          if v_grupo_id is null then
            -- Equipe sem grupo: comportamento idêntico ao de antes (baixa só
            -- do próprio caminhão, sem checagem rígida de saldo suficiente).
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
          else
            -- Equipe viajando em grupo: baixa primeiro do próprio caminhão
            -- e, se faltar, completa nos caminhões parceiros do grupo
            -- (o de maior saldo primeiro). Cada movimentação registra o
            -- caminhão físico de onde a unidade realmente saiu, então nada
            -- fica contado em dobro.
            v_qtd_restante := (v_item ->> 'quantidade')::int;

            select quantidade into v_qtd_atual
              from caminhao_estoque
              where caminhao_id = v_caminhao_id and produto_id = v_produto_id
              for update;

            v_qtd_baixa := least(coalesce(v_qtd_atual, 0), v_qtd_restante);
            if v_qtd_baixa > 0 then
              update caminhao_estoque
                set quantidade = quantidade - v_qtd_baixa, atualizado_em = now()
                where caminhao_id = v_caminhao_id and produto_id = v_produto_id;

              insert into movimentacoes_estoque
                (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
              values
                ('venda', v_produto_id, v_qtd_baixa, v_caminhao_id, p_equipe_id, v_venda.id,
                 public.meu_funcionario_id(), 'Venda ' || v_venda.codigo);
              v_qtd_restante := v_qtd_restante - v_qtd_baixa;
            end if;

            if v_qtd_restante > 0 then
              for v_parceiro in
                select ce.caminhao_id as caminhao_id, ce.quantidade as quantidade
                from caminhao_estoque ce
                where ce.produto_id = v_produto_id
                  and ce.quantidade > 0
                  and ce.caminhao_id in (
                    select e.caminhao_id from equipes e
                    where e.grupo_id = v_grupo_id and e.id <> p_equipe_id and e.encerrada = false
                  )
                order by ce.quantidade desc
                for update of ce
              loop
                exit when v_qtd_restante <= 0;
                v_qtd_baixa := least(v_parceiro.quantidade, v_qtd_restante);
                if v_qtd_baixa > 0 then
                  update caminhao_estoque
                    set quantidade = quantidade - v_qtd_baixa, atualizado_em = now()
                    where caminhao_id = v_parceiro.caminhao_id and produto_id = v_produto_id;

                  insert into movimentacoes_estoque
                    (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
                  values
                    ('venda', v_produto_id, v_qtd_baixa, v_parceiro.caminhao_id, p_equipe_id, v_venda.id,
                     public.meu_funcionario_id(), 'Venda ' || v_venda.codigo || ' (caminhão parceiro de grupo)');
                  v_qtd_restante := v_qtd_restante - v_qtd_baixa;
                end if;
              end loop;
            end if;
          end if;
        end if;
      end loop;
    end if;
  end if;

  return v_venda;
end;
$$;

revoke all on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) from public;
grant execute on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb, uuid) to authenticated;

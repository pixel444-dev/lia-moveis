-- ============================================================================
-- Corrige o cálculo de `equipes.total_avista` / `equipes.total_credito` feito
-- por `criar_venda()` (0008): hoje, numa venda a crédito (`tipo='entrada'`),
-- a função soma o VALOR TOTAL da venda em `total_credito` e não credita nada
-- em `total_avista` — ignorando o valor de entrada, que é dinheiro recebido
-- na hora (deveria contar como caixa, não como crediário).
--
-- Isso diverge do critério já usado em outros dois lugares do app pra estes
-- mesmos totais (`calcularTotaisEquipe()` no frontend, usado por
-- `salvarEdicaoVenda` e pela tela do vendedor em "Equipes / Semanas"):
--   - dinheiro em caixa = vendas à vista (valor cheio) + entradas das vendas
--     a crédito;
--   - crediário = apenas o saldo financiado (valor - entrada) das vendas a
--     crédito.
--
-- Esta migration só troca as duas expressões do UPDATE final de
-- `criar_venda` pra usar o mesmo critério — nada mais muda na função.
--
-- Rode este script no SQL Editor do Supabase (depois do 0008).
-- ============================================================================

drop function if exists public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb);

create function public.criar_venda(
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
  p_itens jsonb
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
begin
  if v_perfil is null then
    raise exception 'Usuário não identificado ou sem perfil ativo.';
  end if;

  -- Gate de inadimplência crônica: só pra vendedor. Gestor sempre pode
  -- vender pra inadimplente sem autorização, igual ao comportamento atual.
  -- Necessário aqui além da policy do passo 3 porque esta função roda
  -- security definer (bypassa RLS).
  if v_perfil = 'vendedor' and public.cliente_bloqueado_por_atraso(p_cliente_id) then
    raise exception 'Cliente com atraso de mais de 1 mês. Solicite autorização do gestor antes de vender.';
  end if;

  if p_tipo = 'entrada' then
    if p_num_parcelas is null or p_num_parcelas < 1 or p_num_parcelas > 12 then
      raise exception 'Número de parcelas inválido (deve ser entre 1 e 12).';
    end if;
    if p_data_primeira_parcela is null then
      raise exception 'Data da primeira parcela é obrigatória para venda a crédito.';
    end if;
  end if;

  -- Geração de código com retry em colisão, mesma lógica de hoje
  -- (proximo_codigo_venda() já existe e continua sendo a fonte do código).
  loop
    v_tentativas := v_tentativas + 1;
    v_codigo := public.proximo_codigo_venda();
    begin
      insert into vendas (codigo, cliente_id, vendedor_id, tipo, produto, valor, num_parcelas, entrada, observacao, equipe_id)
      values (v_codigo, p_cliente_id, p_vendedor_id, p_tipo, p_produto, p_valor, p_num_parcelas, p_entrada, p_observacao, p_equipe_id)
      returning * into v_venda;
      exit;
    exception when unique_violation then
      if v_tentativas >= 3 then
        raise exception 'Não foi possível gerar um código de venda único após % tentativas.', v_tentativas;
      end if;
    end;
  end loop;

  -- Parcelas: só para venda a crédito. Divisão com o resto absorvido pela
  -- última parcela (corrige a sobra de centavos que a divisão simples de
  -- hoje deixa sem tratamento).
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

  -- Itens da venda (venda_itens.quantidade é integer).
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

  -- Totais da equipe: incremento atômico em vez de recalcular todas as
  -- vendas da equipe e sobrescrever (elimina a race condition de hoje).
  -- total_avista = caixa (à vista cheio + entrada das vendas a crédito);
  -- total_credito = só o saldo financiado (valor - entrada) — mesmo
  -- critério de calcularTotaisEquipe() no frontend.
  if p_equipe_id is not null then
    update equipes set
      total_vendas  = coalesce(total_vendas, 0) + 1,
      total_valor   = coalesce(total_valor, 0) + p_valor,
      total_avista  = coalesce(total_avista, 0) + (case when p_tipo = 'avista' then p_valor when p_tipo = 'entrada' then coalesce(p_entrada, 0) else 0 end),
      total_credito = coalesce(total_credito, 0) + (case when p_tipo = 'entrada' then p_valor - coalesce(p_entrada, 0) else 0 end)
    where id = p_equipe_id;
  end if;

  -- Baixa de estoque do caminhão (caminhao_estoque.quantidade e
  -- movimentacoes_estoque.quantidade são integer): só quando é o próprio
  -- vendedor registrando (mesma condição de hoje). Lock de linha
  -- (for update) evita o read-then-write não atômico que existe hoje no JS.
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

revoke all on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb) from public;
grant execute on function public.criar_venda(uuid, uuid, uuid, text, text, numeric, int, numeric, date, text, jsonb) to authenticated;

-- Corrige os totais já acumulados incorretamente pelas vendas a crédito
-- criadas antes desta migration (mesma fórmula do trecho acima).
update equipes eq set
  total_avista = coalesce((
    select sum(case when v.tipo = 'avista' then v.valor when v.tipo = 'entrada' then coalesce(v.entrada, 0) else 0 end)
    from vendas v
    where v.equipe_id = eq.id and coalesce(v.status, '') <> 'devolvida'
  ), 0),
  total_credito = coalesce((
    select sum(case when v.tipo = 'entrada' then v.valor - coalesce(v.entrada, 0) else 0 end)
    from vendas v
    where v.equipe_id = eq.id and coalesce(v.status, '') <> 'devolvida'
  ), 0)
where exists (select 1 from vendas v where v.equipe_id = eq.id);

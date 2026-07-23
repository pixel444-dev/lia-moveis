-- ============================================================================
-- (PASSO 2 — ATIVAÇÃO) Delta de parcelas: devolve só as parcelas que MUDARAM
-- desde a última sincronização (marca d'água atualizado_em), em vez da carteira
-- inteira. É o que faz uma baixa não obrigar o app a rebaixar dezenas de
-- milhares de parcelas — baixa só a(s) que mudou(aram).
--
-- Depende da 0043 (coluna atualizado_em + gatilho em parcelas). Enquanto esta
-- função não existir, o app cai no download completo confiável de sempre —
-- nada quebra.
--
-- Devolve, num único snapshot consistente:
--   parcelas      – as linhas alteradas desde p_desde (QUALQUER status, pra o
--                   app poder REMOVER do cache as que viraram 'devolvida'),
--                   no MESMO formato do download completo (com vendas{codigo,
--                   produto,vendedor_id} e funcionarios{nome} embutidos).
--   qtd_parcelas  – contagem ATUAL de parcelas não-devolvidas da carteira, pro
--   hash_parcelas   app conferir se o cache bateu (deleção física — ex.:
--                   cancelar_venda — não vem no delta; a divergência de
--                   contagem avisa o app pra cair no completo, que poda).
--   server_now    – relógio do servidor (nova marca d'água; nunca usar o
--                   relógio do celular).
--
-- Reaproveita clientes_do_cobrador(uuid) (0009). Só leitura, security definer.
-- Rode no SQL Editor do Supabase, depois da 0043.
-- ============================================================================

create or replace function public.delta_parcelas_cobrador(p_desde timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_perfil   text := public.meu_perfil();
  v_cobrador uuid := public.meu_funcionario_id();
  -- Margem de 2min: cobre o atraso entre o now() do gatilho e o commit, pra
  -- nenhuma linha escapar na fronteira. O reenvio da sobreposição é inofensivo
  -- (o app grava por id, é idempotente).
  v_desde    timestamptz := coalesce(p_desde, '-infinity'::timestamptz) - interval '2 minutes';
  v_parcelas jsonb;
  v_qtd      bigint  := 0;
  v_hash     numeric := 0;
begin
  if v_perfil is distinct from 'cobrador' then
    raise exception 'Apenas o cobrador pode sincronizar a própria carteira.';
  end if;
  if v_cobrador is null then
    raise exception 'Cobrador não identificado.';
  end if;

  with cc as (
    select id from public.clientes_do_cobrador(v_cobrador) as id
  )
  select coalesce(jsonb_agg(
           to_jsonb(p)
           || jsonb_build_object(
                'vendas',
                (select jsonb_build_object('codigo', v.codigo, 'produto', v.produto, 'vendedor_id', v.vendedor_id)
                   from vendas v where v.id = p.venda_id),
                'funcionarios',
                (select jsonb_build_object('nome', f.nome)
                   from funcionarios f where f.id = p.cobrador_id)
              )
         ), '[]'::jsonb)
    into v_parcelas
  from parcelas p
  join cc on cc.id = p.cliente_id
  where p.atualizado_em >= v_desde;

  -- Contagem/hash ATUAIS da carteira (não-devolvidas), mesma definição da
  -- 0042 — pro app conferir se o cache ficou consistente após aplicar o delta.
  with cc as (
    select id from public.clientes_do_cobrador(v_cobrador) as id
  )
  select count(*)::bigint,
         coalesce(sum(hashtextextended(p::text, 0)::numeric), 0)
    into v_qtd, v_hash
  from parcelas p
  join cc on cc.id = p.cliente_id
  where coalesce(p.status, '') <> 'devolvida';

  return jsonb_build_object(
    'parcelas',      v_parcelas,
    'qtd_parcelas',  v_qtd,
    'hash_parcelas', v_hash::text,
    'server_now',    now()
  );
end;
$$;

grant execute on function public.delta_parcelas_cobrador(timestamptz) to authenticated;

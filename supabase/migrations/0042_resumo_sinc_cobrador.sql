-- ============================================================================
-- Resumo leve da carteira do cobrador, para o app decidir se PRECISA rebaixar
-- os dados offline — em vez de rebaixar a carteira inteira toda vez que o TTL
-- de parcelas (20min) vence, mesmo sem nada ter mudado no servidor.
--
-- O app guarda esta "impressão digital" da última sincronização completa e, ao
-- abrir, chama esta função (1 consulta barata). Se a impressão bate, não baixa
-- nada; se difere em clientes e/ou parcelas, baixa só o que mudou.
--
-- NÃO altera nenhuma tabela — é só uma função de leitura (security definer,
-- concedida a authenticated). Enquanto esta função não existir no banco, o app
-- continua funcionando pelo comportamento antigo (por tempo/TTL): o cliente
-- trata a ausência da função como "não sei, cai no TTL".
--
-- A "impressão" é um agregado à prova de ordem: count(*) + soma dos hashes de
-- cada linha (linha inteira via cast pra text, então QUALQUER mudança de
-- QUALQUER campo — baixa, remarque, edição, nova venda, devolução — muda o
-- hash). hashtextextended dá 64 bits; a soma vira numeric (sem overflow) e é
-- devolvida como texto pra não perder precisão no JavaScript.
--
-- Reaproveita clientes_do_cobrador(uuid) (0009): a MESMA definição de carteira
-- usada no resto do sistema (clientes diretos ∪ clientes por rota ativa).
--
-- Rode este script no SQL Editor do Supabase, depois da 0041.
-- ============================================================================

create or replace function public.resumo_sinc_cobrador()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_perfil     text := public.meu_perfil();
  v_cobrador   uuid := public.meu_funcionario_id();
  v_qtd_cli    bigint  := 0;
  v_hash_cli   numeric := 0;
  v_qtd_par    bigint  := 0;
  v_hash_par   numeric := 0;
begin
  if v_perfil is distinct from 'cobrador' then
    raise exception 'Apenas o cobrador pode consultar o resumo da própria carteira.';
  end if;
  if v_cobrador is null then
    raise exception 'Cobrador não identificado.';
  end if;

  with cc as (
    select id from public.clientes_do_cobrador(v_cobrador) as id
  ),
  res_cli as (
    select count(*)::bigint as qtd,
           coalesce(sum(hashtextextended(c::text, 0)::numeric), 0) as h
    from clientes c
    join cc on cc.id = c.id
  ),
  res_par as (
    select count(*)::bigint as qtd,
           coalesce(sum(hashtextextended(p::text, 0)::numeric), 0) as h
    from parcelas p
    join cc on cc.id = p.cliente_id
    where coalesce(p.status, '') <> 'devolvida'
  )
  select res_cli.qtd, res_cli.h, res_par.qtd, res_par.h
    into v_qtd_cli, v_hash_cli, v_qtd_par, v_hash_par
  from res_cli, res_par;

  return jsonb_build_object(
    'cobrador_id',   v_cobrador,
    'qtd_clientes',  v_qtd_cli,
    'hash_clientes', v_hash_cli::text,
    'qtd_parcelas',  v_qtd_par,
    'hash_parcelas', v_hash_par::text,
    'gerado_em',     now()
  );
end;
$$;

grant execute on function public.resumo_sinc_cobrador() to authenticated;

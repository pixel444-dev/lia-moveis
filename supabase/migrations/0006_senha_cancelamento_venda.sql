-- ============================================================================
-- Exige uma senha de confirmação (guardada só no banco, com hash) antes de
-- cancelar uma venda. Hoje `cancelarVenda()` no app fazia os deletes direto
-- via `sb.from(...)`, sem nenhuma checagem no servidor — qualquer usuário
-- autenticado com o DevTools aberto conseguiria apagar uma venda mesmo sem
-- clicar em nada, pois as policies de RLS de `vendas`/`parcelas` liberam
-- `for all to authenticated using (true)`. Esta migration move todo o fluxo
-- de cancelamento (restaurar estoque + apagar dependências + apagar a venda)
-- para dentro de uma função Postgres com SECURITY DEFINER, que:
--   1) confere que quem está chamando é gestor (public.meu_perfil());
--   2) confere a senha de confirmação contra um hash guardado em
--      `senhas_confirmacao` (tabela com RLS sem nenhuma policy — só a própria
--      função, rodando como definer, consegue ler/gravar nela);
--   3) só então executa o cancelamento, tudo numa única transação atômica.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, abra Database → Functions no Studio, clique em
-- "cancelar_venda" e confirme que o campo "Security" está como "Definer".
-- Sem isso a função não consegue ler a tabela `senhas_confirmacao` (RLS sem
-- policy = acesso negado) e a senha nunca vai bater.
-- ============================================================================

create extension if not exists pgcrypto;

-- 1) Tabela que guarda só o hash da senha (nunca a senha em texto puro).
--    RLS habilitada e sem nenhuma policy: nem select, nem insert, nem update
--    ficam acessíveis via `sb.from('senhas_confirmacao')` no client — só a
--    função abaixo (security definer) enxerga esta tabela.
create table if not exists senhas_confirmacao (
  chave text primary key,
  hash text not null,
  atualizado_em timestamptz not null default now()
);

alter table senhas_confirmacao enable row level security;

-- 2) Defina (ou troque) a senha de confirmação do cancelamento rodando isto
--    à parte, substituindo 'TROQUE_ESTA_SENHA' pela senha desejada:
--
-- insert into senhas_confirmacao (chave, hash)
-- values ('cancelamento_venda', crypt('TROQUE_ESTA_SENHA', gen_salt('bf')))
-- on conflict (chave) do update set hash = excluded.hash, atualizado_em = now();

-- 3) Função que faz todo o cancelamento de forma atômica.
drop function if exists public.cancelar_venda(uuid, text);

create function public.cancelar_venda(p_venda_id uuid, p_senha text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_venda vendas%rowtype;
  v_caminhao_id uuid;
  v_funcionario_id uuid;
  v_item record;
  v_parcela_ids uuid[];
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode cancelar vendas.';
  end if;

  select hash into v_hash from senhas_confirmacao where chave = 'cancelamento_venda';
  if v_hash is null or crypt(coalesce(p_senha, ''), v_hash) is distinct from v_hash then
    raise exception 'Senha de confirmação incorreta.';
  end if;

  select * into v_venda from vendas where id = p_venda_id;
  if not found then
    raise exception 'Venda não encontrada.';
  end if;

  select funcionario_id into v_funcionario_id from perfis where id = auth.uid();

  -- Restaura o estoque no caminhão, se a venda tinha equipe/caminhão vinculado
  -- (mesma lógica que já existia em restaurarEstoqueDaVenda no frontend).
  if v_venda.equipe_id is not null then
    select caminhao_id into v_caminhao_id from equipes where id = v_venda.equipe_id;
    if v_caminhao_id is not null then
      for v_item in
        select produto_id, quantidade from venda_itens
        where venda_id = p_venda_id and produto_id is not null
      loop
        insert into caminhao_estoque (caminhao_id, produto_id, quantidade)
        values (v_caminhao_id, v_item.produto_id, v_item.quantidade)
        on conflict (caminhao_id, produto_id)
        do update set quantidade = caminhao_estoque.quantidade + excluded.quantidade,
                      atualizado_em = now();

        insert into movimentacoes_estoque
          (tipo, produto_id, quantidade, caminhao_id, equipe_id, venda_id, responsavel_id, observacao)
        values
          ('estorno', v_item.produto_id, v_item.quantidade, v_caminhao_id, v_venda.equipe_id,
           p_venda_id, v_funcionario_id, 'Cancelamento da venda ' || v_venda.codigo);
      end loop;
    end if;
  end if;

  -- Desvincula o ledger de estoque (mantém o histórico, só solta a FK).
  update movimentacoes_estoque set venda_id = null where venda_id = p_venda_id;

  -- Apaga dependências das parcelas antes das próprias parcelas.
  select array_agg(id) into v_parcela_ids from parcelas where venda_id = p_venda_id;
  if v_parcela_ids is not null then
    delete from visitas_agendadas where parcela_id = any(v_parcela_ids);
    delete from baixas_pendentes where parcela_id = any(v_parcela_ids);
  end if;

  delete from parcelas where venda_id = p_venda_id;
  delete from venda_itens where venda_id = p_venda_id;
  delete from vendas where id = p_venda_id;
end;
$$;

revoke all on function public.cancelar_venda(uuid, text) from public;
grant execute on function public.cancelar_venda(uuid, text) to authenticated;

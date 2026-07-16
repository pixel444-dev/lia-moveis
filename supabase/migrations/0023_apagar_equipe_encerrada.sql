-- ============================================================================
-- Permite ao gestor apagar uma equipe já encerrada (por exemplo, equipes de
-- teste criadas durante validação do sistema), sem apagar as vendas nem os
-- clientes que aquela equipe gerou.
--
-- Um DELETE direto em `equipes` esbarra nas FKs de `vendas.equipe_id`,
-- `movimentacoes_estoque.equipe_id` e `autorizacoes_venda.equipe_id` (sem
-- ON DELETE CASCADE/SET NULL) sempre que houver algo vinculado à equipe.
-- A função abaixo desvincula (equipe_id = null) essas tabelas antes de
-- apagar a equipe — mesma técnica que `cancelar_venda()` (migration 0006) já
-- usa em `movimentacoes_estoque.venda_id` — para preservar vendas, parcelas,
-- itens e cadastro de clientes intactos; só perdem a referência à equipe
-- apagada.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, abra Database → Functions no Studio, clique em
-- "apagar_equipe" e confirme que o campo "Security" está como "Definer".
-- ============================================================================

drop function if exists public.apagar_equipe(uuid);

create function public.apagar_equipe(p_equipe_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_equipe equipes%rowtype;
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode apagar equipes.';
  end if;

  select * into v_equipe from equipes where id = p_equipe_id;
  if not found then
    raise exception 'Equipe não encontrada.';
  end if;

  if not v_equipe.encerrada then
    raise exception 'Só é possível apagar equipes já encerradas.';
  end if;

  -- Solta o vínculo com a equipe nas tabelas que a referenciam, mantendo os
  -- próprios registros (vendas, parcelas, itens, ledger de estoque e
  -- autorizações continuam existindo normalmente).
  update vendas set equipe_id = null where equipe_id = p_equipe_id;
  update movimentacoes_estoque set equipe_id = null where equipe_id = p_equipe_id;
  update autorizacoes_venda set equipe_id = null where equipe_id = p_equipe_id;

  delete from equipe_membros where equipe_id = p_equipe_id;
  delete from equipes where id = p_equipe_id;
end;
$$;

revoke all on function public.apagar_equipe(uuid) from public;
grant execute on function public.apagar_equipe(uuid) to authenticated;

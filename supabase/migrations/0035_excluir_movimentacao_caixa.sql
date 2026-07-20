-- ============================================================================
-- Permite ao gestor excluir um gasto ou depósito lançado errado por um
-- cobrador, na tela de Prestação de contas (mesma tela onde já dá pra
-- corrigir valor/descrição/comprovante — ver função salvarEdicaoMovimentacao()
-- no frontend, que já faz update() direto em movimentacoes_caixa porque a
-- policy movcx_update_gestor de UPDATE já existe em produção).
--
-- Diferente do UPDATE, não temos confirmação de que já existe uma policy de
-- DELETE gestor-only pra movimentacoes_caixa — em vez de arriscar um delete()
-- direto do cliente (que ou falha silenciosamente sob RLS, ou pior, expõe um
-- delete sem estar restrito a gestor caso a policy real seja mais permissiva
-- do que o esperado), fazemos como baixas_pendentes/caixa_cobrador: uma RPC
-- security definer com o check de perfil explícito no código, igual
-- corrigir_baixa()/cancelar_baixa_prestacao() já fazem pra baixas.
--
-- Mesma trava de autorizar_caixa() que baixas_pendentes já tem: não deixa
-- excluir lançamento de uma caixa já aprovada (fechada), pra não alterar
-- dado histórico depois da prestação de contas ter sido encerrada.
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, confira no Studio que `excluir_movimentacao_caixa`
-- está com "Security: Definer".
-- ============================================================================

create or replace function public.excluir_movimentacao_caixa(p_mov_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_mov movimentacoes_caixa%rowtype;
  v_caixa caixa_cobrador%rowtype;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode excluir gasto ou depósito.';
  end if;

  select * into v_mov from movimentacoes_caixa where id = p_mov_id for update;
  if not found then
    raise exception 'Lançamento não encontrado.';
  end if;

  select * into v_caixa from caixa_cobrador where id = v_mov.caixa_id;
  if v_caixa.status = 'aprovado' then
    raise exception 'Não é possível excluir lançamentos de uma caixa já aprovada.';
  end if;

  delete from movimentacoes_caixa where id = p_mov_id;
end;
$$;

revoke all on function public.excluir_movimentacao_caixa(uuid) from public;
grant execute on function public.excluir_movimentacao_caixa(uuid) to authenticated;

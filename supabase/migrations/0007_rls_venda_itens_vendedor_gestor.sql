-- ============================================================================
-- Corrige o erro "Falha ao salvar itens da venda" (supabase_code 42501).
--
-- Descoberta ao inspecionar as policies reais (`select * from pg_policies
-- where tablename = 'venda_itens'`): a tabela já tinha uma policy
-- `venda_itens_vendedor_propria_venda` que só libera o vendedor quando
-- `vendas.vendedor_id = meu_funcionario_id()` (ou seja, só na "própria
-- venda"). O problema é que a tela de registrar venda (perfil vendedor)
-- deixa escolher QUALQUER membro da equipe ativa (chefe ou ajudante) como
-- "vendedor responsável" pela venda — ver `carregarMembrosEquipeSelect()` em
-- docs/index.html. Quando o vendedor logado registra a venda em nome de um
-- colega de equipe, `vendedor_id` grava o colega, não quem está logado, e a
-- policy antiga barra o INSERT em `venda_itens` com 42501.
--
-- Este script troca a regra de "dono exato da venda" por "membro da mesma
-- equipe da venda" (via `equipe_membros`), que é o que o app realmente
-- permite fazer. DELETE continua reservado só a `gestor`: a policy
-- `venda_itens_gestor_all` (pré-existente, não alterada aqui) já cobre isso;
-- a policy restritiva abaixo bloqueia DELETE para o perfil `vendedor`
-- mesmo que a policy "for all" logo abaixo, isoladamente, permitiria.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

-- Desfaz a tentativa anterior (migration original deste arquivo), que tinha
-- ignorado por completo a restrição de "própria equipe" — mais permissiva
-- do que deveria.
drop policy if exists "venda_itens_vendedor_gestor_insert" on venda_itens;
drop policy if exists "venda_itens_vendedor_gestor_update" on venda_itens;
drop policy if exists "venda_itens_gestor_delete" on venda_itens;

-- Substitui a policy original (dono exato) pela versão por equipe.
drop policy if exists "venda_itens_vendedor_propria_venda" on venda_itens;
drop policy if exists "venda_itens_vendedor_propria_equipe" on venda_itens;
create policy "venda_itens_vendedor_propria_equipe" on venda_itens
  for all to authenticated
  using (
    meu_perfil() = 'vendedor' and exists (
      select 1
      from vendas v
      join equipe_membros em on em.equipe_id = v.equipe_id
      where v.id = venda_itens.venda_id
        and em.funcionario_id = meu_funcionario_id()
    )
  )
  with check (
    meu_perfil() = 'vendedor' and exists (
      select 1
      from vendas v
      join equipe_membros em on em.equipe_id = v.equipe_id
      where v.id = venda_itens.venda_id
        and em.funcionario_id = meu_funcionario_id()
    )
  );

-- Vendedor não pode excluir itens de venda — só gestor (via
-- venda_itens_gestor_all, já existente).
drop policy if exists "impedir_delete_vendedor_venda_itens" on venda_itens;
create policy "impedir_delete_vendedor_venda_itens" on venda_itens
  as restrictive
  for delete to authenticated
  using (meu_perfil() <> 'vendedor');

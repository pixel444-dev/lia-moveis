-- ============================================================================
-- Corrige o erro "Falha ao salvar itens da venda" (supabase_code 42501) que
-- vendedores tomavam ao finalizar uma venda: a tabela `venda_itens` não tinha
-- policy de RLS liberando INSERT/UPDATE/DELETE para o perfil `vendedor` (só a
-- tabela `vendas` em si tem policy `using (true)` para qualquer autenticado —
-- ver migration 0006).
--
-- Regra de negócio: registrar/editar os itens de uma venda só pode quem pode
-- registrar a venda — perfis `vendedor` e `gestor`. O perfil `cobrador` não
-- deve ter permissão de escrita aqui. Leitura (SELECT) não é alterada por
-- este script — segue como já está configurado hoje.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

alter table venda_itens enable row level security;

drop policy if exists "venda_itens_vendedor_gestor_insert" on venda_itens;
create policy "venda_itens_vendedor_gestor_insert" on venda_itens
  for insert to authenticated
  with check (public.meu_perfil() in ('vendedor', 'gestor'));

drop policy if exists "venda_itens_vendedor_gestor_update" on venda_itens;
create policy "venda_itens_vendedor_gestor_update" on venda_itens
  for update to authenticated
  using (public.meu_perfil() in ('vendedor', 'gestor'))
  with check (public.meu_perfil() in ('vendedor', 'gestor'));

drop policy if exists "venda_itens_vendedor_gestor_delete" on venda_itens;
create policy "venda_itens_vendedor_gestor_delete" on venda_itens
  for delete to authenticated
  using (public.meu_perfil() in ('vendedor', 'gestor'));

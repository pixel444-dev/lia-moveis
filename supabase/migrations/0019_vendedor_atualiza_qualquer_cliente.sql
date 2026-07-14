-- ============================================================================
-- Corrige perda silenciosa de dados/foto ao editar cliente já existente numa
-- venda: o vendedor conseguia ABRIR e editar o formulário (a policy de
-- SELECT liberava via `clientes_por_rota()`), mas o UPDATE não tinha essa
-- mesma condição — o RLS barrava a escrita sem erro nenhum (0 linhas
-- afetadas), o app mostrava "Cliente atualizado" e nada era salvo de
-- verdade (nem os dados, nem a foto da casa).
--
-- Causa raiz (confirmada via pg_policies em produção):
--   clientes_select: gestor OR cobrador_id=eu OR criado_por=eu
--                     OR id IN clientes_da_minha_equipe()
--                     OR id IN clientes_por_rota()   <- só existia aqui
--   clientes_update: gestor OR cobrador_id=eu OR criado_por=eu
--                     OR id IN clientes_da_minha_equipe()
--
-- Dois ajustes, conforme o comportamento pretendido:
--   1) `clientes_por_rota()` é uma visão pensada pro cobrador (telas de
--      carteira/rota do cobrador, todas guardadas por perfil no frontend
--      hoje) — nunca deveria ter entrado na visibilidade do vendedor. Passa
--      a exigir meu_perfil() = 'cobrador'.
--   2) Vendedor pode atualizar o cadastro de QUALQUER cliente, independente
--      de rota/equipe/quem cadastrou — a regra de negócio real é mais larga
--      que a de leitura. Adiciona meu_perfil() = 'vendedor' como condição
--      própria em clientes_update (USING e WITH CHECK).
--
-- A policy restritiva `exigir_2fa_gestor` (ALL, 2FA obrigatório só quando
-- meu_perfil() = 'gestor') não muda e não é afetada por este ajuste.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

drop policy if exists clientes_select on clientes;
create policy clientes_select on clientes
  for select to authenticated
  using (
    meu_perfil() = 'gestor'
    or cobrador_id = meu_funcionario_id()
    or criado_por = auth.uid()
    or id in (select clientes_da_minha_equipe())
    or (meu_perfil() = 'cobrador' and id in (select clientes_por_rota()))
  );

drop policy if exists clientes_update on clientes;
create policy clientes_update on clientes
  for update to authenticated
  using (
    meu_perfil() = 'gestor'
    or meu_perfil() = 'vendedor'
    or cobrador_id = meu_funcionario_id()
    or criado_por = auth.uid()
    or id in (select clientes_da_minha_equipe())
  )
  with check (
    meu_perfil() = 'gestor'
    or meu_perfil() = 'vendedor'
    or cobrador_id = meu_funcionario_id()
    or criado_por = auth.uid()
    or id in (select clientes_da_minha_equipe())
  );

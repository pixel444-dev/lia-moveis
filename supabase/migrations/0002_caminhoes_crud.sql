-- ============================================================================
-- CRUD de caminhões: permite cadastrar, editar (identificação/placa/foto),
-- desativar (quando vendido) e excluir caminhões pelo próprio app.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

-- 1) Novas colunas em `caminhoes`
alter table caminhoes add column if not exists foto_url text;
alter table caminhoes add column if not exists ativo boolean not null default true;

-- 2) Bucket de armazenamento para as fotos dos caminhões (privado, igual ao
--    padrão já usado em `fotos-clientes` — as imagens são exibidas via URL
--    assinada, não pública).
insert into storage.buckets (id, name, public)
values ('fotos-caminhoes', 'fotos-caminhoes', false)
on conflict (id) do nothing;

-- RLS do bucket — mesmo modelo permissivo para usuários autenticados usado no
-- restante do app. Ajuste se `fotos-clientes` tiver política mais restrita.
drop policy if exists "fotos_caminhoes_authenticated_all" on storage.objects;
create policy "fotos_caminhoes_authenticated_all" on storage.objects
  for all to authenticated
  using (bucket_id = 'fotos-caminhoes')
  with check (bucket_id = 'fotos-caminhoes');

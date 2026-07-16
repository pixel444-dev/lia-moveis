-- ============================================================================
-- Catálogo em PDF: o gestor publica um PDF (catálogo de produtos) que passa
-- a ser a primeira tela que o vendedor vê ao abrir o app. Só um catálogo
-- fica "ativo" por vez — publicar um novo desativa automaticamente o
-- anterior, mas o histórico continua na tabela (nada é apagado sozinho).
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, abra Database → Functions no Studio e confirme que
-- "publicar_catalogo" e "ativar_catalogo" estão com "Security" = "Definer".
-- ============================================================================

-- 1) Tabela de catálogos
create table if not exists catalogos (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  arquivo_path text not null,
  ativo boolean not null default false,
  criado_por uuid references funcionarios(id),
  criado_em timestamptz not null default now()
);

create index if not exists idx_catalogos_ativo on catalogos (ativo, criado_em desc);

-- 2) Bucket de armazenamento para os PDFs (privado — exibido via URL
--    assinada, mesmo padrão já usado em fotos-clientes/fotos-caminhoes).
insert into storage.buckets (id, name, public)
values ('catalogos', 'catalogos', false)
on conflict (id) do nothing;

-- 3) RLS da tabela — todo autenticado pode ver o catálogo, mas só o gestor
--    pode publicar/editar/excluir.
alter table catalogos enable row level security;

drop policy if exists "catalogos_select_authenticated" on catalogos;
create policy "catalogos_select_authenticated" on catalogos
  for select to authenticated using (true);

drop policy if exists "catalogos_gestor_insert" on catalogos;
create policy "catalogos_gestor_insert" on catalogos
  for insert to authenticated with check (public.meu_perfil() = 'gestor');

drop policy if exists "catalogos_gestor_update" on catalogos;
create policy "catalogos_gestor_update" on catalogos
  for update to authenticated using (public.meu_perfil() = 'gestor') with check (public.meu_perfil() = 'gestor');

drop policy if exists "catalogos_gestor_delete" on catalogos;
create policy "catalogos_gestor_delete" on catalogos
  for delete to authenticated using (public.meu_perfil() = 'gestor');

-- 4) RLS do bucket — leitura liberada pra todo autenticado (o app assina a
--    URL na hora de exibir), escrita restrita ao gestor.
drop policy if exists "catalogos_bucket_select_authenticated" on storage.objects;
create policy "catalogos_bucket_select_authenticated" on storage.objects
  for select to authenticated using (bucket_id = 'catalogos');

drop policy if exists "catalogos_bucket_gestor_insert" on storage.objects;
create policy "catalogos_bucket_gestor_insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'catalogos' and public.meu_perfil() = 'gestor');

drop policy if exists "catalogos_bucket_gestor_update" on storage.objects;
create policy "catalogos_bucket_gestor_update" on storage.objects
  for update to authenticated using (bucket_id = 'catalogos' and public.meu_perfil() = 'gestor');

drop policy if exists "catalogos_bucket_gestor_delete" on storage.objects;
create policy "catalogos_bucket_gestor_delete" on storage.objects
  for delete to authenticated using (bucket_id = 'catalogos' and public.meu_perfil() = 'gestor');

-- 5) publicar_catalogo: registra um PDF já enviado ao bucket como o novo
--    catálogo ativo, desativando o(s) anterior(es) no mesmo passo.
drop function if exists public.publicar_catalogo(text, text);

create function public.publicar_catalogo(p_nome text, p_arquivo_path text)
returns catalogos
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_novo catalogos%rowtype;
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode publicar catálogo.';
  end if;
  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'Informe um nome para o catálogo.';
  end if;
  if p_arquivo_path is null or btrim(p_arquivo_path) = '' then
    raise exception 'Arquivo do catálogo não informado.';
  end if;

  update catalogos set ativo = false where ativo = true;

  insert into catalogos (nome, arquivo_path, ativo, criado_por)
  values (btrim(p_nome), p_arquivo_path, true, public.meu_funcionario_id())
  returning * into v_novo;

  return v_novo;
end;
$$;

revoke all on function public.publicar_catalogo(text, text) from public;
grant execute on function public.publicar_catalogo(text, text) to authenticated;

-- 6) ativar_catalogo: reativa um catálogo antigo do histórico (também
--    desativa qualquer outro que esteja ativo).
drop function if exists public.ativar_catalogo(uuid);

create function public.ativar_catalogo(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if public.meu_perfil() is distinct from 'gestor' then
    raise exception 'Apenas gestor pode ativar catálogo.';
  end if;
  if not exists (select 1 from catalogos where id = p_id) then
    raise exception 'Catálogo não encontrado.';
  end if;

  update catalogos set ativo = false where ativo = true;
  update catalogos set ativo = true where id = p_id;
end;
$$;

revoke all on function public.ativar_catalogo(uuid) from public;
grant execute on function public.ativar_catalogo(uuid) to authenticated;

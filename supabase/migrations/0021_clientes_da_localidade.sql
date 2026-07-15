-- ============================================================================
-- Ao clicar numa localidade a lista de clientes vinha vazia mesmo com
-- clientes vinculados (a contagem no card mostrava certo, o detalhe não).
--
-- Causa: `verClientesLocalidade()` buscava direto em `clientes` filtrando
-- `.eq('cobrador_id', funcionarioLogado.id)` — igual ao bug já corrigido pra
-- contagem (migrations 0016/0020), esse filtro direto ignora clientes que só
-- chegam ao cobrador pela ROTA (`cobrador_id` nulo, resolvido via
-- `clientes_do_cobrador()`).
--
-- Move a consulta pro banco, reaproveitando `clientes_do_cobrador()`
-- (migration 0009) do mesmo jeito que `contagem_clientes_por_localidade`
-- (migration 0020) já faz.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

create or replace function public.clientes_da_localidade(p_localidade_id uuid)
returns table (
  id uuid,
  codigo text,
  nome text,
  cpf text,
  telefone text,
  endereco text,
  cidade text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_funcionario_id uuid := public.meu_funcionario_id();
  v_cobrador_loc uuid;
begin
  select l.cobrador_id into v_cobrador_loc from localidades l where l.id = p_localidade_id;
  if v_cobrador_loc is null then
    raise exception 'Localidade não encontrada.';
  end if;

  if v_perfil = 'cobrador' then
    if v_cobrador_loc <> v_funcionario_id then
      raise exception 'Localidade não é sua.';
    end if;
  elsif v_perfil <> 'gestor' then
    raise exception 'Perfil sem permissão para ver clientes da localidade.';
  end if;

  return query
    select c.id, c.codigo, c.nome, c.cpf, c.telefone, c.endereco, c.cidade
    from clientes c
    where c.localidade_id = p_localidade_id
      and c.id in (select public.clientes_do_cobrador(v_cobrador_loc))
    order by c.nome;
end;
$$;

revoke all on function public.clientes_da_localidade(uuid) from public;
grant execute on function public.clientes_da_localidade(uuid) to authenticated;

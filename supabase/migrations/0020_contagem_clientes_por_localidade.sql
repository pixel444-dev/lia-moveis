-- ============================================================================
-- A tela "Localidades" demorava muito pra carregar. Causa: pra contar
-- clientes vinculados a cada localidade, o app baixava TODOS os clientes do
-- cobrador (diretos + por rota, paginados) e contava no navegador — pro
-- gestor, baixava `localidade_id` de TODOS os clientes do sistema. Com
-- carteiras grandes isso significa dezenas/centenas de milhares de linhas
-- só pra chegar num número por localidade.
--
-- Este script move a contagem pro banco: uma única query agregada, que
-- reaproveita `clientes_do_cobrador()` (migration 0009) pra incluir os
-- clientes que só chegam ao cobrador pela rota.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

create or replace function public.contagem_clientes_por_localidade(p_cobrador_id uuid default null)
returns table (localidade_id uuid, total bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_funcionario_id uuid := public.meu_funcionario_id();
begin
  if v_perfil = 'cobrador' then
    if p_cobrador_id is not null and p_cobrador_id <> v_funcionario_id then
      raise exception 'Sem permissão para ver a contagem de outro cobrador.';
    end if;
    return query
      select c.localidade_id, count(*)::bigint
      from clientes c
      where c.localidade_id is not null
        and c.id in (select public.clientes_do_cobrador(v_funcionario_id))
      group by c.localidade_id;
  elsif v_perfil = 'gestor' then
    return query
      select c.localidade_id, count(*)::bigint
      from clientes c
      where c.localidade_id is not null
        and (p_cobrador_id is null or c.id in (select public.clientes_do_cobrador(p_cobrador_id)))
      group by c.localidade_id;
  else
    raise exception 'Perfil sem permissão para ver contagem de localidades.';
  end if;
end;
$$;

revoke all on function public.contagem_clientes_por_localidade(uuid) from public;
grant execute on function public.contagem_clientes_por_localidade(uuid) to authenticated;

-- ============================================================================
-- Permite ao cobrador salvar a localização (GPS) atual de um cliente
-- diretamente pela ficha da tela de cobranças, quando o cliente ainda não
-- tem latitude/longitude cadastradas — assim o cobrador vai completando a
-- localização de cada cliente que falta enquanto visita a rota.
--
-- Segue o mesmo padrão de salvar_localidade_cliente() (migration 0016): um
-- UPDATE direto de `clientes` falha silenciosamente (0 linhas, sem erro)
-- para cliente que só chega até o cobrador pela rota (localidade_id, sem
-- cobrador_id direto), porque a policy `clientes_update` só libera UPDATE
-- por cobrador_id direto. Por isso uma função security definer específica,
-- reaproveitando `clientes_do_cobrador()` pra checar a carteira.
-- ============================================================================

create or replace function public.salvar_localizacao_cliente(p_cliente_id uuid, p_latitude numeric, p_longitude numeric)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_funcionario_id uuid := public.meu_funcionario_id();
begin
  if v_perfil = 'cobrador' then
    if v_funcionario_id is null or not exists (
      select 1 from public.clientes_do_cobrador(v_funcionario_id) cd where cd = p_cliente_id
    ) then
      raise exception 'Cliente não pertence à sua carteira.';
    end if;
  elsif v_perfil <> 'gestor' then
    raise exception 'Perfil sem permissão para salvar localização.';
  end if;

  update clientes set latitude = p_latitude, longitude = p_longitude where id = p_cliente_id;
end;
$$;

revoke all on function public.salvar_localizacao_cliente(uuid, numeric, numeric) from public;
grant execute on function public.salvar_localizacao_cliente(uuid, numeric, numeric) to authenticated;

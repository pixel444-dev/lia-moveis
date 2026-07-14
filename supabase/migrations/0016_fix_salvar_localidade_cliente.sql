-- ============================================================================
-- Corrige "cobrador define localidade e o sistema não salva" — falha
-- silenciosa de RLS, não um erro visível.
--
-- Causa: a policy `clientes_update` só libera UPDATE pra cobrador quando
-- `cobrador_id = meu_funcionario_id()` (atribuição DIRETA). Um cliente que
-- só chega até o cobrador pela ROTA (cobrador_id null, resolvido via
-- `clientes_por_rota()`) não bate em nenhuma condição da policy — o
-- `UPDATE` do app roda, afeta 0 linhas, e como isso não é considerado erro
-- pelo Postgres/PostgREST, `salvarLocalidadeCliente()` mostrava "Localidade
-- salva!" mesmo sem ter salvo nada.
--
-- Em vez de alargar a policy geral de UPDATE de `clientes` (que vale pra
-- qualquer campo, não só localidade), criamos uma função específica que
-- reconhece os dois casos corretamente reaproveitando
-- `clientes_do_cobrador()` (já usada em fichas_do_ciclo/autorizar_caixa).
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

create or replace function public.salvar_localidade_cliente(p_cliente_id uuid, p_localidade_id uuid)
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
    if p_localidade_id is not null and not exists (
      select 1 from localidades where id = p_localidade_id and cobrador_id = v_funcionario_id
    ) then
      raise exception 'Localidade não encontrada ou não é sua.';
    end if;
  elsif v_perfil <> 'gestor' then
    raise exception 'Perfil sem permissão para vincular localidade.';
  end if;

  update clientes set localidade_id = p_localidade_id where id = p_cliente_id;
end;
$$;

revoke all on function public.salvar_localidade_cliente(uuid, uuid) from public;
grant execute on function public.salvar_localidade_cliente(uuid, uuid) to authenticated;

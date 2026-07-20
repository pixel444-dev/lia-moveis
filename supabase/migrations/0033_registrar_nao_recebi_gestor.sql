-- ============================================================================
-- Permite o gestor também registrar remarque de visita (mesma função "Não
-- recebi" que o cobrador usa) direto da tela de Cobranças — dar baixa em
-- parcelas, sem precisar pedir pro cobrador fazer isso pelo app dele.
--
-- Antes, registrar_nao_recebi() só aceitava perfil = 'cobrador', porque
-- usava o próprio funcionário logado como cobrador_id da remarque. Pro
-- gestor não existe "o próprio cobrador" — usamos o cobrador já vinculado
-- ao cliente (clientes.cobrador_id). Se o cliente não tiver cobrador
-- vinculado, a função recusa (a tela de Cobranças já permite vincular um
-- cobrador antes de remarcar).
-- ============================================================================

create or replace function public.registrar_nao_recebi(
  p_parcela_id uuid,
  p_motivo text,
  p_observacao text,
  p_data_remarcada date
)
returns visitas_agendadas
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_cobrador_id uuid;
  v_parcela parcelas%rowtype;
  v_visita visitas_agendadas%rowtype;
begin
  if p_data_remarcada is null or p_data_remarcada < current_date + 1 then
    raise exception 'Data remarcada deve ser no mínimo amanhã.';
  end if;

  select * into v_parcela from parcelas where id = p_parcela_id;
  if not found then
    raise exception 'Parcela não encontrada.';
  end if;

  if v_perfil = 'cobrador' then
    v_cobrador_id := public.meu_funcionario_id();
    if v_cobrador_id is null then
      raise exception 'Apenas cobrador pode registrar visita.';
    end if;
  elsif v_perfil = 'gestor' then
    select cobrador_id into v_cobrador_id from clientes where id = v_parcela.cliente_id;
    if v_cobrador_id is null then
      raise exception 'Cliente sem cobrador vinculado — defina um cobrador antes de remarcar.';
    end if;
  else
    raise exception 'Perfil sem acesso a remarcar visita.';
  end if;

  -- fecha qualquer remarque anterior em aberto da mesma parcela
  update visitas_agendadas set concluida = true
    where parcela_id = p_parcela_id and not concluida;

  insert into visitas_agendadas (cobrador_id, cliente_id, parcela_id, motivo, observacao, data_agendada, concluida)
  values (v_cobrador_id, v_parcela.cliente_id, p_parcela_id, p_motivo, p_observacao, p_data_remarcada, false)
  returning * into v_visita;

  return v_visita;
end;
$$;

revoke all on function public.registrar_nao_recebi(uuid, text, text, date) from public;
grant execute on function public.registrar_nao_recebi(uuid, text, text, date) to authenticated;

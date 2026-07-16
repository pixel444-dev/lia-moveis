-- ============================================================================
-- Corrige erro 42804 (datatype_mismatch) em atualizar_cliente_venda()
-- (migration 0024), reportado ao testar no app: "erro ao salvar cliente,
-- tente novamente" na tela de nova venda, ao editar um cliente já
-- cadastrado.
--
-- Causa: a migration 0024 convertia `municipio_id` para uuid, mas essa
-- coluna guarda o código do IBGE do município (ex.: 5200050 — ver
-- docs/data/municipios-br.json, campo `codigo_ibge`, usado como
-- `window._vncMunicipioId`/`municipio_id` em toda a tela de Vendas/Clientes;
-- e `rotas_municipios.municipio_id` mapeado direto pra `codigo_ibge` em
-- docs/index.html). É bigint, não uuid — o UPDATE falhava com "column
-- municipio_id is of type bigint but expression is of type uuid" antes
-- mesmo de chegar na policy de RLS.
--
-- Rode este script no SQL Editor do Supabase (depois da 0024).
-- ============================================================================

create or replace function public.atualizar_cliente_venda(p_cliente_id uuid, p_dados jsonb)
returns clientes
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_perfil text := public.meu_perfil();
  v_cliente clientes%rowtype;
begin
  if v_perfil not in ('vendedor', 'gestor') then
    raise exception 'Perfil sem permissão para atualizar cliente.';
  end if;

  update clientes set
    nome = p_dados->>'nome',
    cpf = p_dados->>'cpf',
    endereco = p_dados->>'endereco',
    cidade = p_dados->>'cidade',
    municipio_id = nullif(p_dados->>'municipio_id', '')::bigint,
    telefone = coalesce(p_dados->>'telefone', telefone),
    data_nascimento = coalesce(nullif(p_dados->>'data_nascimento', '')::date, data_nascimento),
    bairro = coalesce(p_dados->>'bairro', bairro),
    referencia = coalesce(p_dados->>'referencia', referencia),
    cobrador_id = coalesce(nullif(p_dados->>'cobrador_id', '')::uuid, cobrador_id),
    latitude = coalesce(nullif(p_dados->>'latitude', '')::numeric, latitude),
    longitude = coalesce(nullif(p_dados->>'longitude', '')::numeric, longitude),
    localizacao_endereco = coalesce(p_dados->>'localizacao_endereco', localizacao_endereco),
    foto_casa = coalesce(p_dados->>'foto_casa', foto_casa)
  where id = p_cliente_id
  returning * into v_cliente;

  if not found then
    raise exception 'Cliente não encontrado para atualização.';
  end if;

  return v_cliente;
end;
$$;

revoke all on function public.atualizar_cliente_venda(uuid, jsonb) from public;
grant execute on function public.atualizar_cliente_venda(uuid, jsonb) to authenticated;

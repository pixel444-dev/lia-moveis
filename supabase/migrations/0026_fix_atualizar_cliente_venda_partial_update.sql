-- ============================================================================
-- Corrige "foto da casa não é salva ao editar cliente na tela de venda"
-- (dados do cliente salvam certo, só a foto não).
--
-- Causa: atualizar_cliente_venda() (migrations 0024/0025) grava nome, cpf,
-- endereco, cidade e municipio_id direto de p_dados->>'campo', sem checar se
-- a chave foi enviada. O upload de foto (docs/index.html, dentro de
-- salvarNovoClienteVenda) chama essa RPC de novo, DEPOIS do UPDATE principal,
-- só com `{ foto_casa: novaUrl }` — nenhuma das outras chaves presente.
-- Nesse segundo UPDATE, nome/cpf/endereco/cidade/municipio_id viravam NULL
-- (chave ausente em jsonb ->> retorna NULL), o que bate numa restrição
-- NOT NULL de nome/cpf e derruba o UPDATE inteiro. Como a chamada em
-- docs/index.html não verificava o retorno da RPC, a falha ficou
-- silenciosa: a transação inteira reverte (por isso os dados continuavam
-- certos), mas a foto nunca chegava a ser gravada, sem nenhum aviso.
--
-- Correção: cada campo só é tocado se a chave correspondente existir em
-- p_dados (operador jsonb `?`), em vez de assumir que todas as chaves
-- "obrigatórias" sempre vêm preenchidas. Isso torna a função seguramente
-- reutilizável para atualizar só um subconjunto de campos (como o caso da
-- foto) sem apagar o resto do cadastro.
--
-- Rode este script no SQL Editor do Supabase (depois da 0025).
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
    nome = case when p_dados ? 'nome' then p_dados->>'nome' else nome end,
    cpf = case when p_dados ? 'cpf' then p_dados->>'cpf' else cpf end,
    endereco = case when p_dados ? 'endereco' then p_dados->>'endereco' else endereco end,
    cidade = case when p_dados ? 'cidade' then p_dados->>'cidade' else cidade end,
    municipio_id = case when p_dados ? 'municipio_id' then nullif(p_dados->>'municipio_id', '')::bigint else municipio_id end,
    telefone = case when p_dados ? 'telefone' then p_dados->>'telefone' else telefone end,
    data_nascimento = case when p_dados ? 'data_nascimento' then nullif(p_dados->>'data_nascimento', '')::date else data_nascimento end,
    bairro = case when p_dados ? 'bairro' then p_dados->>'bairro' else bairro end,
    referencia = case when p_dados ? 'referencia' then p_dados->>'referencia' else referencia end,
    cobrador_id = case when p_dados ? 'cobrador_id' then nullif(p_dados->>'cobrador_id', '')::uuid else cobrador_id end,
    latitude = case when p_dados ? 'latitude' then nullif(p_dados->>'latitude', '')::numeric else latitude end,
    longitude = case when p_dados ? 'longitude' then nullif(p_dados->>'longitude', '')::numeric else longitude end,
    localizacao_endereco = case when p_dados ? 'localizacao_endereco' then p_dados->>'localizacao_endereco' else localizacao_endereco end,
    foto_casa = case when p_dados ? 'foto_casa' then p_dados->>'foto_casa' else foto_casa end
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

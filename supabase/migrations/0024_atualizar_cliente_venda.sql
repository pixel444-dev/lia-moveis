-- ============================================================================
-- Corrige "vendedor edita dados do cliente ao registrar uma nova venda e o
-- sistema não salva" (nome, foto, endereço e localização voltam pro dado
-- antigo) — mesma classe de falha silenciosa de RLS já corrigida em
-- salvar_localidade_cliente() (migration 0016) e salvar_localizacao_cliente()
-- (migration 0021).
--
-- Causa: salvarNovoClienteVenda() (docs/index.html), ao editar um cliente já
-- cadastrado, faz um UPDATE direto em `clientes` pelo client-side JS. A
-- policy `clientes_update` não cobre o caso "vendedor encontrou o cliente
-- pela busca global de CPF" (a busca em si roda numa RPC security definer,
-- verificar_cliente_por_cpf, que não é limitada por dono/carteira/equipe —
-- mas o UPDATE de clientes é). Resultado: o UPDATE roda, afeta 0 linhas, e
-- como isso não é erro pra Postgres/PostgREST, a tela mostra "✓ Cliente
-- atualizado" com o nome recém-digitado mesmo sem ter gravado nada — a
-- mesma foto acontecia no upload de foto_casa logo em seguida.
--
-- Igual às duas correções anteriores para esta tabela: em vez de alargar a
-- policy geral de UPDATE de `clientes`, criamos uma função security definer
-- específica para o fluxo de venda, escopada a vendedor/gestor (mesmo
-- critério permissivo de criar_venda() na migration 0018 — a venda pode ser
-- para qualquer cliente do sistema, não só da carteira/equipe de quem
-- registra). Ela também RETORNA a linha atualizada, então o app não precisa
-- de um segundo SELECT (que podia falhar pelo mesmo motivo e mascarar o
-- problema mostrando o nome digitado em vez do que foi de fato salvo).
--
-- Rode este script no SQL Editor do Supabase.
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
    municipio_id = nullif(p_dados->>'municipio_id', '')::uuid,
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

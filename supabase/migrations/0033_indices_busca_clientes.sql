-- ============================================================================
-- A busca de clientes (tela "Clientes", RPC `buscar_clientes` — reaproveitada
-- também em Vendas, Cobranças/gestor, Carnês e Ficha do cliente via
-- `buscarClientesComFiltro()`) está lenta demais pro cobrador.
--
-- Causa: `clientes` não tem NENHUM índice hoje (conferido em todas as
-- migrations já aplicadas — só existem índices em `movimentacoes_estoque`,
-- `equipes` e `catalogos`). A busca por nome/CPF/código/endereço/cidade/
-- celular é um "contém" (`ILIKE '%termo%'`), que sem um índice de trigram
-- obriga o Postgres a varrer a tabela inteira em toda tecla-Enter — e, como
-- já documentado na migration 0020, a carteira de clientes chega a
-- dezenas/centenas de milhares de linhas. `p_limite`/`p_offset` não ajudam
-- aqui: sem índice, o banco tem que varrer (e filtrar por RLS) quase a
-- tabela toda antes de conseguir aplicar o LIMIT/OFFSET.
--
-- Esta migration só ADICIONA índices (nenhuma policy, função ou coluna é
-- alterada), então é segura de rodar a qualquer momento:
--   1) `pg_trgm` + índices GIN de trigram nas colunas de texto usadas pela
--      busca "contém" (nome, cpf, codigo, endereco, cidade, telefone) —
--      permite ao Postgres resolver `ILIKE '%termo%'` por índice em vez de
--      sequential scan.
--   2) Índices B-tree em `cobrador_id` e `municipio_id`, usados no filtro
--      "Todos os cobradores" da busca e no JOIN de `clientes_do_cobrador()`
--      (migration 0009) — hoje também sem índice.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

create extension if not exists pg_trgm;

create index if not exists idx_clientes_nome_trgm on clientes using gin (nome gin_trgm_ops);
create index if not exists idx_clientes_cpf_trgm on clientes using gin (cpf gin_trgm_ops);
create index if not exists idx_clientes_codigo_trgm on clientes using gin (codigo gin_trgm_ops);
create index if not exists idx_clientes_endereco_trgm on clientes using gin (endereco gin_trgm_ops);
create index if not exists idx_clientes_cidade_trgm on clientes using gin (cidade gin_trgm_ops);
create index if not exists idx_clientes_telefone_trgm on clientes using gin (telefone gin_trgm_ops);

create index if not exists idx_clientes_cobrador_id on clientes (cobrador_id);
create index if not exists idx_clientes_municipio_id on clientes (municipio_id);

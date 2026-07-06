-- ============================================================================
-- Reformulação do estoque: estoque central do CD (serraria) + estoque por
-- caminhão (persistente entre semanas, não mais atrelado à equipe).
--
-- Rode este script no SQL Editor do Supabase. Ele NÃO apaga a tabela antiga
-- `equipe_estoque` — ela fica sem uso pelo app a partir desta versão, mas os
-- dados históricos continuam ali até vocês decidirem removê-la.
--
-- Pré-requisito: ajuste os tipos de FK abaixo (uuid) caso `produtos`,
-- `caminhoes`, `equipes`, `funcionarios` ou `vendas` usem outro tipo de chave
-- no seu banco.
-- ============================================================================

-- 1) Estoque do CD (serraria) — saldo atual por produto
create table if not exists estoque_cd (
  id uuid primary key default gen_random_uuid(),
  produto_id uuid not null references produtos(id),
  quantidade integer not null default 0 check (quantidade >= 0),
  atualizado_em timestamptz not null default now(),
  unique (produto_id)
);

-- 2) Estoque por caminhão — saldo atual por produto, persistente entre semanas
create table if not exists caminhao_estoque (
  id uuid primary key default gen_random_uuid(),
  caminhao_id uuid not null references caminhoes(id),
  produto_id uuid not null references produtos(id),
  quantidade integer not null default 0 check (quantidade >= 0),
  atualizado_em timestamptz not null default now(),
  unique (caminhao_id, produto_id)
);

-- 3) Ledger de movimentações — histórico auditável de toda entrada/saída
create table if not exists movimentacoes_estoque (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('producao', 'carregamento', 'devolucao', 'venda', 'estorno')),
  produto_id uuid not null references produtos(id),
  quantidade integer not null check (quantidade > 0),
  caminhao_id uuid references caminhoes(id),
  equipe_id uuid references equipes(id),
  venda_id uuid references vendas(id),
  responsavel_id uuid references funcionarios(id),
  observacao text,
  criado_em timestamptz not null default now()
);

create index if not exists idx_movimentacoes_caminhao on movimentacoes_estoque (caminhao_id, criado_em desc);
create index if not exists idx_movimentacoes_produto on movimentacoes_estoque (produto_id, criado_em desc);

-- 4) Itens de venda passam a referenciar o catálogo (quando aplicável).
--    Fica nullable: itens "outro" (texto livre, digitado na hora) continuam
--    sem produto_id e sem controle de estoque, igual já funciona hoje.
alter table venda_itens add column if not exists produto_id uuid references produtos(id);

-- 5) RLS — replique aqui as mesmas policies já usadas em `equipe_estoque` /
--    `vendas` no seu projeto. Este bloco é um placeholder permissivo para
--    usuários autenticados; ajuste antes de ir pra produção se as demais
--    tabelas tiverem regras mais restritas por perfil.
alter table estoque_cd enable row level security;
alter table caminhao_estoque enable row level security;
alter table movimentacoes_estoque enable row level security;

drop policy if exists "estoque_cd_authenticated_all" on estoque_cd;
create policy "estoque_cd_authenticated_all" on estoque_cd
  for all to authenticated using (true) with check (true);

drop policy if exists "caminhao_estoque_authenticated_all" on caminhao_estoque;
create policy "caminhao_estoque_authenticated_all" on caminhao_estoque
  for all to authenticated using (true) with check (true);

drop policy if exists "movimentacoes_estoque_authenticated_all" on movimentacoes_estoque;
create policy "movimentacoes_estoque_authenticated_all" on movimentacoes_estoque
  for all to authenticated using (true) with check (true);

-- ============================================================================
-- 6) Backfill opcional: traz o saldo atual de `equipe_estoque` (equipes ainda
-- não encerradas) para dentro de `caminhao_estoque`, como ponto de partida.
-- Some por caminhão+produto (várias equipes/semana podem ter usado o mesmo
-- caminhão). Casa `equipe_estoque.produto` (texto) com `produtos.nome` — itens
-- que não derem match ficam de fora e devem ser lançados manualmente na tela
-- de Estoque depois de rodar isto (confira o SELECT de conferência ao final).
-- Rode só depois de conferir que os nomes batem; é seguro rodar mais de uma
-- vez pois faz upsert (soma) — não rode duas vezes sem zerar antes se não
-- quiser somar em dobro.
-- ============================================================================

-- insert into caminhao_estoque (caminhao_id, produto_id, quantidade)
-- select
--   e.caminhao_id,
--   p.id as produto_id,
--   sum(greatest(ee.quantidade_saida - coalesce(ee.quantidade_voltou, 0), 0)) as quantidade
-- from equipe_estoque ee
-- join equipes e on e.id = ee.equipe_id
-- join produtos p on lower(trim(p.nome)) = lower(trim(ee.produto))
-- group by e.caminhao_id, p.id
-- on conflict (caminhao_id, produto_id) do update
--   set quantidade = caminhao_estoque.quantidade + excluded.quantidade,
--       atualizado_em = now();

-- Conferência: itens de equipe_estoque que não bateram com nenhum produto do
-- catálogo (rodar antes do backfill acima para revisar manualmente).
-- select distinct ee.produto
-- from equipe_estoque ee
-- where not exists (
--   select 1 from produtos p where lower(trim(p.nome)) = lower(trim(ee.produto))
-- );

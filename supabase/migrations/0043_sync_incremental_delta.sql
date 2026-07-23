-- ============================================================================
-- (PASSO 2 — OPCIONAL / FUTURO) Sincronização incremental de verdade: baixar
-- só as LINHAS que mudaram desde a última vez, em vez da carteira inteira.
--
-- O passo 1 (0042_resumo_sinc_cobrador) já evita rebaixar quando NADA mudou.
-- Este passo vai além: quando algo muda, baixa só as parcelas/clientes
-- alterados. Para isso o servidor precisa de uma marca de "atualizado em" que
-- suba sozinha a cada mudança — é o que este script cria.
--
-- ⚠️ NÃO é usado pelo app ainda: aplicar este script sozinho é inofensivo
--    (só adiciona coluna + gatilho + índice), mas o download incremental de
--    fato só liga junto com a mudança correspondente no app (docs/index.html).
--    Deixado pronto para aplicar quando quiser dar esse passo.
--
-- ⚠️ CUIDADO OPERACIONAL: a tabela `parcelas` pode ser grande. Por isso a
--    coluna é adicionada SEM default (mudança só de metadado, rápida e sem
--    reescrever a tabela), o backfill inicial é feito à parte, e só então o
--    default passa a valer para novas linhas. Rode em horário de baixo
--    movimento. O backfill em uma tacada trava a tabela por alguns instantes;
--    em tabelas muito grandes, prefira backfill em lotes (comentado abaixo).
--
-- Rode no SQL Editor do Supabase, depois da 0042.
-- ============================================================================

-- 1) Função de gatilho: carimba atualizado_em = now() em toda alteração.
create or replace function public.set_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

-- 2) parcelas ---------------------------------------------------------------
alter table public.parcelas  add column if not exists atualizado_em timestamptz;

-- Backfill inicial (uma tacada). Em tabela muito grande, troque por lotes:
--   update public.parcelas set atualizado_em = coalesce(data_pagamento, now())
--   where atualizado_em is null;  -- repetir em lotes com LIMIT/where id > ...
update public.parcelas
   set atualizado_em = coalesce(data_pagamento, now())
 where atualizado_em is null;

alter table public.parcelas alter column atualizado_em set default now();

drop trigger if exists trg_parcelas_atualizado_em on public.parcelas;
create trigger trg_parcelas_atualizado_em
  before update on public.parcelas
  for each row execute function public.set_atualizado_em();

create index if not exists idx_parcelas_cliente_atualizado
  on public.parcelas (cliente_id, atualizado_em);

-- 3) clientes ---------------------------------------------------------------
alter table public.clientes  add column if not exists atualizado_em timestamptz;

update public.clientes
   set atualizado_em = now()
 where atualizado_em is null;

alter table public.clientes alter column atualizado_em set default now();

drop trigger if exists trg_clientes_atualizado_em on public.clientes;
create trigger trg_clientes_atualizado_em
  before update on public.clientes
  for each row execute function public.set_atualizado_em();

create index if not exists idx_clientes_cobrador_atualizado
  on public.clientes (cobrador_id, atualizado_em);

-- ----------------------------------------------------------------------------
-- Como o app usaria isto (esboço, para o passo de ativação):
--   1. Guardar, junto ao relatório de sincronização, o maior atualizado_em já
--      baixado (marca d'água), por tabela.
--   2. Ao sincronizar, baixar só WHERE atualizado_em > marca (paginado), em vez
--      da carteira inteira — reaproveitando o mesmo motor confiável em lotes.
--   3. Deleções/reatribuições (cliente que sai da carteira, parcela removida)
--      não aparecem num delta por atualizado_em; continuar fazendo uma
--      sincronização COMPLETA periódica (o TTL de 6h da carteira já serve de
--      reconciliação) para podar o que saiu.
-- ----------------------------------------------------------------------------

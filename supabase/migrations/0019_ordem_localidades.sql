-- ============================================================================
-- Permite ao cobrador definir a ordem de exibição das localidades (rotas).
--
-- Sem uma coluna própria pra isso, a lista de localidades e o agrupamento de
-- cartões de cliente por localidade na tela de cobranças sempre saíam em
-- ordem alfabética. Este script adiciona `ordem` e faz um backfill inicial
-- alfabético por cobrador, pra não quebrar a ordem que já existia na tela.
--
-- Rode este script no SQL Editor do Supabase.
-- ============================================================================

alter table localidades add column if not exists ordem integer;

with numeradas as (
  select id, row_number() over (partition by cobrador_id order by nome) - 1 as rn
  from localidades
  where ordem is null
)
update localidades l set ordem = n.rn
from numeradas n
where n.id = l.id;

-- ============================================================================
-- Habilita Supabase Realtime (Postgres Changes) nas tabelas que mudam a
-- cada ação do cobrador em campo, pra alimentar o painel de acompanhamento
-- em tempo real do gestor (recebimentos e visitas aparecendo ao vivo, sem
-- polling).
--
-- Rode este script no SQL Editor do Supabase, depois da 0010.
--
-- Realtime respeita RLS: as policies de SELECT criadas na migration 0010
-- (cobrador vê só o próprio, gestor vê tudo) já bastam pra que o gestor
-- receba eventos de todos os cobradores e cada cobrador só receba os
-- próprios — não precisa de nenhuma policy extra aqui.
--
-- Idempotente: pode rodar de novo sem erro se a tabela já estiver na
-- publicação (`ALTER PUBLICATION ... ADD TABLE` puro dá erro em execução
-- repetida).
-- ============================================================================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'baixas_pendentes'
  ) then
    alter publication supabase_realtime add table public.baixas_pendentes;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'visitas_agendadas'
  ) then
    alter publication supabase_realtime add table public.visitas_agendadas;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'caixa_cobrador'
  ) then
    alter publication supabase_realtime add table public.caixa_cobrador;
  end if;
end $$;

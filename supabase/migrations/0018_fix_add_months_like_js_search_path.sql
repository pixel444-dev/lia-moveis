-- ============================================================================
-- Corrige o linter do Supabase: "Function public.add_months_like_js has a
-- role mutable search_path". A função não fixava search_path, então o
-- Postgres resolve `date_trunc`/`extract` (e qualquer função sem schema)
-- percorrendo o search_path da sessão/role que chama — alguém com permissão
-- de criar objetos em um schema anterior no path poderia sombrear funções
-- usadas aqui. Como a função não referencia nenhuma tabela, fixamos
-- search_path vazio (só funções/operadores do pg_catalog, que são sempre
-- resolvidos primeiro, continuam funcionando).
-- ============================================================================

create or replace function public.add_months_like_js(p_data date, p_meses int)
returns date
language sql
immutable
set search_path = ''
as $$
  select (date_trunc('month', p_data) + (p_meses || ' months')::interval)::date
         + (extract(day from p_data)::int - 1);
$$;

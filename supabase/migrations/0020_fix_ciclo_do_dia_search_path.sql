-- ============================================================================
-- Corrige o linter do Supabase: "Function public.ciclo_do_dia has a role
-- mutable search_path". A função não referencia nenhuma tabela, então
-- fixamos search_path = '' (só objetos do pg_catalog, sempre resolvidos
-- primeiro, continuam funcionando).
-- ============================================================================

create or replace function public.ciclo_do_dia(p_dia int)
returns table(chave text, dia_inicio int, dia_fim int)
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_dia between 10 and 14 then chave := '10'; dia_inicio := 10; dia_fim := 14;
  elsif p_dia between 15 and 19 then chave := '15'; dia_inicio := 15; dia_fim := 19;
  elsif p_dia between 20 and 24 then chave := '20'; dia_inicio := 20; dia_fim := 24;
  elsif p_dia between 25 and 29 then chave := '25'; dia_inicio := 25; dia_fim := 29;
  elsif p_dia >= 30 or p_dia <= 4 then chave := '30'; dia_inicio := 30; dia_fim := 4;
  else chave := '05'; dia_inicio := 5; dia_fim := 9;
  end if;
  return next;
end;
$$;

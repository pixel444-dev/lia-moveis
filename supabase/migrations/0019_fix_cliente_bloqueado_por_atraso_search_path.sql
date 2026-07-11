-- ============================================================================
-- Corrige o linter do Supabase: "Function public.cliente_bloqueado_por_atraso
-- has a role mutable search_path". A função referencia a tabela `parcelas`
-- sem qualificar o schema, então fixamos search_path = public, extensions
-- (mesma convenção usada nas demais funções do projeto) para que a
-- resolução de `parcelas` não dependa do search_path da sessão que chama.
-- ============================================================================

create or replace function public.cliente_bloqueado_por_atraso(p_cliente_id uuid)
returns boolean
language sql
stable
set search_path = public, extensions
as $$
  select exists (
    select 1 from parcelas
    where cliente_id = p_cliente_id
      and not pago
      and coalesce(status, '') <> 'devolvida'
      and data_vencimento <= current_date - interval '30 days'
  );
$$;

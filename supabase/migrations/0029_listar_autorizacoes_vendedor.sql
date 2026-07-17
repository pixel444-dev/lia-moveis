-- ============================================================================
-- Nova aba do vendedor: "Autorizações" — lista as próprias solicitações de
-- autorização de venda (pendentes, autorizadas e negadas), não só o token
-- ativo que verificar_autorizacao_venda já expõe.
--
-- Por que uma função nova em vez de deixar o app consultar
-- autorizacoes_venda direto: verificar_autorizacao_venda (migration 0021)
-- já é security definer e filtra por vendedor_id = meu_funcionario_id()
-- porque a leitura direta da tabela não é garantida como estando liberada
-- pro vendedor enxergar o próprio pedido por vendedor_id (só existe RLS de
-- select conhecida pro gestor). Esta função segue o mesmo padrão: não
-- depende de nenhuma RLS de leitura em autorizacoes_venda, então funciona
-- de forma previsível independente de como o select do gestor está
-- liberado.
--
-- Rode este script no SQL Editor do Supabase (depois do 0028).
-- ============================================================================

create or replace function public.listar_minhas_autorizacoes_venda()
returns setof public.autorizacoes_venda
language sql
stable
security definer
set search_path = public, extensions
as $$
  select *
  from autorizacoes_venda
  where vendedor_id = public.meu_funcionario_id()
  order by criado_em desc
  limit 200;
$$;

revoke all on function public.listar_minhas_autorizacoes_venda() from public;
grant execute on function public.listar_minhas_autorizacoes_venda() to authenticated;

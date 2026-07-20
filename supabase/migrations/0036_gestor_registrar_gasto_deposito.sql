-- ============================================================================
-- Permite ao gestor lançar gasto/depósito direto na caixa de um cobrador,
-- pela tela de Prestação de contas (ex.: o gestor fez um depósito físico
-- pelo cobrador, ou precisa registrar algo que o cobrador esqueceu).
--
-- registrar_gasto()/registrar_deposito() (migration 0010) são cobrador-only
-- por design — usam meu_funcionario_id() como "o próprio cobrador logado" e
-- aplicam regras de uso normal de campo (limite de R$40/dia em alimentação,
-- comprovante obrigatório). Em vez de sobrecarregar essas funções com um
-- branch de perfil, seguimos o mesmo padrão já usado em
-- gestor_abrir_ou_estender_caixa() (equivalente gestor de
-- abrir_caixa_cobrador()): funções gestor_* separadas, que recebem o
-- caixa_id explicitamente (não há "a própria caixa" pro gestor) e não
-- reaplicam as travas de uso normal — o gestor já tem autoridade pra
-- lançamento manual, mesma lógica de corrigir_baixa()/
-- excluir_movimentacao_caixa() não reforçarem essas regras.
--
-- Mesma trava de excluir_movimentacao_caixa(): não deixa lançar em caixa já
-- aprovada (fechada).
--
-- Rode este script no SQL Editor do Supabase.
--
-- ⚠️ Depois de rodar, confira no Studio que `gestor_registrar_gasto` e
-- `gestor_registrar_deposito` estão com "Security: Definer".
-- ============================================================================

create or replace function public.gestor_registrar_gasto(
  p_caixa_id uuid,
  p_categoria text,
  p_descricao text,
  p_valor numeric,
  p_comprovante_url text
)
returns movimentacoes_caixa
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_mov movimentacoes_caixa%rowtype;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode usar esta função.';
  end if;

  select * into v_caixa from caixa_cobrador where id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;
  if v_caixa.status = 'aprovado' then
    raise exception 'Não é possível lançar gasto numa caixa já aprovada.';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Valor do gasto deve ser maior que zero.';
  end if;
  if coalesce(trim(p_descricao), '') = '' then
    raise exception 'Descrição do gasto é obrigatória.';
  end if;

  insert into movimentacoes_caixa (caixa_id, cobrador_id, tipo, categoria, descricao, valor, foto_comprovante)
  values (p_caixa_id, v_caixa.cobrador_id, 'gasto', p_categoria, p_descricao, p_valor, p_comprovante_url)
  returning * into v_mov;

  return v_mov;
end;
$$;

revoke all on function public.gestor_registrar_gasto(uuid, text, text, numeric, text) from public;
grant execute on function public.gestor_registrar_gasto(uuid, text, text, numeric, text) to authenticated;

create or replace function public.gestor_registrar_deposito(
  p_caixa_id uuid,
  p_valor numeric,
  p_comprovante_url text
)
returns movimentacoes_caixa
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caixa caixa_cobrador%rowtype;
  v_mov movimentacoes_caixa%rowtype;
begin
  if public.meu_perfil() <> 'gestor' then
    raise exception 'Apenas gestor pode usar esta função.';
  end if;

  select * into v_caixa from caixa_cobrador where id = p_caixa_id;
  if not found then
    raise exception 'Caixa não encontrada.';
  end if;
  if v_caixa.status = 'aprovado' then
    raise exception 'Não é possível lançar depósito numa caixa já aprovada.';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Valor do depósito deve ser maior que zero.';
  end if;

  insert into movimentacoes_caixa (caixa_id, cobrador_id, tipo, descricao, valor, foto_comprovante)
  values (p_caixa_id, v_caixa.cobrador_id, 'deposito', 'Depósito', p_valor, p_comprovante_url)
  returning * into v_mov;

  return v_mov;
end;
$$;

revoke all on function public.gestor_registrar_deposito(uuid, numeric, text) from public;
grant execute on function public.gestor_registrar_deposito(uuid, numeric, text) to authenticated;

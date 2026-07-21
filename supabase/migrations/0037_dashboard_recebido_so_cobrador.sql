-- ============================================================================
-- Dashboard do gestor: "Recebido no período" e "Recebido hoje" somavam
-- QUALQUER parcela com pago=true, sem distinguir quem gerou a baixa.
--
-- Hoje uma parcela vira pago=true por dois caminhos bem diferentes:
--   1) registrar_recebimento() (migration 0010) — só cobrador pode chamar
--      (raise exception se meu_perfil() <> 'cobrador'), e SEMPRE cria uma
--      linha em baixas_pendentes.
--   2) botão "Dar baixa" na tela Clientes (confirmarBaixa(), docs/index.html)
--      — um UPDATE direto em parcelas, sem passar por baixas_pendentes. Essa
--      página fica visível tanto pra gestor quanto pra cobrador
--      (aplicarPermissoes: clientes: gestorOuCobrador), mas na prática é o
--      gestor quem usa esse caminho pra lançar recebimento avulso ou
--      corrigir dado antigo — e esses lançamentos entravam como "recebido"
--      no dashboard, inflando os cards do topo com dinheiro que nunca
--      passou pela rotina de cobrança (e que também não aparece em
--      "em mãos" de nenhum cobrador, já que confirmarBaixa() não mexe em
--      caixa_cobrador.saldo_esperado — só esse card já era correto).
--
-- Mesmo princípio já usado nos KPIs de vendas (migration 0004: troca
-- vendedor_id por equipe_id porque só é preenchido quando é o próprio
-- vendedor que registra a venda). Aqui, a existência de uma linha em
-- baixas_pendentes (não cancelada) é o sinal confiável de "baixa feita
-- pela rotina do cobrador", independente de quem depois visualizou ou
-- corrigiu a parcela.
--
-- Somamos baixas_pendentes.valor_recebido (em vez de parcelas.valor_pago)
-- pra tratar direito o caso raro de uma parcela com pagamento parcial feito
-- por um cobrador e o restante quitado manualmente pelo gestor: só a parte
-- que realmente passou pelo cobrador entra no total. O critério de data
-- continua sendo parcelas.data_pagamento (data em que a parcela ficou
-- totalmente quitada) — não mudamos esse critério, só a origem do valor.
--
-- em_maos / a_receber / atrasado_* não mudam:
--   - em_maos já vem só de caixa_cobrador.saldo_esperado, que só o fluxo
--     do cobrador altera.
--   - a_receber e atrasado_* são sobre parcelas EM ABERTO — dívida real do
--     cliente, independe de quem vier a receber (mesmo raciocínio já
--     documentado na migration 0003).
--
-- Rode este script no SQL Editor do Supabase, depois da 0036.
-- Mesma assinatura de sempre (sem default nos parâmetros) — CREATE OR
-- REPLACE simples, sem precisar de DROP.
--
-- ⚠️ Existe também dashboard_cobradores() (mostra um valor "recebido" por
-- cobrador na lista lateral do dashboard) que muito provavelmente tem o
-- mesmo problema, pelo mesmo motivo — mas essa função não está em nenhuma
-- migration deste repositório (foi criada direto no SQL Editor do Supabase
-- Studio, fora do controle de versão), então não dá pra corrigir aqui sem
-- antes ver a definição atual dela.
-- ============================================================================

create or replace function public.dashboard_resumo(p_inicio date, p_fim date)
returns jsonb
language plpgsql
-- security definer
as $$
declare r jsonb;
begin
  if public.meu_perfil() is distinct from 'gestor' then raise exception 'Apenas gestor.'; end if;
  select jsonb_build_object(
    'recebido_periodo', coalesce((
      select sum(bp.valor_recebido)
      from baixas_pendentes bp
      join parcelas p on p.id = bp.parcela_id
      where bp.status <> 'cancelada'
        and p.pago
        and p.data_pagamento::date between p_inicio and p_fim
    ), 0),
    'recebido_hoje', coalesce((
      select sum(bp.valor_recebido)
      from baixas_pendentes bp
      join parcelas p on p.id = bp.parcela_id
      where bp.status <> 'cancelada'
        and p.pago
        and p.data_pagamento::date = current_date
    ), 0),
    'em_maos',          coalesce((select sum(saldo_esperado) from caixa_cobrador where status='aberto'),0),
    'a_receber',        coalesce((select sum(valor - coalesce(valor_pago,0)) from parcelas where not pago and coalesce(status,'')<>'devolvida'),0),
    'atrasado_valor',   coalesce((select sum(valor - coalesce(valor_pago,0)) from parcelas where not pago and coalesce(status,'')<>'devolvida' and data_vencimento::date < current_date),0),
    'atrasado_clientes',(select count(distinct cliente_id) from parcelas where not pago and coalesce(status,'')<>'devolvida' and data_vencimento::date < current_date),
    'vendas_qtd',       (select count(*) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null),
    'vendas_valor',     coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null),0),
    'vendas_avista_valor',    coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null and tipo='avista'),0),
    'vendas_crediario_valor', coalesce((select sum(valor) from vendas where data_venda::date between p_inicio and p_fim and coalesce(status,'')<>'devolvida' and equipe_id is not null and tipo='entrada'),0)
  ) into r;
  return r;
end;
$$;

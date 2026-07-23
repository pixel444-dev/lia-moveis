-- 0041 — Corrige parcelas cujo ANO de vencimento ficou com poucos dígitos
-- (ex.: 0026 no lugar de 2026), fazendo a venda inteira aparecer como
-- "Atrasada" na cobrança.
--
-- CAUSA
--   No cadastro da venda, a "data da primeira parcela" foi digitada com o ano
--   incompleto no <input type="date"> — digitar só "26" no campo do ano grava
--   o valor "0026-08-30". O criar_venda() gera todas as parcelas a partir
--   dessa data com add_months_like_js(), então TODAS herdam o ano errado
--   (0026/0027...). Como esse ano fica ~2000 anos no passado,
--   data_vencimento < hoje é sempre verdadeiro e o app (index.html, regra
--   `const atrasada = vencimento < hoje;`) marca cada parcela como "Atrasada".
--
-- CORREÇÃO
--   Nas parcelas com ano < 100, soma 2000 anos: 0026 -> 2026, 0027 -> 2027,
--   etc. (mês e dia são preservados). A trava de validação no app impede que
--   novas parcelas sejam gravadas assim.
--
-- SEGURANÇA / IDEMPOTÊNCIA
--   Nenhuma parcela legítima deste sistema tem ano < 100, então o filtro
--   atinge só as linhas corrompidas. Depois de rodar não sobra nenhuma linha
--   com ano < 100 — rodar de novo não altera nada.

do $$
declare
  v_qtd int;
begin
  update public.parcelas
     set data_vencimento = (data_vencimento + interval '2000 years')::date
   where extract(year from data_vencimento) < 100;

  get diagnostics v_qtd = row_count;
  raise notice 'Parcelas com ano de vencimento corrigido (+2000 anos): %', v_qtd;
end $$;

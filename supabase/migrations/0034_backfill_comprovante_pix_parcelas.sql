-- ============================================================================
-- Backfill do bug corrigido na 0033: parcelas pagas via PIX ANTES desta
-- correção têm o comprovante certinho em `baixas_pendentes.comprovante_pix`
-- (o upload sempre funcionou), mas `parcelas.comprovante_pix` ficou vazio —
-- é por isso que o cobrador via o recibo pago mas não conseguia abrir o
-- comprovante ("recibo via pix mas o comprovante não ficava vinculado à
-- parcela"). A 0033 já resolve daqui pra frente; esta migration acerta o
-- histórico.
--
-- Pega, por parcela, o comprovante da baixa PIX não-cancelada mais recente
-- (`distinct on ... order by criado_em desc`) — mesma baixa cujo
-- `forma_pagamento`/valor já refletem o estado atual da parcela, já que
-- `registrar_recebimento()` sempre sobrescreve `parcelas.forma_pagamento`
-- a cada chamada. Só toca parcelas com `comprovante_pix` ainda nulo — não
-- sobrescreve nada que a 0033 (ou uma correção manual) já tenha preenchido.
--
-- Rode este script no SQL Editor do Supabase, depois da 0033.
-- ============================================================================

update parcelas p
set comprovante_pix = ultima.comprovante_pix
from (
  select distinct on (bp.parcela_id) bp.parcela_id, bp.comprovante_pix
  from baixas_pendentes bp
  where bp.forma_pagamento = 'pix'
    and bp.comprovante_pix is not null
    and bp.status <> 'cancelada'
  order by bp.parcela_id, bp.criado_em desc
) ultima
where p.id = ultima.parcela_id
  and p.comprovante_pix is null;

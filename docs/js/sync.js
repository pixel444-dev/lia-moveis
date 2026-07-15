// ─── MOTOR DE SINCRONIZAÇÃO OFFLINE → SUPABASE ────────────────
// Lê a fila local (DbLocal.listarOperacoesPendentes) e reexecuta cada
// operação contra o Supabase quando há conexão. Genérico de propósito:
// não conhece nenhuma tabela — os handlers de cada tipo de operação são
// registrados por docs/js/sync-handlers.js via Sync.registrarHandler().
// Na versão web (sem SQLite nativo) a fila está sempre vazia e o motor
// vira um no-op barato.
(function () {
  'use strict';

  // Regra de ouro (violada uma vez, na prática, com uma venda de campo
  // perdida de verdade): nenhuma operação — venda, baixa, recebimento,
  // cadastro — pode ser apagada sozinha pelo sistema só porque falhou
  // muitas vezes seguidas. Só existem dois destinos possíveis aqui:
  //   1. sincronizado — deu certo, some da fila.
  //   2. continua tentando pra sempre (erro comum/rede) OU passa a
  //      'descartada' (erro definitivo — nunca vai dar certo sozinho),
  //      mas em NENHUM dos dois casos o registro é apagado do banco local:
  //      'descartada' só tira do ciclo automático de retry, o payload
  //      inteiro continua ali, visível na tela de Pendências, até um
  //      humano decidir manualmente reenviar ou apagar de vez
  //      (ver DbLocal.reenviarOperacao / apagarOperacaoDefinitivamente).
  var handlers = {};
  var rodando = false;

  // Erro de negócio definitivo: repetir nunca vai dar certo (ex.: parcela
  // já baixada por outra pessoa). A operação é descartada na hora, com o
  // motivo guardado em erro_msg para auditoria.
  function ErroDefinitivo(mensagem) {
    var e = new Error(mensagem);
    e.nome_interno = 'ErroDefinitivo';
    return e;
  }
  function ehDefinitivo(err) {
    return !!(err && err.nome_interno === 'ErroDefinitivo');
  }

  function registrarHandler(tipo, fn) {
    handlers[tipo] = fn;
  }

  // Token expirado logo após a rede voltar (o autorefresh do supabase-js
  // ainda não rodou): não é falha da operação — interrompe a rodada sem
  // contar tentativa, igual a erro de rede.
  function _ehErroDeToken(err) {
    var msg = String((err && (err.message || err.msg)) || err || '');
    var code = (err && err.code) || '';
    return code === 'PGRST301' || /jwt|token|401|unauthorized/i.test(msg);
  }

  async function atualizarContadorFila(sincronizando) {
    if (!window.DbLocal || !window.NetStatus) return 0;
    var n = 0, travadas = 0;
    try {
      n = await DbLocal.contarOperacoesPendentes();
      travadas = await DbLocal.contarOperacoesTravadas();
    } catch (e) { /* indicador é cosmético */ }
    NetStatus.atualizarFila(n, !!sincronizando, travadas);
    return n;
  }

  async function sincronizarAgora() {
    if (rodando) return;
    // Só sincroniza com usuário logado: sem o token da sessão o RLS do
    // Supabase recusaria tudo e as recusas contariam como tentativas de
    // negócio. O index.html liga esta trava no login e desliga no logout.
    if (window._syncLiberado !== true) return;
    if (!window.DbLocal || !window.NetStatus) return;
    if (!NetStatus.estaOnline()) { atualizarContadorFila(false); return; }

    rodando = true;
    var sincronizadas = 0;
    try {
      var ops = await DbLocal.listarOperacoesPendentes();
      if (!ops.length) return;
      console.log('[SYNC] Iniciando: ' + ops.length + ' operação(ões) na fila.');
      await atualizarContadorFila(true);

      for (var i = 0; i < ops.length; i++) {
        var op = ops[i];
        var handler = handlers[op.tipo];
        if (!handler) {
          // Tipo que este build não conhece (fila gravada por versão mais
          // nova?) — deixa na fila, sem contar tentativa.
          console.warn('[SYNC] Sem handler para o tipo "' + op.tipo + '" — operação mantida na fila.');
          continue;
        }
        var payload = null;
        try { payload = JSON.parse(op.payload); } catch (e) {
          await DbLocal.atualizarStatusOperacao(op.id, 'descartada', 'Payload corrompido: ' + e.message);
          continue;
        }
        try {
          await handler(payload, op);
          await DbLocal.atualizarStatusOperacao(op.id, 'sincronizado');
          sincronizadas++;
        } catch (err) {
          var msg = String((err && err.message) || err || 'erro desconhecido');
          if (NetStatus.ehErroDeRede(err) || _ehErroDeToken(err)) {
            console.warn('[SYNC] Rede/sessão indisponível no meio da rodada — parando por agora.', msg);
            break;
          }
          if (ehDefinitivo(err)) {
            // Só erro definitivo (nunca contagem de tentativas) tira a
            // operação do ciclo automático — e mesmo assim ela NÃO é
            // apagada, só marcada. Continua inteira, visível na tela de
            // Pendências, até um humano decidir (ver DbLocal.
            // listarOperacoesTravadas / apagarOperacaoDefinitivamente).
            console.error('[SYNC] Operação ' + op.id + ' (' + op.tipo + ') não pôde ser reenviada automaticamente: ' + msg);
            await DbLocal.atualizarStatusOperacao(op.id, 'descartada', msg);
            if (typeof Logger !== 'undefined') {
              Logger.error('sync', 'OPERACAO_PRECISA_ATENCAO', 'Operação offline não sincronizou sozinha — precisa de revisão manual', { tipo: op.tipo, operacao_id: op.id, erro: msg });
            }
          } else {
            // Nunca desiste sozinho por excesso de tentativas: um dado de
            // campo (venda, baixa, recebimento) não pode sumir só porque
            // um número arbitrário de tentativas foi atingido. Continua
            // pendente pra sempre; "tentativas" é só informativo, usado
            // pela tela de Pendências pra sinalizar "está demorando".
            console.warn('[SYNC] Operação ' + op.id + ' (' + op.tipo + ') falhou (tentativa ' + ((Number(op.tentativas) || 0) + 1) + '): ' + msg);
            await DbLocal.registrarTentativa(op.id, msg);
          }
        }
      }
    } catch (err) {
      console.error('[SYNC] Falha inesperada na rodada de sincronização.', err);
    } finally {
      rodando = false;
      var restantes = await atualizarContadorFila(false);
      if (sincronizadas > 0) {
        console.log('[SYNC] Concluído: ' + sincronizadas + ' sincronizada(s), ' + restantes + ' restante(s).');
        try {
          window.dispatchEvent(new CustomEvent('sync:concluido', { detail: { sincronizadas: sincronizadas, restantes: restantes } }));
        } catch (e) { /* evento é opcional */ }
      }
    }
  }

  // Rede que "pisca" no campo: além dos gatilhos explícitos (login, volta
  // da conexão), uma varredura periódica garante que nada fica esquecido.
  // Com a fila vazia custa uma consulta local a cada tique.
  setInterval(function () {
    if (window.NetStatus && NetStatus.estaOnline()) sincronizarAgora();
  }, 90000);

  window.Sync = {
    registrarHandler: registrarHandler,
    sincronizarAgora: sincronizarAgora,
    atualizarContadorFila: atualizarContadorFila,
    ErroDefinitivo: ErroDefinitivo
  };
})();

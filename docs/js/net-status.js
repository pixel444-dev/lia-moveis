// ─── STATUS DE REDE (online/offline) ──────────────────────────
// Fonte da verdade sobre conectividade para toda a camada offline.
// No app nativo usa o plugin @capacitor/network (eventos do Android);
// no navegador cai no fallback navigator.onLine + eventos da janela.
// Também é dono do indicador visual de offline/sincronização.
(function () {
  'use strict';

  var online = (typeof navigator === 'undefined') ? true : navigator.onLine !== false;
  var callbacks = [];
  var qtdPendentes = 0;
  var qtdTravadas = 0;
  var sincronizando = false;

  // ─── Disjuntor de rede ("circuit breaker") ──────────────────
  // O plugin de rede diz "connected" sempre que há rádio ligado — inclusive
  // em zona morta / torre congestionada / portal cativo, onde NÃO existe
  // internet utilizável. Nesse estado estaOnline() é true, então cada leitura
  // do Supabase esperava o timeout INTEIRO antes de cair no cache, e abrir uma
  // ficha/parcelas (que dispara VÁRIAS leituras) parecia travar o app — era a
  // causa central da lentidão offline do cobrador em campo.
  //
  // O disjuntor aprende com a primeira falha de rede: a partir daí TODA
  // chamada é curto-circuitada na hora (cai no cache instantâneo, igual ao
  // offline de verdade), então só a PRIMEIRA leitura ao entrar na zona morta
  // paga o timeout — todas as seguintes são instantâneas. Enquanto o disjuntor
  // está aberto, uma sondagem leve roda em SEGUNDO PLANO (fora do caminho do
  // usuário, ver _sondarConectividade em index.html) só pra descobrir quando a
  // internet voltar; aí o disjuntor fecha, os dados voltam a ser ao vivo e a
  // fila offline é descarregada.
  var LIMITE_FALHAS_REDE = 1;        // falhas de rede seguidas até presumir offline
  var INTERVALO_SONDAGEM_MS = 4000;  // intervalo entre sondagens de reconexão em segundo plano
  var falhasSeguidasRede = 0;
  var disjuntorAberto = false;       // true = presumido offline (curto-circuita tudo)
  var timerSondagem = null;          // setTimeout da próxima sondagem

  function estaOnline() {
    return online;
  }

  function onMudanca(cb) {
    if (typeof cb === 'function') callbacks.push(cb);
  }

  function _notificar(estado) {
    for (var i = 0; i < callbacks.length; i++) {
      try { callbacks[i](estado); } catch (e) { console.error('[NET] Callback de mudança falhou.', e); }
    }
  }

  function _mudou(novoEstado) {
    novoEstado = !!novoEstado;
    if (novoEstado === online) return;
    online = novoEstado;
    console.log('[NET] Conexão mudou: ' + (online ? 'ONLINE' : 'OFFLINE'));
    // Reconexão real (plugin/navegador): fecha o disjuntor pra recomeçar limpo
    // (a notificação de reconexão sai logo abaixo, no _notificar).
    if (online) _fecharDisjuntor(false);
    atualizarIndicador();
    _notificar(online);
  }

  // ─── Decisões e realimentação do disjuntor ──────────────────
  // Chamado por _fetchComRede (index.html) ANTES de cada requisição: true =
  // rejeita na hora sem tocar na rede (cai no cache). Cobre tanto o offline
  // de fato quanto a zona morta detectada pelo disjuntor.
  function deveCurtoCircuitarRede() {
    return !online || disjuntorAberto;
  }

  function _abrirDisjuntor() {
    if (disjuntorAberto) return;
    disjuntorAberto = true;
    atualizarIndicador();  // reflete "modo offline" pro cobrador
    _agendarSondagem();    // passa a sondar a volta da internet em segundo plano
  }

  function _fecharDisjuntor(notificarReconexao) {
    var estavaAberto = disjuntorAberto;
    disjuntorAberto = false;
    falhasSeguidasRede = 0;
    if (timerSondagem) { clearTimeout(timerSondagem); timerSondagem = null; }
    if (estavaAberto) {
      atualizarIndicador();
      // Recuperação de zona morta: a internet voltou sem o plugin nunca ter
      // mudado de estado (ficou "connected" o tempo todo). Dispara a rotina de
      // reconexão (renovar sessão + descarregar a fila), a mesma do onMudanca.
      if (notificarReconexao) _notificar(true);
    }
  }

  // Sondagem de reconexão em segundo plano: enquanto o disjuntor está aberto,
  // pergunta ao index.html (que tem o endpoint) se a rede voltou. NUNCA fica
  // no caminho de uma tela — as telas já caíram no cache instantaneamente, e
  // é só esta sondagem que paga o custo de descobrir a volta da internet.
  function _agendarSondagem() {
    if (timerSondagem || !disjuntorAberto) return;
    timerSondagem = setTimeout(function () {
      timerSondagem = null;
      if (!disjuntorAberto || !online) return;
      var sondar = (typeof window !== 'undefined') && window._sondarConectividade;
      if (typeof sondar !== 'function') { _agendarSondagem(); return; } // endpoint ainda não pronto
      Promise.resolve().then(sondar).then(function (redeOk) {
        if (redeOk) _fecharDisjuntor(true);
        else _agendarSondagem();
      }).catch(function () { _agendarSondagem(); });
    }, INTERVALO_SONDAGEM_MS);
  }

  // Chamado por _fetchComRede DEPOIS de cada requisição real. sucesso=true
  // quando a rede respondeu (qualquer status HTTP, inclusive 4xx/5xx — o
  // transporte funcionou); sucesso=false quando o fetch falhou por rede
  // (timeout/DNS/conexão recusada).
  function registrarResultadoRede(sucesso) {
    if (sucesso) {
      _fecharDisjuntor(true);
    } else {
      falhasSeguidasRede++;
      if (falhasSeguidasRede >= LIMITE_FALHAS_REDE) _abrirDisjuntor();
    }
  }

  // Offline pro que interessa à tela: sem rede de fato OU disjuntor aberto.
  // O indicador visual usa isto pra ser honesto com o cobrador (mostrar
  // "modo offline" na zona morta em vez de um spinner de sincronização).
  function estaEfetivamenteOffline() {
    return !online || disjuntorAberto;
  }

  // Heurística para "essa falha foi por falta de rede?". Cobre o formato
  // que o supabase-js devolve quando o fetch em si falha ("TypeError:
  // Failed to fetch" vira error.message do PostgREST; o gotrue lança
  // AuthRetryableFetchError) e as mensagens dos engines WebView/Chromium.
  // Se o próprio sistema já sabe que está offline, qualquer erro de
  // consulta é tratado como erro de rede — offline não existe resposta
  // parcial confiável.
  function ehErroDeRede(err) {
    // Efetivamente offline (sem rede de fato OU disjuntor aberto): qualquer
    // erro de consulta é tratado como erro de rede — cai no cache na hora.
    if (estaEfetivamenteOffline()) return true;
    if (!err) return false;
    var msg = (typeof err === 'string') ? err : (err.message || err.msg || '');
    if (err.name === 'AuthRetryableFetchError') return true;
    // TimeoutError/AbortError: leitura abortada pelo timeout do fetch com
    // consciência de rede (index.html, _fetchComRede) — "conectado mas sem
    // internet" também é falta de rede pra quem está esperando a tela.
    if (err.name === 'TimeoutError' || err.name === 'AbortError') return true;
    return /failed to fetch|networkerror|network request failed|load failed|fetch failed|err_internet_disconnected|err_name_not_resolved|err_connection|err_network|network error|timed out|signal is aborted/i.test(String(msg));
  }

  // ─── Indicador visual ───────────────────────────────────────
  // Pílula fixa no rodapé: some quando online e sem pendências.
  function _garantirElemento() {
    var el = document.getElementById('indicador-offline');
    if (el || !document.body) return el;
    el = document.createElement('div');
    el.id = 'indicador-offline';
    el.style.cssText = 'display:none;position:fixed;bottom:14px;left:50%;transform:translateX(-50%);z-index:99999;'
      + 'background:#1a1a1a;color:#fff;font-size:13px;font-weight:600;padding:10px 18px;border-radius:999px;'
      + 'box-shadow:0 4px 14px rgba(0,0,0,.25);max-width:92vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'
      + 'font-family:inherit;';
    el.onclick = function () { if (window.abrirPendenciasOffline) window.abrirPendenciasOffline(); };
    document.body.appendChild(el);
    return el;
  }

  function _atualizarBadgeMenu() {
    var badge = document.getElementById('badge-pendencias-offline');
    if (!badge) return;
    var total = qtdTravadas + qtdPendentes;
    if (total > 0) {
      badge.textContent = String(total);
      badge.style.display = 'inline-block';
      badge.style.background = qtdTravadas > 0 ? '#A32D2D' : '#854F0B';
    } else {
      badge.style.display = 'none';
    }
  }

  function atualizarIndicador() {
    _atualizarBadgeMenu();
    var el = _garantirElemento();
    if (!el) return;
    // Prioridade máxima e SEM CONDIÇÃO PRA SUMIR: enquanto houver operação
    // que o motor desistiu de reenviar sozinho, o indicador fica visível e
    // clicável (leva pra tela de Pendências) até um humano decidir o que
    // fazer — nunca mais "sumiu sem avisar" (ver incidente real de uma
    // venda de campo perdida quando isso não existia).
    if (qtdTravadas > 0) {
      el.textContent = '⚠️ ' + qtdTravadas + ' operação(ões) precisam de atenção — toque para ver';
      el.style.background = '#A32D2D';
      el.style.display = 'block';
      el.style.cursor = 'pointer';
      el.style.pointerEvents = 'auto';
      return;
    }
    el.style.cursor = qtdPendentes > 0 ? 'pointer' : 'default';
    el.style.pointerEvents = qtdPendentes > 0 ? 'auto' : 'none';
    if (estaEfetivamenteOffline()) {
      el.textContent = '📴 Sem conexão — modo offline'
        + (qtdPendentes > 0 ? ' · ' + qtdPendentes + ' operação(ões) na fila' : '');
      el.style.background = '#A32D2D';
      el.style.display = 'block';
    } else if (sincronizando) {
      el.textContent = '🔄 Sincronizando ' + (qtdPendentes > 0 ? qtdPendentes + ' operação(ões)...' : '...');
      el.style.background = '#185FA5';
      el.style.display = 'block';
    } else if (qtdPendentes > 0) {
      el.textContent = '⏳ ' + qtdPendentes + ' operação(ões) aguardando sincronização';
      el.style.background = '#854F0B';
      el.style.display = 'block';
    } else {
      el.style.display = 'none';
    }
  }

  // Chamado pelo motor de sincronização para refletir o estado da fila.
  function atualizarFila(pendentes, estaSincronizando, travadas) {
    qtdPendentes = Number(pendentes) || 0;
    sincronizando = !!estaSincronizando;
    qtdTravadas = Number(travadas) || 0;
    atualizarIndicador();
  }

  function _iniciar() {
    var usouPlugin = false;
    try {
      if (typeof capacitorNetwork !== 'undefined' && capacitorNetwork.Network) {
        var Network = capacitorNetwork.Network;
        Network.getStatus().then(function (s) { _mudou(s && s.connected); }).catch(function () {});
        Network.addListener('networkStatusChange', function (s) { _mudou(s && s.connected); });
        usouPlugin = true;
      }
    } catch (e) {
      console.error('[NET] Plugin de rede indisponível — usando fallback do navegador.', e);
    }
    // Mesmo com o plugin ativo, os eventos do navegador não atrapalham
    // (ambos convergem para o mesmo _mudou) e cobrem o caso do plugin
    // demorar a emitir o primeiro evento.
    window.addEventListener('online', function () { _mudou(true); });
    window.addEventListener('offline', function () { _mudou(false); });
    if (!usouPlugin && typeof navigator !== 'undefined') _mudou(navigator.onLine !== false);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', atualizarIndicador);
    } else {
      atualizarIndicador();
    }
  }

  _iniciar();

  window.NetStatus = {
    estaOnline: estaOnline,
    onMudanca: onMudanca,
    ehErroDeRede: ehErroDeRede,
    atualizarFila: atualizarFila,
    atualizarIndicador: atualizarIndicador,
    deveCurtoCircuitarRede: deveCurtoCircuitarRede,
    registrarResultadoRede: registrarResultadoRede,
    estaEfetivamenteOffline: estaEfetivamenteOffline
  };
})();

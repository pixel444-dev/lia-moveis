// ─── HANDLERS DE SINCRONIZAÇÃO + FLUXOS OFFLINE ───────────────
// Duas responsabilidades, sempre em par:
//  1. Handlers que o motor (sync.js) usa para reexecutar no Supabase as
//     operações enfileiradas offline (Sync.registrarHandler).
//  2. window.OfflineFlow — helpers que o index.html chama para ENTRAR no
//     modo offline: enfileirar uma ação que falhou por rede, ler dados do
//     cache local quando a busca online falhar, sessão/perfil offline.
// Este arquivo referencia globals do index.html (sb, Logger, gerarCodigo-
// Cliente, funcionarioLogado) sempre de forma tardia — só dentro de
// funções chamadas depois do app inicializado.
(function () {
  'use strict';

  // ─── Conversões de foto (Blob em memória ⇄ base64 na fila) ──
  function blobParaBase64(blob) {
    return new Promise(function (resolve, reject) {
      var leitor = new FileReader();
      leitor.onload = function () {
        // resultado vem como data URL ("data:image/webp;base64,....")
        var s = String(leitor.result || '');
        resolve(s.slice(s.indexOf(',') + 1));
      };
      leitor.onerror = function () { reject(leitor.error || new Error('Falha ao ler a foto.')); };
      leitor.readAsDataURL(blob);
    });
  }

  function base64ParaBlob(b64, contentType) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Blob([bytes], { type: contentType });
  }

  // Erro vindo do Supabase → decide se vale retry. Códigos de integridade,
  // permissão ou exceção de regra de negócio (RAISE no Postgres) nunca vão
  // passar repetindo — viram ErroDefinitivo e a operação é descartada com
  // o motivo guardado.
  function erroDeBanco(error) {
    var msg = (error && error.message) || 'Erro no banco';
    var code = String((error && error.code) || '');
    if (/^(22|23|42|P0)/.test(code) || code === 'PGRST116') {
      return Sync.ErroDefinitivo(msg + ' [' + code + ']');
    }
    var e = new Error(msg + (code ? ' [' + code + ']' : ''));
    e.code = code;
    return e;
  }

  // ─── Handlers da fila ────────────────────────────────────────

  // Registros do autoteste das fases 1/2 (DbLocal.testarDbLocal) — não há
  // o que enviar; marcar como sincronizado limpa a fila herdada.
  Sync.registrarHandler('teste', async function () { });

  // Antes de criar um cliente "novo" offline, verifica se já existe alguém
  // com o mesmo CPF — pode ter sido cadastrado por outra via (outro
  // vendedor, tela online) enquanto este aparelho estava sem rede, ou o
  // cliente já existir e simplesmente nunca ter passado pelo cache deste
  // celular (por isso a busca offline não achou). Em qualquer um desses
  // casos a pessoa da venda é a MESMA pessoa real — atualiza o cadastro que
  // já existe com os dados frescos coletados em campo, em vez de tentar
  // inserir um duplicado (que ou falha travando a venda pra sempre, ou —
  // pior, se não houver uma restrição de unicidade no banco — cria mesmo
  // um segundo cliente pra mesma pessoa, com histórico de compra separado).
  // Devolve o registro existente já atualizado, ou null se não achou ninguém.
  async function _reconciliarClientePorCpf(dados) {
    if (!dados.cpf) return null;
    var existente = await sb.from('clientes').select('id').eq('cpf', dados.cpf).maybeSingle();
    if (existente.error) throw erroDeBanco(existente.error);
    if (!existente.data) return null;
    // Mesma regra do fluxo online (salvarNovoClienteVenda ao editar um
    // cliente encontrado por CPF): só sobrescreve campo opcional se o
    // vendedor realmente informou algo — o formulário de "cliente novo"
    // não veio pré-preenchido com o cadastro existente, então um campo
    // vazio aqui não pode apagar um dado real que já estava salvo.
    var dadosUpdate = { nome: dados.nome, cpf: dados.cpf, endereco: dados.endereco, cidade: dados.cidade, municipio_id: dados.municipio_id };
    ['telefone', 'data_nascimento', 'bairro', 'referencia', 'cobrador_id', 'latitude', 'longitude', 'localizacao_endereco'].forEach(function (campo) {
      if (dados[campo]) dadosUpdate[campo] = dados[campo];
    });
    var upd = await sb.from('clientes').update(dadosUpdate).eq('id', existente.data.id);
    if (upd.error) throw erroDeBanco(upd.error);
    var atualizado = await sb.from('clientes').select('*').eq('id', existente.data.id).single();
    return atualizado.data || { id: existente.data.id };
  }

  // payload: { clienteId (uuid real p/ edição, "offline-..." p/ novo),
  //            dados: {...}, fotoBase64, etapa?, clienteIdReal? }
  Sync.registrarHandler('cliente_upsert', async function (payload, op) {
    var ehNovo = !payload.clienteId || /^offline-/.test(String(payload.clienteId));
    var clienteId = payload.clienteIdReal || (ehNovo ? null : payload.clienteId);

    if (payload.etapa !== 'foto') {
      if (ehNovo) {
        var dados = Object.assign({}, payload.dados);
        var novo = await _reconciliarClientePorCpf(dados);
        if (!novo) {
          var error = null;
          for (var t = 0; t < 3; t++) {
            // código gerado AGORA, online — o que o formulário mostrava
            // offline não é confiável (o gerador precisa do servidor)
            dados.codigo = await gerarCodigoCliente();
            var res = await sb.from('clientes').insert(dados).select().single();
            novo = res.data; error = res.error;
            if (!error) break;
            if (error.code !== '23505') break;
            // Colisão pode ser no código (a próxima volta do loop já
            // resolve, gerando outro) OU no CPF — nesse caso gerar outro
            // código nunca ia resolver, porque é a MESMA pessoa cadastrada
            // por outra via bem no meio destas tentativas. Reconcilia de
            // novo antes de insistir.
            var reconciliado = await _reconciliarClientePorCpf(dados);
            if (reconciliado) { novo = reconciliado; error = null; break; }
          }
          if (error) throw erroDeBanco(error);
        }
        clienteId = novo.id;
        // troca o registro temporário do cache pelo definitivo
        if (payload.clienteId) await DbLocal.removerDoCache('clientes', payload.clienteId);
        await DbLocal.salvarNoCache('clientes', [novo]);
        // Uma venda enfileirada no mesmo momento (cliente novo + venda na
        // mesma visita, ambos offline) referencia o id temporário — grava o
        // de-para pro handler de venda_criar resolver antes de chamar a RPC.
        if (payload.clienteId && /^offline-/.test(String(payload.clienteId))) {
          await DbLocal.salvarNoCache('cliente_id_map', [{ id: payload.clienteId, real_id: clienteId }]);
        }
      } else {
        var resUpd = await sb.from('clientes').update(payload.dados).eq('id', clienteId);
        if (resUpd.error) throw erroDeBanco(resUpd.error);
        await DbLocal.salvarNoCache('clientes', [Object.assign({ id: clienteId }, payload.dados)]);
      }
      if (payload.fotoBase64) {
        // insert/update já valeu — persiste o progresso pra um retry
        // (ex.: rede caiu no meio do upload) não duplicar o cliente
        payload.etapa = 'foto';
        payload.clienteIdReal = clienteId;
        await DbLocal.atualizarPayloadOperacao(op.id, payload);
      }
    }

    if (payload.fotoBase64 && clienteId) {
      var blob = base64ParaBlob(payload.fotoBase64, 'image/webp');
      var path = 'clientes/' + clienteId + '.webp';
      var up = await sb.storage.from('fotos-clientes').upload(path, blob, { contentType: 'image/webp', upsert: true });
      if (up.error) throw erroDeBanco(up.error);
      var pub = sb.storage.from('fotos-clientes').getPublicUrl(path);
      var resFoto = await sb.from('clientes').update({ foto_casa: pub.data.publicUrl }).eq('id', clienteId);
      if (resFoto.error) throw erroDeBanco(resFoto.error);
    }
  });

  // payload: { parcelaId, tipo ('completa'|'parcial'), valorPago, forma,
  //            data (YYYY-MM-DD), cobradorId, etapa?, _mov? }
  // Mesma lógica do confirmarBaixa online, em 2 etapas persistidas para o
  // retry nunca aplicar a mesma baixa duas vezes.
  Sync.registrarHandler('baixa_parcela', async function (payload, op) {
    if (payload.etapa !== 'movimentacao') {
      var busca = await sb.from('parcelas')
        .select('valor, valor_pago, cliente_id, pago, vendas(codigo)')
        .eq('id', payload.parcelaId).single();
      if (busca.error) throw erroDeBanco(busca.error);
      var parcela = busca.data;
      if (!parcela) throw Sync.ErroDefinitivo('Parcela não encontrada no servidor.');
      if (parcela.pago) throw Sync.ErroDefinitivo('Parcela já estava baixada no servidor.');

      var valorParcela = Number(parcela.valor) || 0;
      var pagoAnterior = Number(parcela.valor_pago) || 0;
      var saldoAtual = Math.round((valorParcela - pagoAnterior) * 100) / 100;
      var tipo = payload.tipo;
      var valorPago = Number(payload.valorPago) || 0;
      // o dinheiro já foi recebido em campo — se o valor cobre o saldo
      // que o servidor conhece agora, a baixa vira completa
      if (tipo === 'parcial' && valorPago >= saldoAtual) tipo = 'completa';
      var pago = tipo === 'completa';
      var valorRecebidoAgora = pago ? saldoAtual : valorPago;

      var atualizacao = {
        pago: pago,
        status: pago ? 'paga' : 'aberta',
        data_pagamento: pago ? new Date(payload.data).toISOString() : null,
        cobrador_id: payload.cobradorId || null,
        valor_pago: pago ? valorParcela : Math.round((pagoAnterior + valorPago) * 100) / 100,
        forma_pagamento: payload.forma,
      };
      var upd = await sb.from('parcelas').update(atualizacao).eq('id', payload.parcelaId).eq('pago', false).select();
      if (upd.error) throw erroDeBanco(upd.error);
      if (!upd.data || !upd.data.length) throw Sync.ErroDefinitivo('Parcela já baixada por outra pessoa.');

      payload.etapa = 'movimentacao';
      payload._mov = {
        cobrador_id: payload.cobradorId || null,
        cliente_id: parcela.cliente_id,
        tipo: 'cobranca',
        descricao: 'Parcela venda ' + ((parcela.vendas && parcela.vendas.codigo) || '') + ' — ' + (tipo === 'parcial' ? 'parcial' : 'completa'),
        valor: valorRecebidoAgora,
        forma_pagamento: payload.forma,
      };
      await DbLocal.atualizarPayloadOperacao(op.id, payload);
    }

    if (payload._mov) {
      var mov = await sb.from('movimentacoes_cobranca').insert(payload._mov);
      if (mov.error) throw erroDeBanco(mov.error);
    }
  });

  // payload: { params } — exatamente os parâmetros da RPC criar_venda,
  // que é atômica no servidor (código, parcelas, itens, estoque, equipe).
  Sync.registrarHandler('venda_criar', async function (payload) {
    var params = payload.params;
    // Cliente cadastrado na mesma visita, também offline: params.p_cliente_id
    // ainda é o id temporário "offline-...". A fila é processada em ordem de
    // criação (cliente_upsert sempre foi enfileirado antes desta venda), então
    // o de-para gravado pelo handler de cliente_upsert já deveria existir —
    // se não existir ainda (ex.: aquele registro falhou e está reagendado),
    // um erro comum (não de rede, não definitivo) mantém esta venda pendente
    // pro próximo ciclo em vez de descartá-la.
    if (params.p_cliente_id && /^offline-/.test(String(params.p_cliente_id))) {
      var mapa = await DbLocal.lerDoCache('cliente_id_map');
      var achado = mapa.find(function (m) { return m.id === params.p_cliente_id; });
      if (!achado) throw new Error('Cliente cadastrado offline nesta venda ainda não sincronizou.');
      params = Object.assign({}, params, { p_cliente_id: achado.real_id });
    }
    var res = await sb.rpc('criar_venda', params);
    if (res.error) throw erroDeBanco(res.error);
  });

  // payload: { parcelaId, tipo ('completo'|'parcial'), valorRecebido,
  //            forma, observacao, comprovanteBase64?, comprovanteExt?,
  //            nomeArquivo?, comprovanteUrl? }
  // Fluxo de campo do cobrador: registrar_recebimento() é atômica no
  // servidor (baixa_pendente + parcela + caixa). O comprovante PIX tirado
  // offline viaja em base64 na fila; o upload usa o nome de arquivo
  // sorteado NA HORA DO ENFILEIRAMENTO (upsert idempotente) e o progresso
  // é persistido para o retry não subir o arquivo de novo.
  Sync.registrarHandler('recebimento_registrar', async function (payload, op) {
    if (payload.comprovanteBase64 && !payload.comprovanteUrl) {
      var contentType = payload.comprovanteExt === 'pdf' ? 'application/pdf' : 'image/webp';
      var blob = base64ParaBlob(payload.comprovanteBase64, contentType);
      var up = await sb.storage.from('comprovantes').upload(payload.nomeArquivo, blob, { contentType: contentType, upsert: true });
      if (up.error) throw erroDeBanco(up.error);
      payload.comprovanteUrl = sb.storage.from('comprovantes').getPublicUrl(payload.nomeArquivo).data.publicUrl;
      payload.comprovanteBase64 = null; // binário já está no servidor
      await DbLocal.atualizarPayloadOperacao(op.id, payload);
    }
    var res = await sb.rpc('registrar_recebimento', {
      p_parcela_id: payload.parcelaId,
      p_tipo: payload.tipo,
      p_valor_recebido: payload.valorRecebido,
      p_forma: payload.forma,
      p_observacao: payload.observacao || null,
      p_comprovante_url: payload.comprovanteUrl || null,
    });
    if (res.error) throw erroDeBanco(res.error);
  });

  // ─── Helpers de entrada no modo offline (chamados do index.html) ──

  function _nativo() {
    return typeof Capacitor !== 'undefined'
      && typeof Capacitor.getPlatform === 'function'
      && Capacitor.getPlatform() !== 'web';
  }

  function _nsCarteira() {
    var id = (typeof funcionarioLogado !== 'undefined' && funcionarioLogado && funcionarioLogado.id) || 'anon';
    return 'clientes_cobrador:' + id;
  }

  // Une o cache geral de clientes com a carteira do cobrador, preferindo,
  // para o mesmo id, o registro mais completo (mais campos preenchidos).
  async function _clientesDoCacheUnificado() {
    if (!window.DbLocal) return [];
    var listas = await Promise.all([DbLocal.lerDoCache('clientes'), DbLocal.lerDoCache(_nsCarteira())]);
    var mapa = new Map();
    listas[0].concat(listas[1]).forEach(function (c) {
      if (!c || c.id == null) return;
      var atual = mapa.get(String(c.id));
      if (!atual || Object.keys(c).length >= Object.keys(atual).length) mapa.set(String(c.id), c);
    });
    return Array.from(mapa.values());
  }

  function _contem(valor, termo) {
    return String(valor || '').toLowerCase().indexOf(termo) !== -1;
  }

  // Busca de clientes offline (tela Clientes): filtra o cache pelo termo
  // em nome/código/cpf/telefone/cidade. Devolve null quando não há cache
  // utilizável — o chamador mostra o erro normal nesse caso.
  async function buscarClientesNoCache(termo) {
    if (!_nativo() || !window.DbLocal) return null;
    var todos = await _clientesDoCacheUnificado();
    if (!todos.length) return null;
    var t = String(termo || '').trim().toLowerCase();
    var filtrados = !t ? todos : todos.filter(function (c) {
      return _contem(c.nome, t) || _contem(c.codigo, t) || _contem(c.cpf, t)
        || _contem(c.telefone, t) || _contem(c.cidade, t);
    });
    filtrados.sort(function (a, b) { return String(a.nome || '').localeCompare(String(b.nome || '')); });
    return filtrados;
  }

  // Busca da tela do cobrador offline: mesmo contrato da consulta online
  // (campo escolhido no select + termo, máx. 10 resultados).
  async function buscarNaCarteiraOffline(campo, termo) {
    if (!_nativo() || !window.DbLocal) return null;
    var todos = await _clientesDoCacheUnificado();
    if (!todos.length) return null;
    var t = String(termo || '').trim().toLowerCase();
    var filtrados = todos.filter(function (c) { return _contem(c[campo], t); });
    filtrados.sort(function (a, b) { return String(a.nome || '').localeCompare(String(b.nome || '')); });
    return filtrados.slice(0, 10);
  }

  async function clienteDoCache(clienteId) {
    if (!_nativo() || !window.DbLocal) return null;
    var todos = await _clientesDoCacheUnificado();
    var achado = todos.find(function (c) { return String(c.id) === String(clienteId); });
    return achado || null;
  }

  async function parcelasDoCacheCliente(clienteId) {
    if (!_nativo() || !window.DbLocal) return null;
    var todas = await DbLocal.lerDoCache('parcelas');
    var doCliente = todas.filter(function (p) { return String(p.cliente_id) === String(clienteId); });
    doCliente.sort(function (a, b) { return String(a.data_vencimento || '').localeCompare(String(b.data_vencimento || '')); });
    return doCliente;
  }

  async function parcelasDoCacheVenda(vendaId) {
    if (!_nativo() || !window.DbLocal) return null;
    var todas = await DbLocal.lerDoCache('parcelas');
    var daVenda = todas.filter(function (p) { return String(p.venda_id) === String(vendaId); });
    daVenda.sort(function (a, b) { return (Number(a.numero) || 0) - (Number(b.numero) || 0); });
    return daVenda;
  }

  // ─── Enfileirar ações que falharam por falta de rede ─────────

  // Cliente (novo ou edição). Devolve true se entrou na fila — o chamador
  // decide fechar modal e avisar. false = sem banco local (web) ou falha.
  async function salvarClienteOffline(clienteId, dados) {
    if (!_nativo() || !window.DbLocal || !window.Sync) return false;
    try {
      var fotoBase64 = null;
      if (window._fotoCasaBlob) {
        try { fotoBase64 = await blobParaBase64(window._fotoCasaBlob); }
        catch (e) { console.error('[OFFLINE] Foto não pôde ser guardada na fila.', e); }
      }
      var idFila = clienteId || ('offline-' + crypto.randomUUID());

      // Editar (offline) um cliente que já está na fila só ATUALIZA a
      // operação existente — duas operações para o mesmo cliente virariam
      // dois cadastros no servidor na hora de sincronizar.
      var opId = null;
      var pendentesFila = await DbLocal.listarOperacoesPendentes();
      for (var i = 0; i < pendentesFila.length; i++) {
        if (pendentesFila[i].tipo !== 'cliente_upsert') continue;
        var payloadExistente = null;
        try { payloadExistente = JSON.parse(pendentesFila[i].payload); } catch (e) { continue; }
        if (payloadExistente && String(payloadExistente.clienteId) === String(idFila)) {
          payloadExistente.dados = Object.assign({}, payloadExistente.dados, dados);
          if (fotoBase64) payloadExistente.fotoBase64 = fotoBase64;
          await DbLocal.atualizarPayloadOperacao(pendentesFila[i].id, payloadExistente);
          opId = pendentesFila[i].id;
          break;
        }
      }
      if (!opId) {
        opId = await DbLocal.enfileirarOperacao('cliente_upsert', {
          clienteId: idFila,
          dados: dados,
          fotoBase64: fotoBase64,
        });
      }
      if (!opId) return false;
      // cache otimista: a lista de clientes offline já mostra o registro
      var existente = clienteId ? await clienteDoCache(clienteId) : null;
      var registro = Object.assign({}, existente || {}, dados, { id: idFila, _offline_pendente: true });
      if (!clienteId) registro.codigo = null; // código real sai só na sincronização
      await DbLocal.salvarNoCache('clientes', [registro]);
      await Sync.atualizarContadorFila();
      return true;
    } catch (e) {
      console.error('[OFFLINE] Falha ao enfileirar cliente.', e);
      return false;
    }
  }

  // Baixa de parcela. Valida contra o cache local (mesmas regras do fluxo
  // online) e atualiza a parcela em cache de forma otimista.
  // Devolve { ok, msg } — msg preenchida quando a recusa tem motivo claro.
  async function baixaOffline(dadosBaixa) {
    if (!_nativo() || !window.DbLocal || !window.Sync) return { ok: false };
    try {
      var todas = await DbLocal.lerDoCache('parcelas');
      var p = todas.find(function (x) { return String(x.id) === String(dadosBaixa.parcelaId); });
      if (!p) return { ok: false, msg: 'Sem conexão e esta parcela não está salva no aparelho. Abra as parcelas deste cliente com internet ao menos uma vez.' };
      if (p.pago) return { ok: false, msg: 'Esta parcela já foi baixada.' };

      var valorParcela = Number(p.valor) || 0;
      var pagoAnterior = Number(p.valor_pago) || 0;
      var saldoAtual = Math.round((valorParcela - pagoAnterior) * 100) / 100;
      var tipo = dadosBaixa.tipo;
      var valorPago = tipo === 'completa' ? saldoAtual : (Number(dadosBaixa.valorPago) || 0);
      if (tipo === 'parcial' && valorPago >= saldoAtual) {
        return { ok: false, msg: 'Valor maior ou igual ao saldo restante — use baixa completa!' };
      }

      var opId = await DbLocal.enfileirarOperacao('baixa_parcela', {
        parcelaId: dadosBaixa.parcelaId,
        tipo: tipo,
        valorPago: valorPago,
        forma: dadosBaixa.forma,
        data: dadosBaixa.data,
        cobradorId: dadosBaixa.cobradorId || null,
      });
      if (!opId) return { ok: false };

      var pago = tipo === 'completa';
      var atualizada = Object.assign({}, p, {
        pago: pago,
        status: pago ? 'paga' : 'aberta',
        data_pagamento: pago ? new Date(dadosBaixa.data).toISOString() : null,
        cobrador_id: dadosBaixa.cobradorId || null,
        valor_pago: pago ? valorParcela : Math.round((pagoAnterior + valorPago) * 100) / 100,
        forma_pagamento: dadosBaixa.forma,
        _offline_pendente: true,
      });
      await DbLocal.salvarNoCache('parcelas', [atualizada]);
      await Sync.atualizarContadorFila();
      return { ok: true };
    } catch (e) {
      console.error('[OFFLINE] Falha ao enfileirar baixa.', e);
      return { ok: false };
    }
  }

  // Recebimento do cobrador (fluxo de campo). O comprovante PIX, se
  // houver, vem de window._comprovanteBlob e vai em base64 na fila.
  // Devolve { ok, msg? }.
  async function recebimentoOffline(dados) {
    if (!_nativo() || !window.DbLocal || !window.Sync) return { ok: false };
    try {
      var comprovanteBase64 = null, ext = null, nomeArquivo = null;
      if (dados.forma === 'pix' && window._comprovanteBlob && !dados.comprovanteUrl) {
        comprovanteBase64 = await blobParaBase64(window._comprovanteBlob);
        ext = window._comprovanteExt || 'webp';
        nomeArquivo = 'pix_' + crypto.randomUUID() + '.' + ext;
      }
      var opId = await DbLocal.enfileirarOperacao('recebimento_registrar', {
        parcelaId: dados.parcelaId,
        tipo: dados.tipo,
        valorRecebido: dados.valorRecebido,
        forma: dados.forma,
        observacao: dados.observacao || null,
        comprovanteBase64: comprovanteBase64,
        comprovanteExt: ext,
        nomeArquivo: nomeArquivo,
        comprovanteUrl: dados.comprovanteUrl || null,
      });
      if (!opId) return { ok: false };

      // otimismo visual: a parcela no cache reflete o recebimento na hora
      var todas = await DbLocal.lerDoCache('parcelas');
      var p = todas.find(function (x) { return String(x.id) === String(dados.parcelaId); });
      if (p) {
        var valorParcela = Number(p.valor) || 0;
        var pagoAnterior = Number(p.valor_pago) || 0;
        var completo = dados.tipo === 'completo';
        var atualizada = Object.assign({}, p, {
          pago: completo,
          status: completo ? 'paga' : 'aberta',
          data_pagamento: completo ? new Date().toISOString() : null,
          valor_pago: completo ? valorParcela : Math.round((pagoAnterior + (Number(dados.valorRecebido) || 0)) * 100) / 100,
          forma_pagamento: dados.forma,
          _offline_pendente: true,
        });
        await DbLocal.salvarNoCache('parcelas', [atualizada]);
      }
      await Sync.atualizarContadorFila();
      return { ok: true };
    } catch (e) {
      console.error('[OFFLINE] Falha ao enfileirar recebimento.', e);
      return { ok: false };
    }
  }

  // Contagem de parcelas em aberto por cliente a partir do cache — usada
  // pela rota do cobrador quando a busca em lote falha por falta de rede.
  async function parcelasAbertasDoCache(clienteIds) {
    if (!_nativo() || !window.DbLocal) return [];
    var ids = new Set((clienteIds || []).map(String));
    var todas = await DbLocal.lerDoCache('parcelas');
    return todas.filter(function (p) {
      return !p.pago && p.status !== 'devolvida' && ids.has(String(p.cliente_id));
    });
  }

  // Venda: guarda os parâmetros exatos da RPC criar_venda para reenviar.
  async function vendaOffline(params) {
    if (!_nativo() || !window.DbLocal || !window.Sync) return false;
    try {
      var opId = await DbLocal.enfileirarOperacao('venda_criar', { params: params });
      if (!opId) return false;
      await Sync.atualizarContadorFila();
      return true;
    } catch (e) {
      console.error('[OFFLINE] Falha ao enfileirar venda.', e);
      return false;
    }
  }

  // ─── Login offline ───────────────────────────────────────────

  function salvarPerfilLogin(userId, dados) {
    try { localStorage.setItem('ascend_perfil_' + userId, JSON.stringify(dados)); } catch (e) { /* melhor esforço */ }
  }

  function perfilLoginCache(userId) {
    try {
      var v = localStorage.getItem('ascend_perfil_' + userId);
      return v ? JSON.parse(v) : null;
    } catch (e) { return null; }
  }

  // Sem rede, o getSession() pode voltar vazio quando o access token já
  // expirou (o refresh falha offline). A sessão persistida continua no
  // localStorage do supabase-js — recupera de lá só para entrar em modo
  // offline; quando a rede voltar o autorefresh normaliza o token.
  function sessaoOfflineFallback() {
    try {
      if (!window.NetStatus || NetStatus.estaOnline()) return null;
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (!/^sb-.*-auth-token$/.test(k)) continue;
        var bruto = JSON.parse(localStorage.getItem(k));
        var sessao = bruto && (bruto.currentSession || bruto);
        if (sessao && sessao.user && sessao.access_token) return sessao;
      }
    } catch (e) { console.error('[OFFLINE] Falha ao ler sessão persistida.', e); }
    return null;
  }

  // ─── Cache de apoio (selects que o modo offline precisa) ─────

  // Consultas diferentes trazem subconjuntos diferentes de campos do
  // mesmo cliente (a busca do cobrador traz cpf/cidade; a carteira traz
  // localidade_id). Salvar mesclando com o registro já cacheado evita que
  // uma consulta "pobre" apague campos que outra "rica" já tinha salvo.
  async function _salvarMesclandoNoCache(ns, lista) {
    if (!Array.isArray(lista) || !lista.length) return;
    var existentes = await DbLocal.lerDoCache(ns);
    var mapa = new Map();
    existentes.forEach(function (r) { if (r && r.id != null) mapa.set(String(r.id), r); });
    var mesclados = lista.map(function (novo) {
      var antigo = (novo && novo.id != null) ? mapa.get(String(novo.id)) : null;
      return antigo ? Object.assign({}, antigo, novo) : novo;
    });
    await DbLocal.salvarNoCache(ns, mesclados);
  }

  async function salvarCobradoresNoCache(lista) {
    if (!_nativo() || !window.DbLocal || !Array.isArray(lista) || !lista.length) return;
    try { await DbLocal.salvarNoCache('funcionarios:cobradores', lista); } catch (e) { /* cache é melhor esforço */ }
  }

  async function cobradoresDoCache() {
    if (!_nativo() || !window.DbLocal) return null;
    var lista = await DbLocal.lerDoCache('funcionarios:cobradores');
    if (!lista.length) return null;
    lista.sort(function (a, b) { return String(a.nome || '').localeCompare(String(b.nome || '')); });
    return lista;
  }

  async function salvarCarteiraNoCache(lista) {
    if (!_nativo() || !window.DbLocal || !Array.isArray(lista) || !lista.length) return;
    try { await _salvarMesclandoNoCache(_nsCarteira(), lista); } catch (e) { /* cache é melhor esforço */ }
  }

  async function carteiraDoCache() {
    if (!_nativo() || !window.DbLocal) return null;
    var lista = await DbLocal.lerDoCache(_nsCarteira());
    return lista.length ? lista : null;
  }

  async function salvarParcelasNoCache(lista) {
    if (!_nativo() || !window.DbLocal || !Array.isArray(lista) || !lista.length) return;
    try { await DbLocal.salvarNoCache('parcelas', lista); } catch (e) { /* cache é melhor esforço */ }
  }

  async function salvarClientesNoCache(lista) {
    if (!_nativo() || !window.DbLocal || !Array.isArray(lista) || !lista.length) return;
    try { await _salvarMesclandoNoCache('clientes', lista); } catch (e) { /* cache é melhor esforço */ }
  }

  // ─── Cache do vendedor (equipe, estoque do caminhão, catálogo) ──
  // Mesma ideia do cache do cobrador acima: grava a cada consulta online
  // bem-sucedida, lê quando a consulta falha por rede. "equipe_ativa" e
  // "produtos" guardam um registro por chave lógica (não por linha do
  // Supabase) — por isso viram um único item de array na hora de salvar.

  // equipe null é um estado válido (vendedor sem equipe ativa nesta semana)
  // e também precisa ser cacheado — senão uma equipe antiga ficaria presa
  // no cache pra sempre e o app ofereceria vender pra um caminhão errado.
  async function salvarEquipeAtivaNoCache(funcionarioId, equipe) {
    if (!_nativo() || !window.DbLocal || !funcionarioId) return;
    try { await DbLocal.salvarNoCache('equipe_ativa', [{ id: String(funcionarioId), equipe: equipe || null }]); }
    catch (e) { /* cache é melhor esforço */ }
  }

  async function equipeAtivaDoCache(funcionarioId) {
    if (!_nativo() || !window.DbLocal || !funcionarioId) return null;
    var lista = await DbLocal.lerDoCache('equipe_ativa');
    var achado = lista.find(function (r) { return String(r.id) === String(funcionarioId); });
    return (achado && achado.equipe) || null;
  }

  async function salvarEstoqueCaminhaoNoCache(caminhaoId, lista) {
    if (!_nativo() || !window.DbLocal || !caminhaoId || !Array.isArray(lista)) return;
    try {
      var tabela = 'caminhao_estoque:' + caminhaoId;
      var comId = lista.filter(function (i) { return i && i.produto_id != null; })
        .map(function (i) { return Object.assign({}, i, { id: i.produto_id }); });
      // Substitui o snapshot inteiro (não mescla) — quantidade é sempre a
      // mais recente da consulta, nunca faz sentido somar/mesclar entre
      // consultas diferentes como acontece com o cadastro de clientes.
      await DbLocal.salvarNoCache(tabela, comId);
    } catch (e) { /* cache é melhor esforço */ }
  }

  async function estoqueCaminhaoDoCache(caminhaoId) {
    if (!_nativo() || !window.DbLocal || !caminhaoId) return null;
    var lista = await DbLocal.lerDoCache('caminhao_estoque:' + caminhaoId);
    return lista.length ? lista : null;
  }

  async function salvarProdutosCatalogoNoCache(lista) {
    if (!_nativo() || !window.DbLocal || !Array.isArray(lista) || !lista.length) return;
    try { await DbLocal.salvarNoCache('produtos', lista); } catch (e) { /* cache é melhor esforço */ }
  }

  async function produtosCatalogoDoCache() {
    if (!_nativo() || !window.DbLocal) return null;
    var lista = await DbLocal.lerDoCache('produtos');
    return lista.length ? lista : null;
  }

  async function salvarMembrosEquipeNoCache(equipeId, lista) {
    if (!_nativo() || !window.DbLocal || !equipeId || !Array.isArray(lista)) return;
    try {
      var comId = lista.filter(function (m) { return m && m.funcionario_id != null; })
        .map(function (m) { return Object.assign({}, m, { id: m.funcionario_id }); });
      await DbLocal.salvarNoCache('equipe_membros:' + equipeId, comId);
    } catch (e) { /* cache é melhor esforço */ }
  }

  async function membrosEquipeDoCache(equipeId) {
    if (!_nativo() || !window.DbLocal || !equipeId) return null;
    var lista = await DbLocal.lerDoCache('equipe_membros:' + equipeId);
    return lista.length ? lista : null;
  }

  async function salvarVendasEquipeNoCache(equipeId, lista) {
    if (!_nativo() || !window.DbLocal || !equipeId || !Array.isArray(lista)) return;
    try { await DbLocal.salvarNoCache('vendas_equipe:' + equipeId, lista); }
    catch (e) { /* cache é melhor esforço */ }
  }

  async function vendasEquipeDoCache(equipeId) {
    if (!_nativo() || !window.DbLocal || !equipeId) return null;
    var lista = await DbLocal.lerDoCache('vendas_equipe:' + equipeId);
    return lista.length ? lista : null;
  }

  // Namespace separado da consulta acima: a tela "Minha equipe" pede um
  // subconjunto de campos diferente (e já filtra "devolvida" na query) — não
  // dá pra compartilhar o mesmo cache sem um formato virar inconsistente
  // com o outro.
  async function salvarVendasSemanaEquipeNoCache(equipeId, lista) {
    if (!_nativo() || !window.DbLocal || !equipeId || !Array.isArray(lista)) return;
    try { await DbLocal.salvarNoCache('vendas_equipe_semana:' + equipeId, lista); }
    catch (e) { /* cache é melhor esforço */ }
  }

  async function vendasSemanaEquipeDoCache(equipeId) {
    if (!_nativo() || !window.DbLocal || !equipeId) return null;
    var lista = await DbLocal.lerDoCache('vendas_equipe_semana:' + equipeId);
    return lista.length ? lista : null;
  }

  // Busca de cliente por CPF offline (tela de Vendas) — mesma unificação de
  // cache usada na busca por nome/código (_clientesDoCacheUnificado), só
  // que filtrando por CPF exato (dígitos).
  async function clienteDoCachePorCPF(cpf) {
    if (!_nativo() || !window.DbLocal) return null;
    var alvo = String(cpf || '').replace(/\D/g, '');
    if (!alvo) return null;
    var todos = await _clientesDoCacheUnificado();
    return todos.find(function (c) { return String(c.cpf || '').replace(/\D/g, '') === alvo; }) || null;
  }

  async function clienteDoCachePorCodigo(codigo) {
    if (!_nativo() || !window.DbLocal) return null;
    var alvo = String(codigo || '').trim();
    if (!alvo) return null;
    var todos = await _clientesDoCacheUnificado();
    return todos.find(function (c) { return String(c.codigo || '').trim() === alvo; }) || null;
  }

  // Aproxima o resultado de verificar_cliente_por_cpf() usando as parcelas
  // que já estão salvas no aparelho (mesma regra de UX do fluxo online: uma
  // parcela em aberto vencida já conta como atraso). temDados=false avisa o
  // chamador que não há parcela nenhuma em cache pra esse cliente — ou seja,
  // não dá pra garantir que ele está em dia, só que não sabemos.
  async function statusInadimplenciaDoCache(clienteId) {
    if (!_nativo() || !window.DbLocal || !clienteId) return { temDados: false, qtdAtrasadas: 0, valorAtrasado: 0 };
    var todas = await DbLocal.lerDoCache('parcelas');
    var doCliente = todas.filter(function (p) { return String(p.cliente_id) === String(clienteId); });
    if (!doCliente.length) return { temDados: false, qtdAtrasadas: 0, valorAtrasado: 0 };
    var hojeISO = new Date().toISOString().slice(0, 10);
    var atrasadas = doCliente.filter(function (p) {
      return !p.pago && p.status !== 'devolvida' && String(p.data_vencimento || '').slice(0, 10) < hojeISO;
    });
    var valorAtrasado = atrasadas.reduce(function (soma, p) {
      return soma + (Number(p.valor) || 0) - (Number(p.valor_pago) || 0);
    }, 0);
    return { temDados: true, qtdAtrasadas: atrasadas.length, valorAtrasado: Math.round(valorAtrasado * 100) / 100 };
  }

  // Vendas ainda na fila (venda_criar, não sincronizadas) — pra tela de
  // Vendas conseguir mostrar um card "salvo no aparelho, aguardando
  // internet" na hora, em vez de a venda simplesmente sumir até sincronizar
  // (o que passava a impressão de que não tinha sido registrada). Resolve
  // nome de cliente/vendedor pelo cache já existente; quando não acha,
  // mostra "—" — é só cosmético, a venda sincroniza do mesmo jeito.
  async function vendasOfflinePendentes(equipeId) {
    if (!_nativo() || !window.DbLocal) return [];
    var ops = await DbLocal.listarOperacoesPendentes();
    var pendentes = ops.filter(function (op) { return op.tipo === 'venda_criar'; });
    if (!pendentes.length) return [];

    var clientesCache = await _clientesDoCacheUnificado();
    var membrosPorEquipe = {};

    var resultado = [];
    for (var i = 0; i < pendentes.length; i++) {
      var op = pendentes[i];
      var payload = null;
      try { payload = JSON.parse(op.payload); } catch (e) { continue; }
      var params = payload && payload.params;
      if (!params) continue;
      if (equipeId && String(params.p_equipe_id) !== String(equipeId)) continue;

      var cliente = clientesCache.find(function (c) { return String(c.id) === String(params.p_cliente_id); });

      var vendedorNome = null;
      if (params.p_equipe_id) {
        if (!(params.p_equipe_id in membrosPorEquipe)) {
          membrosPorEquipe[params.p_equipe_id] = await DbLocal.lerDoCache('equipe_membros:' + params.p_equipe_id);
        }
        var membro = membrosPorEquipe[params.p_equipe_id].find(function (m) { return String(m.funcionario_id) === String(params.p_vendedor_id); });
        vendedorNome = (membro && membro.funcionarios && membro.funcionarios.nome) || null;
      }

      resultado.push({
        id: 'offline-' + op.id,
        codigo: null,
        cliente_id: params.p_cliente_id,
        clientes: cliente ? { nome: cliente.nome, codigo: cliente.codigo } : null,
        funcionarios: vendedorNome ? { nome: vendedorNome } : null,
        produto: params.p_produto,
        valor: params.p_valor,
        tipo: params.p_tipo,
        num_parcelas: params.p_num_parcelas,
        data_venda: op.criado_em,
        _offline_pendente: true,
      });
    }
    return resultado;
  }

  // Resumo legível de uma operação da fila, pra tela de Pendências — nunca
  // deixa uma venda/baixa/recebimento/cadastro travado virar só um ID sem
  // sentido pra quem está olhando. Resolve nome de cliente pelo cache
  // quando existir; sem cache, cai num identificador curto (é só cosmético,
  // os dados reais continuam inteiros no payload).
  async function _resumoOperacao(op) {
    var payload = null;
    try { payload = JSON.parse(op.payload); } catch (e) {
      return { titulo: 'Operação com dado corrompido', detalhes: [] };
    }
    var clientesCache = await _clientesDoCacheUnificado();
    function nomeCliente(id) {
      var c = clientesCache.find(function (x) { return String(x.id) === String(id); });
      if (c) return c.nome + (c.codigo ? ' (#' + c.codigo + ')' : '');
      return 'cliente ' + String(id || '—').slice(0, 8);
    }
    function fmtR(v) { return 'R$ ' + Number(v || 0).toLocaleString('pt-BR', { minimumFractionDigits: 2 }); }

    if (op.tipo === 'venda_criar') {
      var p = payload.params || {};
      return {
        titulo: 'Venda — ' + nomeCliente(p.p_cliente_id),
        detalhes: [
          'Produto: ' + (p.p_produto || '—'),
          'Valor: ' + fmtR(p.p_valor),
          'Tipo: ' + (p.p_tipo === 'entrada' ? ('Crediário ' + (p.p_num_parcelas || '?') + 'x') : 'À vista'),
        ],
      };
    }
    if (op.tipo === 'baixa_parcela') {
      return {
        titulo: 'Baixa de parcela',
        detalhes: [
          'Valor recebido: ' + fmtR(payload.valorPago),
          'Forma: ' + (payload.forma || '—'),
          'Data: ' + (payload.data || '—'),
        ],
      };
    }
    if (op.tipo === 'recebimento_registrar') {
      return {
        titulo: 'Recebimento (cobrador)',
        detalhes: [
          'Valor: ' + fmtR(payload.valorRecebido),
          'Forma: ' + (payload.forma || '—'),
          payload.observacao ? 'Obs.: ' + payload.observacao : null,
        ].filter(Boolean),
      };
    }
    if (op.tipo === 'cliente_upsert') {
      var ehNovo = !payload.clienteId || /^offline-/.test(String(payload.clienteId));
      return {
        titulo: (ehNovo ? 'Novo cliente — ' : 'Edição de cliente — ') + ((payload.dados && payload.dados.nome) || nomeCliente(payload.clienteId)),
        detalhes: [
          payload.dados && payload.dados.telefone ? 'Telefone: ' + payload.dados.telefone : null,
          payload.dados && payload.dados.cidade ? 'Cidade: ' + payload.dados.cidade : null,
        ].filter(Boolean),
      };
    }
    return { titulo: 'Operação: ' + op.tipo, detalhes: [] };
  }

  // Lista única pra tela de Pendências: tudo que ainda está tentando
  // sincronizar sozinho (pendente/erro) + tudo que o motor desistiu de
  // reenviar sozinho (travada — erro definitivo). NADA aqui foi apagado —
  // são exatamente as linhas que ainda existem em fila_operacoes (ver
  // DbLocal.listarOperacoesPendentes / listarOperacoesTravadas). Ordenada
  // da mais recente pra mais antiga.
  async function listarPendenciasOffline() {
    if (!_nativo() || !window.DbLocal) return [];
    var resultados = await Promise.all([
      DbLocal.listarOperacoesPendentes(),
      DbLocal.listarOperacoesTravadas(),
    ]);
    var todas = resultados[0].filter(function (op) { return op.tipo !== 'teste'; }).concat(resultados[1]);
    var lista = [];
    for (var i = 0; i < todas.length; i++) {
      var op = todas[i];
      var resumo = await _resumoOperacao(op);
      lista.push({
        id: op.id,
        tipo: op.tipo,
        travada: op.status === 'descartada',
        // "precisa de atenção" também vale pra quem só está demorando
        // muito (várias tentativas) — não precisa ter virado travada
        // ainda pra alguém já querer dar uma olhada.
        precisaAtencao: op.status === 'descartada' || (Number(op.tentativas) || 0) >= 3,
        tentativas: Number(op.tentativas) || 0,
        erroMsg: op.erro_msg || null,
        criadoEm: op.criado_em,
        titulo: resumo.titulo,
        detalhes: resumo.detalhes,
      });
    }
    lista.sort(function (a, b) { return String(b.criadoEm || '').localeCompare(String(a.criadoEm || '')); });
    return lista;
  }

  // Volta uma operação travada (ou só demorada) pro ciclo automático,
  // zerando tentativas/erro, e tenta sincronizar na hora. Decisão sempre
  // explícita do usuário na tela de Pendências.
  async function reenviarPendencia(id) {
    if (!window.DbLocal || !window.Sync) return;
    await DbLocal.reenviarOperacao(id);
    await Sync.atualizarContadorFila();
    await Sync.sincronizarAgora();
  }

  // Único caminho que apaga uma operação de verdade — só chamado depois de
  // o usuário confirmar explicitamente na tela de Pendências.
  async function apagarPendenciaDefinitivamente(id) {
    if (!window.DbLocal) return;
    await DbLocal.apagarOperacaoDefinitivamente(id);
    if (window.Sync) await Sync.atualizarContadorFila();
  }

  function avisoOfflineHtml(texto) {
    return '<div style="background:#FAEEDA;border:1px solid #FAC775;color:#854F0B;border-radius:10px;'
      + 'padding:10px 14px;margin-bottom:10px;font-size:13px;">📴 '
      + (texto || 'Sem conexão — mostrando dados salvos no aparelho. Podem estar desatualizados.')
      + '</div>';
  }

  window.OfflineFlow = {
    buscarClientesNoCache: buscarClientesNoCache,
    buscarNaCarteiraOffline: buscarNaCarteiraOffline,
    clienteDoCache: clienteDoCache,
    parcelasDoCacheCliente: parcelasDoCacheCliente,
    parcelasDoCacheVenda: parcelasDoCacheVenda,
    salvarClienteOffline: salvarClienteOffline,
    baixaOffline: baixaOffline,
    vendaOffline: vendaOffline,
    recebimentoOffline: recebimentoOffline,
    parcelasAbertasDoCache: parcelasAbertasDoCache,
    salvarPerfilLogin: salvarPerfilLogin,
    perfilLoginCache: perfilLoginCache,
    sessaoOfflineFallback: sessaoOfflineFallback,
    salvarCobradoresNoCache: salvarCobradoresNoCache,
    cobradoresDoCache: cobradoresDoCache,
    salvarCarteiraNoCache: salvarCarteiraNoCache,
    carteiraDoCache: carteiraDoCache,
    salvarParcelasNoCache: salvarParcelasNoCache,
    salvarClientesNoCache: salvarClientesNoCache,
    salvarEquipeAtivaNoCache: salvarEquipeAtivaNoCache,
    equipeAtivaDoCache: equipeAtivaDoCache,
    salvarEstoqueCaminhaoNoCache: salvarEstoqueCaminhaoNoCache,
    estoqueCaminhaoDoCache: estoqueCaminhaoDoCache,
    salvarProdutosCatalogoNoCache: salvarProdutosCatalogoNoCache,
    produtosCatalogoDoCache: produtosCatalogoDoCache,
    salvarMembrosEquipeNoCache: salvarMembrosEquipeNoCache,
    membrosEquipeDoCache: membrosEquipeDoCache,
    salvarVendasEquipeNoCache: salvarVendasEquipeNoCache,
    vendasEquipeDoCache: vendasEquipeDoCache,
    salvarVendasSemanaEquipeNoCache: salvarVendasSemanaEquipeNoCache,
    vendasSemanaEquipeDoCache: vendasSemanaEquipeDoCache,
    clienteDoCachePorCPF: clienteDoCachePorCPF,
    clienteDoCachePorCodigo: clienteDoCachePorCodigo,
    statusInadimplenciaDoCache: statusInadimplenciaDoCache,
    vendasOfflinePendentes: vendasOfflinePendentes,
    listarPendenciasOffline: listarPendenciasOffline,
    reenviarPendencia: reenviarPendencia,
    apagarPendenciaDefinitivamente: apagarPendenciaDefinitivamente,
    avisoOfflineHtml: avisoOfflineHtml,
  };
})();

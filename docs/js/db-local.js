// ─── DB LOCAL (SQLite offline) ────────────────────────────────
// Só roda dentro do app Android/iOS instalado (Capacitor nativo).
// Na versão web (GitHub Pages) fica inerte e o sistema segue 100% online.
(function () {
  'use strict';

  var DB_NAME = 'ascend_offline';
  var db = null;
  var sqliteConn = null;
  var initPromise = null;

  function ehPlataformaNativa() {
    return typeof Capacitor !== 'undefined'
      && typeof Capacitor.getPlatform === 'function'
      && Capacitor.getPlatform() !== 'web';
  }

  function initDbLocal() {
    if (!ehPlataformaNativa()) return Promise.resolve();
    if (initPromise) return initPromise;

    initPromise = (async function () {
      try {
        if (typeof capacitorCapacitorSQLite === 'undefined') {
          throw new Error('Plugin @capacitor-community/sqlite não carregado.');
        }
        var CapacitorSQLite = capacitorCapacitorSQLite.CapacitorSQLite;
        var SQLiteConnection = capacitorCapacitorSQLite.SQLiteConnection;
        sqliteConn = new SQLiteConnection(CapacitorSQLite);

        // sqliteConn.isConnection()/.retrieveConnection() só consultam um
        // Map local dessa instância JS — não o estado real do lado nativo.
        // Como a página pode recarregar (novo app open, location.reload etc.)
        // sem o processo Android morrer, o nativo pode continuar com a
        // conexão "ascend_offline" aberta de uma sessão anterior enquanto
        // esse Map nasce vazio. checkConnectionsConsistency() reconcilia os
        // dois lados: como o Map local está vazio, ele fecha qualquer
        // conexão nativa órfã, evitando "Connection ... already exists" no
        // createConnection() logo abaixo.
        try {
          await sqliteConn.checkConnectionsConsistency();
        } catch (e) { /* segue mesmo se falhar aqui — createConnection cairia no catch geral */ }

        var jaConectado = false;
        try {
          var r = await sqliteConn.isConnection(DB_NAME, false);
          jaConectado = !!(r && r.result);
        } catch (e) { jaConectado = false; }

        if (jaConectado) {
          db = await sqliteConn.retrieveConnection(DB_NAME, false);
        } else {
          // Garante uma senha de criptografia guardada com segurança pelo
          // próprio plugin (Android Keystore / EncryptedSharedPreferences).
          // Só roda uma vez por instalação — depois disso isSecretStored()
          // sempre volta true e este bloco é pulado.
          var segredo = await CapacitorSQLite.isSecretStored();
          if (!segredo || !segredo.result) {
            var senha = (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, '');
            await CapacitorSQLite.setEncryptionSecret({ passphrase: senha });
          }

          // Modo da conexão: "secret" cria o banco do zero já criptografado
          // (quando ainda não existe arquivo) OU só abre um banco que já
          // está criptografado (aberturas seguintes) — em ambos os casos é
          // um simples openOrCreateDatabase com a senha guardada. "encryption"
          // só serve para CONVERTER um arquivo que já existe em texto puro
          // (ex.: instalação anterior à fase 2, sem criptografia) — o plugin
          // lança erro "not found" se tentar usar esse modo num banco que
          // ainda não existe, então só entra aqui quando isDatabaseEncrypted
          // confirma que o arquivo existe e está em texto puro.
          var modo = 'secret';
          try {
            var infoEnc = await CapacitorSQLite.isDatabaseEncrypted({ database: DB_NAME });
            if (infoEnc && infoEnc.result === false) modo = 'encryption';
          } catch (e) {
            // Banco ainda não existe em disco — mantém "secret" (cria já criptografado).
          }

          try {
            db = await sqliteConn.createConnection(DB_NAME, true, modo, 1, false);
          } catch (errCreate) {
            // Segunda rede de segurança: se mesmo depois do
            // checkConnectionsConsistency() o nativo ainda disser que a
            // conexão já existe, fecha a conexão nativa diretamente (isso
            // sim é uma chamada real, não olha o Map local) e tenta criar
            // de novo, uma única vez.
            var msgCreate = (errCreate && errCreate.message) || String(errCreate);
            if (!/already exists/i.test(msgCreate)) throw errCreate;
            try { await sqliteConn.closeConnection(DB_NAME, false); } catch (e) { /* ignora */ }
            db = await sqliteConn.createConnection(DB_NAME, true, modo, 1, false);
          }
        }

        await db.open();

        // Cada CREATE TABLE roda em sua própria chamada — evita depender do
        // parser nativo de statements múltiplos separados por ";" para
        // confirmar que cada tabela foi de fato criada.
        await db.execute(
          'CREATE TABLE IF NOT EXISTS cache_registros (' +
          'tabela TEXT NOT NULL, ' +
          'registro_id TEXT NOT NULL, ' +
          'dados TEXT NOT NULL, ' +
          'atualizado_em TEXT NOT NULL, ' +
          'PRIMARY KEY (tabela, registro_id)' +
          ');'
        );
        await db.execute(
          'CREATE TABLE IF NOT EXISTS fila_operacoes (' +
          'id TEXT PRIMARY KEY, ' +
          'tipo TEXT NOT NULL, ' +
          'payload TEXT NOT NULL, ' +
          "status TEXT NOT NULL DEFAULT 'pendente', " +
          'tentativas INTEGER NOT NULL DEFAULT 0, ' +
          'erro_msg TEXT, ' +
          'criado_em TEXT NOT NULL, ' +
          'sincronizado_em TEXT' +
          ');'
        );
        await db.execute(
          'CREATE TABLE IF NOT EXISTS fotos_pendentes (' +
          'id TEXT PRIMARY KEY, ' +
          'operacao_id TEXT NOT NULL, ' +
          'caminho_local TEXT NOT NULL, ' +
          'bucket TEXT NOT NULL, ' +
          'nome_destino TEXT NOT NULL, ' +
          "status TEXT NOT NULL DEFAULT 'pendente'" +
          ');'
        );

        // Confirma de fato (não só assume) que as 3 tabelas existem antes de
        // declarar sucesso — se alguma não aparecer aqui, cai no catch abaixo
        // e o banco local fica desativado (app segue 100% online).
        var TABELAS_ESPERADAS = ['cache_registros', 'fila_operacoes', 'fotos_pendentes'];
        var verificacao = await db.query("SELECT name FROM sqlite_master WHERE type='table'");
        var nomesEncontrados = ((verificacao && verificacao.values) || []).map(function (linha) { return linha.name; });
        console.log('[DB LOCAL] Tabelas existentes:', nomesEncontrados);

        var faltando = TABELAS_ESPERADAS.filter(function (t) { return nomesEncontrados.indexOf(t) === -1; });
        if (faltando.length) {
          throw new Error('CREATE TABLE não surtiu efeito — faltando: ' + faltando.join(', '));
        }

        console.log('[DB LOCAL] Banco local "' + DB_NAME + '" inicializado.');
      } catch (err) {
        console.error('[DB LOCAL] Falha ao inicializar banco local — seguindo 100% online.', err);
        db = null;
      }
    })();

    return initPromise;
  }

  function getDb() {
    if (!db) console.warn('[DB LOCAL] Banco local indisponível (não inicializado ou falhou). Operação ignorada.');
    return db;
  }

  // Assume que cada registro tem "id" (padrão Supabase); usa "codigo" como
  // alternativa para tabelas que só expõem esse campo. Revisar na fase 2,
  // quando o cache for de fato ligado às telas.
  async function salvarNoCache(tabela, registros) {
    var conexao = getDb();
    if (!conexao || !Array.isArray(registros)) return;
    var agora = new Date().toISOString();
    for (var i = 0; i < registros.length; i++) {
      var registro = registros[i];
      var registroId = registro && (registro.id != null ? registro.id : registro.codigo);
      if (registroId == null) continue;
      await conexao.run(
        'INSERT OR REPLACE INTO cache_registros (tabela, registro_id, dados, atualizado_em) VALUES (?, ?, ?, ?)',
        [tabela, String(registroId), JSON.stringify(registro), agora]
      );
    }
  }

  async function lerDoCache(tabela) {
    var conexao = getDb();
    if (!conexao) return [];
    var res = await conexao.query('SELECT dados FROM cache_registros WHERE tabela = ?', [tabela]);
    return ((res && res.values) || []).map(function (linha) { return JSON.parse(linha.dados); });
  }

  async function enfileirarOperacao(tipo, payload) {
    var conexao = getDb();
    if (!conexao) return null;
    var id = crypto.randomUUID();
    await conexao.run(
      "INSERT INTO fila_operacoes (id, tipo, payload, status, tentativas, criado_em) VALUES (?, ?, ?, 'pendente', 0, ?)",
      [id, tipo, JSON.stringify(payload), new Date().toISOString()]
    );
    return id;
  }

  async function listarOperacoesPendentes() {
    var conexao = getDb();
    if (!conexao) return [];
    var res = await conexao.query(
      "SELECT * FROM fila_operacoes WHERE status IN ('pendente', 'erro') ORDER BY criado_em ASC"
    );
    return (res && res.values) || [];
  }

  async function atualizarStatusOperacao(id, status, erroMsg) {
    var conexao = getDb();
    if (!conexao) return;
    if (status === 'sincronizado') {
      await conexao.run(
        'UPDATE fila_operacoes SET status = ?, erro_msg = ?, sincronizado_em = ? WHERE id = ?',
        [status, erroMsg || null, new Date().toISOString(), id]
      );
    } else {
      await conexao.run(
        'UPDATE fila_operacoes SET status = ?, erro_msg = ? WHERE id = ?',
        [status, erroMsg || null, id]
      );
    }
  }

  // Falha de negócio (não de rede) ao sincronizar: conta a tentativa e
  // guarda o motivo. A operação continua elegível para retry pra sempre —
  // nunca desiste sozinha (ver sync.js: só erro definitivo sai do ciclo
  // automático, e mesmo assim sem apagar nada, ver listarOperacoesTravadas).
  async function registrarTentativa(id, erroMsg) {
    var conexao = getDb();
    if (!conexao) return;
    await conexao.run(
      "UPDATE fila_operacoes SET status = 'erro', tentativas = tentativas + 1, erro_msg = ? WHERE id = ?",
      [erroMsg || null, id]
    );
  }

  async function contarOperacoesPendentes() {
    var conexao = getDb();
    if (!conexao) return 0;
    var res = await conexao.query(
      "SELECT COUNT(*) AS n FROM fila_operacoes WHERE status IN ('pendente', 'erro')"
    );
    return Number((res && res.values && res.values[0] && res.values[0].n) || 0);
  }

  // "Travada" = motor de sincronização desistiu de tentar sozinho (erro
  // definitivo — ver ehDefinitivo em sync.js) OU o payload chegou
  // corrompido. Continua gravada por inteiro no banco, nunca escondida:
  // é isto que alimenta a tela de Pendências (ver OfflineFlow.
  // listarPendenciasOffline), pra nenhuma venda/baixa/recebimento de
  // campo sumir sem um humano decidir o que fazer com ela.
  async function listarOperacoesTravadas() {
    var conexao = getDb();
    if (!conexao) return [];
    var res = await conexao.query(
      "SELECT * FROM fila_operacoes WHERE status = 'descartada' ORDER BY criado_em ASC"
    );
    return (res && res.values) || [];
  }

  async function contarOperacoesTravadas() {
    var conexao = getDb();
    if (!conexao) return 0;
    var res = await conexao.query("SELECT COUNT(*) AS n FROM fila_operacoes WHERE status = 'descartada'");
    return Number((res && res.values && res.values[0] && res.values[0].n) || 0);
  }

  // Devolve uma operação travada pro ciclo automático de retry — usado
  // pela tela de Pendências quando o usuário decide tentar de novo (ex.:
  // o motivo já foi corrigido no servidor). Zera tentativas e o erro.
  async function reenviarOperacao(id) {
    var conexao = getDb();
    if (!conexao) return;
    await conexao.run(
      "UPDATE fila_operacoes SET status = 'pendente', tentativas = 0, erro_msg = NULL WHERE id = ?",
      [id]
    );
  }

  // ÚNICO lugar do sistema que de fato apaga uma operação da fila — e só
  // deve ser chamado depois de o usuário confirmar explicitamente na tela
  // de Pendências que quer descartar aquilo pra sempre. Em todo o resto do
  // fluxo (inclusive quando o motor de sincronização desiste sozinho) a
  // operação é só marcada 'descartada', nunca apagada — exatamente pra não
  // repetir a perda silenciosa de um registro de campo.
  async function apagarOperacaoDefinitivamente(id) {
    var conexao = getDb();
    if (!conexao) return;
    await conexao.run('DELETE FROM fila_operacoes WHERE id = ?', [id]);
  }

  async function removerDoCache(tabela, registroId) {
    var conexao = getDb();
    if (!conexao) return;
    await conexao.run(
      'DELETE FROM cache_registros WHERE tabela = ? AND registro_id = ?',
      [tabela, String(registroId)]
    );
  }

  // Permite a um handler de sincronização persistir progresso parcial no
  // próprio payload (ex.: baixa em 2 passos — parcela atualizada, falta a
  // movimentação de caixa) para o retry não repetir o passo já aplicado.
  async function atualizarPayloadOperacao(id, payload) {
    var conexao = getDb();
    if (!conexao) return;
    await conexao.run(
      'UPDATE fila_operacoes SET payload = ? WHERE id = ?',
      [JSON.stringify(payload), id]
    );
  }

  async function salvarFotoPendente(operacaoId, caminhoLocal, bucket, nomeDestino) {
    var conexao = getDb();
    if (!conexao) return null;
    var id = crypto.randomUUID();
    await conexao.run(
      "INSERT INTO fotos_pendentes (id, operacao_id, caminho_local, bucket, nome_destino, status) VALUES (?, ?, ?, ?, ?, 'pendente')",
      [id, operacaoId, caminhoLocal, bucket, nomeDestino]
    );
    return id;
  }

  async function listarFotosPendentes(operacaoId) {
    var conexao = getDb();
    if (!conexao) return [];
    var res = await conexao.query('SELECT * FROM fotos_pendentes WHERE operacao_id = ?', [operacaoId]);
    return (res && res.values) || [];
  }

  async function testarDbLocal() {
    try {
      await enfileirarOperacao('teste', { mensagem: 'teste de conexão', hora: new Date().toISOString() });
      var pendentes = await listarOperacoesPendentes();
      console.log('[DB LOCAL] Teste OK - ' + pendentes.length + ' operações pendentes na fila');
    } catch (err) {
      console.error('[DB LOCAL] Teste falhou.', err);
    }
  }

  window.DbLocal = {
    initDbLocal: initDbLocal,
    salvarNoCache: salvarNoCache,
    lerDoCache: lerDoCache,
    enfileirarOperacao: enfileirarOperacao,
    listarOperacoesPendentes: listarOperacoesPendentes,
    atualizarStatusOperacao: atualizarStatusOperacao,
    registrarTentativa: registrarTentativa,
    contarOperacoesPendentes: contarOperacoesPendentes,
    listarOperacoesTravadas: listarOperacoesTravadas,
    contarOperacoesTravadas: contarOperacoesTravadas,
    reenviarOperacao: reenviarOperacao,
    apagarOperacaoDefinitivamente: apagarOperacaoDefinitivamente,
    removerDoCache: removerDoCache,
    atualizarPayloadOperacao: atualizarPayloadOperacao,
    salvarFotoPendente: salvarFotoPendente,
    listarFotosPendentes: listarFotosPendentes,
    testarDbLocal: testarDbLocal
  };
})();

# Empacotamento Android (Capacitor) — Fase 0

Este documento descreve como o sistema web (`docs/index.html`) foi empacotado como
um app Android usando [Capacitor](https://capacitorjs.com/), sem nenhuma alteração
de lógica de negócio ou chamadas ao Supabase. É apenas um "wrapper" nativo em volta
do mesmo HTML/JS que já roda no navegador.

## O que foi feito

1. **Inicialização do projeto Node/Capacitor**
   ```bash
   npm init -y
   npm install @capacitor/core @capacitor/cli
   npx cap init "Ascend" "com.liamoveis.ascend" --web-dir www
   ```
   - App ID: `com.liamoveis.ascend`
   - App name: `Ascend`

2. **Organização dos arquivos web**
   - `index.html` foi movido (via `git mv`, preservando histórico) para `docs/index.html`
     (renomeado de `www/` para `docs/` logo depois, para compatibilizar com GitHub Pages —
     ver `docs/.nojekyll`).
   - Nenhuma linha do conteúdo original do `index.html` foi alterada nesta fase.
   - As libs de terceiros (Supabase, xlsx, jsPDF, Chart.js, `@capacitor/core`, o plugin
     SQLite) estão vendorizadas em `docs/js/vendor/` em vez de carregadas por CDN —
     necessário para o app abrir 100% offline (ver Fase 1 abaixo).
   - `capacitor.config.json` está com `"webDir": "docs"`.

3. **Plataforma Android**
   ```bash
   npm install @capacitor/android
   npx cap add android
   npx cap sync android
   ```
   Isso criou a pasta `android/` com o projeto nativo (Gradle) e copiou o conteúdo
   de `docs/` para `android/app/src/main/assets/public`.

4. **Permissões em `android/app/src/main/AndroidManifest.xml`**
   - `INTERNET` (já vem por padrão no template do Capacitor — necessária para
     falar com o Supabase).
   - `CAMERA` — o sistema usa `<input type="file" capture="environment">` para
     foto de comprovante/cliente, e o `FileProvider` já configurado pelo template
     entrega a foto capturada ao WebView.
   - `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` com `android:maxSdkVersion="32"`
     — apenas para compatibilidade com Android ≤ 12 (API ≤ 32). Em versões mais
     novas (Scoped Storage / Photo Picker), o seletor de arquivos do sistema não
     exige essas permissões, então elas foram limitadas via `maxSdkVersion` para
     não gerar avisos desnecessários em lojas/lint.

## ⚠️ Build/abertura no Android Studio — não testado neste ambiente

Os passos abaixo (item 5 do pedido original) **não puderam ser executados** aqui
porque este é um ambiente remoto sem interface gráfica e sem o Android SDK
instalado (o proxy de rede do ambiente bloqueia o download do SDK a partir de
`dl.google.com`, e não há Android Studio instalado):

- `npx cap open android` — precisa de Android Studio com GUI.
- `cd android && ./gradlew assembleDebug` — precisa do Android SDK
  (`compileSdkVersion`/`targetSdkVersion` 36, `minSdkVersion` 24, ver
  `android/variables.gradle`) instalado localmente.

**Você precisa rodar esses dois comandos na sua máquina local** para validar o
build antes de considerar esta fase concluída. Veja os pré-requisitos abaixo.

## Pré-requisitos de ambiente (máquina local)

- **Node.js** 18+ e npm.
- **JDK 17 ou 21** (Capacitor 8 / Android Gradle Plugin atual requer JDK 17+).
- **Android Studio** (versão recente, ex. Ladybug/Koala ou mais nova) com:
  - Android SDK Platform 36 (compile/target SDK deste projeto).
  - Android SDK Build-Tools correspondente.
  - Uma variável de ambiente `ANDROID_HOME` (ou `ANDROID_SDK_ROOT`) apontando
    para a pasta do SDK, por exemplo:
    ```bash
    export ANDROID_HOME="$HOME/Android/Sdk"
    export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin"
    ```
  - Um emulador (AVD) ou dispositivo físico com depuração USB, caso queira rodar
    o app, além do build.

## Como testar depois de instalar os pré-requisitos

```bash
npm install
npx cap sync android
npx cap open android      # abre o projeto no Android Studio
# ou, via linha de comando:
cd android && ./gradlew assembleDebug
```

O APK de debug fica em `android/app/build/outputs/apk/debug/app-debug.apk`.

## Como gerar um novo build após qualquer alteração no `docs/`

Sempre que o `docs/index.html` (ou outro arquivo dentro de `docs/`) for alterado:

```bash
npx cap sync android
```

Isso copia o conteúdo atualizado de `docs/` para
`android/app/src/main/assets/public` e atualiza plugins/configuração nativa.
Depois, gere o build novamente:

```bash
cd android && ./gradlew assembleDebug          # build de debug
cd android && ./gradlew assembleRelease         # build de release (requer assinatura)
```

Ou simplesmente abra o Android Studio (`npx cap open android`) e rode/gere o
build por lá.

## Fase 2 funcional — modo offline de verdade (cache, fila e sincronização)

A infraestrutura das fases 1/2 (SQLite criptografado) agora está **ligada às
telas**. Arquitetura, em 4 arquivos novos + edições cirúrgicas no `index.html`:

| Arquivo | Papel |
|---|---|
| `docs/js/net-status.js` | `window.NetStatus` — detecção de conectividade (plugin `@capacitor/network` no app; fallback `navigator.onLine` na web) + indicador visual (pílula no rodapé: offline / sincronizando / N pendentes). `ehErroDeRede(err)` decide se uma falha foi por falta de rede. |
| `docs/js/sync.js` | `window.Sync` — motor genérico: lê a fila (`fila_operacoes`), despacha por tipo para um handler, marca `sincronizado`/`erro`/`descartada`. Erro de rede/token interrompe a rodada sem punir a operação; erro de negócio conta tentativa (máx. 8) e erro definitivo (códigos 22/23/42/P0/PGRST116) descarta com o motivo em `erro_msg`. Trava `window._syncLiberado`: só roda logado (senão o RLS recusaria tudo). Gatilhos: login, volta da rede (após `refreshSession()`), varredura a cada 90 s. |
| `docs/js/sync-handlers.js` | Handlers de cada tipo de operação + `window.OfflineFlow` (helpers que o `index.html` usa para entrar no modo offline). |
| `docs/js/db-local.js` | Ganhou `registrarTentativa`, `contarOperacoesPendentes`, `removerDoCache`, `atualizarPayloadOperacao` (progresso parcial de handler persistido no payload). |

**Tipos de operação na fila** (`fila_operacoes.tipo`):

- `cliente_upsert` — cadastro/edição de cliente offline. Cliente novo ganha id
  temporário `offline-<uuid>` no cache; o código real é gerado na sincronização
  (`gerarCodigoCliente` online). Foto da casa vai em base64 no payload. Editar
  offline um cliente ainda pendente **mescla na mesma operação** (não duplica).
  Duas etapas persistidas: insert → foto (retry não insere de novo).
- `baixa_parcela` — baixa da tela de Cobranças. Revalida a parcela no servidor
  na hora de sincronizar (parcial que cobre o saldo vira completa; parcela já
  baixada por outra pessoa → descartada com motivo). Duas etapas: update da
  parcela → insert da movimentação de caixa.
- `recebimento_registrar` — fluxo de campo do cobrador (RPC atômica
  `registrar_recebimento`). Comprovante PIX tirado offline vai em base64; o
  upload usa nome fixo sorteado no enfileiramento (idempotente) e o progresso é
  persistido (retry não sobe o arquivo duas vezes).
- `venda_criar` — parâmetros exatos da RPC atômica `criar_venda`; erro de regra
  de negócio (ex.: inadimplência) descarta com o motivo guardado.
- `teste` — legado do autoteste das fases 1/2; sincroniza como no-op e limpa a fila.

**Cache local** (`cache_registros.tabela`): `clientes` (busca geral + ficha),
`clientes_cobrador:<id do cobrador>` (carteira), `parcelas`, 
`funcionarios:cobradores` (select do modal de baixa). Gravado a cada consulta
online bem-sucedida (mesclando campos, para uma consulta "pobre" não apagar o
que uma "rica" salvou); lido quando a consulta falha por rede. Escritas offline
atualizam o cache de forma otimista (`_offline_pendente: true`).

**Login offline**: o perfil (`meus_dados_login`) fica salvo por usuário no
aparelho após cada login online. No boot sem rede: sessão persistida do
supabase-js é recuperada (mesmo com access token expirado) e o app entra com o
perfil salvo — o bug antigo de "Perfil não encontrado" + signOut offline morreu.
Primeiro acesso continua exigindo internet. Logout com fila pendente pede
confirmação (a fila só sincroniza com o dono logado).

**Web (GitHub Pages) intacta**: sem SQLite nativo, `enfileirarOperacao` devolve
null e todos os fluxos offline caem nos erros normais de antes. Validado com
Chromium headless (rede 100% bloqueada): boot limpo, login renderiza, camada
offline inerte.

**Limitações conhecidas (aceitas nesta fase):**
- Venda/recebimento via RPC: se a resposta se perder DEPOIS do servidor gravar
  (janela mínima), o retry pode duplicar — a RPC não tem chave de idempotência
  (melhoria futura no backend).
- Painéis de saldo/desempenho/ciclos do cobrador e dashboard do gestor não têm
  cache — degradam com aviso. A rota por localidades usa as parcelas salvas.
- Fila é por aparelho: sincroniza no próximo login de quem gravou.

## Roteiro de testes em dispositivo real (Fase 1 + Fase 2: offline + SQLite + criptografia)

Nada da camada offline (`docs/js/db-local.js`) foi validado em Android de verdade
ainda — só com mocks em Node e Chromium headless neste ambiente (que não tem SDK
Android). Antes de considerar a Fase 1/2 concluída, rode este roteiro num
aparelho físico ou emulador.

### 0. Preparar o build
```bash
npm install
npx cap sync android
cd android && ./gradlew assembleDebug
```
Instale o APK gerado (`android/app/build/outputs/apk/debug/app-debug.apk`) —
`adb install -r app-debug.apk` ou arrastando pro emulador.

### 1. App abre sem tela branca (valida a vendorização das libs de CDN)
Abra o app com internet normal. Se aparecer tela branca / nada renderiza, é
regressão grave — veja o passo 3 para pegar o erro no console.

### 2. Boot 100% offline (o motivo de toda a Fase 1)
1. Force-stop o app (Configurações → Apps → Ascend → Forçar parada) ou desinstale
   e reinstale, pra garantir que não há WebView cacheado.
2. Ative o **modo avião** (sem wifi, sem dados).
3. Abra o app.
4. **Esperado:** tela de login aparece normalmente. Se der tela branca ou erro,
   alguma lib deixou de estar vendorizada corretamente.

### 3. Ver os logs em tempo real (essencial pros próximos passos)
Com o cabo USB conectado e depuração USB ativada:
```bash
chrome://inspect
```
No Chrome desktop, abra essa URL, encontre o WebView do app na lista e clique
em **inspect** — abre um DevTools remoto ligado direto no app rodando no
aparelho. Alternativa via terminal:
```bash
adb logcat -s chromium:I Capacitor:I
```

### 4. Confirmar que o SQLite local inicializou de verdade
Com o DevTools remoto aberto (passo 3), no console procure por, nesta ordem,
logo após o carregamento da página:
```
[DB LOCAL] Tabelas existentes: ['cache_registros', 'fila_operacoes', 'fotos_pendentes']
[DB LOCAL] Banco local "ascend_offline" inicializado.
```
Se aparecer `[DB LOCAL] Falha ao inicializar banco local...` em vez disso, o
banco local não subiu — copie a mensagem de erro completa (o `console.error`
já loga o erro nativo inteiro) e investigamos a partir disso.

### 5. Confirmar o ciclo offline completo (substitui o antigo autoteste)
O autoteste da fase 1 foi removido — agora o teste é o fluxo real:

1. **Aqueça o cache com internet**: faça login (cobrador), abra a busca, toque
   num cliente, abra as parcelas dele. Console deve mostrar `[SYNC]` limpando
   os registros `teste` antigos da fila.
2. **Modo avião.** Feche e reabra o app: deve entrar direto (login offline,
   sem "Perfil não encontrado") com a pílula "📴 Sem conexão" no rodapé.
3. Busque o mesmo cliente (vem do cache), abra as parcelas, **registre um
   recebimento** (teste também com PIX + foto do comprovante). Esperado:
   alerta "salvo no aparelho", parcela aparece como paga, pílula mostra
   operação na fila. Cadastre também um cliente novo (código fica vazio —
   sai na sincronização).
4. Feche o app, reabra ainda em modo avião: fila e cache devem persistir.
5. **Desligue o modo avião** com o app aberto. Em segundos o console deve
   mostrar `[SYNC] Iniciando ...` e `[SYNC] Concluído: N sincronizada(s)`;
   a pílula some. Confira no Supabase: parcela baixada, movimentação/baixa
   pendente criada, cliente novo com código real, comprovante no bucket.
6. Repita o passo 3 e, antes de voltar a internet, faça logout: deve aparecer
   a confirmação de "operações não sincronizadas".

### 6. Confirmar que o banco está realmente criptografado (não só configurado)
Com o app já aberto pelo menos uma vez (pra o arquivo existir):
```bash
adb shell run-as com.liamoveis.ascend ls databases/
# deve listar algo como: ascend_offlineSQLite.db

adb shell run-as com.liamoveis.ascend cat databases/ascend_offlineSQLite.db > /tmp/ascend_offline.db
head -c 16 /tmp/ascend_offline.db | xxd
```
Um banco SQLite **não** criptografado começa com os bytes ASCII
`53 51 4c 69 74 65 20 66 6f 72 6d 61 74 20 33 00` (`"SQLite format 3\0"`).
Se o cabeçalho vier diferente disso (bytes que parecem aleatórios), o arquivo
está criptografado — é o resultado esperado. Se vier exatamente esse texto,
a criptografia não está ativa e algo no `mode`/`androidIsEncryption` falhou
silenciosamente (nesse caso o log do passo 4 também deveria ter mostrado erro).

### 7. Teste de migração (só se você já tinha testado a Fase 1 antes da criptografia)
Se este aparelho já tinha uma instalação anterior rodando o banco em texto
puro (antes deste commit), instale o novo APK **sem desinstalar** o anterior
(`adb install -r`) e repita o passo 4 — o log de sucesso deve aparecer
normalmente, confirmando que o arquivo antigo foi convertido em vez de travar
a abertura. Se este é seu primeiro teste em dispositivo, pule este passo (não
existe banco antigo pra migrar).

### 8. Regressão geral do sistema (com internet)
Login, navegue por 2-3 telas (Clientes, Vendas, Cobranças), tire uma foto de
comprovante (valida as permissões de Câmera da Fase 0), faça logout. Com
internet, tudo continua batendo direto no Supabase como antes — a camada
offline só entra quando uma chamada falha por rede (e, no sucesso, alimenta o
cache em segundo plano, o que não muda nada visível).

## Próximos passos sugeridos (fora do escopo desta fase)

- Assinatura do app (keystore) para gerar um release/AAB para a Play Store.
- Ícone e splash screen personalizados (hoje usam os placeholders padrão do
  Capacitor em `android/app/src/main/res/`).
- Eventual uso de plugins nativos do Capacitor (Camera, Filesystem, etc.) para
  substituir os `<input type="file">` por APIs nativas — não feito aqui de
  propósito, pois o pedido desta fase foi só empacotar sem mexer na lógica.

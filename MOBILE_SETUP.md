# Empacotamento Android (Capacitor) — Fase 0

Este documento descreve como o sistema web (`www/index.html`) foi empacotado como
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
   - `index.html` foi movido (via `git mv`, preservando histórico) para `www/index.html`.
   - Nenhuma linha do conteúdo do `index.html` foi alterada.
   - Não havia outros arquivos estáticos locais (imagens, CSS, JS) referenciados por
     caminho relativo — o ícone é um SVG inline (`data:image/svg+xml`), as libs
     (Supabase, xlsx, jsPDF, Chart.js) vêm de CDN (`unpkg`/`cdnjs`), e as fotos de
     clientes/comprovantes ficam no Supabase Storage (URLs remotas). Por isso a
     mudança de pasta não quebra nenhum link.
   - `capacitor.config.json` já foi gerado com `"webDir": "www"`.

3. **Plataforma Android**
   ```bash
   npm install @capacitor/android
   npx cap add android
   npx cap sync android
   ```
   Isso criou a pasta `android/` com o projeto nativo (Gradle) e copiou o conteúdo
   de `www/` para `android/app/src/main/assets/public`.

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

## Como gerar um novo build após qualquer alteração no `www/`

Sempre que o `www/index.html` (ou outro arquivo dentro de `www/`) for alterado:

```bash
npx cap sync android
```

Isso copia o conteúdo atualizado de `www/` para
`android/app/src/main/assets/public` e atualiza plugins/configuração nativa.
Depois, gere o build novamente:

```bash
cd android && ./gradlew assembleDebug          # build de debug
cd android && ./gradlew assembleRelease         # build de release (requer assinatura)
```

Ou simplesmente abra o Android Studio (`npx cap open android`) e rode/gere o
build por lá.

## Próximos passos sugeridos (fora do escopo desta fase)

- Assinatura do app (keystore) para gerar um release/AAB para a Play Store.
- Ícone e splash screen personalizados (hoje usam os placeholders padrão do
  Capacitor em `android/app/src/main/res/`).
- Eventual uso de plugins nativos do Capacitor (Camera, Filesystem, etc.) para
  substituir os `<input type="file">` por APIs nativas — não feito aqui de
  propósito, pois o pedido desta fase foi só empacotar sem mexer na lógica.

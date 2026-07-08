#!/usr/bin/env bash
# ============================================================================
# Localiza tudo sobre as tabelas de estoque (estoque_cd, caminhao_estoque,
# movimentacoes_estoque) espalhadas neste repositório: onde a tabela é
# criada (supabase/migrations/*.sql) e onde é usada no app (docs/index.html).
#
# Motivo de existir: essas 3 tabelas foram criadas via migração SQL versionada
# neste repo (não direto no painel do Supabase), mas quem procura só em
# docs/js/db-local.js (SQLite/Capacitor local) não encontra nada, porque
# aquele arquivo é outra coisa — cache/fila offline do app mobile, sem
# relação com o estoque do CD/caminhão no Postgres do Supabase.
#
# Uso: ./scripts/estoque-schema-info.sh
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TABELAS=("estoque_cd" "caminhao_estoque" "movimentacoes_estoque")
APP_FILE="docs/index.html"
MIGRATIONS_DIR="supabase/migrations"

linha() { printf '%.0s─' {1..78}; echo; }

echo "Repositório: $REPO_ROOT"
echo "Tabelas de estoque: ${TABELAS[*]}"
linha

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "⚠️  Pasta $MIGRATIONS_DIR não existe neste checkout."
  echo "   Rode 'git fetch origin main && git checkout origin/main -- $MIGRATIONS_DIR'"
  echo "   ou confirme que você está na branch/commit certos."
  exit 1
fi

for tabela in "${TABELAS[@]}"; do
  echo
  echo "### Tabela: $tabela"
  linha

  echo "-- Definição (supabase/migrations/*.sql):"
  arquivo=$(grep -rl "create table if not exists $tabela" "$MIGRATIONS_DIR" 2>/dev/null | head -1 || true)
  if [ -z "$arquivo" ]; then
    echo "  ⚠️  Nenhum 'create table' encontrado para '$tabela' em $MIGRATIONS_DIR."
    echo "     Pode ter sido criada direto no Supabase (fora do repo) — confirme lá."
  else
    echo "  Arquivo: $arquivo"
    echo
    awk -v t="create table if not exists $tabela" '
      index($0, t) { printing=1 }
      printing { print "  " $0 }
      printing && /\);/ { printing=0; exit }
    ' "$arquivo"
  fi

  echo
  echo "-- Uso no app ($APP_FILE) — cada linha é um ponto onde o código lê/escreve a tabela:"
  if grep -qn "from('$tabela')" "$APP_FILE" 2>/dev/null; then
    grep -n "from('$tabela')" "$APP_FILE" | sed 's/^/  /'
  else
    echo "  (nenhuma referência encontrada — pode estar sem uso ainda no app)"
  fi
  linha
done

echo
echo "### Referência rápida — para quem for escrever RLS/policy:"
cat <<'EOF'
  estoque_cd            -> saldo do centro de distribuição (CD/serraria).
                           Só o GESTOR mexe (registrar produção, e é a origem
                           do "Carregar caminhão"). Vendedor nunca acessa.

  caminhao_estoque       -> saldo atual de cada caminhão (persistente entre
                           semanas, não mais por equipe). Escrito pelo GESTOR
                           (carregar/devolver, cancelar/editar venda) E pelo
                           VENDEDOR (a venda dele decrementa o estoque do
                           caminhão da própria equipe ativa — só o caminhão
                           dela, nenhum outro).

  movimentacoes_estoque  -> ledger histórico (produção/carregamento/
                           devolução/venda/estorno). Inserido por GESTOR e
                           VENDEDOR conforme a ação; pensado para ser
                           somente-inserção (nunca update/delete), preserva
                           auditoria.

  A migração 0001_estoque_cd_caminhao.sql aplica uma policy permissiva
  ("authenticated" pode tudo) igual ao padrão já usado no resto do app —
  não há RLS por perfil (gestor/vendedor/cobrador) em nenhuma tabela hoje.
  Se for apertar isso, precisa localizar no Supabase a tabela/mecanismo por
  trás do RPC `meus_dados_login()` (é ele quem resolve auth.uid() -> perfil
  + funcionario_id) — esse mapeamento não está neste repo, foi criado direto
  no Supabase.
EOF

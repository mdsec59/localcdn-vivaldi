#!/usr/bin/env bash
# fetch-upstream.sh — Clona (o actualiza) el repositorio upstream de LocalCDN.
# Es la base sobre la que build.sh genera el port para Vivaldi.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
REPO_URL="${LOCALCDN_REPO:-https://codeberg.org/nobody/LocalCDN.git}"

if [[ -d "$UPSTREAM/.git" ]]; then
  echo "[i] Actualizando upstream en $UPSTREAM"
  git -C "$UPSTREAM" fetch --depth 1 origin
  git -C "$UPSTREAM" reset --hard FETCH_HEAD
else
  echo "[i] Clonando $REPO_URL en $UPSTREAM"
  git clone --depth 1 "$REPO_URL" "$UPSTREAM"
fi

echo "[i] Commit de trabajo:"
git -C "$UPSTREAM" log --oneline -1

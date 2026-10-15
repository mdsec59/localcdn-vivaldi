#!/usr/bin/env bash
# make-key.sh — Genera una clave pública RSA para fijar el ID de la extensión.
# El ID queda estable aunque cambie la ruta de instalación (útil para permisos y pruebas).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/manifest/key.txt"
TMP="$(mktemp -d /tmp/opencode/localcdn-key.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

command -v openssl >/dev/null 2>&1 || { echo "[x] openssl no está instalado" >&2; exit 1; }

if [[ -f "$OUT" ]]; then
  echo "[!] Ya existe $OUT; no se sobrescribe (el ID cambiaría). Bórralo a mano si quieres regenerarlo."
  exit 0
fi

openssl genrsa -out "$TMP/key.pem" 2048
openssl rsa -in "$TMP/key.pem" -pubout -outform DER | base64 -w0 > "$OUT"
echo "[ok] Clave pública escrita en $OUT"
echo "     ID esperado: $(python3 - "$OUT" <<'PY'
import base64, hashlib, sys
key = open(sys.argv[1]).read().strip()
digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
print("".join(chr(ord('a') + int(c, 16)) for c in digest))
PY
)"

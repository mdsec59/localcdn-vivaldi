#!/usr/bin/env bash
# smoke-test.sh — Lanza una instancia AISLADA de Vivaldi con el port cargado y captura los logs.
# No toca el perfil real del usuario (--user-data-dir temporal).
#
# Uso:  tools/smoke-test.sh [segundos]
# Salida: /tmp/opencode/vivaldi-mv2-test.log  y un resumen por stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WAIT="${1:-20}"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }

BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-mv2.XXXXXX)"
LOG="/tmp/opencode/vivaldi-mv2-test.log"

echo "[i] Binario : $BIN"
echo "[i] Perfil  : $PROFILE"
echo "[i] Extens. : $TARGET"

# --enable-logging=stderr hace visibles los errores de carga de extensiones.
timeout --signal=TERM "$WAIT" "$BIN" \
  --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --enable-logging=stderr --v=0 \
  --load-extension="$TARGET" \
  about:blank >"$LOG" 2>&1 || true

pkill -f "$PROFILE" 2>/dev/null || true

echo
echo "=== 1. Warnings/errores de extensiones en el log ==="
grep -iE "manifest|extension|mv2|localcdn|deprecat|unsupported" "$LOG" | head -40 || echo "(sin coincidencias)"

echo
echo "=== 2. ¿Aparece la extensión en las preferencias del perfil? ==="
python3 - "$PROFILE" <<'PY' || echo "(no se pudo inspeccionar Preferences)"
import glob, json, sys
hits = []
for pref in glob.glob(sys.argv[1] + "/Default/Preferences"):
    try:
        data = json.load(open(pref, encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        print("  no legible:", exc); continue
    ext = data.get("extensions", {})
    for state in ("settings", "ui"):
        for eid, info in (ext.get(state) or {}).items():
            path = (info or {}).get("path", "")
            manifest = (info or {}).get("manifest", {})
            if "localcdn" in path.lower() or "LocalCDN" in str(manifest.get("name", "")):
                hits.append((eid, manifest.get("name"), manifest.get("version"),
                             manifest.get("manifest_version"), path))
if hits:
    for h in hits:
        print("  id=%s name=%s version=%s mv=%s path=%s" % h)
else:
    print("  (extensión no encontrada en Preferences)")
PY

echo
echo "Log completo: $LOG"

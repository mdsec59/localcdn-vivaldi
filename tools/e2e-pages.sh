#!/usr/bin/env bash
# e2e-pages.sh — Fase 2.6/2.7: las páginas internas de la extensión abren y muestran datos
# en Chromium/Vivaldi (estadísticas, registro de actividad y bienvenida).
#
# 2.6 Comprueba que pages/statistics y pages/logging renderizan (y no se quedan en blanco por
#     usar APIs exclusivas de Firefox).
# 2.7 Comprueba que la ventana de bienvenida abre y que sus enlaces/avisos existen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:-$ROOT/dist/localcdn-vivaldi}"
WORK="${WORK:-/tmp/opencode/localcdn-pages}"
CDP_PORT="${CDP_PORT:-9362}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || command -v google-chrome || command -v chromium || command -v chromium-browser || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-pages.XXXXXX)"
cleanup() { pkill -f "$PROFILE" 2>/dev/null || true; }
trap cleanup EXIT

"$BIN" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --remote-debugging-port="$CDP_PORT" \
  --load-extension="$TARGET" about:blank >"$WORK/vivaldi.log" 2>&1 &

for _ in $(seq 1 25); do
  curl -s "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
  sleep 1
done
sleep 3

# El ID se lee del target de la página de fondo (MV2 expone background.html como target).
EXT_ID="$(python3 - "$CDP_PORT" "$TARGET" <<'PY'
import hashlib, json, sys, urllib.request
puerto, ruta = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{puerto}/json/list", timeout=10) as fh:
        for d in json.load(fh):
            u = d.get("url", "")
            if u.startswith("chrome-extension://"):
                print(u.split("/")[2]); sys.exit()
except Exception:
    pass
h = hashlib.sha256(ruta.encode()).hexdigest()[:32]
print("".join(chr(ord("a") + int(c, 16)) for c in h))
PY
)"

echo "=== Fase 2.6/2.7: páginas internas (extensión $EXT_ID) ==="
echo

leer() { # nombre-ruta id-elemento
  echo "== $1"
  $CDP eval "$CDP_PORT" "$(basename "$1")" "
    (() => {
      const el = document.getElementById('$2');
      return {
        titulo: document.title,
        existeElementoClave: Boolean(el),
        textoElementoClave: el ? el.textContent.trim().replace(/\\s+/g, ' ').slice(0, 160) : null,
        longitudVisible: (document.body ? document.body.innerText.trim().length : 0),
        errores: (window.__errores || []).length
      };
    })()" || echo "   (no se pudo leer)"
  echo
}

for ruta in statistics/statistics.html:statistics-overview logging/logging.html:logging-content welcome/welcome.html:chromium-banner; do
  pagina="${ruta%%:*}"; elemento="${ruta##*:}"
  curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?chrome-extension://$EXT_ID/pages/$pagina" >/dev/null
  sleep 2
  leer "$pagina" "$elemento"
done

$CDP close "$CDP_PORT" || true
sleep 2
cleanup
echo "Artefactos en: $WORK"

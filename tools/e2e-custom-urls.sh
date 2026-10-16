#!/usr/bin/env bash
# e2e-custom-urls.sh — Prueba funcional de la pestaña "URLs personalizadas".
#
# Verifica que una regla añadida por el usuario intercepta de verdad una petición:
#   1. Lanza Vivaldi aislado con la extensión + CDP.
#   2. Añade una regla desde el background (customUrls.addEntry): un host INEXISTENTE
#      (sin DNS) mapeado a un recurso local real.
#   3. Desde una página, fetch() a esa URL:
#        - con la regla ACTIVA la respuesta llega del recurso local (chrome-extension://),
#        - con la regla DESACTIVADA la petición falla (no hay DNS),
#      lo que demuestra que la intercepción es la causa del éxito.
#   4. Comprueba que la validación rechaza un recurso inexistente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="/tmp/opencode/localcdn-custom-urls"
HTTP_PORT="${HTTP_PORT:-8899}"
CDP_PORT="${CDP_PORT:-9334}"
WAIT_APP="${WAIT_APP:-6}"
CDP="python3 $ROOT/tools/cdp.py"
FAKE_URL="https://cdn.prueba-inexistente.example/lib/mylib-1.2.3.min.js"
LOCAL_RESOURCE="resources/jquery/3.7.1/jquery.min.jsm"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>LocalCDN custom urls</title></head>
<body><h1 id="h">custom urls</h1></body></html>
HTML

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-custom.XXXXXX)"
cleanup() { pkill -f "$PROFILE" 2>/dev/null || true; kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$BIN" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --remote-debugging-port="$CDP_PORT" \
  --load-extension="$TARGET" about:blank >"$WORK/vivaldi.log" 2>&1 &

for _ in $(seq 1 25); do
  curl -s "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
  sleep 1
done

curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?http://127.0.0.1:$HTTP_PORT/index.html" >/dev/null
sleep "$WAIT_APP"

PAGE_TARGET="127.0.0.1:$HTTP_PORT/index.html"

echo "=== 1. Validación: recurso inexistente debe rechazarse ==="
$CDP eval "$CDP_PORT" "background.html" \
  "customUrls.addEntry({pattern: '$FAKE_URL', resource: 'resources/no/existe.jsm'})" || true

echo
echo "=== 2. Alta de la regla (host inexistente -> recurso local real) ==="
$CDP eval "$CDP_PORT" "background.html" \
  "customUrls.addEntry({pattern: '$FAKE_URL', resource: '$LOCAL_RESOURCE', label: 'prueba e2e'})" || true

echo
echo "=== 3. fetch() con la regla ACTIVA (debe servirse en local) ==="
$CDP eval "$CDP_PORT" "$PAGE_TARGET" \
  "(async () => { try { const r = await fetch('$FAKE_URL'); const t = await r.text();
     return { urlFinal: r.url, estado: r.status, bytes: t.length,
              local: r.url.startsWith('chrome-extension://') }; }
     catch (e) { return { error: String(e) }; } })()" || true

echo
echo "=== 4. Desactivar la regla y repetir (debe fallar: no hay DNS) ==="
$CDP eval "$CDP_PORT" "background.html" \
  "(async () => { const list = await customUrls.load();
     const entry = list.find(e => e.pattern === '$FAKE_URL');
     return { id: entry ? entry.id : null, desactivado: entry ? await customUrls.toggleEntry(entry.id) : null }; })()" || true

$CDP eval "$CDP_PORT" "$PAGE_TARGET" \
  "(async () => { try { const r = await fetch('$FAKE_URL'); const t = await r.text();
     return { sorpresa: true, urlFinal: r.url, bytes: t.length }; }
     catch (e) { return { falloEsperado: true, error: String(e) }; } })()" || true

echo
echo "=== 5. matchUrl() en el background (coincidencia exacta del patrón) ==="
$CDP eval "$CDP_PORT" "background.html" \
  "(async () => { await customUrls.load();
     return { entradaActiva: customUrls.entries.map(e => ({ p: e.pattern, activa: e.enabled })),
              match: customUrls.matchUrl('$FAKE_URL') }; })()" || true

echo
echo "=== 6. Índice de recursos disponible para la UI ==="
python3 - <<PY
import json
with open("$TARGET/resources-index.json", encoding="utf-8") as fh:
    index = json.load(fh)
print({"recursos": len(index), "tiene_jquery": "$LOCAL_RESOURCE" in index})
PY

echo
echo "=== 7. Cierre ordenado ==="
$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

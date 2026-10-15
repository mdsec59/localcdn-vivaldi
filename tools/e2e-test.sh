#!/usr/bin/env bash
# e2e-test.sh — Prueba funcional real dentro de Vivaldi.
#
# Verifica que LocalCDN (port Vivaldi) intercepta peticiones a CDNs y las sirve desde
# sus recursos locales. Método:
#   1. Sirve una página de prueba por HTTP local.
#   2. Lanza una instancia AISLADA de Vivaldi con la extensión + remote debugging.
#   3. Abre la página vía CDP y desde ella hace fetch() a URLs de CDN conocidas.
#   4. Comprueba en la respuesta la URL FINAL (si es chrome-extension://.../resources/...).
#   5. Lee el contador chrome.storage.local.amountInjected del background page.
#   6. Cierra el navegador de forma ordenada (Browser.close) para volcar el net-log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="/tmp/opencode/localcdn-e2e"
HTTP_PORT="${HTTP_PORT:-8899}"
CDP_PORT="${CDP_PORT:-9333}"
WAIT_APP="${WAIT_APP:-6}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>LocalCDN e2e</title>
<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
</head><body><h1 id="h">LocalCDN e2e</h1></body></html>
HTML

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-e2e.XXXXXX)"
NETLOG="$WORK/netlog.json"
cleanup() { pkill -f "$PROFILE" 2>/dev/null || true; kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

"$BIN" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check \
  --remote-debugging-port="$CDP_PORT" \
  --log-net-log="$NETLOG" \
  --load-extension="$TARGET" about:blank >"$WORK/vivaldi.log" 2>&1 &

for _ in $(seq 1 25); do
  curl -s "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
  sleep 1
done

curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?http://127.0.0.1:$HTTP_PORT/index.html" >/dev/null
sleep "$WAIT_APP"

echo "=== 1. Targets visibles por CDP ==="
$CDP list "$CDP_PORT" || true

echo
echo "=== 2. Verificación DENTRO de la página (URL final de cada recurso) ==="
$CDP eval "$CDP_PORT" "127.0.0.1:$HTTP_PORT/index.html" '
(async () => {
  const urls = [
    "https://code.jquery.com/jquery-3.7.1.min.js",
    "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css",
    "https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js"
  ];
  const out = [];
  for (const u of urls) {
    try {
      const r = await fetch(u);
      const body = await r.text();
      out.push({ pedido: u, urlFinal: r.url, estado: r.status, bytes: body.length,
                 local: r.url.startsWith("chrome-extension://") });
    } catch (e) { out.push({ pedido: u, error: String(e) }); }
  }
  out.push({ scriptEnDom: document.querySelector("script[src*=jquery]")?.src || null,
             hojaEnDom: document.querySelector("link[href*=bootstrap]")?.href || null });
  return out;
})()' || true

echo
echo "=== 3. Contador interno de la extensión (background page) ==="
$CDP eval "$CDP_PORT" "background.html" '
new Promise(res => chrome.storage.local.get(null, items => res({
  amountInjected: items.amountInjected ?? 0,
  claves: Object.keys(items)
})))' || echo "(no se pudo leer el background page)"

echo
echo "=== 4. Cierre ordenado del navegador ==="
$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "=== 5. net-log: hosts de CDN solicitados ==="
grep -oE 'https://(code\.jquery\.com|cdn\.jsdelivr\.net|ajax\.googleapis\.com)[^"]*' "$NETLOG" 2>/dev/null | sort -u | head || echo "(nada)"
echo "=== net-log: recursos servidos por la extensión ==="
grep -oE 'chrome-extension://[a-p]+/resources/[^"]*' "$NETLOG" 2>/dev/null | sort -u | head || echo "(ninguno)"

echo
echo "Artefactos en: $WORK"

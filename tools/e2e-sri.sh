#!/usr/bin/env bash
# e2e-sri.sh — Fase 4.4: SRI / crossorigin y el test oficial de jQuery.
#
# Contexto: el test oficial pide jQuery 2.1.4, que NO existe en resources/, así que la
# extensión sirve la última versión local de la línea 2.x (2.2.4) — ver
# modules/internal/targets.js: `if (type.startsWith('/jquery/2.')) return '2.2.4'`.
# En Firefox el "HTML filter" elimina integrity/crossorigin del HTML, así que la sustitución
# pasa desapercibida. En Chromium no existe filterResponseData (issue 487422), el atributo
# integrity se mantiene y el navegador rechaza el script porque el hash no coincide con los
# bytes servidos.
#
# La prueba usa tres iframes aislados para separar las causas:
#   A) sin integrity ni crossorigin            -> debe cargar (la inyección funciona)
#   B) integrity de 2.1.4 + crossorigin        -> debe fallar (hash distinto al servido)
#   C) integrity del fichero servido (2.2.4) + crossorigin -> debe cargar (CORS y SRI OK)
# El caso C es clave: si cargase, demuestra que el bloqueo es el hash y no CORS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="${WORK:-/tmp/opencode/localcdn-sri}"
HTTP_PORT="${HTTP_PORT:-8907}"
CDP_PORT="${CDP_PORT:-9355}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || command -v google-chrome || command -v chromium || command -v chromium-browser || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

SERVIDO="$TARGET/resources/jquery/2.2.4/jquery.min.jsm"
[[ -f "$SERVIDO" ]] || { echo "[x] No existe $SERVIDO" >&2; exit 1; }
HASH_SERVIDO="sha512-$(python3 -c "
import base64, hashlib
print(base64.b64encode(hashlib.sha512(open('$SERVIDO','rb').read()).digest()).decode())")"
echo "[i] hash del fichero servido (jquery 2.2.4): $HASH_SERVIDO"

cat > "$WORK/index.html" <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>sri</title></head>
<body>
<script>
window.__casos = {
  a: {etiqueta: 'A) sin integrity ni crossorigin',
      html: '<script src="https://ajax.googleapis.com/ajax/libs/jquery/2.1.4/jquery.min.js"><\\/script>'},
  b: {etiqueta: 'B) integrity de 2.1.4 (el del test oficial) + crossorigin',
      html: '<script src="https://ajax.googleapis.com/ajax/libs/jquery/2.1.4/jquery.min.js" integrity="sha512-AFwxAkWdvxRd9qhYYp1qbeRZj6/iTNmJ2GFwcxsMOzwwTaRwz2a/2TX225Ebcj3whXte1WGQb38cXE5j7ZQw3g==" crossorigin="anonymous"><\\/script>'},
  c: {etiqueta: 'C) integrity del fichero realmente servido (2.2.4) + crossorigin',
      html: '<script src="https://ajax.googleapis.com/ajax/libs/jquery/2.1.4/jquery.min.js" integrity="$HASH_SERVIDO" crossorigin="anonymous"><\\/script>'}
};
</script>
contenedor de pruebas SRI
</body></html>
HTML

cat > "$WORK/js-sri.js" <<'JS'
(async () => {
  const salida = {};
  const espera = (ms) => new Promise((r) => setTimeout(r, ms));

  for (const clave of Object.keys(window.__casos)) {
    const caso = window.__casos[clave];
    const marco = document.createElement('iframe');
    marco.setAttribute('sandbox', 'allow-scripts allow-same-origin');
    marco.style.width = '1px';
    marco.style.height = '1px';
    document.body.appendChild(marco);
    const doc = marco.contentDocument;
    doc.open();
    doc.write('<!doctype html><html><body>' + caso.html + '<\/body><\/html>');
    doc.close();
    await espera(3000);
    const win = marco.contentWindow;
    const recursos = win.performance.getEntriesByType('resource').map((e) => e.name);
    const jquery = recursos.find((n) => /jquery/.test(n)) || null;
    salida[clave] = {
      etiqueta: caso.etiqueta,
      jqueryDefinido: typeof win.jQuery !== 'undefined',
      versionInstalada: win.jQuery ? win.jQuery.fn.jquery : null,
      urlPedida: jquery,
      desdeExtension: Boolean(jquery && jquery.startsWith('chrome-extension://'))
    };
  }
  return salida;
})()
JS

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-sri.XXXXXX)"
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
sleep 5

echo
echo "=== 4.4 SRI/crossorigin con jQuery 2.1.4 (sustitución por 2.2.4) ==="
$CDP eval "$CDP_PORT" "index.html" "$(cat "$WORK/js-sri.js")" | tee "$WORK/resultado-sri.json"

$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

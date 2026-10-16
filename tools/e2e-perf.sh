#!/usr/bin/env bash
# e2e-perf.sh — Fase 4.8: coste de la intercepción.
#
# Método: se sirven los MISMOS 22 ficheros de dos formas y se comparan los tiempos que ve la
# página (performance.now(), con cache: 'no-store'):
#
#   A) intercepción: se pide la URL del CDN -> la extensión la redirige a
#      chrome-extension://…/resources/… (webRequest en MV2; reglas DNR en el prototipo MV3)
#   B) referencia: se pide el mismo fichero por HTTP local (python http.server) desde
#      /resources/…
#
# La diferencia es el coste añadido por la intercepción (decisión + esquema de extensión) frente a
# servir el mismo fichero desde disco por HTTP. Se informa mediana y media, no sólo la media, para
# que un pico no distorsione. El baseline de red real (descarga desde el CDN) no se incluye: la
# máquina de pruebas usa una red restringida (Psiphon), así que no es un número comparable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:-$ROOT/dist/localcdn-vivaldi}"
WORK="${WORK:-/tmp/opencode/localcdn-perf}"
CDP_PORT="${CDP_PORT:-9363}"
HTTP_PORT="${HTTP_PORT:-8920}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>rendimiento</title></head>
<body><script>window.__vivo = true;</script>rendimiento</body></html>
HTML

cat > "$WORK/js-perf.js" <<'JS'
(async () => {
  const FICHEROS = [
    ['https://code.jquery.com/jquery-3.7.1.min.js', 'resources/jquery/3.7.1/jquery.min.jsm'],
    ['https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js', 'resources/jquery/3.7.1/jquery.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/moment.js/2.30.1/moment-with-locales.min.js', 'resources/moment.js/2.30.1/moment-with-locales.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/d3/7.9.0/d3.min.js', 'resources/d3/7.9.0/d3.min.jsm'],
    ['https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js', 'resources/lodash.js/4.17.21/lodash.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/popper.js/2.11.8/umd/popper.min.js', 'resources/popper.js/2.11.8/umd/popper.min.jsm'],
    ['https://cdn.jsdelivr.net/npm/axios@1.20.0/dist/axios.min.js', 'resources/axios/1.20.0/axios.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/alpinejs/3.17.1/alpine.js', 'resources/alpinejs/3.17.1/alpine.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.6.15/hls.min.js', 'resources/hls.js/1.6.15/hls.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/animate.css/4.1.1/animate.min.css', 'resources/animate.css/4.1.1/animate.min.css'],
    ['https://use.fontawesome.com/releases/v6.7.2/css/all.css', 'resources/font-awesome/6.7.2/css/all.min.css'],
    ['https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css', 'resources/twitter-bootstrap/5.3.8/bootstrap.min.css'],
    ['https://cdnjs.cloudflare.com/ajax/libs/underscore.js/1.13.8/underscore-min.js', 'resources/underscore.js/1.13.8/underscore-min.jsm'],
    ['https://cdn.jsdelivr.net/npm/vue@3.5.42/dist/vue.min.js', 'resources/vue/3.5.42/vue.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/tinymce/5.10.5/tinymce.min.js', 'resources/tinymce/5.10.5/tinymce.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/select2/4.1.0/js/select2.min.js', 'resources/select2/4.1.0/select2.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.3.1/umd/react-dom.production.min.js', 'resources/react-dom/18.3.1/umd/react-dom.production.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/mathjax/3.2.2/es5/tex-chtml.js', 'resources/mathjax/3.2.2/es5/tex-chtml.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js', 'resources/leaflet/1.9.4/leaflet.jsm'],
    ['https://maxcdn.bootstrapcdn.com/font-awesome/4.7.0/css/font-awesome.min.css', 'resources/font-awesome/4.7.0/css/font-awesome.min.css'],
    ['https://code.jquery.com/ui/1.14.2/jquery-ui.min.js', 'resources/jqueryui/1.14.2/jquery-ui.min.jsm'],
    ['https://cdnjs.cloudflare.com/ajax/libs/gsap/3.15.0/gsap.min.js', 'resources/gsap/3.15.0/gsap.min.jsm']
  ];
  const BASE_LOCAL = window.__baseLocal;

  async function medir(url) {
    const t0 = performance.now();
    const r = await fetch(url, {cache: 'no-store'});
    const buf = await r.arrayBuffer();
    return {ms: performance.now() - t0, bytes: buf.byteLength, url: r.url};
  }
  const estad = (xs) => {
    const s = [...xs].sort((a, b) => a - b);
    const media = xs.reduce((a, b) => a + b, 0) / xs.length;
    return {
      n: xs.length,
      mediana: Number(s[Math.floor(s.length / 2)].toFixed(2)),
      media: Number(media.toFixed(2)),
      min: Number(s[0].toFixed(2)),
      max: Number(s[s.length - 1].toFixed(2))
    };
  };

  // Calentamiento (no se mide).
  await medir(FICHEROS[0][0]).catch(() => {});

  const A = []; // interceptado
  const B = []; // referencia local por HTTP
  let bytes = 0;
  for (const [cdn, local] of FICHEROS) {
    try { const m = await medir(cdn); A.push(m.ms); bytes += m.bytes; } catch (e) { A.push(NaN); }
  }
  for (const [, local] of FICHEROS) {
    try { const m = await medir(BASE_LOCAL + '/' + local); B.push(m.ms); } catch (e) { B.push(NaN); }
  }

  const limpiar = (xs) => xs.filter((x) => Number.isFinite(x));
  return {
    interceptado: estad(limpiar(A)),
    referenciaHttpLocal: estad(limpiar(B)),
    bytesTotales: bytes,
    fallos: A.filter((x) => !Number.isFinite(x)).length + B.filter((x) => !Number.isFinite(x)).length
  };
})()
JS

ln -s "$TARGET/resources" "$WORK/resources"   # para servir los mismos ficheros por HTTP local
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-perf.XXXXXX)"
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
# La referencia se sirve desde el propio build (mismos ficheros) por HTTP local.
python3 - "$WORK/index.html" "$HTTP_PORT" <<'PY'
import sys
ruta, puerto = sys.argv[1:3]
html = open(ruta, encoding='utf-8').read()
html = html.replace('<script>window.__vivo = true;</script>',
                    f'<script>window.__vivo = true; window.__baseLocal = "http://127.0.0.1:{puerto}";</script>')
open(ruta, 'w', encoding='utf-8').write(html)
PY

curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?http://127.0.0.1:$HTTP_PORT/index.html" >/dev/null
sleep 4

echo "=== Fase 4.8: coste de la intercepción (22 ficheros) ==="
$CDP eval "$CDP_PORT" "index.html" "$(cat "$WORK/js-perf.js")" | tee "$WORK/resultado-perf.json"

$CDP close "$CDP_PORT" || true
sleep 2
cleanup
echo
echo "Artefactos en: $WORK"

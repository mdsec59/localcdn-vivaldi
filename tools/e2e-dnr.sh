#!/usr/bin/env bash
# e2e-dnr.sh — Fase 6.1/6.2/6.6: prueba del prototipo MV3 con declarativeNetRequest.
#
#   6.1 Reglas válidas: el navegador carga los rulesets sin errores y
#       declarativeNetRequest.testMatchOutcome confirma coincidencias.
#   6.2 Límites y particionado: se consultan los límites reales del Chromium de Vivaldi
#       (constantes + reglas disponibles) y se comprueba cuántas reglas caben.
#   6.6 Paridad funcional: la matriz de recursos debe servirse desde resources/ local
#       igual que con el motor webRequest (MV2).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:-$ROOT/dist/localcdn-vivaldi-mv3}"
WORK="${WORK:-/tmp/opencode/localcdn-dnr}"
HTTP_PORT="${HTTP_PORT:-8912}"
CDP_PORT="${CDP_PORT:-9360}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build-mv3.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>matriz DNR</title></head>
<body><script>window.__vivo = true;</script>matriz DNR</body></html>
HTML

# Misma matriz que tools/e2e-matrix.sh (22 URLs): permite comparar MV2 vs MV3.
# El destino esperado se comprueba contra el fichero local servido.
cat > "$WORK/js-matriz-dnr.js" <<'JS'
(async () => {
  const MATRIZ = [
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
  const resultados = [];
  for (const [url, esperado] of MATRIZ) {
    const fila = {url, esperado};
    try {
      const r = await fetch(url, {cache: 'no-store'});
      fila.local = r.url.startsWith('chrome-extension://');
      fila.ok = fila.local && r.url.includes(esperado);
      fila.recibido = r.url.replace(/^chrome-extension:\/\/[^/]+/, 'EXT');
      fila.bytes = (await r.arrayBuffer()).byteLength;
    } catch (e) {
      fila.ok = false;
      fila.error = String(e);
    }
    resultados.push(fila);
  }
  return {
    total: resultados.length,
    servidosEnLocal: resultados.filter((f) => f.ok).length,
    fallos: resultados.filter((f) => !f.ok)
  };
})()
JS

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-dnr.XXXXXX)"
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
sleep 3

# ID de la extensión: se toma del target del service worker; si aún no existe, se calcula
# con el algoritmo de Chromium (SHA-256 de la ruta absoluta) para extensiones sin clave.
EXT_ID="$(python3 - "$CDP_PORT" "$TARGET" <<'PY'
import hashlib, json, sys, urllib.request
puerto, ruta = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{puerto}/json/list", timeout=10) as fh:
        destinos = json.load(fh)
    for d in destinos:
        u = d.get("url", "")
        if u.startswith("chrome-extension://") and "sw.js" in u:
            print(u.split("/")[2]); sys.exit()
except Exception:
    pass
h = hashlib.sha256(ruta.encode()).hexdigest()[:32]
print("".join(chr(ord("a") + int(c, 16)) for c in h))
PY
)"

echo "=== Prototipo MV3: $(basename "$TARGET") ==="
echo "    extensión: $EXT_ID"
echo

echo "=== 6.1/6.2 Reglas cargadas, límites y coincidencia (testMatchOutcome) ==="
curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?chrome-extension://$EXT_ID/limits.html" >/dev/null
for _ in $(seq 1 20); do
  TITULO="$($CDP eval "$CDP_PORT" "limits.html" "document.title" 2>/dev/null || echo "")"
  [[ "$TITULO" == *listo* ]] && break
  sleep 1
done
$CDP eval "$CDP_PORT" "limits.html" "document.getElementById('salida').textContent" | tee "$WORK/limites.json"
echo

echo "=== 6.6 Paridad con la matriz de recursos (MV3/DNR) ==="
curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?http://127.0.0.1:$HTTP_PORT/index.html" >/dev/null
sleep 4
$CDP eval "$CDP_PORT" "index.html" "$(cat "$WORK/js-matriz-dnr.js")" | tee "$WORK/resultado-matriz-dnr.json"

$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

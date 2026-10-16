#!/usr/bin/env bash
# e2e-parity.sh — Paridad de funciones que upstream desactiva en Chromium (Fase 2).
#
#   2.1 Bloqueo de Google Fonts: la opción "Block Google Fonts" debe redirigir
#       fonts.googleapis.com al CSS de reemplazo local (resources/google-fonts-placeholder.css).
#   2.2 Font Awesome: el CSS debe servirse en local Y las fuentes referenciadas con rutas
#       relativas (url(../webfonts/...)) deben cargarse desde la extensión. Ese es el motivo
#       real de la desactivación upstream en Chromium: el "file guard" interceptaba esas
#       URLs relativas porque no llevan el secreto.
#   2.4 Estado del sanitizador de cabeceras y 2.6 datos de estadísticas.
#
# Los fragmentos JS viven en ficheros para no lidiar con el escaping del shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="${WORK:-/tmp/opencode/localcdn-parity}"
HTTP_PORT="${HTTP_PORT:-8903}"
CDP_PORT="${CDP_PORT:-9347}"
WAIT_APP="${WAIT_APP:-6}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>paridad</title>
<link rel="stylesheet" href="https://use.fontawesome.com/releases/v6.7.2/css/all.css">
</head>
<body>
<i class="fa fa-check" id="icono"></i>
<span id="vacia"></span>
</body></html>
HTML

cat > "$WORK/js-fa.js" <<'JS'
(async () => {
  const cssUrl = 'https://use.fontawesome.com/releases/v6.7.2/css/all.css';
  const r = await fetch(cssUrl);
  const css = await r.text();
  const urlsDeFuente = [...css.matchAll(/url\(([^)]+)\)/g)]
      .map((m) => m[1].replace(/["']/g, '').split(' ')[0])
      .filter((u) => !u.startsWith('data:'))
      .slice(0, 4)
      .map((u) => new URL(u, r.url).href);
  await new Promise((res) => setTimeout(res, 1500));
  const face = document.fonts && [...document.fonts].find((f) => /Font Awesome/.test(f.family));
  if (face) { try { await face.load(); } catch (e) {} }
  const icono = getComputedStyle(document.getElementById('icono'), '::before');
  const recursos = performance.getEntriesByType('resource').map((e) => e.name);
  return {
    cssLocal: r.url.startsWith('chrome-extension://'),
    cssFinal: r.url.replace(/^chrome-extension:\/\/[^/]+/, 'chrome-extension://<id>'),
    bytesCss: css.length,
    urlsDeFuente,
    peticionesDeFuente: recursos.filter((n) => /webfonts|fonts\//.test(n)).length,
    ejemplosDeRecursos: recursos.slice(0, 6),
    tipoDeFuente: face ? face.family : null,
    estadoDeFuente: face ? face.status : null,
    iconoAplicado: icono.content !== 'none' && icono.content !== 'normal'
  };
})()
JS

cat > "$WORK/js-fonts-on.js" <<'JS'
(async () => {
  try {
    const r = await fetch('https://fonts.googleapis.com/css?family=Roboto');
    return {
      local: r.url.startsWith('chrome-extension://'),
      estado: r.status,
      final: r.url.replace(/^chrome-extension:\/\/[^/]+/, 'chrome-extension://<id>'),
      bytes: (await r.text()).length
    };
  } catch (e) { return {error: String(e)}; }
})()
JS

cat > "$WORK/js-fonts-off.js" <<'JS'
(async () => {
  try {
    const r = await fetch('https://fonts.googleapis.com/css?family=Roboto');
    return {local: r.url.startsWith('chrome-extension://'), estado: r.status};
  } catch (e) { return {bloqueado: String(e)}; }
})()
JS

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-parity.XXXXXX)"
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
PAGE="127.0.0.1:$HTTP_PORT/index.html"

echo "=== 2.2a. Font Awesome: CSS servido en local + fuentes relativas ==="
$CDP eval "$CDP_PORT" "$PAGE" "$(cat "$WORK/js-fa.js")" || true

echo
echo "=== 2.2b. file guard: subrecursos permitidos por ser de la extensión ==="
$CDP eval "$CDP_PORT" "background.html" 'fileGuard._seen' || true

echo
echo "=== 2.1a. Google Fonts: Block Google Fonts ACTIVADO ==="
$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.set({blockGoogleFonts: true}, () => res({activado: true})))' || true
sleep 2
$CDP eval "$CDP_PORT" "$PAGE" "$(cat "$WORK/js-fonts-on.js")" || true

echo
echo "=== 2.1b. Google Fonts: Block Google Fonts DESACTIVADO ==="
$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.set({blockGoogleFonts: false}, () => res({activado: false})))' || true
sleep 2
$CDP eval "$CDP_PORT" "$PAGE" "$(cat "$WORK/js-fonts-off.js")" || true

echo
echo "=== 2.4. sanitizador de cabeceras y hosts válidos ==="
$CDP eval "$CDP_PORT" "background.html" \
  '({sanitizerDisponible: typeof requestSanitizer !== "undefined",
     validHosts: stateManager.validHosts.length,
     googleFontsEnMappings: Object.keys(mappings.cdn).filter((h) => h.includes("fonts.g")).slice(0, 5)})' || true

echo
echo "=== 2.6. Contadores e internalStatistics ==="
$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.get(null, (items) =>
     res({amountInjected: items.amountInjected ?? 0,
          internalStatistics: items.internalStatistics ?? null})))' || true

$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

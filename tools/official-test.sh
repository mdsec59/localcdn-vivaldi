#!/usr/bin/env bash
# official-test.sh — Ejecuta el test OFICIAL de LocalCDN (localcdn.org/test) con Vivaldi.
#
# El test oficial abre páginas que piden recursos a CDNs y comprueba las cabeceras de la
# respuesta. Escribe el veredicto en #message-log y cambia el logo (protegido / sin proteger):
#   - "LocalCDN is fully operational."  -> respuesta servida en local (correcto)
#   - "Your browser was able to connect to a CDN." -> NO interceptado
#
# Este script abre cada página de prueba, espera, extrae el texto de #message-log, el
# indicador de progreso y el estado del logo, y guarda una captura como evidencia.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="${WORK:-/tmp/opencode/localcdn-official-test}"
CDP_PORT="${CDP_PORT:-9335}"
WAIT_APP="${WAIT_APP:-6}"
WAIT_POLLS="${WAIT_POLLS:-15}"
WAIT_STEP="${WAIT_STEP:-2}"
CDP="python3 $ROOT/tools/cdp.py"

PAGES_DEFECTO=(
  "https://www.localcdn.org/test/jquery"
  "https://www.localcdn.org/test/fontawesome"
  "https://www.localcdn.org/test/materialicons"
  "https://www.localcdn.org/test/worstcase"
  "https://www.localcdn.org/test/tinymce"
)

# Permite ejecutar solo algunas páginas: PAGES="url1 url2" tools/official-test.sh
if [[ -n "${PAGES:-}" ]]; then
  read -r -a PAGES_ARR <<<"$PAGES"
else
  PAGES_ARR=("${PAGES_DEFECTO[@]}")
fi

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-official.XXXXXX)"
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

echo "=== LocalCDN: test oficial (extensión: $TARGET) ==="
echo

READY_JS='
(() => {
  const progress = document.getElementById("progress-indicator");
  const log = document.getElementById("message-log");
  const text = progress ? progress.textContent : "";
  // Los tests de Font Awesome y Material Icons sólo se ejecutan en Firefox: en Chromium
  // el propio test oculta #message-log y muestra el aviso "only Firefox". Eso también
  // cuenta como terminado (no es un cuelgue).
  const omitido = Boolean(log && log.style.display === "none");
  return {
    ready: omitido || (text !== "" && text.indexOf("Determining status") === -1),
    text,
    omitido
  };
})()'

for page in "${PAGES_ARR[@]}"; do
  name="${page##*/}"
  echo "----------------------------------------------------------------"
  echo "== Página de prueba: $name"
  curl -s -X PUT "http://127.0.0.1:$CDP_PORT/json/new?$page" >/dev/null
  sleep "$WAIT_APP"
  ready=false
  for _ in $(seq 1 "$WAIT_POLLS"); do
    state=$($CDP eval "$CDP_PORT" "$page" "$READY_JS" 2>/dev/null || echo '{}')
    if [[ "$state" == *'"ready": true'* ]]; then
      ready=true
      break
    fi
    sleep "$WAIT_STEP"
  done
  [[ "$ready" == true ]] || echo "  (aviso: el test no terminó a tiempo; se muestra el estado actual)"
  $CDP eval "$CDP_PORT" "$page" '
    (() => {
      const log = document.getElementById("message-log");
      const progress = document.getElementById("progress-indicator");
      const logo = document.getElementById("logo");
      const aviso = document.getElementById("notice-fontawesome-only-firefox") ||
                    document.getElementById("notice-materialicons-only-firefox");
      return {
        url: location.href,
        titulo: document.title,
        omitidoPorElTest: Boolean(log && log.style.display === "none"),
        aviso: aviso ? aviso.textContent.trim().replace(/\s+/g, " ").slice(0, 120) : null,
        progreso: progress ? progress.textContent : null,
        logo: logo ? logo.src.split("/").pop() : null,
        mensajes: log ? Array.from(log.children).map((d) => d.textContent.trim()) : []
      };
    })()' || echo "  (no se pudo leer la página $name)"
done

echo
echo "----------------------------------------------------------------"
echo "== Captura de evidencia (página jQuery)"
$CDP shot "$CDP_PORT" "localcdn.org/test/jquery" "$WORK/test-oficial-jquery.png" || true

echo
echo "== Estado de la extensión en el navegador de prueba"
$CDP eval "$CDP_PORT" "background.html" '
  new Promise((res) => chrome.storage.local.get(null, (items) => res({
    amountInjected: items.amountInjected ?? 0,
    allowlistedDomains: items.allowlistedDomains ?? ""
  })))' || echo "  (no se pudo leer el background page)"

echo
echo "== URLs personalizadas activas (deben estar vacías en una instalación limpia)"
$CDP eval "$CDP_PORT" "background.html" \
  "customUrls.load().then((list) => ({ total: list.length, entradas: list }))" || true

echo
echo "== Cierre ordenado"
$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

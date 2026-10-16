#!/usr/bin/env bash
# e2e-headers.sh — Fase 2.4: stripMetadata con EXTRA_HEADERS en Chromium/Vivaldi.
#
# Comprueba que el sanitizador de cabeceras (core/request-sanitizer.js) funciona de verdad en
# Vivaldi, es decir que las peticiones que SÍ salen a la red hacia un CDN conocido salen sin
# Origin/Referer/Cookie.
#
# Método: se pide una ruta NO mapeada de un host de la lista de CDNs. Al no tener equivalente
# local, la petición no se intercepta y llega a la red; ahí se observan las cabeceras reales
# con el evento CDP Network.requestWillBeSentExtraInfo. Se hacen dos pasadas:
#   A) con stripMetadata activado (por defecto)  -> Origin/Referer deben desaparecer
#   B) con stripMetadata desactivado (control)   -> Origin/Referer deben aparecer
# Sin la pasada B no se podría saber si la ausencia de cabeceras es mérito de la extensión.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/dist/localcdn-vivaldi"
WORK="${WORK:-/tmp/opencode/localcdn-headers}"
HTTP_PORT="${HTTP_PORT:-8905}"
CDP_PORT="${CDP_PORT:-9353}"
CDP="python3 $ROOT/tools/cdp.py"

[[ -d "$TARGET" ]] || { echo "[x] Falta $TARGET. Ejecuta tools/build.sh" >&2; exit 1; }
BIN="${VIVALDI_BIN:-$(command -v vivaldi-stable || command -v vivaldi || echo /opt/vivaldi/vivaldi)}"

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>cabeceras</title></head>
<body>prueba de cabeceras</body></html>
HTML

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
PROFILE="$(mktemp -d /tmp/opencode/vivaldi-headers.XXXXXX)"
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

# Ruta sin equivalente local: no se intercepta y la petición sale a la red.
# El retardo da tiempo a que el agente de red del renderer esté listo y emita
# Network.requestWillBeSent (necesario para asociar el evento extra a una URL).
JS_ACTIVO="setTimeout(() => { fetch('https://ajax.googleapis.com/sin-mapeo-activo.js', {credentials: 'omit'}).catch(() => {}); }, 1500);"
JS_INACTIVO="setTimeout(() => { fetch('https://ajax.googleapis.com/sin-mapeo-inactivo.js', {credentials: 'omit'}).catch(() => {}); }, 1500);"

echo "=== Fase A: stripMetadata ACTIVADO (por defecto) ==="
$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.set({stripMetadata: true}, () => res({stripMetadata: true})))' || true
sleep 1
$CDP listen "$CDP_PORT" "index.html" 6 "" "$JS_ACTIVO" >"$WORK/eventos-activo.json" || true

echo
echo "=== Fase B: stripMetadata DESACTIVADO (control) ==="
$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.set({stripMetadata: false}, () => res({stripMetadata: false})))' || true
sleep 1
$CDP listen "$CDP_PORT" "index.html" 6 "" "$JS_INACTIVO" >"$WORK/eventos-inactivo.json" || true

cat > "$WORK/verificar.py" <<'PY'
import json
import sys

SENSIBLES = ("origin", "referer", "cookie")



def eventos(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def cabeceras_de_cdn(lista, fragmento):
    """Devuelve {id: (url, cabeceras)} de la petición cuyo URL contiene `fragmento`."""
    por_id = {}
    for evento in lista:
        if evento.get("ev") in ("request", "response"):
            por_id.setdefault(evento.get("id"), evento.get("url", "?"))

    objetivo = [rid for rid, url in por_id.items() if fragmento in (url or "")]
    salida = {}
    for evento in lista:
        if evento.get("ev") != "enviado-extra":
            continue
        rid = evento.get("id")
        url = evento.get("url")
        if url in (None, "?"):
            url = por_id.get(rid, "?")
        # Si el evento principal no llegó (carrera del renderer) y solo hay un extra sin
        # identificar, se asume que es el nuestro: la página no genera otro tráfico.
        if fragmento in (url or "") or (not objetivo and url == "?"):
            salida[rid] = (url if url != "?" else f"{fragmento} (sin evento principal)", evento.get("cabeceras", {}))
    return salida


def main():
    activo = cabeceras_de_cdn(eventos(sys.argv[1]), "sin-mapeo-activo.js")
    inactivo = cabeceras_de_cdn(eventos(sys.argv[2]), "sin-mapeo-inactivo.js")

    print(f"[i] peticiones observadas al CDN — activado: {len(activo)}, control: {len(inactivo)}")
    for etiqueta, datos in (("ACTIVADO", activo), ("CONTROL", inactivo)):
        for _rid, (url, cabeceras) in datos.items():
            print(f"    {etiqueta}: {url}")
            print(f"        {json.dumps(cabeceras, ensure_ascii=False)}")

    if not activo or not inactivo:
        print("[x] No se observaron peticiones al CDN en alguna de las fases", file=sys.stderr)
        return 1

    fallos = []
    for rid, (url, cabeceras) in activo.items():
        presentes = [c for c in SENSIBLES if c in cabeceras]
        if presentes:
            fallos.append(f"con stripMetadata activado {url} aún envía {presentes}")
    for rid, (url, cabeceras) in inactivo.items():
        if "origin" not in cabeceras:
            fallos.append(
                f"el control {url} no envía Origin: la medición no es fiable"
            )

    if fallos:
        for fallo in fallos:
            print(f"[x] {fallo}", file=sys.stderr)
        return 1

    print()
    print("[ok] 2.4: con stripMetadata activado no salen Origin/Referer/Cookie hacia el CDN,")
    print("     y con el sanitizador desactivado sí salen (control correcto).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

python3 "$WORK/verificar.py" "$WORK/eventos-activo.json" "$WORK/eventos-inactivo.json"

$CDP eval "$CDP_PORT" "background.html" \
  'new Promise((res) => chrome.storage.local.set({stripMetadata: true}, () => res({restaurado: true})))' >/dev/null || true
$CDP close "$CDP_PORT" || true
sleep 2
cleanup

echo
echo "Artefactos en: $WORK"

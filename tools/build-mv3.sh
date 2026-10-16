#!/usr/bin/env bash
#
# build-mv3.sh — Fase 6: construye el prototipo MV3 (declarativeNetRequest).
#
# A diferencia de tools/build.sh (que mantiene Manifest V2 y el motor original),
# esto genera una extensión MV3 mínima: reglas estáticas DNR + un service worker
# de diagnóstico. NO pretende ser un port completo; sirve para medir el encaje
# de las reglas en los límites de Chromium y para probar la paridad con la
# matriz de recursos (tools/e2e-dnr.sh).
#
# Variables:
#   BASE      build MV2 del que tomar recursos/  (def. dist/localcdn-vivaldi)
#   DEST      carpeta de salida                  (def. dist/localcdn-vivaldi-mv3)
#   HOSTS     lista de CDN a incluir (separados por comas)
#             (def. los 6 que usa tools/e2e-matrix.sh; vacío = TODOS)
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

BASE="${BASE:-dist/localcdn-vivaldi}"
DEST="${DEST:-dist/localcdn-vivaldi-mv3}"
HOSTS="${HOSTS-cdnjs.cloudflare.com,cdn.jsdelivr.net,ajax.googleapis.com,code.jquery.com,maxcdn.bootstrapcdn.com,use.fontawesome.com}"

# Versión: se copia la del manifest MV2 de origen.
VERSION="$(python3 - "$BASE/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['version'])
PY
)"

if [[ ! -d "$BASE/resources" ]]; then
  echo "ERROR: no existe $BASE/resources. Ejecuta antes tools/build.sh" >&2
  exit 1
fi

TMP="$(mktemp -d /tmp/opencode/build-mv3.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generando reglas DNR (hosts: ${HOSTS:-TODOS})"
if [[ -n "$HOSTS" ]]; then
  node tools/gen-dnr.mjs --base "$BASE" --out "$TMP/rules" --solo-hosts "$HOSTS"
else
  node tools/gen-dnr.mjs --base "$BASE" --out "$TMP/rules"
fi

echo "==> Ensamblando $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/rules"
cp "$TMP"/rules/ruleset-*.json "$DEST/rules/"
cp "$TMP"/rules/index.json "$DEST/rules/index.json"
cp mv3/sw.js mv3/limits.html mv3/limits.js "$DEST/"

# Recursos por enlaces duros: no duplican los 88 MB.
cp -al "$BASE/resources" "$DEST/resources" 2>/dev/null || cp -r "$BASE/resources" "$DEST/resources"

# Manifest MV3 con la lista de rulesets generada.
python3 - "$VERSION" "$TMP/rules/index.json" "$DEST/manifest.json" <<'PY'
import json, sys

version, ruta_indice, ruta_manifest = sys.argv[1:4]
indice = json.load(open(ruta_indice, encoding='utf-8'))

manifest = {
    'manifest_version': 3,
    'name': 'LocalCDN Vivaldi (prototipo MV3)',
    'short_name': 'LocalCDN MV3',
    'version': version,
    'description': 'Prototipo MV3 con reglas declarativeNetRequest generadas desde core/mappings.js (Fase 6).',
    'author': 'Port de LocalCDN para Vivaldi',
    'homepage_url': 'https://codeberg.org/nobody/LocalCDN',
    'icons': {'48': 'icons/icon.svg', '96': 'icons/icon.svg'},
    'permissions': ['declarativeNetRequest', 'declarativeNetRequestFeedback', 'storage'],
    'host_permissions': ['<all_urls>'],
    'background': {'service_worker': 'sw.js'},
    'declarative_net_request': {
        'rule_resources': [
            {'id': r['id'], 'enabled': True, 'path': f"rules/{r['id']}.json"}
            for r in indice['reglasPorRuleset']
        ]
    },
    'web_accessible_resources': [
        {'resources': ['resources/*'], 'matches': ['<all_urls>']}
    ]
}

json.dump(manifest, open(ruta_manifest, 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
print(f"    manifest MV3 con {len(manifest['declarative_net_request']['rule_resources'])} rulesets")
PY

if [[ -f "$BASE/icons/icon.svg" ]]; then
  mkdir -p "$DEST/icons"
  cp "$BASE/icons/icon.svg" "$DEST/icons/icon.svg"
fi

echo
echo "==> Hecho: $DEST"
python3 - "$DEST/rules/index.json" <<'PY'
import json, sys
i = json.load(open(sys.argv[1], encoding='utf-8'))
print(f"    reglas: {i['reglasTotales']} en {i['rulesets']} rulesets "
      f"(máx. {i['maxReglasEnUnRuleset']} por ruleset, hosts: {i['hosts']})")
PY
echo "    Cargar en Vivaldi: vivaldi://extensions → Modo desarrollador → Cargar descomprimida"
echo "    Diagnóstico: tools/e2e-dnr.sh"

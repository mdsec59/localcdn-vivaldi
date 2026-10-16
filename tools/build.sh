#!/usr/bin/env bash
# build.sh — Genera dist/localcdn-vivaldi a partir de upstream/ + la plantilla de manifest para Vivaldi.
#
# Uso:
#   tools/build.sh            # construye y empaqueta
#   tools/build.sh --no-zip   # construye sin zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
DIST="$ROOT/dist"
TARGET="$DIST/localcdn-vivaldi"
TEMPLATE="$ROOT/manifest/manifest.vivaldi.json"
MAKE_ZIP=1

[[ "${1:-}" == "--no-zip" ]] && MAKE_ZIP=0

[[ -d "$UPSTREAM" ]] || { echo "[x] Falta upstream/. Ejecuta tools/fetch-upstream.sh" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "[x] Falta $TEMPLATE" >&2; exit 1; }

UPSTREAM_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPSTREAM/manifest.json" | head -n1)"
[[ -n "$UPSTREAM_VERSION" ]] || { echo "[x] No se pudo leer la versión de upstream/manifest.json" >&2; exit 1; }

echo "[i] Upstream: $(git -C "$UPSTREAM" log --oneline -1 2>/dev/null || echo 'sin git') (v$UPSTREAM_VERSION)"
mkdir -p "$TARGET"

# 1) Copiar el árbol de upstream, excluyendo metadatos de repo/CI/estilo que no hacen falta en runtime.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude='.git/' --exclude='.github/' \
    --exclude='.eslintrc' --exclude='.eslintignore' \
    --exclude='.stylelintrc' --exclude='.csslintrc' --exclude='.gitignore' \
    --exclude='CONTRIBUTING.md' --exclude='PULL_REQUEST_TEMPLATE.md' \
    --exclude='screenshots/' \
    "$UPSTREAM/" "$TARGET/"
else
  echo "[!] rsync no disponible, usando cp -a (sin limpieza previa)"
  rm -rf "$TARGET"; mkdir -p "$TARGET"
  cp -a "$UPSTREAM/." "$TARGET/"
  rm -rf "$TARGET/.git" "$TARGET/screenshots"
fi

# 2) Manifest específico para Chromium/Vivaldi.
cp "$TEMPLATE" "$TARGET/manifest.json"

# 2b) Copiar los ficheros propios del port (no existen en upstream).
mkdir -p "$TARGET/pages/options"
cp "$ROOT/patches/core/custom-urls.js" "$TARGET/core/custom-urls.js"
cp "$ROOT/patches/pages/options/options-custom-urls.js" "$TARGET/pages/options/options-custom-urls.js"
cp "$ROOT/patches/pages/options/options-custom-urls.css" "$TARGET/pages/options/options-custom-urls.css"

# 2c) Inyectar la UI y las traducciones, y generar el índice de recursos.
python3 "$ROOT/tools/patch-build.py" "$TARGET"

# 3) Clave de firma opcional -> ID de extensión estable entre recargas.
if [[ -f "$ROOT/manifest/key.txt" ]]; then
  KEY="$(tr -d '\n' < "$ROOT/manifest/key.txt")"
  python3 - "$TARGET/manifest.json" "$KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    manifest = json.load(fh)
manifest["key"] = key
with open(path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
  echo "[i] Clave de firma inyectada (ID estable)"
else
  echo "[i] Sin manifest/key.txt -> ID derivado de la ruta (tools/make-key.sh para fijarlo)"
fi

# 4) Marca de origen para poder auditar de dónde salió el build.
cat > "$TARGET/BUILD-INFO.txt" <<EOF
Port Vivaldi generado por localcdn-vivaldi/tools/build.sh
Upstream: $(git -C "$UPSTREAM" rev-parse HEAD 2>/dev/null || echo desconocido)
Upstream version: $UPSTREAM_VERSION
Fecha: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# 5) Empaquetado.
if [[ "$MAKE_ZIP" == "1" ]] && command -v zip >/dev/null 2>&1; then
  ZIP="$DIST/localcdn-vivaldi-${UPSTREAM_VERSION}.zip"
  rm -f "$ZIP"
  (cd "$DIST" && zip -qr "$(basename "$ZIP")" localcdn-vivaldi)
  echo "[i] Empaquetado: $ZIP"
elif [[ "$MAKE_ZIP" == "1" ]]; then
  echo "[!] zip no instalado: se omite el empaquetado"
fi

echo "[ok] Listo: $TARGET"

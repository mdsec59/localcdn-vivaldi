#!/usr/bin/env python3
"""patch-build.py — Aplica las modificaciones del port sobre un árbol ya copiado del upstream.

Se ejecuta desde tools/build.sh. Hace, en orden:
  0. Aplica los parches literales de patches/substitutions.json (Fase 2: Google Fonts,
     Font Awesome y file guard en Chromium).
  1. Inyecta la pestaña "Custom URLs" en pages/options/options.html (botón + contenido + CSS/JS).
  2. Inyecta core/custom-urls.js en pages/background/background.html.
  3. Fusiona las traducciones de patches/locales/*.json en _locales/*/messages.json.
  4. Genera resources-index.json (raíz) con los recursos locales disponibles.

Falla con un mensaje claro si un ancla esperada no existe: eso indica que upstream cambió y el
port necesita revisarse.
"""

import json
import pathlib
import sys

INJECTIONS = {
    "options_css": (
        '<link rel="stylesheet" type="text/css" href="../base.css">',
        '<link rel="stylesheet" type="text/css" href="../base.css">\n'
        '        <link rel="stylesheet" type="text/css" href="options-custom-urls.css">',
    ),
    "options_js": (
        '<script src="options.js"></script>',
        '<script src="options.js"></script>\n'
        '        <script defer src="options-custom-urls.js"></script>',
    ),
    "options_tab_button": (
        '<input type="button" id="btn-info-tab" class="option-buttons" data-option-tab="info-tab" data-i18n-content="btnInfo" value="Info">',
        '<input type="button" id="btn-info-tab" class="option-buttons" data-option-tab="info-tab" data-i18n-content="btnInfo" value="Info">\n'
        '            <input type="button" id="btn-custom-urls-tab" class="option-buttons" data-option-tab="custom-urls-tab" data-i18n-content="customUrlsTab" value="Custom URLs">',
    ),
    "options_tab_content": (
        '<div class="notice notice-default hidden" id="notice-locale">',
        '<div id="custom-urls-tab" class="tab-content"></div>\n        '
        '<div class="notice notice-default hidden" id="notice-locale">',
    ),
    "background_js": (
        '<script src="../../core/main.js"></script>',
        '<script src="../../core/custom-urls.js"></script>\n'
        '        <script src="../../core/main.js"></script>',
    ),
}


def fail(message):
    print(f"[x] patch-build: {message}", file=sys.stderr)
    sys.exit(1)


def inject(path, anchor, replacement, label):
    if not path.exists():
        fail(f"no existe {path}")
    text = path.read_text(encoding="utf-8")
    if replacement.strip() in text and replacement.split("\n")[-1].strip() in text:
        print(f"[i] {label}: ya estaba inyectado")
        return
    if anchor not in text:
        fail(
            f"ancla no encontrada en {path} ({label}). Upstream cambió; revisa tools/patch-build.py"
        )
    if text.count(anchor) > 1:
        fail(f"ancla ambigua en {path} ({label}): aparece {text.count(anchor)} veces")
    path.write_text(text.replace(anchor, replacement, 1), encoding="utf-8")
    print(f"[i] {label}: inyectado")


def apply_substitutions(root, patches_dir):
    """Aplica sustituciones literales de texto sobre ficheros del upstream.

    Las cadenas exactas viven en patches/substitutions.json (antes/después). Si el texto
    original no aparece, se aborta: significa que upstream cambió y hay que revisar el port.
    """
    definitions = patches_dir / "substitutions.json"
    if not definitions.exists():
        fail(f"no existe {definitions}")
    items = json.loads(definitions.read_text(encoding="utf-8"))

    for item in items:
        target = root / item["file"]
        if not target.exists():
            fail(f"no existe {target}")
        text = target.read_text(encoding="utf-8")
        old, new = item["old"], item["new"]
        label = f"{item['file']} ({item.get('label', '')})"

        if new and new in text:
            print(f"[i] {label}: ya aplicado")
            continue
        if old not in text:
            fail(
                f"texto original no encontrado en {label}. Revisa patches/substitutions.json"
            )
        if text.count(old) != 1:
            fail(f"texto original ambiguo en {label}: {text.count(old)} coincidencias")
        target.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"[i] {label}: parche aplicado")


def merge_locales(root, patches_dir):
    for locale_file in sorted(patches_dir.glob("*.json")):
        locale = locale_file.stem
        target = root / "_locales" / locale / "messages.json"
        if not target.exists():
            fail(f"no existe el locale {target}")
        messages = json.loads(target.read_text(encoding="utf-8"))
        additions = json.loads(locale_file.read_text(encoding="utf-8"))
        added = [key for key in additions if key not in messages]
        messages.update(
            {key: value for key, value in additions.items() if key not in messages}
        )
        target.write_text(
            json.dumps(messages, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        print(
            f"[i] locale {locale}: {len(added)} claves añadidas ({len(messages)} en total)"
        )


def build_resource_index(root):
    resources = root / "resources"
    if not resources.is_dir():
        fail("no existe la carpeta resources/")
    paths = sorted(
        str(path.relative_to(root)).replace("\\", "/")
        for path in resources.rglob("*")
        if path.is_file()
    )
    # IMPORTANTE: se guarda en la RAÍZ de la extensión, fuera de resources/.
    # Cualquier petición a resources/* sin el secreto de fileGuard (ver
    # core/file-guard.js) es redirigida a la raíz, así que no se puede comprobar la
    # existencia de un recurso con un fetch() directo. El índice, al estar en la raíz,
    # sí es accesible desde el background y desde la página de opciones.
    index = root / "resources-index.json"
    index.write_text(
        json.dumps(paths, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    print(f"[i] índice de recursos: {len(paths)} ficheros -> {index.relative_to(root)}")


def main(argv):
    if len(argv) != 2:
        fail("uso: patch-build.py <directorio-del-build>")
    root = pathlib.Path(argv[1]).resolve()
    patches = pathlib.Path(__file__).resolve().parent.parent / "patches"
    if not patches.is_dir():
        fail(f"no existe {patches}")

    options_html = root / "pages" / "options" / "options.html"
    background_html = root / "pages" / "background" / "background.html"

    apply_substitutions(root, patches)

    inject(
        options_html,
        INJECTIONS["options_css"][0],
        INJECTIONS["options_css"][1],
        "options.html CSS",
    )
    inject(
        options_html,
        INJECTIONS["options_js"][0],
        INJECTIONS["options_js"][1],
        "options.html JS",
    )
    inject(
        options_html,
        INJECTIONS["options_tab_button"][0],
        INJECTIONS["options_tab_button"][1],
        "options.html pestaña",
    )
    inject(
        options_html,
        INJECTIONS["options_tab_content"][0],
        INJECTIONS["options_tab_content"][1],
        "options.html contenido",
    )
    inject(
        background_html,
        INJECTIONS["background_js"][0],
        INJECTIONS["background_js"][1],
        "background.html JS",
    )

    merge_locales(root, patches / "locales")
    build_resource_index(root)
    print("[ok] patch-build completado")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

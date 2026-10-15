# Cómo instalar y probar el port en tu Vivaldi

## Opción A — Cargar descomprimida (recomendada, sin firma)

1. Genera la extensión:

   ```bash
   cd ~/localcdn-vivaldi
   tools/fetch-upstream.sh      # solo la primera vez
   tools/build.sh               # crea dist/localcdn-vivaldi/
   ```

2. Abre Vivaldi y ve a `vivaldi://extensions`.
3. Activa **Modo de desarrollador** (arriba a la derecha).
4. Pulsa **Cargar descomprimida** y selecciona la carpeta `~/localcdn-vivaldi/dist/localcdn-vivaldi`.
5. Si aparece el aviso de Manifest V2 (ver `VIVALDI-NOTAS.md`), **activa la extensión** con su interruptor.
6. Opcional: en los detalles de la extensión, activa **Permitir en incógnito** si lo necesitas.

Tras cada `tools/build.sh` que cambie ficheros, pulsa **Recargar** en `vivaldi://extensions`.

## Opción B — Instalar como extensión empaquetada (.crx)

```bash
cd ~/localcdn-vivaldi
rm -rf dist/crx && mkdir -p dist/crx
shadow="/tmp/opencode/localcdn-crx"; rm -rf "$shadow"; mkdir -p "$shadow"
# Vivaldi/Chromium empaqueta y deja el .crx junto a la carpeta:
cp -a dist/localcdn-vivaldi "$shadow/localcdn-vivaldi"
/opt/vivaldi/vivaldi --pack-extension="$shadow/localcdn-vivaldi" --no-message-box
```

Se genera `localcdn-vivaldi.crx`. Para instalarlo, arrástralo a `vivaldi://extensions`.
Requiere `--pack-extension-key=clave.pem` si quieres conservar el mismo ID entre versiones (ver §5.2 del to-do).

## Verificar que funciona

### 1. Test oficial

Abre <https://www.localcdn.org/test/> y pulsa **Run the test**. Debe terminar en verde
(«…locally»), sin peticiones fallidas.

### 2. Test automatizado incluido

```bash
tools/smoke-test.sh    # ¿la carga Vivaldi? (perfil aislado, ~25 s)
tools/e2e-test.sh      # ¿intercepta CDNs de verdad? (~40 s)
```

`e2e-test.sh` abre una página de prueba, pide jQuery y Bootstrap a sus CDNs y comprueba que la URL
final es `chrome-extension://…/resources/…`, además de leer el contador `amountInjected`.

### 3. Comprobar a mano

En cualquier web que use jQuery (muchas), abre la consola de DevTools, pestaña **Red**, recarga y
busca la petición al CDN: la columna *Size/Initiator* mostrará origen `chrome-extension`. El icono
de la extensión en la barra mostrará un contador con los recursos servidos localmente.

## Notas

- Los scripts usan **perfiles temporales** (`--user-data-dir=/tmp/opencode/…`): no tocan tu perfil real
  ni tus extensiones.
- Rutas y perfiles de Vivaldi: `~/.config/vivaldi/Default` (perfil por defecto), `~/.config/vivaldi/Profile 1`, etc.
- Si `vivaldi` no está en el `PATH`, los scripts usan `/opt/vivaldi/vivaldi`. Puedes forzar el binario
  con `VIVALDI_BIN=/ruta/al/binario`.

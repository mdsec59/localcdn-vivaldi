# Análisis del upstream (LocalCDN 2.6.86)

Documento de referencia: qué hace el código original, cómo está organizado y **qué exactamente**
hay que tocar para que funcione en Vivaldi/Chromium.

## 1. Cómo funciona (resumen)

1. `core/state-manager.js` registra un listener **bloqueante** de `chrome.webRequest.onBeforeRequest`
   filtrando por los hosts de CDN que la extensión conoce (`stateManager.validHosts`).
2. `core/request-analyzer.js` decide si una petición es candidata válida y busca una copia local
   (`getLocalTarget`) usando las tablas de `core/mappings.js`.
3. `core/interceptor.js` devuelve `{ redirectUrl: chrome.runtime.getURL('resources/…') }`, o bien
   `cancel: true` para métodos no-GET, o una página de aviso de recurso bloqueado.
4. `core/resources.js` es el catálogo de recursos locales (un objeto por biblioteca/versión con
   `path`, `integrity`, etc.); `core/file-guard.js` valida integridad/hashes.
5. `core/mappings.js` mapea **host de CDN + patrón de ruta → recurso local**.
6. `core/request-sanitizer.js` limpia cabeceras (metadatos) mediante `onBeforeSendHeaders`.
7. `core/manipulate-dom.js` elimina atributos `integrity`/`crossorigin` del HTML en tránsito para
   evitar bloqueos por SRI (solo Firefox, usa `filterResponseData`).
8. `core/main.js`, `core/state-manager.js` gestionan iconos, badges, estadísticas y almacenamiento.

## 2. Dónde el código ya distingue Firefox de Chromium

La detección está en `core/constants.js`:

```js
const BrowserType = {
    'CHROMIUM': chrome.runtime.getURL('/').startsWith('chrome-extension'),
    'FIREFOX':  chrome.runtime.getURL('/').startsWith('moz-extension')
};
```

Ramas condicionales existentes (y su efecto en Chromium/Vivaldi):

| Archivo | Condición | Efecto en Chromium/Vivaldi |
|---|---|---|
| `core/manipulate-dom.js:31` | `!BrowserType.FIREFOX` | Desactiva la eliminación de `integrity`/`crossorigin` (Chromium no tiene `filterResponseData`). Se registra un aviso. |
| `core/request-analyzer.js:52` | `!BrowserType.FIREFOX` | Rechaza ciertos recursos vía `chromeSupport()` (p. ej. inyección de Font Awesome). |
| `core/mappings.js:1258` | `!BrowserType.FIREFOX` | **Elimina** los endpoints de Google Fonts del mapa (`fonts.gstatic.com`, `fonts.googleapis.com`). |
| `core/interceptor.js:93` | `BrowserType.FIREFOX && …` | El bloqueo de Google Fonts y el *placeholder* CSS solo se aplican en Firefox. |
| `core/request-sanitizer.js:30` | ternario | En Chromium añade `ExtraInfoSpec.EXTRA_HEADERS` (soportado en Chromium; **verificar en Vivaldi**). |

Conclusión: **upstream ya tiene el andamiaje para Chromium**, pero quedó sin mantenimiento y con
funcionalidad reducida (Google Fonts, Font Awesome, manipulación de HTML). El port debe decidir si
recupera esas funciones o las documenta como limitación.

## 3. Diferencias de manifest (upstream → este port)

| Clave | Upstream (Firefox) | Port Vivaldi |
|---|---|---|
| `browser_specific_settings` | `gecko` + `gecko_android` con `strict_min_version` y `data_collection_permissions` | **eliminada** (no aplica en Chromium) |
| `manifest_version` | 2 | 2 (ver `docs/VIVALDI-NOTAS.md`; MV3 es el plan B) |
| `background.page` | `pages/background/background.html` | igual (MV2 lo permite; en MV3 sería service worker) |
| `browser_action` | presente | igual (`_execute_browser_action` válido en MV2) |
| `permissions` | `*://*/*`, `privacy`, `storage`, `webNavigation`, `webRequest`, `webRequestBlocking` | igual |
| `web_accessible_resources` | `resources/*` | igual (en MV3 cambia a lista de objetos) |
| `content_security_policy` | cadena | igual (en MV3 cambia a objeto) |
| `key` | ausente | opcional: fija el ID de extensión (`tools/make-key.sh`) |

## 4. Catálogo de recursos

- `resources/` contiene **233 directorios** de bibliotecas con múltiples versiones (incluye también
  variantes `.jsm` y `.cssm`).
- `audit/audit.sh` verifica la integridad de los ficheros descargándolos (con Tor opcional) y puede
  repararlos con `-r`. Útil en la fase de mantenimiento.
- Los recursos se sirven como `web_accessible_resources`, condición necesaria para que la redirección
  `chrome-extension://` funcione en Chromium.

## 5. Claves de almacenamiento relevantes

`chrome.storage.local` (o `sync`, según `storageType`):

- `amountInjected` — contador acumulado de recursos servidos localmente (útil como aserción de pruebas).
- `internalStatistics` / `internalStatisticsData` — estadísticas internas (por dominio y rango de fechas).
- `allowlistedDomains`, `domainsManipulateDOM`, `allowedDomainsGoogleFonts`, `blockGoogleFonts`,
  `blockMissing`, `disablePrefetch`, `stripMetadata`, `showIconBadge`, `selectedIcon`, `enableLogging`…

Estas claves permiten escribir pruebas automatizadas fiables (ver `tools/e2e-test.sh`).

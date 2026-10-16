# Registro de decisiones (ADR)

## D-001 — Estrategia de port: MV2 primero, MV3 preparado
- **Fecha:** 15-oct-2026
- **Contexto:** upstream es MV2 y Firefox-only; Chromium retiró MV2 y Vivaldi lo mantiene
  «de momento» (8.1 avisa, 8.2 aún funciona).
- **Decisión:** portar manteniendo **MV2** (es la vía que da paridad funcional y funciona hoy en
  Vivaldi 8.2) y **planificar un plan B MV3 + declarativeNetRequest** como fase separada.
- **Consecuencias:** reutilizamos casi todo el código (`chrome.*`, ramas Chromium ya existentes);
  el trabajo de MV3 queda acotado a la Fase 6 y no bloquea el uso diario. Existe riesgo de que
  Vivaldi retire MV2 en cualquier versión futura.

## D-002 — No reescribir el motor de intercepción
- **Contexto:** el `webRequest` bloqueante es lo que permite redirigir la petición *antes* de que
  salga a la red (verificado: ningún host de CDN en el net-log).
- **Decisión:** mantener el motor del upstream y limitar el port a manifest, integración, pruebas y
  arreglos puntuales de las ramas Chromium.
- **Consecuencias:** menos divergencia con upstream ⇒ `fetch-upstream.sh` + `build.sh` siguen
  funcionando; los cambios propios se concentran en `manifest/` y `tools/`.

## D-003 — Distribución local, no tienda
- **Contexto:** no se puede publicar MV2 en la Chrome Web Store desde el 31-ago-2026 y LocalCDN no
  tiene tienda propia.
- **Decisión:** distribución mediante **carga descomprimida** (+ zip/crx opcional) y sin
  `update_url`; actualizaciones por script.
- **Consecuencias:** sin auto-actualización; hay que reconstruir y recargar a mano (documentado).

## D-004 — Base congelada y trazabilidad
- **Decisión:** cada build registra en `dist/localcdn-vivaldi/BUILD-INFO.txt` el commit upstream y
  la fecha; la versión de la extensión es la de upstream (`2.6.86` hoy).
- **Consecuencias:** si más adelante hacemos cambios propios que rompan compatibilidad, pasaremos a
  un versionado `2.6.86+vvN` (pendiente, §5.5 del to-do).

## D-005 — Pruebas automatizadas con CDP, sin dependencias
- **Contexto:** Vivaldi no soporta *headless* como Chrome, pero sí `--remote-debugging-port`.
- **Decisión:** usar un cliente CDP mínimo en Python (`tools/cdp.py`, solo stdlib) y perfiles
  temporales aislados, en lugar de Playwright/Puppeteer (que queda como mejora opcional).
- **Consecuencias:** pruebas reproducibles sin instalar nada; menos potencia que Playwright
  (sin aserciones de UI), suficiente para validar intercepción y almacenamiento.

## D-006 — Google Fonts y Font Awesome se recuperan en Chromium (Fase 2)
- **Fecha:** 16-oct-2026
- **Contexto:** upstream desactiva ambas en Chromium: borra los endpoints de Google Fonts en
  `mappings.js` cuando `!BrowserType.FIREFOX` (issue #1085) y rechaza Font Awesome en
  `requestAnalyzer.chromeSupport()`.
- **Decisión:** recuperar las dos en el port. Google Fonts vuelve a los mapeos y el bloqueo
  funciona con su *placeholder* CSS local; se quita el rechazo de Font Awesome en Chromium.
- **Hallazgo importante:** el fallo real de Font Awesome **no** era `chromeSupport()` sino
  `fileGuard`, que redirigía las URLs relativas del CSS (sin firma). Arreglo: `fileGuard.signed()`,
  comparación por valor y permiso de subrecursos por `requestDetails.type`
  (`font`/`image`/`media`) además de por `initiator`.
- **Consecuencias:** la motivación que quedó documentada antes (WAR/CORS) era **incorrecta**; se
  corrige. `tools/e2e-parity.sh` lo verifica.

## D-007 — SRI + sustitución de versión: limitación heredada de Chromium (4.4)
- **Contexto:** los sitios usan `integrity="sha…" crossorigin`. Firefox borra esos atributos con
  `webRequest.filterResponseData`, que **Chromium no implementa** (crbug 487422); no hay API
  equivalente y DNR sólo toca cabeceras.
- **Decisión:** **no** reescribir el motor para intentarlo; documentar la limitación
  (`docs/LIMITACIONES.md` §1). Se comprueba que CORS y SRI **sí** funcionan con recursos de
  extensión (caso C de `tools/e2e-sri.sh`): lo único que se rompe es el hash, y sólo **porque la
  versión servida no es la pedida** (2.1.4 → 2.2.4).
- **Consecuencias:** el test oficial de jQuery seguirá marcando «LocalCDN is not working as
  intended» en Chromium mientras exista la sustitución de versiones. Queda como opción de futuro
  «no sustituir versiones» (perdería cobertura). El prototipo MV3 la evita por construcción
  (D-008).

## D-008 — Plan B: reglas estáticas DNR, con `urlFilter` y sin sustitución de versión (Fase 6)
- **Fecha:** 16-oct-2026
- **Contexto:** límites reales medidos en el Chromium de Vivaldi: **330.000** reglas estáticas
  totales, **50** rulesets activos, **5.000** reglas dinámicas/de sesión y **1.000** regex.
- **Decisión:** el plan B se apoya en reglas **estáticas** con `urlFilter` (nunca `regexFilter`:
  el cupo regex es de 1.000), generadas por `tools/gen-dnr.mjs` y empaquetadas en rulesets
  equilibrados por familia de CDN. Se genera siempre una regla por versión **existente en disco**:
  el prototipo **no** sustituye versiones.
- **Consecuencias:** el espacio completo (83.960 reglas en 14 rulesets) cabe con ~75 % de margen y
  la matriz de recursos da **paridad 22/22**. Se pierde cobertura cuando piden una versión no
  distribuida (p. ej. `angularjs/1.8.3`, que MV2 sustituía por 1.8.2), a cambio de no romper nunca
  el SRI. El trabajo pendiente es la migración del motor a *service worker* (6.3).
  Detalle en `docs/PLAN-MV3.md`.

## D-009 — URLs personalizadas como función propia, aparte de `mappings.js`
- **Fecha:** 16-oct-2026
- **Contexto:** el catálogo de upstream es cerrado; tocar `mappings.js` se pierde en cada
  actualización.
- **Decisión:** implementar las reglas «URL de CDN → recurso local» como parche propio
  (`patches/core/custom-urls.js`), persistidas en `chrome.storage.local`, con validación del
  destino y aplicadas a través de `fileGuard.signed()`.
- **Consecuencias:** no diverge del dato de upstream; en MV3 se mapean de forma natural a reglas
  **dinámicas**. Detalle en `docs/URLS-PERSONALIZADAS.md`.

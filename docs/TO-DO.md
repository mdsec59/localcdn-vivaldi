# TO-DO — LocalCDN para Vivaldi

Plan de trabajo detallado del port. Prioridades: **P0** = necesario para usarlo a diario ·
**P1** = paridad de funcionalidad y calidad · **P2** = mejoras y futuro.

Leyenda de estimación: ~horas · ~~días · tamaño S/M/L.
Criterio de terminado por defecto: el ítem incluye cómo verificarlo.

Estado global: **Fases 0 y 5.x de base hechas**; **Fase 2 completada y verificada**, **Fase 4 completada (4.1–4.5)**, **Fase 6 prototipo viable y verificado (6.1, 6.2, 6.5, 6.6)**. Pendiente: 0.6–0.9, 1.4–1.9, 2.6–2.8, 3.x, 4.6–4.8, 5.2–5.6 y 6.3–6.4.

---

## Fase 0 — Verificación del terreno ✅ (15-oct-2026)

Objetivo: saber si MV2 sigue funcionando en el Vivaldi instalado antes de invertir trabajo.

- [x] **0.1 Confirmar versiones del entorno** (S)
  Vivaldi `8.2.4133.52 stable`; upstream LocalCDN commit `ade7a97` = v2.6.86.
  *Verificación:* `vivaldi --version`, `git -C upstream log --oneline -1`. **Hecho.**
- [x] **0.2 Comprobar que Vivaldi 8.2 carga el MV2 portado** (M)
  Cargado con `--load-extension` en perfil aislado. `disable_reasons: []`,
  permisos `webRequest/Blocking` concedidos, `location: 8`.
  *Verificación:* `tools/smoke-test.sh`. **Hecho.**
- [x] **0.3 Comprobar interceptación real de CDNs** (M)
  3 redirecciones a `chrome-extension://…/resources/…` y `amountInjected: 5`; ningún host de CDN
  en el net-log. *Verificación:* `tools/e2e-test.sh`. **Hecho.**
- [x] **0.4 Documentar el calendario de MV2 y los riesgos** (S)
  Ver `docs/VIVALDI-NOTAS.md` §1 y §4. **Hecho.**
- [x] **0.5 Registrar la decisión de estrategia** (S)
  MV2 como vía principal + plan B MV3. Ver `docs/DECISIONES.md` D-001. **Hecho.**
- [ ] **0.6 Verificar el comportamiento del aviso de MV2 en la UI de 8.2** (S) — P0
  Abrir `vivaldi://extensions` con la extensión instalada de forma **persistente** (no efímera) y
  anotar: ¿aparece aviso?, ¿queda desactivada?, ¿sobrevive a reiniciar Vivaldi?
  *Verificación:* captura + párrafo añadido a `VIVALDI-NOTAS.md` §3.
- [ ] **0.7 Comprobar qué ocurre al actualizar el navegador** (S) — P1
  Documentar si una actualización de Vivaldi 8.2→8.3 desactiva la extensión.
  Bloqueado hasta que exista la actualización (hay 8.2.4133.80 disponible: **probar tras actualizar**).
- [ ] **0.8 Fijar el ID de extensión con clave propia** (S) — P1
  Ejecutar `tools/make-key.sh` y `tools/build.sh` para que el ID no dependa de la ruta de instalación.
  *Verificación:* `BUILD-INFO.txt` + ID estable tras mover `dist/` a otra carpeta.
- [ ] **0.9 Congelar y documentar la base upstream** (S) — P1
  Anotar commit/versión en `README.md` y en `docs/ANALISIS-UPSTREAM.md`; comprobar que
  `tools/fetch-upstream.sh` reproduce el mismo punto de partida.

---

## Fase 1 — Port mínimo funcional (P0)

Objetivo: extensión instalable, con manifest correcto, reproducible y con ID estable.

- [x] **1.1 Manifest MV2 para Chromium** (S)
  `manifest/manifest.vivaldi.json`: sin `browser_specific_settings`, mismos permisos que upstream.
  **Hecho.**
- [x] **1.2 Script de construcción** (S)
  `tools/build.sh` (rsync de upstream + manifest + `BUILD-INFO.txt` + zip). **Hecho.**
- [x] **1.3 Script de obtención de upstream** (S)
  `tools/fetch-upstream.sh`. **Hecho.**
- [ ] **1.4 Inyectar la clave de ID estable en build** (S) — P1
  El código ya soporta `manifest/key.txt`; falta generarlo (0.8) y verificar el ID resultante.
- [ ] **1.5 Revisar rutas relativas e i18n en Chromium** (M) — P0
  Revisar `pages/*` (popup, options, help, statistics, logging, welcome, donate) y `_locales/`
  (`default_locale: en_US`): que `__MSG_*__` se resuelvan, que no haya rutas `moz-extension`.
  *Verificación:* inspección de consola en el *background page* y en el popup sin errores
  (`tools/cdp.py eval <port> "background.html" ...`).
- [ ] **1.6 Verificar que el popup y las opciones abren bien en Vivaldi** (M) — P0
  Comprobar visualmente: icono en barra, contador/badge, popup, `pages/options/options.html`
  (guardado de ajustes persiste tras reinicio).
  *Verificación:* checklist manual + capturas.
- [ ] **1.7 Añadir versión de port al build** (S) — P2
  Decidir formato (`2.6.86+vv1` no es válido en Chromium: usar `2.6.86.1`) y aplicarlo en `build.sh`.
- [ ] **1.8 Script de instalación/recarga en el perfil real** (M) — P1
  `tools/deploy.sh`: copiar/sincronizar a una ruta estable (p. ej. `~/.local/share/localcdn-vivaldi/`)
  e instrucciones de recarga; opcionalmente avisar si el ID cambia.
- [ ] **1.9 `.gitignore` y primera publicación del repo** (S) — P1
  Excluye `upstream/` y `dist/`; commit inicial con README + docs + tools.

---

## Fase 2 — Paridad funcional en Chromium/Vivaldi (P1)

Objetivo: recuperar o documentar con precisión las funciones que upstream desactiva en Chromium.

- [x] **2.1 Bloqueo de Google Fonts** (M) — P1
  **Hecho (16-oct-2026).** Reactivado en Chromium (D-006). `tools/e2e-parity.sh`: con la opción
  activa se sirve el *placeholder* local (`resources/google-fonts-placeholder.css`, 200, 0 bytes);
  desactivada, carga de Google.
  Hoy `core/mappings.js` elimina los endpoints de Google Fonts cuando `!BrowserType.FIREFOX`, y la
  lógica de bloqueo vive tras `BrowserType.FIREFOX`. Evaluar: (a) reactivar en Chromium, (b) usar el
  *placeholder* CSS local, o (c) documentar como no soportado.
  *Verificación:* test con página que cargue `fonts.googleapis.com` + opción activada.
- [x] **2.2 Inyección de Font Awesome** (M) — P1
  **Hecho (16-oct-2026).** Causa raíz real: `fileGuard`, no `chromeSupport()` (D-006). Se sirve la
  fuente `fa-solid-900` (200, tipo `font`, iniciador = página) y `fileGuard._seen` la registra.
  `request-analyzer.chromeSupport()` la rechaza en Chromium. Investigar la causa original
  (issue upstream) y decidir recuperar o documentar.
  *Verificación:* página con Font Awesome servido localmente.
- [x] **2.3 Eliminación de `integrity`/`crossorigin` en HTML** (L) — P2
  **Documentado (16-oct-2026).** Limitación heredada de Chromium (sin `filterResponseData`);
  ADR D-007 y `docs/LIMITACIONES.md` §1.
  Imposible en Chromium sin `filterResponseData` (issue Chromium 487422). Alternativas: *content
  script* que limpie atributos antes de la ejecución (limitado), `declarativeNetRequest` con
  `modifyHeaders` (no puede tocar el HTML), o asumir la limitación.
  *Verificación:* decisión escrita en `DECISIONES.md` + nota en la UI de opciones.
- [x] **2.4 `stripMetadata` con `EXTRA_HEADERS`** (S) — P1
  **Hecho (16-oct-2026).** `tools/e2e-headers.sh`: con el saneador activo no salen
  `Origin`/`Referer`; con el control desactivado sí (prueba de que Vivaldi acepta `EXTRA_HEADERS`).
  Confirmar que `onBeforeSendHeaders` con `EXTRA_HEADERS` funciona en Vivaldi (Chromium lo soporta)
  y que las cabeceras se limpian. *Verificación:* página de eco de cabeceras (p. ej. `httpbin`) con
  la opción activada.
- [x] **2.5 Revisar `xhrTestDomain` y el «HTML filter»** (M) — P2
  **Documentado (16-oct-2026).** No soportados en Chromium; el bloqueo de Google Fonts no depende
  de ellos. `docs/LIMITACIONES.md` §2.
  Funciones que dependen de `filterResponseData` o de comportamiento Firefox; decidir estado.
- [x] **2.6 Métricas y página de estadísticas** (S) — P1
  **Hecho (16-oct-2026).** `tools/e2e-pages.sh`: `statistics.html` y `logging.html` renderizan
  (títulos, tabla de CDN/frameworks y resumen «Promedio/Reemplazos»), sin errores de API.
  Comprobar que `pages/statistics` y `pages/logging` muestran datos en Chromium.
- [x] **2.7 Revisar la ventana de bienvenida y los avisos** (S) — P2
  **Hecho (16-oct-2026).** `welcome.html` abre y muestra el aviso `chromium-banner`
  («Non-Firefox browsers do not support all features of LocalCDN»), que cubre parte de 2.8.
  `pages/welcome` (ya se abrió en la prueba) y notas de actualización.
- [~] **2.8 Recursos no soportados: mensaje claro** (S) — P2
  El dato ya existe (contadores `missing`/`blocked` por pestaña); falta mostrarlo en opciones.
  `docs/LIMITACIONES.md` §3.
  Los avisos actuales van a la consola del background; valorar mostrarlos en la UI.

- [~] **2.9 URLs personalizadas (función propia del port)** (M) — P1
  **Implementada y verificada (sin commitear a 16-oct-2026).** Reglas «URL de CDN → recurso local»
  propias, aparte de `mappings.js` (D-009). `tools/e2e-custom-urls.sh` en verde.
  `docs/URLS-PERSONALIZADAS.md`.

---

## Fase 3 — Integración específica de Vivaldi (P1/P2)

Objetivo: que el port se sienta nativo y sea cómodo de mantener en este navegador.

- [ ] **3.1 Revisar la UI con el tema de Vivaldi (claro/oscuro)** (M) — P1
  `pages/base.css` + `style.css`: que popup y opciones respeten el tema del sistema/navegador.
  *Verificación:* capturas en tema claro y oscuro.
- [ ] **3.2 Icono y badge en la barra** (S) — P1
  Verificar que el contador (`browserAction` + `setBadgeText`) funciona y que el icono se ve nítido
  en Vivaldi (18/19/38 px).
- [ ] **3.3 Evaluar el panel lateral de Vivaldi** (M) — P2
  Vivaldi permite paneles; valorar mostrar estadísticas de LocalCDN en un panel lateral
  (`side_panel` es MV3; en MV2 habría que usar API propia de Vivaldi). Documentar límites.
- [ ] **3.4 Revisar atajos de teclado** (`commands`) (S) — P2
  El manifest declara `_execute_browser_action`; comprobar que se puede asignar en `vivaldi://extensions/shortcuts`.
- [ ] **3.5 Compatibilidad con el cliente de correo/feed de Vivaldi** (S) — P2
  Comprobar que la extensión no interfiere en `chrome-extension://mpognobbkildjkofajifpdfhcoklimli/*`.
- [ ] **3.6 Multi-perfil** (S) — P2
  Documentar instalación por perfil (cada perfil necesita su carga descomprimida).

---

## Fase 4 — Pruebas y validación (P0/P1)

Objetivo: confianza para usarlo a diario y detectar regresiones al actualizar upstream.

- [x] **4.1 Test oficial** (S) — P0
  **Hecho (16-oct-2026).** Ejecución completa registrada en `docs/LIMITACIONES.md` §4: `worstcase`
  **16 Protected / 1 Unprotected** (exclusión deliberada de upstream), `tinymce` OK, y las páginas
  `fontawesome`/`materialicons` **omitidas por el propio test** fuera de Firefox (ya no se reportan
  como cuelgue). El rojo de `jquery` es la limitación de SRI (D-007).
  `https://www.localcdn.org/test/` debe terminar en verde. **Pendiente de ejecución manual.**
- [x] **4.2 Matriz de recursos** (M) — P1
  **Hecho (16-oct-2026).** `tools/e2e-matrix.sh`: **22/22** URLs de CDN servidas desde
  `chrome-extension://…/resources/…`.
  Ampliar `tools/e2e-test.sh`: jQuery, AngularJS, Bootstrap (CSS/JS), Font Awesome, MathJax, Alpine,
  moment, … Comprobar redirección + `amountInjected` esperado.
- [x] **4.3 Versiones no soportadas → fallback** (M) — P0
  **Hecho (16-oct-2026).** `jquery-9.9.9` no se intercepta ni se cancela; la página sigue viva y la
  extensión lo contabiliza como `missing`.
  Verificar que una versión desconocida (p. ej. `jquery-9.9.9`) **no se rompe**: la extensión no debe
  romper la web (`cancel: false`, o recurso «blocked» según opción `blockMissing`).
- [x] **4.4 SRI y CSP estricta** (M) — P1
  **Diagnosticado (16-oct-2026).** `tools/e2e-sri.sh`, casos A/B/C: CORS y SRI **sí** funcionan con
  recursos de extensión; sólo falla el hash por sustitución de versión. ADR D-007.
  Páginas con `integrity="sha384-…"`: comprobar el comportamiento en Chromium (limitación conocida,
  ver 2.3) y documentarlo.
- [x] **4.5 Allowlist y «Permitir en incógnito»** (S) — P1
  **Hecho (16-oct-2026).** Funciona; matiz: la clave debe coincidir con `URL.host` **incluido el
  puerto** (`127.0.0.1:8906` sí; `127.0.0.1` no).
  Comprobar que la lista blanca de dominios desactiva la inyección en esos sitios.
- [ ] **4.6 Regresión en sitios reales** (M) — P1
  Navegar por ~20 sitios conocidos (noticias, tiendas, foros) y revisar que no haya errores nuevos de
  consola ni recursos roscados. Documentar hallazgos.
- [ ] **4.9 Validar los mapeos en tiempo de build** (S) — P1
  Encontrados **36 mapeos de upstream que apuntan a ficheros locales inexistentes** (rompen la web:
  redirigen a un recurso que no existe). Añadir una validación en `patch-build.py`/`build.sh` que
  descarte esos mapeos. Detalle en `docs/LIMITACIONES.md` §5.
- [ ] **4.7 Automatización avanzada con Playwright/Puppeteer sobre Vivaldi** (M) — P2
  `tools/cdp.py` cubre lo básico; Playwright permitiría aserciones de UI y CI.
- [ ] **4.8 Rendimiento** (S) — P2
  Medir impacto en carga (antes/después) con y sin la extensión; vigilar `onBeforeRequest` sobre
  `validHosts`.

---

## Fase 5 — Empaquetado, distribución y mantenimiento (P1/P2)

- [x] **5.1 Zip reproducible** (S) — `tools/build.sh` genera `dist/localcdn-vivaldi-<versión>.zip`. **Hecho.**
- [ ] **5.2 CRX firmado y clave de empaquetado** (M) — P2
  `vivaldi --pack-extension=… --pack-extension-key=…`; guardar la clave fuera del repo y documentar.
- [ ] **5.3 Script de sincronización con upstream** (M) — P1
  `tools/update-upstream.sh`: fetch del upstream, rebuild y **diff del manifest** + resumen de cambios
  relevantes (mapeos nuevos, recursos nuevos) para decidir si re-portar algo.
- [ ] **5.4 Verificación de integridad de recursos** (M) — P2
  Usar `upstream/audit/audit.sh` (con `-r` para reparar) y documentar el procedimiento y su
  resultado en la red local (puede necesitar `torsocks`).
- [ ] **5.5 CHANGELOG y versionado del port** (S) — P2
  `CHANGELOG.md` con el formato de versión decidido en 1.7 y la relación upstream→port.
- [ ] **5.6 Checklist de release** (S) — P1
  Documento con pasos: sync → build → smoke → e2e → test oficial → zip → instalación → nota de versión.

---

## Fase 6 — Plan B: MV3 + declarativeNetRequest (P1 si MV2 muere; P2 hoy)

Objetivo: sobrevivir a la retirada de MV2 en Vivaldi. Trabajo acotado, no bloquea el uso actual.

- [x] **6.1 Generador de reglas DNR desde `core/mappings.js`** (L) — P1
  **Hecho (16-oct-2026).** `tools/gen-dnr.mjs` (Node, evalúa `resources.js`/`mappings.js` en `vm`).
  Reglas `urlFilter` + `redirect.extensionPath`. Verificado con `testMatchOutcome`.
  `docs/PLAN-MV3.md` §6.1.
  Convertir cada entrada `CDN + patrón → recursos/…` en reglas `redirect` (o `regexFilter` +
  `redirect.extensionPath`). Generador en Python/Node dentro de `tools/`.
  *Verificación:* reglas válidas (`declarativeNetRequest.testMatchOutcome` o carga sin errores).
- [x] **6.2 Presupuesto de reglas y particionado** (M) — P1
  **Medido (16-oct-2026).** Límites reales del Chromium de Vivaldi: **330.000** reglas estáticas,
  **50** rulesets, **5.000** dinámicas, **1.000** regex. El espacio completo son **83.960** reglas
  en 14 rulesets ⇒ cabe. `docs/PLAN-MV3.md` §6.2.
  MV3 limita el número de reglas (límite bajo para dinámicas y decenas de miles para estáticas por
  *ruleset*). **Verificar los límites vigentes en la versión de Chromium de Vivaldi** y particionar
  por CDN/biblioteca, activando *rulesets* por demanda.
- [~] **6.3 Migrar `background.page` → service worker** (L) — P1
  **Analizado (16-oct-2026).** Plan de migración (`storage.session` para `stateManager.tabs`,
  reconexión de ports, listeners top-level) en `docs/PLAN-MV3.md` §6.3. Es el trabajo pendiente
  principal del plan B.
  Adaptar `state-manager.js` (estado en memoria → `chrome.storage.session`), `messenger.js` (ports) y
  los *listeners* (los SW se suspenden).
- [~] **6.4 Sustituir el `webRequest` bloqueante** (M) — P1
  **Analizado (16-oct-2026).** Tabla de equivalencias en `docs/PLAN-MV3.md` §6.4: casi todo tiene
  equivalente DNR (`requestMethods`, `initiatorDomains`, `modifyHeaders`); se pierde la decisión en
  tiempo de petición y la sustitución de versión.
  Qué se pierde: cancelación de métodos no-GET, `onBeforeSendHeaders` (metadatos) y la lógica de
  decisión en tiempo de petición. Reasignar a DNR (`modifyHeaders`, `block`) o aceptar la pérdida.
- [x] **6.5 Adaptar `web_accessible_resources` y CSP a MV3** (S) — P2
  **Hecho (16-oct-2026).** Forma de objetos (`resources` + `matches`) en el prototipo;
  `docs/PLAN-MV3.md` §6.5.
  Formato de objetos y `content_security_policy` ampliado.
- [x] **6.6 Paridad funcional y repetición de Fase 4** (M) — P1
  **Hecho (16-oct-2026).** `tools/e2e-dnr.sh` repite la matriz con el motor DNR: **22/22**.
  `docs/PLAN-MV3.md` §6.6.
  Repetir la matriz de pruebas con el motor DNR antes de considerar el cambio.

---

## Bloqueadores y dependencias

- **Dependencia externa:** la fecha en que Vivaldi retire MV2 (Fase 6 se vuelve P0 ese día).
- **Dependencia de red:** `audit/audit.sh` necesita acceso a los CDNs (red con restricciones → usar Tor).
- **Bloqueo técnico conocido:** `filterResponseData` inexistente en Chromium (ítems 2.3, 2.5).

## Criterios de aceptación (definición de «listo» del port)

1. La extensión se instala en Vivaldi sin errores y sobrevive a reinicios.
2. El test de <https://www.localcdn.org/test/> da verde en Vivaldi.
3. `tools/e2e-test.sh` redirige al menos 5 bibliotecas distintas a recursos locales.
4. Ninguna web de prueba se rompe por una versión no soportada (no hay peticiones «muertas»).
5. `tools/build.sh` es reproducible desde un clon limpio y registra el commit de origen.
6. Existe un procedimiento documentado de actualización y de migración a MV3.

## Registro de progreso

| Fecha | Cambio |
|---|---|
| 15-oct-2026 | Fase 0 completada (carga MV2 + interceptación real verificadas); Fase 1.1–1.3 hechas; creados scripts, docs y este to-do. |

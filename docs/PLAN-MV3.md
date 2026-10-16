# Plan B: MV3 + `declarativeNetRequest` (Fase 6)

Este documento responde a los ítems 6.1–6.6 de `TO-DO.md` con **mediciones reales** sobre el
Vivaldi del usuario (Chromium 152, 16-oct-2026). No describe un port terminado: es el
estudio de viabilidad con un prototipo funcional y el detalle de lo que se gana y se pierde.

Artefactos:

| Qué | Dónde |
|---|---|
| Generador de reglas | `tools/gen-dnr.mjs` |
| Constructor del prototipo | `tools/build-mv3.sh` |
| Prueba automática | `tools/e2e-dnr.sh` |
| Prototipo (6 CDN) | `dist/localcdn-vivaldi-mv3/` |
| Prototipo (espacio completo) | `dist/localcdn-vivaldi-mv3-full/` |
| Service worker de diagnóstico | `mv3/sw.js`, `mv3/limits.html`, `mv3/limits.js` |
| Reglas generadas (14 rulesets) | `mv3/rules/…` + `mv3/rules/index.json` |

---

## 6.1 Generador de reglas DNR

`tools/gen-dnr.mjs` (Node) evalúa `core/resources.js` y `core/mappings.js` en un contexto `vm`
del propio Node. **No** se reescribe ni se parchea el dato de upstream: se lee tal cual, con
`BrowserType.FIREFOX = true` para conservar los endpoints de Google Fonts (igual que hace el port
en Chromium).

Traducción de la lógica de intercepción a reglas **estáticas**:

* **Recursos «de fichero»** (plantilla con nombre, p. ej. `resources/jquery/{version}/jquery.min.jsm`):
  una regla por cada *versión que existe en disco*. Si el patrón del CDN acaba en `/` (caso Font
  Awesome `font-awesome/{version}/css/`) se le añade el nombre del fichero; de lo contrario la
  regla redirigiría *toda* la carpeta a un solo fichero (defecto detectado y corregido durante el
  desarrollo).
* **Recursos «de directorio» / bundles** (plantilla acabada en `/`, p. ej. `resources/select2/{version}/`):
  MV2 usa sólo el **nombre** del fichero pedido y lo coloca en el directorio del recurso, sin
  reflejar los subdirectorios del CDN. Por eso el generador invierte el proceso: enumera los
  ficheros locales, reconstruye el nombre de CDN equivalente (`.jsm`→`.js`, `.min.jsm`→`.min.js` y
  `.js` para bundles sin comprimir, `.min.css`/`.css`) y emite la URL. Cuando el patrón es un
  «directorio pelado» (`.../{version}/`) se inserta un comodín `*` porque la URL real puede llevar
  subdirectorios intermedios (p. ej. `select2/4.1.0/js/select2.min.js`).

Decisiones de forma de la regla:

* Se usa **`urlFilter`**, no `regexFilter`: el cupo de reglas regex es de **1.000** (medido, §6.2)
  y aquí hacen falta decenas de miles.
* **Dos reglas por URL** (`|https://…` y `|http://…`) con ancla `|` para que el host coincida
  **exactamente**. El ancla `||` casaría también subdominios, cosa que el motor MV2 no hace.
* `resourceTypes` cubre lo que puede transportar una biblioteca o sus subrecursos: `script`,
  `stylesheet`, `image`, `font`, `media`, `xmlhttprequest`, `other`, `object`, `ping`,
  `csp_report`, `websocket`.

**Verificación (hecha).** El prototipo carga los 14 rulesets sin errores y
`declarativeNetRequest.testMatchOutcome` confirma coincidencias exactas
(`tools/e2e-dnr.sh`, artefacto `limites.json`):

```
OK  https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js          [ruleset-01]
OK  https://cdnjs.cloudflare.com/ajax/libs/select2/4.1.0/js/select2.min.js    [ruleset-01]
OK  https://cdn.jsdelivr.net/npm/moment@2.30.1/moment.min.js                  [ruleset-09]
OK  https://code.jquery.com/jquery-3.7.1.min.js                               [ruleset-14]
OK  https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/js/bootstrap.min.js       [ruleset-14]
NO  https://cdnjs.cloudflare.com/ajax/libs/nonexistent/9.9.9/nonexistent.min.js
```

La última línea también es un resultado correcto: una versión inexistente **no** coincide, así que
la petición sigue su curso y la web no se rompe (equivalente al `cancel: false` de MV2).

`NO https://ajax.googleapis.com/…/angularjs/1.8.3/angular.min.js` ilustra la única diferencia
funcional de fondo (ver §Diferencias): en disco sólo hay `angular.js/1.8.2`; MV2 sustituye
`1.8.3 → 1.8.2` en tiempo de petición, las reglas estáticas no.

---

## 6.2 Presupuesto de reglas, límites reales y particionado

Límites **medidos** en el Chromium de Vivaldi (vía `chrome.declarativeNetRequest`, véase
`mv3/sw.js` y `limites.json`):

| Constante | Valor medido | Cómo afecta |
|---|---|---|
| Cupo total de reglas estáticas | **330.000** (derivado: `availableStaticRuleCount` 246.040 + 83.960 cargadas) | el espacio completo cabe de sobra |
| `MAX_NUMBER_OF_ENABLED_STATIC_RULESETS` | **50** | los 67 hosts se empaquetan en 14 rulesets |
| `MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES` | **5.000** | insuficiente para el mapeo completo; sólo para reglas «a demanda» |
| `MAX_NUMBER_OF_REGEX_RULES` | **1.000** | descarta la conversión basada en `regexFilter`/`regexSubstitution` |
| `GETMATCHEDRULES_QUOTA_INTERVAL` | **10** | cuota de depuración (`getMatchedRules`), irrelevante en producción |

`MAX_NUMBER_OF_STATIC_RULES` no está expuesto como constante en esta versión; se deduce del cupo
disponible.

Presupuesto del mapeo real (`resources/` = 2.011 ficheros, 293 recursos de fichero + 20 de
directorio, 67 hosts):

| Conjunto | Reglas | Rulesets | Reglas máx./ruleset |
|---|---|---|---|
| **Espacio completo** | **83.960** | 14 | 7.216 |
| Sólo los 6 CDN de la matriz de pruebas | 12.606 | 3 | 7.216 |

**Conclusión de 6.2:** el espacio completo de mapeos de LocalCDN **cabe** hoy en reglas estáticas
(83.960 de 330.000, ~25 %) y en 14 de 50 rulesets con el reparto equilibrado por familias de CDN
que hace `empaquetar()`. No hace falta particionar ni activar por demanda *por presupuesto*; el
prototipo carga los 14 rulesets de golpe. El particionado se conserva igualmente porque:

* permite activar/desactivar familias completas por demanda (y en el futuro por opción de usuario);
* deja el margen suficiente para que un ruleset crezca sin acercarse a ningún techo.

Dos advertencias medidas:

* **Un mismo mapeo se repite en muchos CDN espejo.** `highlight.js` solo aporta **25.704 reglas**
  (536 ficheros × espejos × http/https) y `bootstrap-datepicker`, `select2`, `angular.js` y
  `twitter-bootstrap` suman otras ~24.000. Si el cupo bajara, la primera palanca es reducir la
  lista de hosts espejo (los mapeos son idénticos: `mappings.cdn['cdn.bootcdn.net'] =
  mappings.cdn['cdnjs.cloudflare.com']`).
* El tope por *ruleset* no se ha podido verificar por encima de 7.216 reglas; Chrome documenta
  30.000 por ruleset, y el reparto nunca se acerca a ese número.

---

## 6.3 `background.page` → service worker

Qué se rompe al pasar de página de fondo persistente a *service worker* (MV3 lo suspende):

* **Estado en memoria.** El port mantiene `stateManager.tabs` (inyecciones, `missing`, `blocked`
  por pestaña) como objeto vivo en `core/state-manager.js`. Un SW se suspende a los ~30 s de
  inactividad y **pierde** ese objeto.
  *Migración:* mover el estado por pestaña a `chrome.storage.session` (MV3, no persiste al
  reiniciar el navegador, que es el comportamiento deseado) y reconstruir lo necesario en
  `chrome.runtime.onStartup`/`onInstalled`. Las **estadísticas agregadas** ya van a
  `chrome.storage.local`, así que sobreviven.
* **`messenger.js` con `Port` largos.** Los `chrome.runtime.connect` de la UI (options,
  statistics, logging) pueden cortarse cuando el SW se suspende.
  *Migración:* sustituir los ports de larga vida por `sendMessage` bajo demanda, o volver a
  conectarlos desde la UI al reabrir (patrón «reconectar si el port se cierra»).
* **Listeners registrados al cargar.** `webRequest`, `webNavigation` y el menú de contexto deben
  registrarse en el ámbito *top-level* del SW (lo son); los listeners registrados dentro de
  llamadas asíncronas no se conservan entre suspensiones.
* **Icono y `browserAction`** se convierten en `action`; el *badge* con la cuenta de inyecciones se
  recalcula al despertar el SW.

Ninguna de estas piezas es infranqueable, pero es la parte que más trabajo tiene: el equivalente
MV3 del motor necesita **reconstruir su estado** al despertar y **no** puede mantener la decisión
«en caliente» que hoy toma `interceptor.js` petición a petición.

---

## 6.4 Sustituir el `webRequest` bloqueante

Qué hacía MV2 y cómo queda:

| Función de MV2 | ¿Se puede con DNR? | Cómo |
|---|---|---|
| Redirigir una URL de CDN a `resources/…` | **Sí** | `action.type: redirect` + `urlFilter` (§6.1) |
| Decidir en tiempo de petición (versión, bundle, iniciador) | **No** | las reglas son estáticas; se precalcula todo en el generador |
| Cancelar peticiones de métodos no-GET | **Sí** | `condition.requestMethods` / `excludedRequestMethods` |
| Redirigir a la página «blocked» | **Sí** | `redirect` a `resources/blocked/index.html` |
| Bloquear / permitir por dominio (lista blanca) | **Sí** | `condition.initiatorDomains` + `excludedInitiatorDomains` en reglas dinámicas |
| **Borrar cabeceras** (`Origin`, `Referer`, `Cookie`) — *stripMetadata* | **Sí** | `action.type: modifyHeaders` con `operation: remove` (ya verificado que Vivaldi soporta `EXTRA_HEADERS` en 2.4) |
| Contar inyecciones/missing/blocked por pestaña | **No** (sólo) | `declarativeNetRequest.getMatchedRules()` con cuota (`GETMATCHEDRULES_QUOTA_INTERVAL`) o heurística por `webNavigation` |

Pérdidas reales que hay que asumir en MV3:

1. **Sustitución de versión** (§Diferencias). Se pierde servir «la última de la línea 1.8.x» cuando
   piden 1.8.3. Es una pérdida de cobertura, pero **mejora** la privacidad de hecho: las reglas
   sólo sirven contenido byte a byte igual al que el CDN habría entregado para esa versión.
2. **`xhrTestDomain` y el «HTML filter»** de Firefox (2.5) no existen; ya están fuera del port.
3. **La decisión dinámica por iniciador** (si `initiator` es de la lista blanca) obliga a generar
   reglas con `initiatorDomains`; como la lista blanca la fija el usuario, se traduce a reglas
   **dinámicas** (cupo 5.000), no estáticas. Con una lista blanca vacía no hace falta ninguna.

`stripMetadata` **sí** es reproducible con DNR: `modifyHeaders` puede eliminar cabeceras de la
petición, y el 2.4 ya demostró que Vivaldi acepta el permiso de cabeceras extra.

---

## 6.5 `web_accessible_resources` y CSP

* **WAR.** MV2 usa la forma de lista (`"resources/*"`). MV3 exige **lista de objetos** con
  `resources` + `matches`:
  ```json
  "web_accessible_resources": [
    { "resources": ["resources/*"], "matches": ["<all_urls>"] }
  ]
  ```
  El prototipo ya lo declara así. Para un `action.type: redirect` con `extensionPath` **no** hace
  falta WAR (la carga la hace el navegador, no el sitio); se declara por si algún subrecurso se
  sirve por URL al documento.
* **CSP.** El Manifest V2 del port declara `default-src 'self'; img-src 'self' data:`. En MV3 el
  campo pasa a `content_security_policy.extension_pages` con la misma política. No hay `eval` ni
  scripts remotos en el port, así que no hay cambios de fondo.

---

## 6.6 Paridad funcional

`tools/e2e-dnr.sh` repite la **misma matriz de 22 URLs** que `tools/e2e-matrix.sh` (Fase 4.2),
pero cargando sólo el prototipo MV3. Resultado:

```
{ "total": 22, "servidosEnLocal": 22, "fallos": [] }
```

Es decir, **paridad 22/22** con el motor `webRequest` de MV2 para los recursos de la matriz,
incluidos los casos que dependen de la lógica de bundles (`select2/4.1.0/js/select2.min.js`,
`mathjax/3.2.2/es5/tex-chtml.js`) y los que llegan por `use.fontawesome.com`.

---

## Diferencias MV2 vs MV3 (resumen)

| Aspecto | MV2 (port actual) | MV3 (prototipo) |
|---|---|---|
| Mecanismo | `webRequest` bloqueante + decisión en tiempo de petición | reglas DNR estáticas precalculadas |
| Versión pedida que no existe | se sustituye por la última de la línea (p. ej. 1.8.3→1.8.2) | no se intercepta (la web carga el original) |
| Atributo `integrity` (SRI) | se rompe al sustituir versión (limite heredado, ver 4.4) | **no se rompe**: sólo se sirve la versión exacta, y el hash coincide |
| Estado por pestaña | objeto en memoria del background | `chrome.storage.session` + reconstrucción |
| Reglas | código en `mappings.js`/`request-analyzer.js` | 83.960 reglas `urlFilter` en 14 rulesets |
| Cabeceras | `onBeforeSendHeaders` imperativo | `modifyHeaders` declarativo |
| Coste de mantenimiento | seguir el motor de upstream | regenerar reglas cuando cambie `mappings.js` |

Un efecto colateral interesante: la limitación de SRI que arrastra MV2 (4.4) **desaparece** en el
planteamiento MV3, porque el precio de no sustituir versiones es exactamente lo que hace que el
hash siga cuadrando.

---

## Conclusión

* El plan B **es viable**: el mapeo completo cabe en reglas estáticas con el 75 % de margen, y la
  matriz de recursos da paridad total.
* El trabajo pendiente de verdad es **6.3** (pasar el motor a un service worker con estado en
  `storage.session`), no las reglas.
* Recomendación: mantener MV2 como vía principal (D-001) y tratar este prototipo como la base del
  plan B, con el generador `tools/gen-dnr.mjs` como pieza que se puede regenerar en cada
  actualización de upstream.

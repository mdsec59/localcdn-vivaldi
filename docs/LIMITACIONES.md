# Limitaciones y hallazgos de la paridad en Chromium

Documenta lo que **no** se puede recuperar en Vivaldi/Chromium sin reescribir el motor, lo que se
recuperó, y los defectos de datos del propio upstream encontrados al portar. Corresponde a los
ítems **2.3**, **2.5**, **2.8**, **4.1** y **4.4** de `TO-DO.md`.

---

## 1. Eliminación de `integrity`/`crossorigin` en HTML (2.3, 4.4)

**Estado: limitación heredada, no un defecto del port.**

Los sitios escriben `<link rel="stylesheet" … integrity="sha512-…" crossorigin="anonymous">` y
`<script … integrity="sha384-…">`. Para que la sustitución funcione aunque el fichero servido no
sea el pedido, Firefox tiene un *HTML filter* (`webRequest.filterResponseData`) que **borra** esos
atributos antes de que el navegador valide la integridad. Chromium **no** implementa
`filterResponseData` (crbug 487422); no hay API equivalente, y `declarativeNetRequest` sólo puede
tocar **cabeceras**, no el cuerpo/HTML.

Consecuencia medida con el test oficial (`jquery`) y en `tools/e2e-sri.sh`:

| Caso | Resultado |
|---|---|
| A. `<script src=…>` sin `integrity` | jQuery **definido** (se sirve 2.2.4 local) |
| B. con el `integrity` de 2.1.4 (el del test oficial) | jQuery **undefined** (hash no cuadra: se sirve 2.2.4) |
| C. con el `integrity` del fichero realmente servido + `crossorigin` | jQuery **definido** |

Es decir: **CORS y SRI funcionan perfectamente con recursos de extensión** (caso C). Lo único que
falla es el hash **porque la versión servida no es la pedida**. El mensaje del test oficial
(«The test resource could not be fetched locally or remotely», + «LocalCDN is not working as
intended») es engañoso: la petición sí se sirvió en local.

Dos vías para cerrarlo (ninguna adoptada todavía):

* **(a) dejar de sustituir versiones** cuando la petición lleva `integrity` — imposible: el
  `integrity` viaja en el HTML, no en la petición, y Chromium no lo expone.
* **(b) no sustituir versiones nunca en Chromium** (opción): se pierde cobertura, pero ningún sitio
  con SRI se rompe. Es la filosofía que el prototipo MV3 aplica por construcción
  (ver `PLAN-MV3.md`).

Nota relacionada: en el **test oficial** las páginas `fontawesome` y `materialicons` **no se
cuelgan**. El propio test las omite fuera de Firefox (`if (navigator.userAgent.indexOf("Firefox")
!= -1) … else oculta #message-log`). `tools/official-test.sh` ahora lo detecta y lo informa como
`omitidoPorElTest: true` en vez de leer el texto residual «Determining status…» del log oculto.

---

## 2. `xhrTestDomain` y el «HTML filter» (2.5)

**Estado: no soportado en Chromium; documentado.**

* El *HTML filter* es la misma carencia que en §1 (`filterResponseData` no existe en Chromium).
* `xhrTestDomain` es una comprobación de Firefox orientada a `XHR` cuyo objeto no aplica aquí.

Ambos ya quedaron fuera del camino de ejecución en el port (los parches de la Fase 2 mantienen el
bloqueo de Google Fonts sin depender de ellos).

---

## 3. Mensajes de recursos no soportados (2.8)

**Estado: pendiente de UI; el dato ya existe.**

Hoy, cuando una petición no se puede servir (versión inexistente, recurso no soportado), el aviso
va a la **consola del background** (`LogString`) y los contadores por pestaña quedan accesibles en
`stateManager.tabs` (`missing`, `blocked`). Lo que falta es **mostrarlo en la UI de opciones**:
una sección «no soportado en Chromium» que liste, por ejemplo, Font Awesome en
`use.fontawesome.com` (que upstream marca «only supported by Firefox» pese a que el port sí
recupera la inyección de Font Awesome por CDNJS — ver 2.2) y los recursos con SRI.

Evidencia del estado real de los avisos: en el test oficial, `worstcase` termina **16 Protected /
1 Unprotected** y el único no protegido es
`https://use.fontawesome.com/releases/v5.7.2/css/all.css` con el texto «only supported by Firefox».
No es un fallo del port: es una decisión de upstream que el port no cambia.

---

## 4. Test oficial: resultado registrado (4.1)

Ejecución completa (`tools/official-test.sh`, artefacto `/tmp/opencode/official-run2.txt`):

| Página | Resultado | Lectura |
|---|---|---|
| `jquery` | «Standard test with jQuery completed.» + «The test resource could not be fetched locally or remotely.» + «LocalCDN is not working as intended.» | **limitación de SRI** (§1), no un fallo del port |
| `fontawesome` | `omitidoPorElTest: true` | el test no corre en Chromium (§1, nota) |
| `materialicons` | `omitidoPorElTest: true` | ídem |
| `worstcase` | **16 Protected / 1 Unprotected** (FA 5.7.2 de `use.fontawesome.com`) | paridad alta; el único fallo es una exclusión deliberada de upstream |
| `tinymce` | «TinyMCE: replaced by LocalCDN» | correcto |

Estado interno tras el recorrido: `amountInjected: 42`, sin dominios en lista blanca, sin URLs
personalizadas (instalación limpia).

**Criterio de 4.1 cumplido en lo verificable**: la extensión funciona; lo que el test marca en
rojo se explica por una limitación de Chromium heredada, no por el port.

---

## 5. Defectos de datos de upstream encontrados

Al invertir los mapeos para generar reglas (§6.1 de `PLAN-MV3.md`) aparecieron **36 entradas de
`mappings.js` que apuntan a ficheros que no existen** en `resources/`. Son defectos de datos de
upstream, **no** del port, y afectan también al MV2 actual: cuando un sitio pide uno de esos
ficheros, la extensión redirige a una URL local inexistente (`ERR_FILE_NOT_FOUND`) en vez de
dejarlo pasar al CDN.

| Recurso | Mapeo espera | En disco |
|---|---|---|
| `bootstrapFontsOnly` | `resources/twitter-bootstrap/fonts/…` | la carpeta existe, pero el mapeo elide `{version}` |
| `docsifyThemeDefault` | `theme-default.css` (singular) | `theme-defaults.css` (plural) |
| `fancyBoxMediaJS` | `helpers/jquery.fancybox-media.*` | no se distribuye el *helper* |
| `jQueryTablesorter` | `resources/jquery.tablesorter/{v}/jquery.tablesorter.min.jsm` | el fichero está en `{v}/js/` |
| `lightGalleryJS` | `lightgallery-all.min.jsm` | sólo `lightgallery.min.jsm` |
| `ravenPluginAngularJS` | `plugins/angular.min.jsm` | no se distribuye `plugins/` |

**Recomendación** (no aplicada, para no divergir del dato de upstream): una validación en tiempo de
build que **elimine** los mapeos cuyo fichero local no exista. Es estrictamente mejor que
redirigir a un fichero inexistente, porque la web sigue funcionando (carga del CDN) en vez de
romperse. Queda anotado como candidato en `TO-DO.md` (Fase 4).

---

## 6. Resumen de lo recuperado en Chromium

Para contraste, esto sí se recuperó y está verificado (Fase 2):

* **2.1 Bloqueo de Google Fonts** — activo (placeholder CSS local de 0 bytes) / desactivado (carga
  de Google). `tools/e2e-parity.sh`.
* **2.2 Inyección de Font Awesome** — activa; la causa raíz real del fallo era `fileGuard`, no el
  `chromeSupport()` como se creía. `tools/e2e-parity.sh`.
* **2.4 `stripMetadata` con `EXTRA_HEADERS`** — verificado con y sin la opción.
  `tools/e2e-headers.sh`.

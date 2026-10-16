# URLs personalizadas (función del port)

Función **propia de este port**, no presente en upstream LocalCDN: permite declarar reglas
«URL de CDN → recurso local» adicionales, para CDNs o bibliotecas que el mapeo de upstream no
cubre. Se implementa como parche sobre el motor existente, sin reescribirlo (D-002).

## Por qué

El mapeo de upstream cubre un catálogo amplio pero cerrado. Hay dos casos frecuentes que deja
fuera:

1. **Un CDN propio o poco común** (paquete interno, espejo de empresa) que sirve ficheros que ya
   están (o se pueden dejar) en `resources/`.
2. **Una versión nueva** de una biblioteca ya presente, antes de que upstream actualice
   `mappings.js`.

En lugar de tocar `mappings.js` (que se pierde en cada actualización de upstream), las reglas
viven en `chrome.storage.local` y se aplican en el motor de intercepción.

## Piezas

| Fichero | Papel |
|---|---|
| `patches/core/custom-urls.js` | Motor: modelo de datos, validación, índice y coincidencia de URL |
| `patches/pages/options/options-custom-urls.js` | UI de la pestaña «URLs personalizadas» en opciones |
| `patches/pages/options/options-custom-urls.css` | Estilos de la pestaña |
| `patches/substitutions.json` | Inyecciones en `options.html`, `background.html` y locales |

Se inyecta en la página de opciones (una pestaña más, quedan 5/5) y en la página de fondo, donde
`request-analyzer` consulta `customUrls.matchUrl()` antes de darse por vencido.

## Modelo de datos

Cada entrada:

```js
{
  id:      'c-…',
  pattern: 'https://mi-cdn.example/*/jquery.min.js',  // URL de CDN (con o sin comodines)
  matchType: 'wildcard' | 'exact' | 'prefix',
  target:  'resources/jquery/3.7.1/jquery.min.jsm',   // recurso local dentro de la extensión
  enabled: true,
  note:    'texto libre'
}
```

* Al guardar en `chrome.storage.local` (clave `customUrls`) se persiste entre reinicios.
* `customUrls.validateEntry()` comprueba que el destino exista y sea legible **antes** de aceptar
  la regla (evita las «peticiones muertas» de §5 de `LIMITACIONES.md`).
* `customUrls.resourceIndex()` alimenta el autocompletado del campo destino con el inventario real
  de `resources/` (**2.011** opciones).

## Cómo se aplica

`customUrls.matchUrl(url)` devuelve la entrada que casa (o `null`). Cuando casa,
`customUrls.redirectUrlFor(entry)` construye la URL `chrome-extension://<id>/<target>` y la
**firma con `fileGuard.signed()`** (igual que hacen los redireccionamientos de upstream desde la
Fase 2.2). Sin la firma, `fileGuard` redirigiría el subrecurso a la raíz de la extensión.

## Verificación (hecha)

`tools/e2e-custom-urls.sh`:

* Con una regla activa, una petición a la URL de CDN se sirve desde
  `chrome-extension://…/resources/jquery/3.7.1/jquery.min.jsm?_=…` (**200**, **87.533 bytes**).
* Al desactivar la regla, la petición deja de servirse en local (vuelve al CDN).
* La interfaz muestra **5/5** pestañas y el autocompletado ofrece **2.011** recursos.

## Interacción con las otras fases

* **Lista de permitidos (4.5):** si el iniciador está permitido, no se aplica ninguna regla
  personalizada (mismo camino que el resto de la intercepción).
* **MV3 (Fase 6):** estas reglas son un caso ideal para reglas **dinámicas** de
  `declarativeNetRequest` (cupo 5.000), porque las fija el usuario en tiempo de ejecución y no
  caben en los rulesets estáticos generados. Es la migración natural cuando el plan B se active.

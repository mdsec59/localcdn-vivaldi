# LocalCDN para Vivaldi

Port **no oficial** de [LocalCDN](https://codeberg.org/nobody/LocalCDN) para el navegador **Vivaldi**
(Chromium). LocalCDN emula redes de distribución de contenido (CDN): intercepta las peticiones a CDNs
conocidos y sirve los recursos (jQuery, Bootstrap, Angular, Font Awesome…) desde copias locales dentro
de la propia extensión. Resultado: menos peticiones a terceros, menos rastreadores y carga más rápida.

El proyecto original dejó de dar soporte a navegadores Chromium cuando Google empezó a retirar las API
de Manifest V2. Este repositorio mantiene un **port mantenible** para Vivaldi, con:

- manifest adaptado a Chromium (sin claves exclusivas de Gecko),
- scripts de construcción, instalación y pruebas,
- documentación del estado real de MV2 en Vivaldi y del plan B (MV3 + declarativeNetRequest).

## Estado (16-oct-2026)

| Comprobación | Resultado |
|---|---|
| Vivaldi del sistema | 8.2.4133.52 stable (Linux Mint 22.2) · Chromium **152** |
| Upstream base | commit `ade7a97`, versión **2.6.86** |
| ¿Carga MV2 en Vivaldi 8.2? | **Sí** (cargada como extensión de línea de comandos, `disable_reasons: []`) |
| ¿Permisos sensibles concedidos? | **Sí**: `webRequest`, `webRequestBlocking`, `webNavigation`, `privacy`, `storage`, `*://*/*` |
| ¿Intercepta y sirve recursos locales? | **Sí** — matriz de **22/22** recursos (`tools/e2e-matrix.sh`) |
| Fase 2 (paridad Chromium) | **Hecha**: Google Fonts, Font Awesome y `stripMetadata` recuperados y verificados |
| Fase 4 (pruebas) | **Hecha (4.1–4.5)**: matriz, versión inexistente, SRI, lista blanca y test oficial |
| Fase 6 (plan B MV3+DNR) | **Prototipo viable y verificado**: 83.960 reglas en 14 rulesets, paridad **22/22** |

### Evidencia de la prueba funcional (e2e dentro de Vivaldi)

| Petición de la web | URL final servida | Bytes |
|---|---|---|
| `https://code.jquery.com/jquery-3.7.1.min.js` | `chrome-extension://…/resources/jquery/3.7.1/jquery.min.jsm` | 87 533 |
| `https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js` | `chrome-extension://…/resources/jquery/3.7.1/jquery.min.jsm` | 87 533 |
| `https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/…/bootstrap.min.css` | `chrome-extension://…/resources/twitter-bootstrap/5.3.8/bootstrap.min.css` | 232 108 |

Contador interno de la extensión tras la prueba: `amountInjected: 5`.
En el net-log **no aparece ningún host de CDN**, es decir, no hubo tráfico hacia el CDN.

> Detalle: `.jsm`/`.cssm` son las extensiones internas de LocalCDN (JS/CSS "mimificado") para sus copias locales.

### Límites conocidos

* **SRI + sustitución de versión** (`integrity`/`crossorigin`): en Chromium no se puede filtrar el
  HTML (no hay `filterResponseData`), así que un recurso con `integrity` de una versión distinta a
  la servida se rechaza. CORS y SRI **sí** funcionan cuando el hash cuadra. Ver
  [`docs/LIMITACIONES.md`](docs/LIMITACIONES.md) y el ADR D-007.
* **Font Awesome en `use.fontawesome.com`** aparece como «only supported by Firefox»: es una
  exclusión deliberada de upstream, no un fallo del port.

## Estructura del proyecto

```
localcdn-vivaldi/
├── README.md                     # este archivo
├── docs/
│   ├── TO-DO.md                  # plan de trabajo detallado (fases, prioridades, criterios)
│   ├── ANALISIS-UPSTREAM.md      # cómo funciona LocalCDN y qué cambia en Chromium/Vivaldi
│   ├── VIVALDI-NOTAS.md          # estado de MV2 en Vivaldi, IDs, rutas, riesgos
│   ├── INSTALACION.md            # instalar y probar en tu Vivaldi paso a paso
│   ├── DECISIONES.md             # registro de decisiones (ADR) del port
│   ├── LIMITACIONES.md           # lo que no se puede recuperar en Chromium + hallazgos
│   ├── PLAN-MV3.md               # Fase 6: estudio de viabilidad del plan B (DNR) con medidas
│   └── URLS-PERSONALIZADAS.md    # función propia: reglas «URL de CDN → recurso local»
├── manifest/
│   └── manifest.vivaldi.json     # plantilla de manifest MV2 para Chromium
├── mv3/                          # prototipo MV3 (service worker + página de diagnóstico)
├── patches/                      # sustituciones y parches propios sobre upstream
├── tools/
│   ├── fetch-upstream.sh         # clona/actualiza LocalCDN upstream
│   ├── build.sh                  # genera dist/localcdn-vivaldi (+ zip)
│   ├── build-mv3.sh              # genera el prototipo MV3 (dist/localcdn-vivaldi-mv3)
│   ├── gen-dnr.mjs               # generador de reglas declarativeNetRequest desde mappings.js
│   ├── make-key.sh               # ID de extensión estable (clave pública)
│   ├── smoke-test.sh             # ¿carga la extensión en Vivaldi?
│   ├── e2e-test.sh               # ¿intercepta recursos realmente?
│   ├── e2e-parity.sh             # Fase 2: Google Fonts, Font Awesome, stripMetadata
│   ├── e2e-matrix.sh             # Fase 4: matriz 22/22, versión inexistente, lista blanca
│   ├── e2e-sri.sh                # Fase 4.4: SRI/crossorigin (casos A/B/C)
│   ├── e2e-headers.sh            # Fase 2.4: stripMetadata con control
│   ├── e2e-dnr.sh                # Fase 6: límites DNR y paridad con el prototipo MV3
│   ├── e2e-custom-urls.sh        # URLs personalizadas
│   ├── official-test.sh          # test oficial de LocalCDN dentro de Vivaldi
│   └── cdp.py                    # cliente CDP mínimo (stdlib) para automatizar Vivaldi
├── dist/                         # (generado, no versionado)
└── upstream/                     # clon de LocalCDN (no versionado)
```

## Inicio rápido

```bash
tools/fetch-upstream.sh     # 1. clona LocalCDN (~117 MB)
tools/build.sh              # 2. genera dist/localcdn-vivaldi + zip
tools/smoke-test.sh         # 3. comprueba que Vivaldi la carga (perfil aislado)
tools/e2e-test.sh           # 4. comprueba que intercepta CDNs de verdad
```

Pruebas de paridad y calidad (necesitan `DISPLAY=:0`):

```bash
tools/e2e-parity.sh         # Fase 2
tools/e2e-matrix.sh         # Fase 4.2/4.3/4.5
tools/e2e-sri.sh            # Fase 4.4
tools/official-test.sh      # test oficial (PAGES="url" para una sola página)
```

Plan B (MV3), opcional:

```bash
tools/build-mv3.sh          # HOSTS= (vacío) genera el conjunto completo
tools/e2e-dnr.sh            # límites reales de DNR + paridad de la matriz
```

Instalación manual en tu navegador: ver [`docs/INSTALACION.md`](docs/INSTALACION.md).

## Licencia

El código de LocalCDN es **MPL 2.0** (ver `upstream/LICENSE.txt`). Este port solo añade manifest y
herramientas; mantén la misma licencia y la atribución a *nobody* y al proyecto Decentraleyes si lo
distribuyes. No está afiliado a LocalCDN ni a Vivaldi Technologies.

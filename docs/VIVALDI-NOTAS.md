# Notas específicas de Vivaldi (y del fin de Manifest V2)

Documento vivo. Recoge el estado real de MV2 en Vivaldi, lo que hemos verificado en este equipo y
lo que hay que vigilar.

## 1. Contexto: el calendario de MV2 en Chromium y Vivaldi

Fechas relevantes (fuentes: `developer.chrome.com` *Manifest V2 support timeline*, prensa
especializada de julio de 2026, comentario fijado del equipo de Vivaldi en Reddit):

| Fecha | Hecho |
|---|---|
| 24-jul-2025 | Chrome desactiva MV2 «en todas partes». |
| 31-mar-2025 | MV2 desactivado con opción de reactivar extensiones (fase previa). |
| jun-2026 | Chrome 150/151 dejan MV2 «en soporte vital» (las extensiones desempaquetadas dejan de arrancar). |
| 08-jul-2026 | Google confirma la retirada total de MV2 de la Chrome Web Store. |
| jul-2026 | **Vivaldi 8.1** empieza a **avisar** de que las extensiones MV2 «ya no están soportadas»; el equipo aclara que el aviso es informativo, que las extensiones **se pueden reactivar en `vivaldi:extensions`** y que deberían seguir funcionando «durante el ciclo de 8.1» (~2 meses). Vivaldi admite que no es viable mantenerlo «a largo plazo». |
| 31-ago-2026 | Chrome Web Store elimina definitivamente las extensiones MV2 restantes. |
| 15-oct-2026 (hoy) | Vivaldi **8.2.4133.52** — este port **carga y funciona** (ver §2). |

Conclusión: MV2 funciona hoy en Vivaldi 8.2, pero es una **ventana que se cierra**. El proyecto
debe tratar MV2 como vía principal con fecha de caducidad y preparar el plan B (MV3 + DNR, ver
`TO-DO.md` §Fase 6).

## 2. Lo que hemos verificado en esta máquina

Pruebas hechas con instancias **aisladas** de Vivaldi (`--user-data-dir` temporal) para no tocar tu perfil:

**a) Carga de la extensión (`tools/smoke-test.sh`)**

En `…/Default/Preferences`, la extensión aparece como:

```json
"active_permissions": { "api": ["privacy","storage","webNavigation","webRequest","webRequestBlocking"],
                        "explicit_host": ["*://*/*"] },
"disable_reasons": [],
"location": 8,                       // extensiones cargadas por línea de comandos (--load-extension)
"preferences": { "net.network_prediction_options": 2 }   // lo escribió el background page de LocalCDN
```

`disable_reasons: []` ⇒ **habilitada**; la preferencia `network_prediction_options` demuestra que
`core/main.js` se ejecutó (usa `chrome.privacy`).

**b) Interceptación real (`tools/e2e-test.sh`)** — 3 redirecciones a recursos locales y
`amountInjected: 5`; ningún host de CDN en el net-log. Detalle en el `README.md`.

**c) Sin errores de MV2 en el log del navegador** (`--enable-logging=stderr`): no aparece ningún
mensaje de rechazo por `manifest_version: 2`.

## 3. Detalles de plataforma que afectan al port

- **ID de extensión desempaquetada**: se deriva del SHA-256 de la ruta absoluta instalada; mapeado a
  letras `a`-`p`. La ruta actual (`dist/localcdn-vivaldi`) da `mdalmhkphiimeanlihjeokkcehjgeahd`.
  Si cambias de carpeta, **cambia el ID** (y con él las concesiones de permisos). Para fijarlo, usa
  `tools/make-key.sh` (añade `key` al manifest) — pendiente en `TO-DO.md` §1.3.
- **Vivaldi no tiene tienda de extensiones propia**: se usa la Chrome Web Store o instalación local.
  Como ya no se puede publicar MV2 en la store, la vía práctica es **cargar descomprimida**.
- **Rutas útiles**: `vivaldi://extensions` (modo desarrollador), `vivaldi://version`, perfiles en
  `~/.config/vivaldi/` (`Default/`, `Profile 1/`…). El modo incógnito requiere marcar «Permitir en
  incógnito» manualmente.
- **Instalación por línea de comandos** (lo que usan los scripts): `vivaldi --load-extension=<ruta>`.
  Vivaldi/Kylin 8.2 respeta `--load-extension`, `--user-data-dir`, `--remote-debugging-port` y
  `--log-net-log`.
- **Automatización**: funciona el protocolo CDP (`--remote-debugging-port`). Se incluye
  `tools/cdp.py` (solo biblioteca estándar) para evaluar JS en la página y en el *background page*.
  Esto habilita pruebas con Playwright/Puppeteer en el futuro (§4.7).
- **Aviso de MV2 en la UI**: al abrir `vivaldi://extensions` puede aparecer el aviso de que las
  extensiones MV2 «ya no están soportadas», con la extensión desactivada. Basta reactivarla con el
  interruptor. **Verificar y documentar el comportamiento exacto** (§0.6).
- **Google Fonts**: en Chromium el mapa de Google Fonts se elimina en tiempo de carga
  (`core/mappings.js`), así que la opción «bloquear Google Fonts» **no actúa** (§2.1 del to-do).
- **`filterResponseData`** no existe en Chromium ⇒ la eliminación de `integrity`/`crossorigin` del
  HTML en tránsito no funciona (§2.3).

## 4. Riesgos abiertos

1. **Retirada de MV2 en Vivaldi 8.3+**: es cuestión de tiempo. Mitigación: Fase 6 (MV3).
2. **Reactividad de los avisos**: la extensión puede quedar desactivada tras una actualización del
   navegador; hay que re-activarla a mano. Mitigación: documentar + script de comprobación.
3. **Red local (Cuba)**: la verificación de recursos (`audit.sh`) requiere acceso a los CDNs; puede
   fallar de forma intermitente. Considerar `torsocks`/réplicas locales.
4. **Firma y distribución**: sin tienda, no hay actualizaciones automáticas. Mitigación: script de
   reconstrucción y `vivaldi --pack-extension` opcional (§5.2).

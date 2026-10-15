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

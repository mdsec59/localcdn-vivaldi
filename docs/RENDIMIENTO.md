# Rendimiento: coste de la intercepción (Fase 4.8)

Responde al ítem **4.8** de `TO-DO.md`. Prueba: `tools/e2e-perf.sh`. Artefacto:
`/tmp/opencode/localcdn-perf/resultado-perf.json`.

## Método

Se sirven **los mismos 22 ficheros** (4.419.147 bytes en total) de dos formas y se mide el tiempo
que ve la página (`performance.now()`, con `cache: 'no-store'` para que no haya caché):

* **A — interceptado:** se pide la URL del CDN y la extensión la redirige a
  `chrome-extension://…/resources/…` (motor `webRequest` en MV2).
* **B — referencia:** se pide el mismo fichero por **HTTP local** (`python3 -m http.server`,
  mismos bytes, misma máquina).

La diferencia entre A y B es el coste añadido por la intercepción (decisión + esquema de extensión)
frente a «leer el mismo fichero de disco y servirlo». Se incluye el calentamiento y se informa
**mediana** además de la media.

## Resultado (16-oct-2026, Vivaldi 8.2.4133.52 · Chromium 152)

| | n | mediana (ms) | media (ms) | mín (ms) | máx (ms) |
|---|---|---|---|---|---|
| Interceptado (extensión) | 22 | **10,0** | 9,75 | 6,9 | 17,4 |
| Referencia (HTTP local) | 22 | **5,9** | 5,94 | 4,8 | 9,0 |

* **Sobrecoste de la intercepción ≈ 4 ms por petición** (≈ 4,1 ms en la media).
* Fallos: **0**.

## Cómo leerlo

* El coste **no** es el tiempo que ahorra la extensión (eso exige comparar con la descarga real del
  CDN). Es el **precio interno** de servir en local: ~4 ms de más frente a servir el mismo fichero
  por HTTP local, y muy por debajo de una ida y vuelta a un CDN real.
* El ahorro real de LocalCDN es de **red**: se evita la petición al tercero (privacidad y latencia),
  a cambio de este coste de proceso, despreciable en comparación.
* **No se incluye el baseline de descarga desde el CDN** (el que daría el ahorro neto) porque la
  máquina de pruebas usa una red restringida (Psiphon) y ese número no sería comparable. Queda como
  medición pendiente para un entorno con red abierta.

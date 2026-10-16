#!/usr/bin/env node
// gen-dnr.mjs — Fase 6.1: genera reglas declarativeNetRequest (MV3) desde core/mappings.js.
//
// Por qué en Node: mappings.js/resources.js son objetos JavaScript. Evaluarlos en un contexto
// `vm` es exacto; un analizador propio se rompería en cuanto upstream cambie el formato. El
// script NO modifica upstream: sólo lee.
//
// Cómo traduce la lógica de MV2 a reglas estáticas (ver docs/PLAN-MV3.md):
//
//   * Recursos "de fichero"  (plantilla con nombre, p. ej. resources/jquery/{version}/jquery.min.jsm)
//     → una regla por (URL de CDN, versión que EXISTE en disco). Nunca se sirve una versión
//       distinta de la pedida: es la diferencia clave con MV2 y evita romper el atributo
//       `integrity` (SRI), que en Chromium no se puede filtrar.
//   * Recursos "de directorio" (plantilla acabada en `/`, p. ej. resources/select2/{version}/)
//     → MV2 añade el nombre pedido al directorio y convierte `.js` → `.jsm`; aquí se invierte
//       el proceso: por cada fichero local se generan las URLs de CDN equivalentes
//       (`.jsm` → `.js`, `.min.jsm` → `.min.js` y `.js` para bundles sin comprimir, etc.).
//
// Se usa `urlFilter` (no `regexFilter`): las reglas regex tienen un tope aparte (~1000) y aquí
// hacen falta decenas de miles. Dos reglas por URL (http/https) con ancla `|` para que el host
// coincida EXACTAMENTE (el ancla `||` casaría también subdominios, cosa que upstream no hace).
//
// Uso:
//   node tools/gen-dnr.mjs [--base dist/localcdn-vivaldi] [--upstream upstream]
//                          [--out mv3/rules] [--max-por-ruleset 4000] [--solo-hosts a,b]
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.resolve(AQUI, '..');

function arg(nombre, porDefecto) {
  const i = process.argv.indexOf(`--${nombre}`);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : porDefecto;
}

const BASE = path.resolve(RAIZ, arg('base', 'dist/localcdn-vivaldi'));
const UPSTREAM = path.resolve(RAIZ, arg('upstream', 'upstream'));
const SALIDA = path.resolve(RAIZ, arg('out', 'mv3/rules'));
const MAX_POR_RULESET = Number(arg('max-por-ruleset', '4000'));
const SOLO_HOSTS = arg('solo-hosts', '').split(',').filter(Boolean);

// Tipos de recurso que LocalCDN intercepta en la práctica (los que pueden transportar una
// biblioteca o sus subrecursos: fuentes, sprites, mapas de estilo…).
const TIPOS = [
  'script', 'stylesheet', 'image', 'font', 'media', 'xmlhttprequest',
  'other', 'object', 'ping', 'csp_report', 'websocket'
];

// ---------------------------------------------------------------------------
// 1. Cargar resources.js y mappings.js en un contexto controlado.
// ---------------------------------------------------------------------------
function cargarModelo() {
  // FIREFOX: true para conservar los endpoints de Google Fonts, igual que hace el port en
  // Chromium (upstream los borra en Chromium por el issue #1085; el port los mantiene).
  const contexto = { console, BrowserType: { FIREFOX: true, CHROMIUM: false, EDGE: false } };
  vm.createContext(contexto);
  vm.runInContext(fs.readFileSync(path.join(UPSTREAM, 'core/resources.js'), 'utf8'), contexto);
  vm.runInContext(fs.readFileSync(path.join(UPSTREAM, 'core/mappings.js'), 'utf8'), contexto);
  return {
    resources: vm.runInContext('resources', contexto),
    cdn: vm.runInContext('mappings.cdn', contexto),
    ultimaActualizacion: vm.runInContext('mappings.lastMappingUpdate', contexto)
  };
}

// ---------------------------------------------------------------------------
// 2. Inventario real de ficheros y clasificación por recurso.
// ---------------------------------------------------------------------------
function inventariar() {
  const raizRecursos = path.join(BASE, 'resources');
  const ficheros = [];
  (function recorrer(dir) {
    for (const entrada of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entrada.name);
      if (entrada.isDirectory()) recorrer(p);
      else ficheros.push(path.relative(BASE, p).split(path.sep).join('/'));
    }
  })(raizRecursos);
  return ficheros;
}

function escaparRegex(texto) {
  return texto.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function clasificarRecursos(resources, ficheros) {
  const indice = {};
  for (const clave of Object.keys(resources)) {
    const plantilla = resources[clave].path;
    const esDirectorio = plantilla.endsWith('/');
    const entrada = { clave, plantilla, esDirectorio, versiones: {} };
    if (!plantilla.includes('{version}')) {
      entrada.fijo = ficheros.includes(plantilla) ? plantilla : null;
    } else if (esDirectorio) {
      // Recurso de directorio: los ficheros viven dentro de la carpeta de cada versión
      // (o directamente en la carpeta, si la plantilla no usa {version}).
      const corte = plantilla.indexOf('{version}');
      const prefijo = corte > -1 ? plantilla.slice(0, corte) : plantilla;
      const patron = new RegExp(
        '^' + escaparRegex(prefijo) + (corte > -1 ? '([^/]+)/' : '')
      );
      for (const fichero of ficheros) {
        const m = patron.exec(fichero);
        if (!m) continue;
        const rel = fichero.slice(m[0].length);
        if (!rel) continue;
        const version = corte > -1 ? m[1] : '';
        (entrada.versiones[version] ||= []).push({ rel, fichero });
      }
    } else {
      const patron = new RegExp(
        '^' + escaparRegex(plantilla).replace('\\{version\\}', '([^/]+)') + '$'
      );
      for (const fichero of ficheros) {
        const m = patron.exec(fichero);
        if (m) entrada.versiones[m[1]] = fichero;
      }
    }
    indice[clave] = entrada;
  }
  return indice;
}

// Nombres de CDN equivalentes a un fichero local.
function nombresDeCdn(rel, esElementUI) {
  const nombres = new Set();
  const añadir = (n) => {
    nombres.add(n);
    if (esElementUI) nombres.add(n.toLowerCase());
  };
  if (rel.endsWith('.min.jsm')) {
    añadir(rel.slice(0, -4) + '.js'); // .min.jsm -> .min.js
    añadir(rel.slice(0, -8) + '.js'); // .min.jsm -> .js   (bundles sin comprimir)
  } else if (rel.endsWith('.jsm')) {
    añadir(rel.slice(0, -1)); // .jsm -> .js
  } else if (rel.endsWith('.min.css')) {
    añadir(rel);
    añadir(rel.replace('.min.css', '.css'));
  } else {
    añadir(rel);
  }
  return [...nombres];
}

// ---------------------------------------------------------------------------
// 3. Generar reglas.
// ---------------------------------------------------------------------------
function generarReglas(modelo, indice) {
  const reglas = [];
  const incidencias = {
    sinRecurso: [],
    sinFichero: [],
    recursosSinFichero: Object.keys(indice).filter((clave) => {
      const e = indice[clave];
      return e.plantilla.includes('{version}')
        ? Object.keys(e.versiones).length === 0
        : e.fijo === null;
    })
  };

  const recursoDe = new Map(Object.keys(modelo.resources).map((n) => [modelo.resources[n], n]));
  let id = 0;
  const emitir = (url, destino) => {
    for (const esquema of ['https', 'http']) {
      id += 1;
      reglas.push({
        id,
        priority: 1,
        action: { type: 'redirect', redirect: { extensionPath: `/${destino}` } },
        condition: { urlFilter: `|${esquema}://${url}`, resourceTypes: TIPOS }
      });
    }
  };

  for (const host of Object.keys(modelo.cdn)) {
    if (SOLO_HOSTS.length && !SOLO_HOSTS.includes(host)) continue;
    for (const basePath of Object.keys(modelo.cdn[host])) {
      for (const patron of Object.keys(modelo.cdn[host][basePath])) {
        const clave = recursoDe.get(modelo.cdn[host][basePath][patron]);
        if (!clave) {
          incidencias.sinRecurso.push(`${host}${basePath}${patron}`);
          continue;
        }
        const entrada = indice[clave];
        const esElementUI = entrada.plantilla.startsWith('resources/element-ui/');

        if (!entrada.esDirectorio) {
          if (!entrada.plantilla.includes('{version}')) {
            // Plantilla sin versión: el patrón puede pedir cualquier versión -> comodín '*'.
            if (entrada.fijo) {
              emitir(`${host}${basePath}${patron.replaceAll('{version}', '*')}`, entrada.fijo);
            } else {
              incidencias.sinFichero.push(`${host}${basePath}${patron} -> ${entrada.plantilla}`);
            }
            continue;
          }
          for (const [version, fichero] of Object.entries(entrada.versiones)) {
            // Un patrón que termina en '/' es un prefijo de directorio (p. ej. Font Awesome
            // `font-awesome/{version}/css/`): hay que añadir el nombre del fichero, si no la
            // regla casaría TODOS los ficheros de esa carpeta y los redirigiría a uno solo.
            const base = fichero.split('/').pop();
            const conNombre = patron.endsWith('/');
            const nombre = conNombre ? nombresDeCdn(base, false)[0] : null;
            const url = patron.replaceAll('{version}', version) + (conNombre ? nombre : '');
            emitir(`${host}${basePath}${url}`, fichero);
          }
          if (Object.keys(entrada.versiones).length === 0) {
            incidencias.sinFichero.push(`${host}${basePath}${patron} -> ${entrada.plantilla}`);
          }
          continue;
        }

        // Recurso de directorio: se invierte la lógica de bundles de MV2. El nombre del
        // fichero local se convierte al nombre de CDN equivalente (.jsm -> .js, etc.).
        if (!patron.includes('{version}') && entrada.plantilla.includes('{version}')) {
          incidencias.sinFichero.push(`${host}${basePath}${patron} -> ${entrada.plantilla}`);
          continue;
        }
        // MV2 sólo usa el NOMBRE del fichero pedido y lo coloca en el directorio del recurso
        // (los subdirectorios del CDN no se reflejan en disco). Por eso aquí se aparean los
        // patrones con el nombre base de cada fichero local, no con la ruta relativa.
        const [antesVersion, despuesVersion] = patron.split('{version}');
        const despues = (despuesVersion || '').replace(/^\//, '');
        const ultimaBarra = despues.lastIndexOf('/');
        const prefijoFichero = ultimaBarra > -1 ? despues.slice(ultimaBarra + 1) : despues;
        // Patrón "directorio pelado" (`.../{version}/`): la URL real puede llevar
        // subdirectorios intermedios (p. ej. `select2/4.1.0/js/select2.min.js`); se cubre
        // con un comodín, igual que hace MV2 al ignorar la ruta.
        const urlBase = antesVersion + '{VERSION}' + (ultimaBarra > -1 ? despues.slice(0, ultimaBarra + 1) : '');
        const comodin = prefijoFichero === '';
        for (const [version, ficheros] of Object.entries(entrada.versiones)) {
          // Si la carpeta local no tiene versión, la URL lleva comodín en su lugar.
          const versionEnUrl = version === '' ? '*' : version;
          for (const { rel, fichero } of ficheros) {
            const base = rel.split('/').pop();
            for (const nombre of nombresDeCdn(base, esElementUI)) {
              if (!nombre.startsWith(prefijoFichero)) continue;
              const url = (urlBase + (comodin ? '*' : '') + nombre).replace('{VERSION}', versionEnUrl);
              emitir(`${host}${basePath}${url}`, fichero);
            }
          }
        }
      }
    }
  }
  return { reglas, incidencias };
}

// ---------------------------------------------------------------------------
// 4. Empaquetar en rulesets equilibrados (≤ --max-por-ruleset) por familia de CDN.
// ---------------------------------------------------------------------------
function extraerHost(urlFilter) {
  return urlFilter.replace(/^\|https?:\/\//, '').split('/')[0];
}

function empaquetar(reglas, maxPorRuleset) {
  const porHost = new Map();
  for (const regla of reglas) {
    const host = extraerHost(regla.condition.urlFilter);
    if (!porHost.has(host)) porHost.set(host, []);
    porHost.get(host).push(regla);
  }
  const grupos = [...porHost.entries()]
    .map(([host, lista]) => ({ host, reglas: lista }))
    .sort((a, b) => b.reglas.length - a.reglas.length);

  const rulesets = [];
  for (const grupo of grupos) {
    let hueco = rulesets.find((r) => r.reglas.length + grupo.reglas.length <= maxPorRuleset);
    if (!hueco) {
      hueco = { hosts: [], reglas: [] };
      rulesets.push(hueco);
    }
    hueco.hosts.push(grupo.host);
    hueco.reglas.push(...grupo.reglas);
  }
  rulesets.forEach((ruleset, i) => {
    ruleset.nombre = `ruleset-${String(i + 1).padStart(2, '0')}`;
    ruleset.reglas.forEach((regla, j) => {
      regla.id = j + 1;
    });
  });
  return rulesets;
}

// ---------------------------------------------------------------------------
// Programa principal
// ---------------------------------------------------------------------------
const modelo = cargarModelo();
const ficheros = inventariar();
const indice = clasificarRecursos(modelo.resources, ficheros);
const { reglas, incidencias } = generarReglas(modelo, indice);
const rulesets = empaquetar(reglas, MAX_POR_RULESET);

fs.rmSync(SALIDA, { recursive: true, force: true });
fs.mkdirSync(SALIDA, { recursive: true });

const recursosManifest = [];
for (const ruleset of rulesets) {
  fs.writeFileSync(path.join(SALIDA, `${ruleset.nombre}.json`), JSON.stringify(ruleset.reglas));
  recursosManifest.push({ id: ruleset.nombre, enabled: true, path: `rules/${ruleset.nombre}.json` });
}

const deFichero = Object.values(indice).filter((e) => !e.esDirectorio).length;
const deDirectorio = Object.values(indice).filter((e) => e.esDirectorio).length;

const resumen = {
  generado: new Date().toISOString(),
  ultimaActualizacionDeMappings: modelo.ultimaActualizacion,
  base: path.relative(RAIZ, BASE),
  recursosDeFichero: deFichero,
  recursosDeDirectorio: deDirectorio,
  ficherosLocales: ficheros.length,
  reglasTotales: reglas.length,
  urlsDistintas: reglas.length / 2,
  rulesets: rulesets.length,
  hosts: new Set(reglas.map((r) => extraerHost(r.condition.urlFilter))).size,
  maxReglasEnUnRuleset: Math.max(...rulesets.map((r) => r.reglas.length)),
  reglasPorRuleset: rulesets.map((r) => ({
    id: r.nombre,
    reglas: r.reglas.length,
    hosts: r.hosts
  })),
  incidencias: {
    mappingsSinRecurso: incidencias.sinRecurso,
    mappingsSinFicheroLocal: incidencias.sinFichero.slice(0, 20),
    mappingsSinFicheroLocalTotal: incidencias.sinFichero.length,
    recursosSinFicheroLocal: incidencias.recursosSinFichero
  },
  fragmentoManifest: {
    manifest_version: 3,
    declarative_net_request: { rule_resources: recursosManifest },
    permissions: ['declarativeNetRequest', 'declarativeNetRequestFeedback']
  }
};
fs.writeFileSync(path.join(SALIDA, 'index.json'), JSON.stringify(resumen, null, 2));

console.log(`[i] base            : ${resumen.base}`);
console.log(`[i] mappings        : ${resumen.ultimaActualizacionDeMappings}`);
console.log(`[i] ficheros locales: ${resumen.ficherosLocales}`);
console.log(`[i] recursos        : ${deFichero} de fichero + ${deDirectorio} de directorio`);
console.log(`[i] reglas          : ${resumen.reglasTotales} (${resumen.urlsDistintas} URLs × http/https)`);
console.log(`[i] rulesets        : ${resumen.rulesets} (máx. ${resumen.maxReglasEnUnRuleset} reglas cada uno)`);
console.log(`[i] hosts           : ${resumen.hosts}`);
if (incidencias.sinFichero.length) {
  console.log(`[!] ${incidencias.sinFichero.length} mappings sin fichero local`);
}
if (incidencias.sinRecurso.length) {
  console.log(`[!] ${incidencias.sinRecurso.length} mappings sin recurso asociado`);
}
console.log(`[ok] Escrito en ${path.relative(process.cwd(), SALIDA)}`);

'use strict';

/*
 * Página de diagnóstico del prototipo MV3.
 * Vuelca en #salida un JSON con los límites de declarativeNetRequest y el
 * resultado de testMatchOutcome para unas URLs de ejemplo. El script de pruebas
 * (tools/e2e-dnr.sh) lee ese texto a través de CDP.
 */

const URLS_DE_PRUEBA = [
  'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/select2/4.1.0/js/select2.min.js',
  'https://cdn.jsdelivr.net/npm/moment@2.30.1/moment.min.js',
  'https://ajax.googleapis.com/ajax/libs/angularjs/1.8.3/angular.min.js',
  'https://code.jquery.com/jquery-3.7.1.min.js',
  'https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/js/bootstrap.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/nonexistent/9.9.9/nonexistent.min.js'
];

async function preguntar(orden) {
  return chrome.runtime.sendMessage(orden);
}

async function principal() {
  const salida = {};

  salida.limites = await preguntar({ tipo: 'limites' });
  salida.coincidencias = [];
  for (const url of URLS_DE_PRUEBA) {
    salida.coincidencias.push(await preguntar({ tipo: 'match', url, recurso: 'script' }));
  }

  document.getElementById('salida').textContent = JSON.stringify(salida, null, 2);
  document.title = 'listo';
}

principal();

'use strict';

/*
 * Prototipo MV3 (Fase 6) — service worker mínimo.
 *
 * No sustituye al motor de LocalCDN: sirve para (a) medir los límites reales de
 * declarativeNetRequest en el Chromium de Vivaldi y (b) comprobar que las reglas
 * generadas por tools/gen-dnr.mjs interceptan de verdad.
 *
 * Órdenes (chrome.runtime.sendMessage):
 *   {tipo: 'limites'}                -> límites + rulesets activos + recuento de reglas
 *   {tipo: 'match', url, recurso}    -> declarativeNetRequest.testMatchOutcome
 */

const CONSTANTES = [
  'MAX_NUMBER_OF_STATIC_RULES',
  'MAX_NUMBER_OF_ENABLED_STATIC_RULESETS',
  'MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES',
  'MAX_NUMBER_OF_UNSAFE_DYNAMIC_AND_SESSION_RULES',
  'MAX_NUMBER_OF_REGEX_RULES',
  'GETMATCHEDRULES_QUOTA_INTERVAL'
];

async function limites() {
  const dnr = chrome.declarativeNetRequest;
  const info = {
    chrome: navigator.userAgent,
    metodo: 'declarativeNetRequest (MV3)',
    enabledRulesets: await dnr.getEnabledRulesets(),
    availableStaticRuleCount: await dnr.getAvailableStaticRuleCount(),
    constantes: {}
  };
  for (const nombre of CONSTANTES) {
    if (typeof dnr[nombre] === 'number') info.constantes[nombre] = dnr[nombre];
  }
  try {
    const respuesta = await fetch(chrome.runtime.getURL('rules/index.json'));
    const indice = await respuesta.json();
    info.reglasGeneradas = indice.reglasTotales;
    info.rulesets = indice.reglasPorRuleset.map((r) => ({
      id: r.id,
      reglas: r.reglas,
      hosts: r.hosts.length
    }));
  } catch (error) {
    info.errorIndice = String(error);
  }
  return info;
}

async function testMatch(url, recurso) {
  const resultado = await chrome.declarativeNetRequest.testMatchOutcome({
    url,
    type: recurso || 'script',
    initiator: 'https://example.com'
  });
  return {
    url,
    tipo: recurso || 'script',
    reglasCoincidentes: resultado.matchedRules.map((r) => ({
      ruleId: r.ruleId,
      rulesetId: r.rulesetId
    }))
  };
}

chrome.runtime.onMessage.addListener((mensaje, remitente, responder) => {
  (async () => {
    try {
      if (mensaje && mensaje.tipo === 'limites') responder(await limites());
      else if (mensaje && mensaje.tipo === 'match') responder(await testMatch(mensaje.url, mensaje.recurso));
      else responder({ error: 'orden desconocida' });
    } catch (error) {
      responder({ error: String(error) });
    }
  })();
  return true;
});

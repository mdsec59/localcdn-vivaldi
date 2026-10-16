/**
 * Custom URLs — permite al usuario añadir sus propios mapeos CDN -> recurso local.
 * Belongs to LocalCDN (Vivaldi port).
 *
 * Cada entrada: {id, label, pattern, matchType: 'glob'|'regex', resource, enabled, created}
 * y se guarda en chrome.storage.local bajo la clave `customUrls`.
 *
 * Este módulo es autónomo: registra su propio listener bloqueante de webRequest para los
 * hosts de las entradas personalizadas, por lo que no depende de core/mappings.js.
 * Precedencia: al registrarse antes que los listeners por pestaña del upstream, una regla
 * personalizada gana cuando ambas coinciden.
 *
 * @license MPL 2.0
 */

'use strict';


/**
 * Custom URLs
 */

const customUrls = {};

customUrls.STORAGE_KEY = 'customUrls';
customUrls.MESSAGE_PREFIX = 'customUrls:';

customUrls.entries = [];
customUrls._compiled = {};
customUrls._listener = null;
customUrls._listenerUrls = [];
customUrls._indexPromise = null;


/**
 * Utilidades de patrones
 */

customUrls.escapeRegExp = function (value) {
    return value.replace(/[.+^${}()|[\]\\]/g, '\\$&');
};

customUrls.patternToRegExp = function (pattern, matchType) {
    if (matchType === 'regex') {
        return new RegExp(pattern);
    }
    const escaped = customUrls.escapeRegExp(pattern).replace(/\*/g, '.*').replace(/\?/g, '.');
    return new RegExp(`^${escaped}$`);
};

/**
 * Deduce el host de un patrón para poder filtrar en webRequest.
 * webRequest exige patrones de coincidencia, no expresiones regulares.
 */
customUrls.hostFromPattern = function (pattern) {
    const cleaned = String(pattern).replace(/\\/g, '');
    const candidates = cleaned.match(/[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+/gi) || [];
    const looksLikeFile = /\.(js|mjs|jsm|css|cssm|json|map|min|png|jpe?g|gif|svg|ico|woff2?|ttf|otf|eot|txt|xml)$/i;

    for (const candidate of candidates) {
        if (!looksLikeFile.test(candidate)) {
            return candidate.toLowerCase();
        }
    }
    return null;
};

customUrls.filenameFromUrl = function (url) {
    try {
        const pathname = new URL(url).pathname;
        return pathname.split('/').filter(Boolean).pop() || '';
    } catch (err) {
        return String(url).split('?')[0].split('/').filter(Boolean).pop() || '';
    }
};


/**
 * Persistencia
 */

customUrls.normalizeEntry = function (entry) {
    return {
        'id': entry.id || customUrls._newId(),
        'label': entry.label || '',
        'pattern': entry.pattern || '',
        'matchType': entry.matchType === 'regex' ? 'regex' : 'glob',
        'resource': entry.resource || '',
        'enabled': entry.enabled !== false,
        'created': entry.created || Date.now()
    };
};

customUrls._newId = function () {
    return `cu_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
};

customUrls.load = function () {
    return new Promise((resolve) => {
        chrome.storage.local.get(customUrls.STORAGE_KEY, function (items) {
            const stored = items[customUrls.STORAGE_KEY];
            customUrls.entries = Array.isArray(stored)
                ? stored.map(customUrls.normalizeEntry)
                : [];
            resolve(customUrls.entries);
        });
    });
};

customUrls.save = function () {
    return new Promise((resolve) => {
        chrome.storage.local.set({[customUrls.STORAGE_KEY]: customUrls.entries}, resolve);
    });
};


/**
 * Validación
 */

customUrls.validateEntry = async function (entry) {
    const normalized = customUrls.normalizeEntry(entry);

    if (!normalized.pattern.trim()) {
        return {'ok': false, 'error': 'emptyPattern'};
    }
    try {
        customUrls.patternToRegExp(normalized.pattern, normalized.matchType);
    } catch (err) {
        return {'ok': false, 'error': 'invalidRegex', 'detail': String(err)};
    }
    if (!customUrls.hostFromPattern(normalized.pattern)) {
        return {'ok': false, 'error': 'noHost'};
    }
    const resource = await customUrls.checkResource(normalized.resource);
    if (!resource.ok) {
        return resource;
    }
    if (!normalized.label) {
        normalized.label = `${customUrls.hostFromPattern(normalized.pattern)} · ${customUrls.filenameFromUrl(normalized.pattern).replace(/\*/g, 'x')}`;
    }
    return {'ok': true, 'entry': normalized};
};

customUrls.checkResource = async function (resource) {
    if (!resource || !/^resources\//.test(resource)) {
        return {'ok': false, 'error': 'badResourcePath'};
    }
    const index = await customUrls.resourceIndex();
    if (index.length === 0) {
        // Sin índice (build incompleto) no bloqueamos al usuario, pero avisamos.
        return {'ok': true, 'warning': 'indexUnavailable'};
    }
    if (!index.includes(resource)) {
        return {'ok': false, 'error': 'resourceNotFound'};
    }
    return {'ok': true};
};

/**
 * Índice de recursos locales (resources-index.json, en la raíz de la extensión).
 *
 * No se puede comprobar un recurso con fetch() directo: cualquier petición a
 * resources/* sin el secreto de fileGuard (core/file-guard.js) se redirige a la raíz
 * de la extensión. El índice, al estar en la raíz, sí es accesible desde el
 * background, y además evita leer 2000+ ficheros.
 */
customUrls.resourceIndex = function () {
    if (!customUrls._indexPromise) {
        customUrls._indexPromise = fetch(chrome.runtime.getURL('resources-index.json'))
            .then((response) => (response.ok ? response.json() : []))
            .catch((err) => {
                console.warn(`${LogString.PREFIX} no se pudo cargar resources-index.json: ${err}`);
                return [];
            });
    }
    return customUrls._indexPromise;
};


/**
 * Intercepción
 */

customUrls.matchUrl = function (url) {
    for (const entry of customUrls.entries) {
        if (entry.enabled === false) {
            continue;
        }
        const expression = customUrls._compiled[entry.id];
        if (expression && expression.test(url)) {
            return {'entry': entry, 'redirectUrl': customUrls.redirectUrlFor(entry)};
        }
    }
    return null;
};

/**
 * URL de destino para una entrada.
 *
 * Es imprescindible firmarla con el secreto del "file guard": cualquier petición a
 * chrome-extension://<id>/resources/* que no acabe en ese secreto es redirigida a la raíz
 * de la extensión y no se sirve el recurso.
 */
customUrls.redirectUrlFor = function (entry) {
    const url = chrome.runtime.getURL(entry.resource);
    if (typeof fileGuard === 'undefined') {
        return url;
    }
    return typeof fileGuard.signed === 'function' ? fileGuard.signed(url) : url + fileGuard.secret;
};

customUrls._onBeforeRequest = function (requestDetails) {
    if (requestDetails.method !== 'GET') {
        return {};
    }
    const match = customUrls.matchUrl(requestDetails.url);
    if (!match) {
        return {};
    }
    console.log(`${LogString.PREFIX} custom url -> ${match.redirectUrl}`);
    customUrls._countInjection();
    return {'redirectUrl': match.redirectUrl};
};

customUrls._countInjection = function () {
    chrome.storage.local.get('amountInjected', function (items) {
        chrome.storage.local.set({'amountInjected': (items.amountInjected || 0) + 1});
    });
};

customUrls._compileAll = function () {
    customUrls._compiled = {};
    for (const entry of customUrls.entries) {
        try {
            customUrls._compiled[entry.id] = customUrls.patternToRegExp(entry.pattern, entry.matchType);
        } catch (err) {
            console.warn(`${LogString.PREFIX} custom url: patrón inválido (${entry.pattern})`);
        }
    }
};

customUrls.disable = function () {
    if (customUrls._listener) {
        chrome.webRequest.onBeforeRequest.removeListener(customUrls._listener);
        customUrls._listener = null;
        customUrls._listenerUrls = [];
    }
};

customUrls.enable = function () {
    const urls = [];

    customUrls.disable();

    for (const entry of customUrls.entries) {
        if (entry.enabled === false) {
            continue;
        }
        const host = customUrls.hostFromPattern(entry.pattern);
        if (!host) {
            continue;
        }
        const filter = `*://${host}/*`;
        if (!urls.includes(filter)) {
            urls.push(filter);
        }
    }

    if (urls.length === 0) {
        return;
    }

    customUrls._listenerUrls = urls;
    customUrls._listener = customUrls._onBeforeRequest;
    chrome.webRequest.onBeforeRequest.addListener(customUrls._listener, {'urls': urls}, ['blocking']);
    console.log(`${LogString.PREFIX} custom urls activas: ${urls.length} host(s)`);
};

customUrls.reload = async function () {
    await customUrls.load();
    customUrls._compileAll();
    customUrls.enable();
    return customUrls.entries;
};


/**
 * API para la página de opciones
 */

customUrls.addEntry = async function (entry) {
    const validation = await customUrls.validateEntry(entry);
    if (!validation.ok) {
        return validation;
    }
    customUrls.entries.push(validation.entry);
    await customUrls.save();
    await customUrls.reload();
    return {'ok': true, 'entry': validation.entry};
};

customUrls.removeEntry = async function (id) {
    customUrls.entries = customUrls.entries.filter((entry) => entry.id !== id);
    await customUrls.save();
    await customUrls.reload();
    return {'ok': true};
};

customUrls.toggleEntry = async function (id) {
    const entry = customUrls.entries.find((item) => item.id === id);
    if (!entry) {
        return {'ok': false, 'error': 'notFound'};
    }
    entry.enabled = entry.enabled === false;
    await customUrls.save();
    await customUrls.reload();
    return {'ok': true, 'enabled': entry.enabled};
};

customUrls.clearEntries = async function () {
    customUrls.entries = [];
    await customUrls.save();
    await customUrls.reload();
    return {'ok': true};
};

customUrls.exportEntries = function () {
    return JSON.stringify(customUrls.entries, null, 2);
};

customUrls.importEntries = async function (json) {
    let parsed;
    try {
        parsed = JSON.parse(json);
    } catch (err) {
        return {'ok': false, 'error': 'invalidJson'};
    }
    if (!Array.isArray(parsed)) {
        return {'ok': false, 'error': 'notAnArray'};
    }

    const added = [];
    const errors = [];

    for (const item of parsed) {
        const validation = await customUrls.validateEntry(item);
        if (validation.ok) {
            const exists = customUrls.entries.some(
                (entry) => entry.pattern === validation.entry.pattern && entry.resource === validation.entry.resource);
            if (!exists) {
                customUrls.entries.push(validation.entry);
                added.push(validation.entry);
            }
        } else {
            errors.push({'pattern': (item && item.pattern) || '', 'error': validation.error});
        }
    }

    await customUrls.save();
    await customUrls.reload();
    return {'ok': true, 'added': added.length, 'errors': errors};
};


/**
 * Mensajería con la página de opciones
 */

customUrls._handleMessage = async function (message) {
    switch (message.topic) {
        case 'customUrls:list':
            return {'ok': true, 'entries': customUrls.entries};
        case 'customUrls:add':
            return customUrls.addEntry(message.entry);
        case 'customUrls:remove':
            return customUrls.removeEntry(message.id);
        case 'customUrls:toggle':
            return customUrls.toggleEntry(message.id);
        case 'customUrls:clear':
            return customUrls.clearEntries();
        case 'customUrls:export':
            return {'ok': true, 'json': customUrls.exportEntries()};
        case 'customUrls:import':
            return customUrls.importEntries(message.json);
        case 'customUrls:test': {
            const match = customUrls.matchUrl(message.url);
            return {'ok': true, 'match': match ? {'label': match.entry.label, 'resource': match.entry.resource,
                'redirectUrl': match.redirectUrl} : null};
        }
        case 'customUrls:hostOf':
            return {'ok': true, 'host': customUrls.hostFromPattern(message.pattern || '')};
        default:
            return {'ok': false, 'error': 'unknownTopic'};
    }
};

chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
    if (!message || typeof message.topic !== 'string' || message.topic.indexOf(customUrls.MESSAGE_PREFIX) !== 0) {
        return false;
    }
    customUrls._handleMessage(message).then(sendResponse).catch((err) => sendResponse({'ok': false, 'error': String(err)}));
    return true;
});

chrome.storage.onChanged.addListener(function (changes, area) {
    if (area === 'local' && changes[customUrls.STORAGE_KEY]) {
        const incoming = JSON.stringify(changes[customUrls.STORAGE_KEY].newValue || []);
        const current = JSON.stringify(customUrls.entries);
        if (incoming !== current) {
            customUrls.reload();
        }
    }
});


/**
 * Inicialización
 */

customUrls.init = function () {
    customUrls.reload().catch((err) => console.error(`${LogString.PREFIX} custom urls: ${err}`));
};

document.addEventListener('DOMContentLoaded', customUrls.init);

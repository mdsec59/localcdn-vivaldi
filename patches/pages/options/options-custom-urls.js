/**
 * Options (Custom URLs) — UI para añadir mapeos CDN -> recurso local.
 * Belongs to LocalCDN (Vivaldi port).
 *
 * Se inyecta como una pestaña más en pages/options/options.html y se comunica con el
 * background (core/custom-urls.js) por mensajes `customUrls:*`.
 *
 * @license MPL 2.0
 */

'use strict';


/**
 * Custom URLs (Options)
 */

const optionsCustomUrls = {};

optionsCustomUrls._index = [];
optionsCustomUrls._noticeTimer = null;


/**
 * Utilidades
 */

optionsCustomUrls._t = function (key, fallback) {
    return chrome.i18n.getMessage(key) || fallback;
};

optionsCustomUrls._escape = function (value) {
    return String(value === undefined || value === null ? '' : value)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
};

optionsCustomUrls._send = function (message) {
    return new Promise((resolve) => {
        chrome.runtime.sendMessage(message, function (response) {
            if (chrome.runtime.lastError) {
                resolve({'ok': false, 'error': chrome.runtime.lastError.message});
            } else {
                resolve(response || {'ok': false, 'error': 'noResponse'});
            }
        });
    });
};

optionsCustomUrls._notice = function (text, type) {
    const element = document.getElementById('custom-urls-notice');

    if (!element) {
        return;
    }
    element.textContent = text;
    element.className = `notice notice-${type === 'error' ? 'warning' : 'default'} custom-urls-notice`;
    clearTimeout(optionsCustomUrls._noticeTimer);
    optionsCustomUrls._noticeTimer = setTimeout(function () {
        element.className = 'notice notice-default hidden custom-urls-notice';
    }, 6000);
};

optionsCustomUrls._errorText = function (code, detail) {
    const texts = {
        'emptyPattern': optionsCustomUrls._t('customUrlsErrorEmptyPattern', 'Escribe una URL o patrón.'),
        'invalidRegex': optionsCustomUrls._t('customUrlsErrorInvalidRegex', 'La expresión regular no es válida.'),
        'noHost': optionsCustomUrls._t('customUrlsErrorNoHost', 'No se pudo deducir el dominio del patrón.'),
        'badResourcePath': optionsCustomUrls._t('customUrlsErrorBadResource', 'La ruta debe ser un recurso interno, p. ej. resources/jquery/3.7.1/jquery.min.jsm'),
        'resourceNotFound': optionsCustomUrls._t('customUrlsErrorResourceNotFound', 'El recurso local no existe en esta extensión.'),
        'invalidJson': optionsCustomUrls._t('customUrlsErrorInvalidJson', 'El JSON no es válido.'),
        'notAnArray': optionsCustomUrls._t('customUrlsErrorNotAnArray', 'El JSON debe ser una lista de entradas.')
    };
    return `${texts[code] || code}${detail ? ` (${detail})` : ''}`;
};


/**
 * Detección automática de recurso local a partir de una URL
 */

optionsCustomUrls._detectCandidates = function (url) {
    let pathname;

    try {
        pathname = new URL(url).pathname;
    } catch (err) {
        pathname = String(url);
    }

    const file = pathname.split('/').filter(Boolean).pop() || '';
    const directory = pathname.split('/').filter(Boolean).slice(-2, -1)[0] || '';
    const base = file
        .replace(/\.min\.(js|css)$/i, '')
        .replace(/\.(js|css)$/i, '')
        .replace(/[-.]\d+(\.\d+)*$/, '')
        .toLowerCase();
    const versions = (pathname.match(/\d+\.\d+(?:\.\d+)*/g) || []).map((value) => value.toLowerCase());
    const candidates = [];

    for (const resource of optionsCustomUrls._index) {
        const resourceFile = resource.split('/').pop().toLowerCase();
        const resourceBase = resourceFile
            .replace(/\.min\.(jsm|cssm|js|css)$/i, '')
            .replace(/\.(jsm|cssm|js|css)$/i, '');
        if (!base || (resourceBase !== base && resourceBase.indexOf(base) !== 0 && base.indexOf(resourceBase) !== 0)) {
            continue;
        }
        let score = 10;
        if (resourceBase === base) {
            score += 5;
        }
        if (directory && resource.toLowerCase().indexOf(directory.toLowerCase()) !== -1) {
            score += 8;
        }
        // Preferir la versión que aparece en la URL (p. ej. jquery@3.7.1 -> /3.7.1/).
        if (versions.some((version) => resource.toLowerCase().indexOf(version) !== -1)) {
            score += 30;
        }
        candidates.push({'resource': resource, 'score': score});
    }

    candidates.sort((a, b) => b.score - a.score || a.resource.length - b.resource.length);
    return candidates.slice(0, 25).map((item) => item.resource);
};


/**
 * Render
 */

optionsCustomUrls.init = function () {
    const tab = document.getElementById('custom-urls-tab');

    if (!tab) {
        return;
    }

    tab.innerHTML = optionsCustomUrls._template();
    optionsCustomUrls._registerEventListeners();
    optionsCustomUrls._loadIndex();
    optionsCustomUrls._refresh();
};

optionsCustomUrls._template = function () {
    return `
    <div class="option-group">
        <div class="option">
            <div class="title-option without-checkbox">${optionsCustomUrls._t('customUrlsTitle', 'Custom URLs (URLs personalizadas)')}</div>
            <p class="description-option without-checkbox">${optionsCustomUrls._t('customUrlsDescription',
                'Añade tus propios mapeos: cuando una web pida una URL que coincida con tu patrón, LocalCDN servirá el recurso local que elijas. Sirve para cubrir versiones o CDNs que la extensión todavía no conoce.')}</p>
            <div id="custom-urls-notice" class="notice notice-default hidden custom-urls-notice"></div>
        </div>
    </div>

    <div class="option-group">
        <div class="option">
            <div class="title-option without-checkbox">${optionsCustomUrls._t('customUrlsAddTitle', 'Añadir una URL')}</div>
            <div class="custom-urls-form">
                <label class="custom-urls-label" for="custom-urls-pattern">${optionsCustomUrls._t('customUrlsPattern', 'URL del CDN o patrón')}</label>
                <input id="custom-urls-pattern" class="input-text custom-urls-input" type="text"
                       placeholder="https://cdn.ejemplo.com/lib/1.2.3/lib.min.js" autocomplete="off">
                <label class="custom-urls-label" for="custom-urls-match-type">${optionsCustomUrls._t('customUrlsMatchType', 'Tipo de coincidencia')}</label>
                <select id="custom-urls-match-type" class="custom-urls-select">
                    <option value="glob">${optionsCustomUrls._t('customUrlsMatchGlob', 'Comodines (* y ?)')}</option>
                    <option value="regex">${optionsCustomUrls._t('customUrlsMatchRegex', 'Expresión regular')}</option>
                </select>
                <button id="custom-urls-detect" class="btns" type="button">${optionsCustomUrls._t('customUrlsDetect', 'Detectar recurso local')}</button>
                <label class="custom-urls-label" for="custom-urls-resource">${optionsCustomUrls._t('customUrlsResource', 'Recurso local de la extensión')}</label>
                <input id="custom-urls-resource" class="input-text custom-urls-input" type="text" list="custom-urls-resource-list"
                       placeholder="resources/jquery/3.7.1/jquery.min.jsm" autocomplete="off">
                <datalist id="custom-urls-resource-list"></datalist>
                <label class="custom-urls-label" for="custom-urls-label">${optionsCustomUrls._t('customUrlsLabel', 'Etiqueta (opcional)')}</label>
                <input id="custom-urls-label" class="input-text custom-urls-input" type="text" placeholder="jQuery 3.7.1" autocomplete="off">
                <button id="custom-urls-add" class="btns custom-urls-primary" type="button">${optionsCustomUrls._t('customUrlsAdd', 'Añadir URL')}</button>
            </div>
            <p class="description-option without-checkbox">${optionsCustomUrls._t('customUrlsHint',
                'Ejemplos: 1) URL exacta: https://cdn.ejemplo.com/lib/jquery-3.7.1.min.js   2) Con comodines: https://cdn.ejemplo.com/lib/*.min.js   3) Regex: ^https://cdn\\.ejemplo\\.com/lib/[0-9.]+/lib\\.min\\.js$')}</p>
        </div>
    </div>

    <div class="option-group">
        <div class="option">
            <div class="title-option without-checkbox">${optionsCustomUrls._t('customUrlsListTitle', 'URLs personalizadas activas')}</div>
            <table class="custom-urls-table">
                <thead>
                    <tr>
                        <th>${optionsCustomUrls._t('customUrlsColumnState', 'Estado')}</th>
                        <th>${optionsCustomUrls._t('customUrlsColumnPattern', 'Patrón')}</th>
                        <th>${optionsCustomUrls._t('customUrlsColumnResource', 'Recurso local')}</th>
                        <th>${optionsCustomUrls._t('customUrlsColumnActions', 'Acciones')}</th>
                    </tr>
                </thead>
                <tbody id="custom-urls-rows"></tbody>
            </table>
            <p id="custom-urls-empty" class="description-option without-checkbox">${optionsCustomUrls._t('customUrlsEmpty', 'Todavía no has añadido ninguna URL.')}</p>
        </div>
    </div>

    <div class="option-group">
        <div class="option">
            <div class="title-option without-checkbox">${optionsCustomUrls._t('customUrlsTestTitle', 'Probar una URL')}</div>
            <div class="custom-urls-test">
                <input id="custom-urls-test-url" class="input-text custom-urls-input" type="text"
                       placeholder="https://cdn.ejemplo.com/lib/1.2.3/lib.min.js" autocomplete="off">
                <button id="custom-urls-test-button" class="btns" type="button">${optionsCustomUrls._t('customUrlsTest', 'Probar')}</button>
            </div>
            <p id="custom-urls-test-result" class="description-option without-checkbox"></p>
        </div>
    </div>

    <div class="option-group">
        <div class="option">
            <div class="title-option without-checkbox">${optionsCustomUrls._t('customUrlsImportExportTitle', 'Importar / exportar')}</div>
            <textarea rows="7" id="custom-urls-json" class="input-text without-checkbox" spellcheck="false"></textarea>
            <div class="import-export">
                <input id="custom-urls-export" type="button" value="${optionsCustomUrls._t('customUrlsExport', 'Exportar')}">
                <input id="custom-urls-import" type="button" value="${optionsCustomUrls._t('customUrlsImport', 'Importar')}">
                <input id="custom-urls-clear" type="button" value="${optionsCustomUrls._t('customUrlsClear', 'Borrar todo')}">
            </div>
            <p class="description-option without-checkbox">${optionsCustomUrls._t('customUrlsImportHint',
                'Puedes pegar una lista JSON de entradas y pulsar Importar. Formato: [{"pattern": "...", "resource": "resources/..."}]')}</p>
        </div>
    </div>

    <div class="option-group">
        <div class="option">
            <p class="description-option without-checkbox">${optionsCustomUrls._t('customUrlsResourceHint',
                'Los recursos disponibles son los que ya incluye la extensión (carpeta resources/). Para tener recursos más recientes, actualiza desde el repositorio (tools/update-upstream.sh) y vuelve a construir.')}</p>
        </div>
    </div>`;
};

optionsCustomUrls._registerEventListeners = function () {
    const tabButton = document.getElementById('btn-custom-urls-tab');

    if (tabButton) {
        tabButton.addEventListener('click', optionsCustomUrls._onTabClick);
    }
    document.getElementById('custom-urls-add').addEventListener('click', optionsCustomUrls._onAdd);
    document.getElementById('custom-urls-detect').addEventListener('click', optionsCustomUrls._onDetect);
    document.getElementById('custom-urls-export').addEventListener('click', optionsCustomUrls._onExport);
    document.getElementById('custom-urls-import').addEventListener('click', optionsCustomUrls._onImport);
    document.getElementById('custom-urls-clear').addEventListener('click', optionsCustomUrls._onClear);
    document.getElementById('custom-urls-test-button').addEventListener('click', optionsCustomUrls._onTest);

    document.getElementById('custom-urls-rows').addEventListener('click', optionsCustomUrls._onRowAction);
};

/**
 * Cambio de pestaña: reutiliza la lógica del upstream si está disponible
 * (options._changeTab) y si no, hace un cambio mínimo autónomo.
 */
optionsCustomUrls._onTabClick = function (event) {
    if (typeof options !== 'undefined' && typeof options._changeTab === 'function') {
        options._changeTab(event);
        return;
    }

    const target = event.target.getAttribute('data-option-tab');
    for (const element of document.getElementsByClassName('tab-content')) {
        element.style.display = element.id === target ? 'block' : 'none';
    }
    for (const button of document.getElementsByClassName('option-buttons')) {
        button.classList.toggle('option-buttons-active', button === event.target);
    }
};

optionsCustomUrls._loadIndex = async function () {
    try {
        const response = await fetch('../../resources-index.json');
        optionsCustomUrls._index = await response.json();
    } catch (err) {
        console.warn('[ LocalCDN ] no se pudo cargar resources-index.json', err);
        return;
    }
    const list = document.getElementById('custom-urls-resource-list');
    if (list) {
        list.innerHTML = optionsCustomUrls._index.slice(0, 4000)
            .map((resource) => `<option value="${optionsCustomUrls._escape(resource)}"></option>`).join('');
    }
};

optionsCustomUrls._refresh = async function () {
    const response = await optionsCustomUrls._send({'topic': 'customUrls:list'});
    const entries = (response && response.entries) || [];

    document.getElementById('custom-urls-empty').style.display = entries.length ? 'none' : 'block';
    document.getElementById('custom-urls-rows').innerHTML = entries.map((entry) => `
        <tr class="${entry.enabled === false ? 'custom-urls-row-disabled' : ''}">
            <td><input type="checkbox" data-action="toggle" data-id="${optionsCustomUrls._escape(entry.id)}" ${entry.enabled === false ? '' : 'checked'}></td>
            <td><div class="custom-urls-cell">${optionsCustomUrls._escape(entry.label)}</div>
                <code class="custom-urls-code">${optionsCustomUrls._escape(entry.pattern)}</code>
                <span class="custom-urls-badge">${optionsCustomUrls._escape(entry.matchType)}</span></td>
            <td><code class="custom-urls-code">${optionsCustomUrls._escape(entry.resource)}</code></td>
            <td><button class="btns custom-urls-small" data-action="remove" data-id="${optionsCustomUrls._escape(entry.id)}">${optionsCustomUrls._t('customUrlsRemove', 'Quitar')}</button></td>
        </tr>`).join('');
};

optionsCustomUrls._onRowAction = async function (event) {
    const target = event.target;
    const action = target.getAttribute('data-action');
    const id = target.getAttribute('data-id');

    if (!action || !id) {
        return;
    }
    if (action === 'remove') {
        await optionsCustomUrls._send({'topic': 'customUrls:remove', 'id': id});
        optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsRemoved', 'URL eliminada.'), 'ok');
    } else if (action === 'toggle') {
        await optionsCustomUrls._send({'topic': 'customUrls:toggle', 'id': id});
        optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsToggled', 'Estado actualizado.'), 'ok');
    }
    optionsCustomUrls._refresh();
};

optionsCustomUrls._onAdd = async function () {
    const entry = {
        'pattern': document.getElementById('custom-urls-pattern').value.trim(),
        'matchType': document.getElementById('custom-urls-match-type').value,
        'resource': document.getElementById('custom-urls-resource').value.trim(),
        'label': document.getElementById('custom-urls-label').value.trim()
    };
    const response = await optionsCustomUrls._send({'topic': 'customUrls:add', 'entry': entry});

    if (!response.ok) {
        optionsCustomUrls._notice(optionsCustomUrls._errorText(response.error, response.detail), 'error');
        return;
    }
    optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsAdded', 'URL añadida y activa.'), 'ok');
    document.getElementById('custom-urls-pattern').value = '';
    document.getElementById('custom-urls-resource').value = '';
    document.getElementById('custom-urls-label').value = '';
    optionsCustomUrls._refresh();
};

optionsCustomUrls._onDetect = async function () {
    const url = document.getElementById('custom-urls-pattern').value.trim();

    if (!url) {
        optionsCustomUrls._notice(optionsCustomUrls._errorText('emptyPattern'), 'error');
        return;
    }
    const candidates = optionsCustomUrls._detectCandidates(url.replace(/\*/g, 'x'));

    if (candidates.length === 0) {
        optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsNoCandidates',
            'No se encontró un recurso local parecido. Elige una ruta de la lista (resources/…).'), 'error');
        return;
    }
    document.getElementById('custom-urls-resource').value = candidates[0];
    optionsCustomUrls._notice(`${optionsCustomUrls._t('customUrlsCandidates', 'Candidatos encontrados:')} ${candidates.length}`, 'ok');
};

optionsCustomUrls._onTest = async function () {
    const url = document.getElementById('custom-urls-test-url').value.trim();
    const result = document.getElementById('custom-urls-test-result');

    if (!url) {
        result.textContent = optionsCustomUrls._errorText('emptyPattern');
        return;
    }
    const response = await optionsCustomUrls._send({'topic': 'customUrls:test', 'url': url});

    if (!response.ok) {
        result.textContent = optionsCustomUrls._errorText(response.error);
        return;
    }
    if (!response.match) {
        result.textContent = optionsCustomUrls._t('customUrlsTestNoMatch', 'Ninguna URL personalizada coincide con esa dirección.');
        return;
    }
    result.textContent = `${optionsCustomUrls._t('customUrlsTestMatch', '¡Coincide!')} ${response.match.label} → ${response.match.redirectUrl}`;
};

optionsCustomUrls._onExport = async function () {
    const response = await optionsCustomUrls._send({'topic': 'customUrls:export'});

    if (response.ok) {
        document.getElementById('custom-urls-json').value = response.json;
        optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsExported', 'Lista exportada al cuadro de texto.'), 'ok');
    }
};

optionsCustomUrls._onImport = async function () {
    const json = document.getElementById('custom-urls-json').value.trim();
    const response = await optionsCustomUrls._send({'topic': 'customUrls:import', 'json': json});

    if (!response.ok) {
        optionsCustomUrls._notice(optionsCustomUrls._errorText(response.error), 'error');
        return;
    }
    const errors = (response.errors || []).length;
    optionsCustomUrls._notice(`${optionsCustomUrls._t('customUrlsImported', 'Importadas:')} ${response.added}` +
        (errors ? ` · ${optionsCustomUrls._t('customUrlsImportErrors', 'con errores:')} ${errors}` : ''), errors ? 'error' : 'ok');
    optionsCustomUrls._refresh();
};

optionsCustomUrls._onClear = async function () {
    await optionsCustomUrls._send({'topic': 'customUrls:clear'});
    optionsCustomUrls._notice(optionsCustomUrls._t('customUrlsCleared', 'Se han borrado todas las URLs personalizadas.'), 'ok');
    optionsCustomUrls._refresh();
};

document.addEventListener('DOMContentLoaded', optionsCustomUrls.init);

/*
    app.js — AutoSort Web UI.

    Talks to the add-on over /api/*. Every request carries the session token
    that the add-on put in this page's URL; without it the server replies 403.

    All rendering uses textContent or escaped interpolation, so an item name
    can never inject markup.
*/

'use strict';

const TOKEN = new URLSearchParams(location.search).get('token') || '';

const state = {
    bags: [],          // live bag contents
    catalog: [],       // every bag, available or not
    rules: [],         // working copy, saved on demand
    savedRules: '[]',  // serialized last-saved rules, for Revert
    options: {},
    categories: [],
    slots: [],
    showIcons: localStorage.getItem('autosort.icons') !== 'false',
    pending: null,     // item awaiting the rule-builder modal
    progressTimer: null,
    defaultsInfo: null,   // built-in default groups as described by the add-on
    savedDefaults: '{}',  // serialized last-saved defaults, for Revert and dirty checks
};

/* ------------------------------------------------------------------ utils */

const $ = (id) => document.getElementById(id);

function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
}

let toastTimer;
function toast(msg, kind) {
    const t = $('toast');
    t.textContent = msg;
    t.className = 'toast show' + (kind ? ' ' + kind : '');
    clearTimeout(toastTimer);
    // Errors and warnings stay up long enough to read and copy.
    const ms = kind === 'bad' ? 12000 : kind === 'warn' ? 7000 : 3200;
    toastTimer = setTimeout(() => { t.className = 'toast'; }, ms);
}

async function call(path, options) {
    const opts = Object.assign({ headers: {} }, options || {});
    opts.headers['X-AutoSort-Token'] = TOKEN;
    if (opts.body) opts.headers['Content-Type'] = 'application/json';

    const res = await fetch('/api/' + path, opts);
    const data = await res.json().catch(() => ({ ok: false, error: 'bad response' }));
    if (!res.ok || data.ok === false) {
        throw new Error(data.error || ('HTTP ' + res.status));
    }
    return data;
}

function iconFor(id) {
    if (!state.showIcons || !id) return '';
    return `<img class="icon" loading="lazy" alt=""
        src="https://static.ffxiah.com/images/icon/${Number(id)}.png"
        onerror="this.style.visibility='hidden'">`;
}

/* ------------------------------------------------------------------- tabs */

document.querySelectorAll('.tab').forEach((btn) => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach((b) => b.classList.remove('active'));
        document.querySelectorAll('.panel').forEach((p) => p.classList.remove('active'));
        btn.classList.add('active');
        $('tab-' + btn.dataset.tab).classList.add('active');
        if (btn.dataset.tab === 'status') loadStatus();
        if (btn.dataset.tab === 'layout' && window.Layout) window.Layout.onShow();
        if (btn.dataset.tab === 'run') updateDirtyUi();
    });
});

/* --------------------------------------------------------------- inventory */

async function loadStatus() {
    try {
        const data = await call('status');
        state.bags = data.bags || [];
        $('character').textContent = data.character || '—';
        $('conn').textContent = 'connected';
        $('conn').className = 'conn ok';
        renderBags();
    } catch (err) {
        $('conn').textContent = 'disconnected';
        $('conn').className = 'conn bad';
        $('bag-list').innerHTML =
            `<p class="empty">Could not reach the add-on: ${esc(err.message)}</p>`;
    }
}

function renderBags() {
    const filter = $('item-filter').value.trim().toLowerCase();
    const hideEmpty = $('hide-empty').checked;
    const out = [];

    state.bags.forEach((bag) => {
        const matches = bag.items.filter(
            (it) => !filter || it.name.toLowerCase().includes(filter));
        if (hideEmpty && matches.length === 0) return;

        const pct = bag.max ? Math.round((bag.used / bag.max) * 100) : 0;
        const rows = matches.map((it) => {
            const tags = [];
            if (it.locked) tags.push('<span class="tag lock">equipped</span>');
            if (it.rare) tags.push('<span class="tag">Rare</span>');
            if (it.ex) tags.push('<span class="tag">Ex</span>');
            return `<li class="item${it.locked ? ' locked' : ''}"
                 data-id="${Number(it.id)}" data-name="${esc(it.name)}"
                 data-category="${esc(it.category)}" data-slot="${esc(it.slot_name || '')}">
                ${iconFor(it.id)}
                <span class="nm">${esc(it.name)}</span>
                ${it.count > 1 ? `<span class="ct">x${Number(it.count)}</span>` : ''}
                <span class="cat">${esc(it.slot_name || it.category)}</span>
                ${tags.join('')}
            </li>`;
        }).join('');

        out.push(`<div class="bag">
            <div class="bag-head">
                <strong>${esc(bag.name)}</strong>
                <span class="muted">${bag.used}/${bag.max}</span>
                <div class="meter"><div style="width:${pct}%"></div></div>
            </div>
            <ul class="items">${rows || '<li class="empty">No matching items</li>'}</ul>
        </div>`);
    });

    $('bag-list').innerHTML = out.join('') ||
        '<p class="empty">No accessible bags. Are you logged in?</p>';

    document.querySelectorAll('.item:not(.locked)').forEach((el) => {
        el.addEventListener('click', () => openRuleBuilder(el.dataset));
    });
}

$('item-filter').addEventListener('input', renderBags);
$('hide-empty').addEventListener('change', renderBags);
$('refresh-status').addEventListener('click', loadStatus);

/* ------------------------------------------------------- rule builder modal */

function destOptions(selected) {
    const opts = ['<option value="keep">Keep in place</option>'];
    state.catalog.forEach((b) => {
        const label = b.name + (b.available ? '' : ' (not accessible)')
            + (b.accepts === 'equipment' ? ' — gear only'
                : b.accepts === 'furniture' ? ' — furniture only' : '');
        opts.push(`<option value="${esc(b.key)}"${b.key === selected ? ' selected' : ''}>${esc(label)}</option>`);
    });
    return opts.join('');
}

function openRuleBuilder(data) {
    state.pending = data;
    $('modal-item').textContent = data.name;

    const kind = $('modal-kind');
    kind.innerHTML =
        `<option value="exact">this exact item (${esc(data.name)})</option>
         <option value="category">every ${esc(data.category)} item</option>` +
        (data.slot ? `<option value="slot">every ${esc(data.slot)} item</option>` : '');

    $('modal-dest').innerHTML = destOptions();
    $('modal').classList.remove('hidden');
}

$('modal-cancel').addEventListener('click', () => {
    $('modal').classList.add('hidden');
    state.pending = null;
});

$('modal-add').addEventListener('click', () => {
    const d = state.pending;
    if (!d) return;
    const kind = $('modal-kind').value;
    const rule = { to: $('modal-dest').value };

    if (kind === 'exact') rule.match = d.name;
    else if (kind === 'category') rule.category = d.category;
    else rule.category = d.slot;

    // Specific rules are useless below a broad one, so exact-name rules go to
    // the top and category rules to the bottom.
    if (kind === 'exact') state.rules.unshift(rule);
    else state.rules.push(rule);

    $('modal').classList.add('hidden');
    state.pending = null;
    renderRules();
    toast('Rule added. Remember to save.', 'warn');
});

/* ------------------------------------------------------------------- rules */

function renderRulesInner() {
    const list = $('rule-list');
    $('rule-empty').style.display = state.rules.length ? 'none' : 'block';

    list.innerHTML = state.rules.map((r, i) => {
        const catOpts = ['<option value="">Any</option>']
            .concat(state.categories.map((c) =>
                `<option value="${esc(c)}"${r.category === c ? ' selected' : ''}>${esc(c)}</option>`))
            .concat(['<option disabled>— equipment slots —</option>'])
            .concat(state.slots.map((s) =>
                `<option value="${esc(s)}"${r.category === s ? ' selected' : ''}>${esc(s)}</option>`))
            .join('');

        return `<div class="rule${isBlank(r) ? ' blank' : ''}" data-i="${i}"
            ${isBlank(r) ? 'title="Blank rules are ignored. Give it a name or a category."' : ''}>
            <div class="ord">
                <button class="mini" data-act="up" ${i === 0 ? 'disabled' : ''}>▲</button>
                <span>${i + 1}</span>
                <button class="mini" data-act="down" ${i === state.rules.length - 1 ? 'disabled' : ''}>▼</button>
            </div>
            <input type="text" data-field="match" placeholder="e.g. *Crystal"
                   value="${esc(r.match || '')}">
            <select data-field="category">${catOpts}</select>
            <select data-field="to">${destOptions(r.to)}</select>
            <button class="mini del" data-act="del">✕</button>
        </div>`;
    }).join('');

    list.querySelectorAll('.rule').forEach((row) => {
        const i = Number(row.dataset.i);
        row.querySelectorAll('[data-field]').forEach((input) => {
            input.addEventListener('change', () => {
                const v = input.value;
                const f = input.dataset.field;
                state.rules[i][f] = v === '' ? undefined : v;
            });
        });
        row.querySelectorAll('[data-act]').forEach((btn) => {
            btn.addEventListener('click', () => {
                const act = btn.dataset.act;
                if (act === 'del') state.rules.splice(i, 1);
                else if (act === 'up' && i > 0) {
                    [state.rules[i - 1], state.rules[i]] = [state.rules[i], state.rules[i - 1]];
                } else if (act === 'down' && i < state.rules.length - 1) {
                    [state.rules[i + 1], state.rules[i]] = [state.rules[i], state.rules[i + 1]];
                }
                renderRules();
            });
        });
    });
}

$('add-rule').addEventListener('click', () => {
    state.rules.push({ match: '', category: '', to: 'satchel' });
    renderRules();
});

/* --------------------------------------------- working copy vs saved copy */

/* A rule with no name and no category would match EVERY item and override all
   the built-in defaults, so an empty row is never saved or previewed. */
function isBlank(r) { return !r.match && !r.category; }

function cleanRules() {
    return state.rules
        .filter((r) => r.to && !isBlank(r))
        .map((r) => ({
            match: r.match || undefined,
            category: r.category || undefined,
            to: r.to,
        }));
}
window.cleanRules = cleanRules;

/* Compare rules and defaults by VALUE. The add-on's JSON has no stable key
   order (Lua tables are unordered), so comparing raw JSON text reports
   "unsaved changes" for rules that are actually identical. */
function canonRules(list) {
    return JSON.stringify(list.filter((r) => !isBlank(r))
        .map((r) => [r.match || '', r.category || '', r.to || '']));
}
function canonDefaults(d) {
    const o = {};
    Object.keys(d || {}).sort().forEach((k) => { o[k] = d[k]; });
    return JSON.stringify(o);
}

function isDirty() {
    return canonRules(cleanRules()) !== canonRules(JSON.parse(state.savedRules)) ||
           canonDefaults(state.options.defaults) !== canonDefaults(JSON.parse(state.savedDefaults));
}

/* Everything that shows "you have unsaved changes" hangs off this. */
function updateDirtyUi() {
    const dirty = isDirty();
    ['lay-dirty', 'rules-dirty'].forEach((id) => { const el = $(id); if (el) el.classList.toggle('hidden', !dirty); });
    ['lay-save', 'lay-revert'].forEach((id) => { const el = $(id); if (el) el.disabled = !dirty; });
    const banner = $('run-dirty');
    if (banner) banner.classList.toggle('hidden', !dirty);
}

function rulesChanged() {
    updateDirtyUi();
    if (window.Layout) window.Layout.onRulesChanged();
}

function renderRules() { renderRulesInner(); rulesChanged(); }

function revertAll() {
    state.rules = JSON.parse(state.savedRules);
    state.options.defaults = JSON.parse(state.savedDefaults);
    renderDefaults();
    renderRules();
    toast('Reverted to the saved rules.');
}
window.revertAll = revertAll;

$('revert-rules').addEventListener('click', revertAll);

async function saveAll() {
    const blanks = state.rules.filter(isBlank).length;
    const clean = cleanRules();

    const options = {
        delay: Number($('opt-delay').value) || 0.8,
        keep_free: Number($('opt-keepfree').value) || 0,
        protect_gear: $('opt-gear').checked,
        protect: $('opt-protect').value.split('\n')
            .map((s) => s.trim()).filter(Boolean),
        defaults: state.options.defaults,
    };

    const data = await call('settings', {
        method: 'POST',
        body: JSON.stringify({ rules: clean, options: options }),
    });
    applySettings(data);
    if (data.dropped && data.dropped.length) {
        toast('Saved, but dropped: ' + data.dropped.join('; '), 'warn');
    } else if (blanks) {
        toast(`Saved. ${blanks} blank rule(s) were skipped: give a rule a name or category.`, 'warn');
    } else {
        toast('Saved to ' + (data.saved_to || 'the rule file'), 'ok');
    }
}

window.saveAll = saveAll;

$('save-rules').addEventListener('click', () => saveAll().catch((e) => toast(e.message, 'bad')));
$('save-options').addEventListener('click', () => saveAll().catch((e) => toast(e.message, 'bad')));

/* ---------------------------------------------------------- built-in defaults */

function renderDefaults() {
    const info = state.defaultsInfo;
    const d = state.options.defaults || {};
    const box = $('def-groups');
    if (!info || !box) return;

    $('def-enabled').checked = d.enabled !== false;
    box.classList.toggle('off', d.enabled === false);

    const free = d.inventory_free;
    const opts = ['auto', 5, 10, 15, 20, 25, 30, 40];
    if (typeof free === 'number' && opts.indexOf(free) === -1) opts.push(free);
    $('def-free').innerHTML = opts.map((o) => {
        const label = o === 'auto' ? `auto (${info.inventory_free_effective})` : String(o);
        return `<option value="${o}"${o === free ? ' selected' : ''}>${esc(label)}</option>`;
    }).join('');

    box.innerHTML = info.groups.map((g) => {
        const on = d[g.id] !== false;
        const chain = g.chain.map((c) =>
            `<span class="link${c.available ? '' : ' na'}" title="${c.available ? '' : 'Not accessible right now'}">${esc(c.name)}</span>`
        ).join('<span class="arrow">›</span>');
        return `<div class="def-row${on ? '' : ' off'}">
            <label class="check"><input type="checkbox" data-group="${esc(g.id)}"${on ? ' checked' : ''}>
                <strong>${esc(g.label)}</strong></label>
            ${g.soft ? '<span class="tag">only if Inventory is crowded</span>' : ''}
            ${g.keep ? '<span class="tag">stays put</span>' : ''}
            <div class="muted">${esc(g.description)}</div>
            ${chain ? `<div class="chain">${chain}</div>` : ''}
        </div>`;
    }).join('');
}

$('def-enabled').addEventListener('change', (e) => {
    state.options.defaults.enabled = e.target.checked;
    renderDefaults(); rulesChanged();
});
$('def-free').addEventListener('change', (e) => {
    const v = e.target.value;
    state.options.defaults.inventory_free = v === 'auto' ? 'auto' : Number(v);
    rulesChanged();
});
$('def-groups').addEventListener('change', (e) => {
    const g = e.target.dataset && e.target.dataset.group;
    if (!g) return;
    state.options.defaults[g] = e.target.checked;
    renderDefaults(); rulesChanged();
});

/* ---------------------------------------------------------------- settings */

function applySettings(data) {
    state.rules = (data.rules || []).map((r) => Object.assign({}, r));
    state.savedRules = JSON.stringify(state.rules);
    state.options = data.options || {};
    state.options.defaults = state.options.defaults || {};
    state.savedDefaults = JSON.stringify(state.options.defaults);
    state.defaultsInfo = data.defaults || null;
    state.categories = data.categories || [];
    state.slots = data.slots || [];
    state.catalog = data.bags || [];

    $('character').textContent = data.character || '—';
    $('rule-file').textContent = data.rule_file || '';
    $('opt-delay').value = state.options.delay ?? 0.8;
    $('opt-keepfree').value = state.options.keep_free ?? 0;
    $('opt-gear').checked = state.options.protect_gear !== false;
    $('opt-protect').value = (state.options.protect || []).join('\n');
    $('opt-icons').checked = state.showIcons;
    $('gear-count').textContent = data.gear_protected
        ? `Currently protecting ${data.gear_protected} item(s).` : '';

    const sel = $('preview-bag');
    sel.innerHTML = '<option value="">All bags</option>' +
        state.catalog.filter((b) => b.available)
            .map((b) => `<option value="${esc(b.key)}">${esc(b.name)}</option>`).join('');

    (data.problems || []).forEach((p) => toast('Rule file: ' + p, 'warn'));
    renderDefaults();
    renderRules();
}

$('opt-icons').addEventListener('change', (e) => {
    state.showIcons = e.target.checked;
    localStorage.setItem('autosort.icons', String(state.showIcons));
    renderBags();
});

/* ------------------------------------------------------------ preview / run */

async function doPreview() {
    try {
        const bag = $('preview-bag').value;
        const data = await call('preview', {
            method: 'POST',
            body: JSON.stringify({ bag: bag || undefined }),
        });
        renderPreview(data);
        $('do-execute').disabled = data.moves.length === 0;
    } catch (err) {
        toast(err.message, 'bad');
    }
}

function renderPreview(p) {
    $('move-count').textContent = p.moves.length;
    $('issue-count').textContent = p.blocked.length + p.skipped.length;

    const parts = [`<strong>${p.moves.length}</strong> move(s)`];
    if (p.blocked.length) parts.push(`<span class="bad">${p.blocked.length} blocked</span>`);
    if (p.skipped.length) parts.push(`${p.skipped.length} protected or equipped`);
    if (p.unmatched) parts.push(`${p.unmatched} matched no rule`);
    if (p.inventory) parts.push(`Inventory ${p.inventory.free_before} free now, ${p.inventory.free_after} after (target ${p.inventory.target})`);
    $('preview-summary').innerHTML = parts.join(' &middot; ') +
        (p.warnings || []).map((w) => `<div class="warn">${esc(w)}</div>`).join('');

    $('move-list').innerHTML = p.moves.length ? p.moves.map((m) => `
        <div class="row">
            ${iconFor(m.item_id)}
            <span class="nm">${esc(m.name)}${m.count > 1 ? ` x${m.count}` : ''}</span>
            <span class="muted">${esc(m.from_name)} → <strong>${esc(m.to_name)}</strong></span>
            <span class="tag ${m.source === 'user' ? 'yours' : ''}">${m.source === 'user' ? 'your rule' : esc(String(m.rule_label || 'default').replace('default: ', ''))}</span>
            ${m.parked ? '<span class="tag">staging</span>' : ''}
            ${m.hops === 2 ? '<span class="tag">2 hops</span>' : ''}
        </div>`).join('')
        : '<p class="empty">Nothing to move.</p>';

    $('capacity-list').innerHTML = (p.capacity || [])
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((c) => {
            const pct = c.max ? Math.round((c.after / c.max) * 100) : 0;
            const delta = c.after - c.before;
            return `<div class="row">
                <span class="nm">${esc(c.name)}</span>
                <span class="muted">${c.before} → ${c.after} / ${c.max}
                    ${delta ? `<span class="${delta > 0 ? 'up' : 'down'}">${delta > 0 ? '+' : ''}${delta}</span>` : ''}</span>
                <div class="meter${c.over ? ' over' : ''}"><div style="width:${Math.min(100, pct)}%"></div></div>
            </div>`;
        }).join('');

    const issues = p.blocked.map((b) => `
        <div class="row bad-row">${iconFor(b.item_id)}
            <span class="nm">${esc(b.name)}</span>
            <span class="muted">${esc(b.reason)}</span></div>`)
        .concat(p.skipped.map((s) => `
        <div class="row">${iconFor(s.item_id)}
            <span class="nm">${esc(s.name)}</span>
            <span class="muted">${esc(s.reason)}</span></div>`));
    $('issue-list').innerHTML = issues.join('') ||
        '<p class="empty">Nothing blocked.</p>';
}

async function doExecute() {
    if (!confirm('Execute this sort? Items will be moved in game.')) return;
    try {
        const data = await call('execute', { method: 'POST' });
        if (!data.total) { toast(data.message || 'Nothing to move.'); return; }
        $('progress-wrap').classList.remove('hidden');
        $('do-execute').disabled = true;
        $('do-stop').disabled = false;
        watchProgress();
    } catch (err) {
        toast(err.message, 'bad');
    }
}

function watchProgress() {
    clearInterval(state.progressTimer);
    state.progressTimer = setInterval(async () => {
        try {
            const p = await call('progress');
            const pct = p.total ? Math.round(((p.completed + p.failed) / p.total) * 100) : 0;
            $('progress-bar').style.width = pct + '%';
            $('progress-text').textContent =
                `${p.completed} moved, ${p.failed} failed, of ${p.total}`;
            $('progress-log').textContent = (p.log || []).slice(-40).join('\n');

            if (!p.running) {
                clearInterval(state.progressTimer);
                $('do-stop').disabled = true;
                toast(p.aborted ? 'Sort stopped.'
                    : `Done: ${p.completed} moved, ${p.failed} failed.`,
                    p.failed ? 'warn' : 'ok');
                loadStatus();
                doPreview();
            }
        } catch (err) {
            clearInterval(state.progressTimer);
            toast('Lost contact with the add-on.', 'bad');
        }
    }, 600);
}

$('do-preview').addEventListener('click', doPreview);
$('do-execute').addEventListener('click', doExecute);
$('do-stop').addEventListener('click', async () => {
    try { await call('stop', { method: 'POST' }); } catch (e) { toast(e.message, 'bad'); }
});

/* -------------------------------------------------------------------- boot */

(async function init() {
    if (!TOKEN) {
        document.body.innerHTML =
            '<p class="empty">Missing session token. Open this page with ' +
            '<code>//as open</code> in game rather than by typing the address.</p>';
        return;
    }
    try {
        applySettings(await call('settings'));
        await loadStatus();
        const p = await call('progress');
        if (p.running) {
            $('progress-wrap').classList.remove('hidden');
            $('do-stop').disabled = false;
            watchProgress();
        }
    } catch (err) {
        $('conn').textContent = 'disconnected';
        $('conn').className = 'conn bad';
        toast('Could not reach the add-on: ' + err.message, 'bad');
    }
})();

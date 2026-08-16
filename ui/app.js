/* AutoSort Web UI — frontend logic (vanilla JS, no dependencies).
 *
 * Talks to the Lua HTTP server via the /api/* JSON endpoints. All state is
 * kept in the `state` object; each tab re-renders from that state. Settings
 * (enabled bags + rules) are edited locally and pushed with an explicit Save.
 */

'use strict';

const state = {
    settings: { enabled_bags: {}, rules: [], move_delay: 0.7, port: 9898 },
    catalog: [],        // [{key,name,id,note}]
    categories: [],     // ["Weapon","Armor",...]
    status: null,       // last /api/status response
    plan: null,         // last preview plan
    progressTimer: null,
};

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class') node.className = v;
        else if (k === 'html') node.innerHTML = v;
        else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
        else if (v !== null && v !== undefined) node.setAttribute(k, v);
    }
    for (const c of children) {
        if (c == null) continue;
        node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return node;
}

function esc(s) {
    return String(s).replace(/[&<>"']/g, m => (
        { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]
    ));
}

let toastTimer = null;
function toast(msg, kind = '') {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'toast show ' + kind;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = 'toast'; }, 2600);
}

async function api(path, method = 'GET', body = null) {
    const opts = { method, headers: {} };
    if (body !== null) {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
    }
    const res = await fetch('/api/' + path, opts);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
}

function setConn(online) {
    const pill = $('#conn-status');
    if (online) { pill.textContent = 'Connected'; pill.className = 'pill pill-online'; }
    else { pill.textContent = 'Disconnected'; pill.className = 'pill pill-offline'; }
}

function nameForBag(key) {
    const b = state.catalog.find(c => c.key === key);
    return b ? b.name : key;
}

/* ------------------------------------------------------------------ */
/* Item icons + description tooltip                                    */
/* ------------------------------------------------------------------ */

// Build the icon URL for an item id from the configured base URL.
// Returns null when icons are disabled or no base URL / id is available.
function iconUrl(id) {
    if (!state.settings || state.settings.show_icons === false) return null;
    const base = state.settings.icon_base_url;
    if (!base || id == null) return null;
    return base + id + '.png';
}

// Create an icon element for an item, with a graceful fallback placeholder
// (the item's first letter) if the CDN image is missing or icons are off.
function makeIcon(item) {
    const wrap = el('span', { class: 'item-icon' });
    const url = iconUrl(item.id);
    const placeholder = () => {
        wrap.classList.add('item-icon-ph');
        wrap.textContent = (item.name || '?').charAt(0).toUpperCase();
    };
    if (!url) { placeholder(); return wrap; }
    const img = el('img', { src: url, alt: item.name || '', loading: 'lazy' });
    img.addEventListener('error', () => { wrap.innerHTML = ''; placeholder(); });
    wrap.appendChild(img);
    return wrap;
}

// Shared floating tooltip element (created once).
let _tip = null;
function ensureTip() {
    if (!_tip) {
        _tip = el('div', { class: 'item-tip hidden' });
        document.body.appendChild(_tip);
    }
    return _tip;
}

// Build the tooltip HTML for an item from its metadata.
function tipHtml(item) {
    const rows = [];
    rows.push(`<div class="tip-head">${esc(item.name || 'Unknown')}</div>`);
    const meta = [];
    if (item.category) meta.push(esc(item.category));
    if (item.slots) meta.push(esc(item.slots));
    if (item.level) meta.push('Lv.' + esc(item.level));
    if (item.item_level) meta.push('iLv.' + esc(item.item_level));
    if (meta.length) rows.push(`<div class="tip-meta">${meta.join(' · ')}</div>`);
    if (item.jobs) rows.push(`<div class="tip-jobs">${esc(item.jobs)}</div>`);
    if (item.description) rows.push(`<div class="tip-desc">${esc(item.description)}</div>`);
    else rows.push(`<div class="tip-desc tip-dim">No description available.</div>`);
    if (item.id != null) rows.push(`<div class="tip-id">Item ID: ${esc(item.id)}</div>`);
    return rows.join('');
}

// Wire hover/focus behaviour on a row element to show the item tooltip.
function attachTip(node, item) {
    const show = (e) => {
        const tip = ensureTip();
        tip.innerHTML = tipHtml(item);
        tip.classList.remove('hidden');
        moveTip(e);
    };
    const moveTip = (e) => {
        const tip = ensureTip();
        const pad = 14;
        let x = e.clientX + pad, y = e.clientY + pad;
        const r = tip.getBoundingClientRect();
        if (x + r.width > window.innerWidth) x = e.clientX - r.width - pad;
        if (y + r.height > window.innerHeight) y = e.clientY - r.height - pad;
        tip.style.left = Math.max(4, x) + 'px';
        tip.style.top = Math.max(4, y) + 'px';
    };
    const hide = () => { ensureTip().classList.add('hidden'); };
    node.addEventListener('mouseenter', show);
    node.addEventListener('mousemove', moveTip);
    node.addEventListener('mouseleave', hide);
}

/* ------------------------------------------------------------------ */
/* Tabs                                                                */
/* ------------------------------------------------------------------ */

function initTabs() {
    $$('.tab').forEach(tab => {
        tab.addEventListener('click', () => {
            $$('.tab').forEach(t => t.classList.remove('active'));
            $$('.tab-panel').forEach(p => p.classList.remove('active'));
            tab.classList.add('active');
            $('#tab-' + tab.dataset.tab).classList.add('active');
            if (tab.dataset.tab === 'status') loadStatus();
        });
    });
}

/* ------------------------------------------------------------------ */
/* Tab 1: Inventory Status                                             */
/* ------------------------------------------------------------------ */

async function loadStatus() {
    const list = $('#status-list');
    list.innerHTML = '<div class="empty">Loading…</div>';
    try {
        const data = await api('status');
        setConn(true);
        state.status = data;
        renderStatus(data.bags || []);
        // The status catalog carries live slot counts + availability badges,
        // so re-render the Bag Settings toggles now that we have richer data.
        if (data.catalog) renderBagToggles();
    } catch (e) {
        setConn(false);
        list.innerHTML = '<div class="empty">Could not reach the add-on. Is AutoSort loaded in-game?</div>';
    }
}

function pctClass(pct) {
    if (pct > 100) return 'over';
    if (pct >= 90) return 'warn';
    return '';
}

function renderStatus(bags) {
    const list = $('#status-list');
    list.innerHTML = '';
    if (!bags.length) {
        list.appendChild(el('div', { class: 'empty' }, 'No enabled bags. Enable bags in the Bag Settings tab.'));
        return;
    }

    bags.forEach(bag => {
        const pct = Math.floor((bag.used / Math.max(1, bag.max)) * 100);
        const head = el('div', { class: 'bag-card-head' },
            el('span', { class: 'bag-name' }, bag.name),
            el('span', { class: 'bag-slots' }, `${bag.used} / ${bag.max}`),
            el('div', { class: 'progress-bar' },
                el('div', { class: 'progress-fill ' + pctClass(pct), style: `width:${Math.min(100, pct)}%` })),
            el('span', { class: 'bag-chevron' }, '▶'),
        );
        const itemsWrap = el('div', { class: 'bag-items' });
        if (!bag.items.length) {
            itemsWrap.appendChild(el('div', { class: 'empty' }, 'Empty'));
        } else {
            bag.items.forEach(it => {
                const row = el('div', { class: 'item-row' },
                    makeIcon(it),
                    el('span', { class: 'item-name' }, it.name),
                    el('span', { class: 'item-cat' }, it.category),
                    el('span', { class: 'item-qty' }, '×' + it.count),
                );
                attachTip(row, it);
                itemsWrap.appendChild(row);
            });
        }
        const card = el('div', { class: 'bag-card' }, head, itemsWrap);
        head.addEventListener('click', () => card.classList.toggle('open'));
        list.appendChild(card);
    });
}

/* ------------------------------------------------------------------ */
/* Tab 2: Bag Settings                                                 */
/* ------------------------------------------------------------------ */

function renderBagToggles() {
    const wrap = $('#bag-toggles');
    wrap.innerHTML = '';
    // Prefer live catalog from /api/status (has used/max); fall back to settings catalog.
    const catalog = (state.status && state.status.catalog) || state.catalog.map(c => ({
        ...c, enabled: !!state.settings.enabled_bags[c.key], used: 0, max: 80,
    }));

    catalog.forEach(b => {
        const isInv = b.key === 'inventory';
        const enabled = !!state.settings.enabled_bags[b.key] || isInv;
        const input = el('input', { type: 'checkbox' });
        input.checked = enabled;
        if (isInv) input.disabled = true;
        input.addEventListener('change', () => {
            state.settings.enabled_bags[b.key] = input.checked;
            card.classList.toggle('disabled', !input.checked);
            populateMuleBagDropdown(); // update mule bag options when bags change
        });

        // Detection badge: reflects what the game reports as accessible right now.
        // Inventory is always accessible. `available` comes from /api/status.
        const available = isInv || b.available === true;
        const badge = el('span', {
            class: 'detect-badge ' + (available ? 'detected' : 'unavailable'),
            title: available
                ? 'AutoSort can see this bag right now.'
                : 'Not accessible right now (e.g. a Mog House bag while you are out in the field). You can still enable it — it just won\'t be sorted until you have access.',
        }, available ? '✓ Detected' : 'Not accessible');

        const name = el('div', { class: 'name' }, b.name, badge);

        const card = el('div', { class: 'toggle-card' + (enabled ? '' : ' disabled') },
            el('label', { class: 'switch' }, input, el('span', { class: 'slider' })),
            el('div', { class: 'toggle-info' },
                name,
                el('div', { class: 'slots' }, `Slots: ${b.used ?? 0} / ${b.max ?? 80}`),
                el('div', { class: 'note' }, b.note || ''),
            ),
        );
        wrap.appendChild(card);
    });
}

function populateMuleBagDropdown() {
    const select = $('#mule-bag');
    const currentValue = select.value;
    select.innerHTML = '<option value="">None — no mule designation</option>';
    
    const catalog = (state.status && state.status.catalog) || state.catalog;
    catalog.forEach(b => {
        if (state.settings.enabled_bags[b.key]) {
            const opt = el('option', { value: b.key }, b.name);
            select.appendChild(opt);
        }
    });
    
    // Restore the previous selection if it's still valid
    if (state.settings.mule_bag && state.settings.enabled_bags[state.settings.mule_bag]) {
        select.value = state.settings.mule_bag;
    } else if (currentValue && state.settings.enabled_bags[currentValue]) {
        select.value = currentValue;
    } else {
        select.value = '';
    }
}

async function saveBagSettings() {
    state.settings.move_delay = parseFloat($('#move-delay').value) || 0.7;
    // Send '' (empty string) rather than null so the Lua backend reliably
    // clears the mule bag — JSON null can decode to an absent key in Lua.
    state.settings.mule_bag = $('#mule-bag').value || '';
    try {
        const res = await api('settings', 'POST', {
            enabled_bags: state.settings.enabled_bags,
            rules: state.settings.rules,
            move_delay: state.settings.move_delay,
            mule_bag: state.settings.mule_bag,
        });
        if (res.ok) {
            state.settings = res.settings;
            toast('Bag settings saved.', 'ok');
            loadStatus();
        } else {
            toast('Save failed: ' + (res.error || 'unknown'), 'err');
        }
    } catch (e) {
        toast('Save failed — add-on unreachable.', 'err');
    }
}

// Ask the game which bags are accessible right now. The backend auto-enables
// any newly-seen bags (leaving your manual choices untouched) and returns the
// refreshed settings. We then re-render toggles + status so the badges update.
async function detectBags() {
    const btn = $('#settings-detect');
    if (btn) { btn.disabled = true; btn.textContent = '🔍 Detecting…'; }
    try {
        const res = await api('detect', 'POST', {});
        if (res.ok) {
            if (res.settings) state.settings = res.settings;
            const n = (res.newly && res.newly.length) || 0;
            toast(n > 0
                ? `Detected & enabled ${n} new bag(s).`
                : 'Scan complete — no new bags found.', 'ok');
            await loadStatus();      // refreshes catalog + availability badges
            renderBagToggles();
            populateMuleBagDropdown();
        } else {
            toast('Detection failed: ' + (res.error || 'unknown'), 'err');
        }
    } catch (e) {
        toast('Detection failed — add-on unreachable.', 'err');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = '🔍 Auto-detect bags'; }
    }
}

/* ------------------------------------------------------------------ */
/* Tab 3: Sort Rules                                                   */
/* ------------------------------------------------------------------ */

function populateTargetDropdowns() {
    const targets = state.catalog; // all bags valid as targets
    const fill = (sel) => {
        sel.innerHTML = '';
        targets.forEach(b => sel.appendChild(el('option', { value: b.key }, b.name)));
    };
    fill($('#new-rule-target'));

    const catSel = $('#new-rule-category');
    catSel.innerHTML = '';
    state.categories.forEach(c => catSel.appendChild(el('option', { value: c }, c)));
}

function initRuleForm() {
    const typeSel = $('#new-rule-type');
    const patternInput = $('#new-rule-pattern');
    const catSel = $('#new-rule-category');

    typeSel.addEventListener('change', () => {
        if (typeSel.value === 'category') {
            patternInput.classList.add('hidden');
            catSel.classList.remove('hidden');
        } else {
            patternInput.classList.remove('hidden');
            catSel.classList.add('hidden');
        }
    });

    $('#add-rule').addEventListener('click', () => {
        const type = typeSel.value;
        const pattern = type === 'category' ? catSel.value : patternInput.value.trim();
        const target = $('#new-rule-target').value;
        if (!pattern) { toast('Enter an item name or pick a category.', 'err'); return; }
        state.settings.rules.push({ match_type: type, pattern, target });
        patternInput.value = '';
        renderRules();
        toast('Rule added (remember to Save).');
    });
}

function renderRules() {
    const body = $('#rules-body');
    body.innerHTML = '';
    const rules = state.settings.rules || [];
    if (!rules.length) {
        body.appendChild(el('tr', {}, el('td', { colspan: '5', class: 'empty' }, 'No rules yet. Add one above.')));
        return;
    }
    rules.forEach((r, i) => {
        const tag = r.match_type === 'category'
            ? el('span', { class: 'tag tag-cat' }, 'Category')
            : el('span', { class: 'tag tag-name' }, 'Name');

        const targetSel = el('select');
        state.catalog.forEach(b => {
            const opt = el('option', { value: b.key }, b.name);
            if (b.key === r.target) opt.selected = true;
            targetSel.appendChild(opt);
        });
        targetSel.addEventListener('change', () => { r.target = targetSel.value; });

        const upBtn = el('button', { class: 'btn btn-ghost btn-sm', title: 'Move up' }, '↑');
        upBtn.addEventListener('click', () => { if (i > 0) { swapRule(i, i - 1); } });
        const downBtn = el('button', { class: 'btn btn-ghost btn-sm', title: 'Move down' }, '↓');
        downBtn.addEventListener('click', () => { if (i < rules.length - 1) { swapRule(i, i + 1); } });
        const delBtn = el('button', { class: 'btn btn-danger btn-sm' }, 'Delete');
        delBtn.addEventListener('click', () => { rules.splice(i, 1); renderRules(); });

        body.appendChild(el('tr', {},
            el('td', {}, String(i + 1)),
            el('td', {}, tag),
            el('td', { class: 'mono' }, r.pattern),
            el('td', {}, targetSel),
            el('td', {}, upBtn, downBtn, delBtn),
        ));
    });
}

function swapRule(a, b) {
    const r = state.settings.rules;
    [r[a], r[b]] = [r[b], r[a]];
    renderRules();
}

async function saveRules() {
    try {
        const res = await api('settings', 'POST', {
            enabled_bags: state.settings.enabled_bags,
            rules: state.settings.rules,
            move_delay: state.settings.move_delay,
        });
        if (res.ok) {
            state.settings = res.settings;
            renderRules();
            toast('Rules saved.', 'ok');
        } else {
            toast('Save failed: ' + (res.error || 'unknown'), 'err');
        }
    } catch (e) {
        toast('Save failed — add-on unreachable.', 'err');
    }
}

/* ------------------------------------------------------------------ */
/* Tab 4: Preview & Execute                                            */
/* ------------------------------------------------------------------ */

async function generatePreview() {
    try {
        const res = await api('preview', 'POST');
        if (!res.ok) { toast('Preview failed.', 'err'); return; }
        state.plan = res.plan;
        renderPlan(res.plan);
        $('#execute-sort').disabled = (res.plan.moves.length === 0);
        toast(`Preview: ${res.plan.moves.length} move(s).`, 'ok');
    } catch (e) {
        toast('Preview failed — add-on unreachable.', 'err');
    }
}

function renderPlan(plan) {
    // Warnings
    const warnBox = $('#preview-warnings');
    if (plan.warnings && plan.warnings.length) {
        warnBox.classList.remove('hidden');
        warnBox.innerHTML = '<strong>Warnings</strong><ul>' +
            plan.warnings.map(w => `<li>${esc(w)}</li>`).join('') + '</ul>';
    } else {
        warnBox.classList.add('hidden');
        warnBox.innerHTML = '';
    }

    // Moves
    const body = $('#moves-body');
    body.innerHTML = '';
    $('#move-count').textContent = plan.moves.length;
    if (!plan.moves.length) {
        body.appendChild(el('tr', {}, el('td', { colspan: '6', class: 'empty' }, 'No moves — everything is already sorted or unmatched.')));
    } else {
        const muleBag = state.settings.mule_bag;
        plan.moves.forEach(m => {
            const isMuleItem = muleBag && m.to === muleBag;
            const rowClass = isMuleItem ? 'mule-row' : '';
            const toNameDisplay = isMuleItem ? m.to_name + ' 📦' : m.to_name;
            const nameCell = el('td', {},
                el('span', { class: 'item-name-cell' }, makeIcon(m), el('span', {}, m.name)));
            attachTip(nameCell, m);
            body.appendChild(el('tr', { class: rowClass },
                nameCell,
                el('td', { class: 'item-qty' }, '×' + m.count),
                el('td', {}, m.from_name),
                el('td', { class: 'move-arrow' }, '→'),
                el('td', {}, toNameDisplay),
                el('td', {}, el('span', { class: 'hop-badge hop-' + m.hops }, m.hops + (m.hops === 1 ? ' hop' : ' hops'))),
            ));
        });
    }

    // Capacity
    const capWrap = $('#capacity-list');
    capWrap.innerHTML = '';
    const caps = plan.capacity || {};
    const keys = Object.keys(caps);
    if (!keys.length) {
        capWrap.appendChild(el('div', { class: 'empty' }, 'No capacity data.'));
    } else {
        keys.forEach(k => {
            const c = caps[k];
            const pct = c.pct;
            const cls = pctClass(pct);
            const overLabel = c.over ? el('span', { class: 'over' }, 'OVER CAPACITY') : el('span', {}, pct + '%');
            capWrap.appendChild(el('div', { class: 'cap-card' },
                el('div', { class: 'cap-head' }, el('strong', {}, c.name), overLabel),
                el('div', { class: 'progress-bar' },
                    el('div', { class: 'progress-fill ' + cls, style: `width:${Math.min(100, pct)}%` })),
                el('div', { class: 'cap-delta' }, `${c.before} → ${c.after} / ${c.max} slots`),
            ));
        });
    }

    // Unmatched
    const unWrap = $('#unmatched-list');
    unWrap.innerHTML = '';
    $('#unmatched-count').textContent = (plan.unmatched || []).length;
    if (!plan.unmatched || !plan.unmatched.length) {
        unWrap.appendChild(el('div', { class: 'empty' }, '—'));
    } else {
        plan.unmatched.forEach(u => {
            unWrap.appendChild(el('span', { class: 'chip' }, `${u.name} ×${u.count} (${u.bag_name})`));
        });
    }
}

async function executeSort() {
    if (!state.plan) { toast('Generate a preview first.', 'err'); return; }
    try {
        const res = await api('execute', 'POST');
        if (!res.ok) { toast(res.error || 'Execute failed.', 'err'); return; }
        $('#exec-progress').classList.remove('hidden');
        $('#execute-sort').disabled = true;
        $('#stop-sort').classList.remove('hidden');
        pollProgress();
    } catch (e) {
        toast('Execute failed — add-on unreachable.', 'err');
    }
}

function pollProgress() {
    clearInterval(state.progressTimer);
    state.progressTimer = setInterval(async () => {
        try {
            const p = await api('progress');
            const total = p.total || 0;
            const done = p.completed || 0;
            const pct = total ? Math.floor((done / total) * 100) : 100;
            $('#progress-fill').style.width = pct + '%';
            $('#progress-text').textContent = `${done} / ${total} moves`;
            $('#progress-log').textContent = (p.log || []).join('\n');
            $('#progress-log').scrollTop = $('#progress-log').scrollHeight;
            if (!p.running) {
                clearInterval(state.progressTimer);
                $('#stop-sort').classList.add('hidden');
                $('#execute-sort').disabled = false;
                toast('Sort finished.', 'ok');
                loadStatus();
            }
        } catch (e) {
            clearInterval(state.progressTimer);
            $('#stop-sort').classList.add('hidden');
        }
    }, 700);
}

async function stopSort() {
    try { await api('stop', 'POST'); } catch (e) {}
    clearInterval(state.progressTimer);
    $('#stop-sort').classList.add('hidden');
    $('#execute-sort').disabled = false;
    toast('Sort stopped.');
}

/* ------------------------------------------------------------------ */
/* Bootstrap                                                           */
/* ------------------------------------------------------------------ */

async function loadSettings() {
    try {
        const res = await api('settings');
        setConn(true);
        state.settings = res.settings;
        state.catalog = res.catalog || [];
        state.categories = res.categories || [];
        $('#move-delay').value = state.settings.move_delay ?? 0.7;
        populateTargetDropdowns();
        populateMuleBagDropdown();
        renderBagToggles();
        renderRules();
    } catch (e) {
        setConn(false);
        toast('Could not load settings — is AutoSort loaded in-game?', 'err');
    }
}

function initButtons() {
    $('#status-refresh').addEventListener('click', loadStatus);
    $('#global-refresh').addEventListener('click', () => { loadSettings(); loadStatus(); });
    $('#settings-save').addEventListener('click', saveBagSettings);
    $('#settings-detect').addEventListener('click', detectBags);
    $('#rules-save').addEventListener('click', saveRules);
    $('#add-rule') && null; // wired in initRuleForm
    $('#generate-preview').addEventListener('click', generatePreview);
    $('#execute-sort').addEventListener('click', executeSort);
    $('#stop-sort').addEventListener('click', stopSort);
}

document.addEventListener('DOMContentLoaded', async () => {
    initTabs();
    initButtons();
    initRuleForm();
    await loadSettings();
    await loadStatus();
});

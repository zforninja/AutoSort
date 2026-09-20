/*
    layout.js — The Layout page: every bag with its items, drag and drop to
    make rules, and a live projection of where everything ends up.

    Depends on app.js (state, call, esc, toast, iconFor, renderRules, ...) and
    rulegen.js (pure logic). Loaded after both.

    How dropping works:
      * drop an item on a bag  -> a rule is created or retargeted
      * every change re-plans with the UNSAVED rules (POST /api/preview with a
        rules payload), so "After sort" shows the real result before anything
        is written or moved
      * Save writes the rule file; nothing moves in game until you Execute
*/

'use strict';

const Layout = (function () {
    const R = window.RuleGen;

    const L = {
        view: 'current',       // 'current' | 'after'
        mode: 'item',          // what a drop creates a rule for
        selected: new Set(),   // origin uids of selected items
        dragging: [],          // items being dragged
        plan: null,            // latest preview
        proj: null,            // projection of that plan
        rev: 0,                // ignores out-of-date preview responses
        timer: null,
        items: {},             // origin uid -> item (with bag_key/bag_name)
    };

    /* ----------------------------------------------------------- helpers */

    const bagName = (key) => {
        const b = state.catalog.find((c) => c.key === key);
        return b ? b.name : key;
    };

    function indexItems() {
        L.items = {};
        state.bags.forEach((b) => b.items.forEach((it) => {
            L.items[R.uid(b.key, it.slot)] = Object.assign({}, it, { bag_key: b.key, bag_name: b.name });
        }));
    }

    function bagByKey(key) {
        return state.bags.find((b) => b.key === key);
    }

    /* Per-item facts from the latest plan, keyed by ORIGIN uid. */
    function planFacts() {
        const moves = {}, blocked = {}, skipped = {};
        if (L.plan) {
            L.plan.moves.forEach((m) => { moves[R.uid(m.orig_key, m.orig_slot)] = m; });
            L.plan.blocked.forEach((b) => { blocked[R.uid(b.bag_key, b.slot)] = b; });
            L.plan.skipped.forEach((s) => { skipped[R.uid(s.bag_key, s.slot)] = s; });
        }
        return { moves, blocked, skipped };
    }

    /* ---------------------------------------------------------- rendering */

    function chipHtml(it, originUid, facts, view) {
        const move = facts.moves[originUid];
        const block = facts.blocked[originUid];
        const skip = facts.skipped[originUid];
        const selected = L.selected.has(originUid);
        const badges = [];
        const tip = [it.name + ' — ' + (it.slot_name || it.category)];
        if (it.count > 1) tip.push('x' + it.count);

        if (it.locked) badges.push('<span class="tag lock">equipped</span>');
        if (it.moved) {
            badges.push(`<span class="tag in">from ${esc(it.from_name)}</span>`);
            if (move) tip.push('moved by ' + move.rule_label);
        } else if (view === 'current' && move && move.to_key !== it.bag_key) {
            badges.push(`<span class="tag out">→ ${esc(bagName(move.to_key))}</span>`);
            tip.push('will move to ' + bagName(move.to_key) + ' (' + move.rule_label + ')');
        }
        if (block) {
            badges.push('<span class="tag bad">blocked</span>');
            tip.push('blocked: ' + block.reason);
        }
        if (skip && !it.locked) tip.push('left alone: ' + skip.reason);

        const classes = ['chip'];
        if (it.locked) classes.push('locked');
        if (selected) classes.push('selected');
        if (it.moved) classes.push('arrived');
        if (view === 'current' && move) classes.push('leaving');
        if (block) classes.push('blocked');

        return `<li class="${classes.join(' ')}" data-uid="${esc(originUid)}"
            ${it.locked ? '' : 'draggable="true"'} title="${esc(tip.join('\n'))}">
            ${iconFor(it.id)}<span class="nm">${esc(it.name)}</span>
            ${it.count > 1 ? `<span class="ct">x${Number(it.count)}</span>` : ''}
            ${badges.join('')}
        </li>`;
    }

    function bagCardHtml(bag, facts, view, filter) {
        const shown = bag.items.filter((it) => !filter || it.name.toLowerCase().includes(filter));
        const pct = bag.max ? Math.round((bag.used / bag.max) * 100) : 0;
        const overflow = bag.used > bag.max;

        const chips = shown.map((it) => {
            // Arrivals keep the identity of the bag and slot they came from.
            const origin = it.moved ? R.uid(it.from, it.slot) : R.uid(bag.key, it.slot);
            return chipHtml(Object.assign({ bag_key: bag.key }, it), origin, facts, view);
        }).join('');

        const send = L.selected.size
            ? `<button class="mini send" data-send="${esc(bag.key)}" title="Send the selected items here">Move here</button>`
            : '';
        const note = bag.accepts === 'equipment' ? '<span class="tag">gear only</span>'
            : bag.accepts === 'furniture' ? '<span class="tag">furniture only</span>' : '';

        return `<div class="bag-card" data-bag="${esc(bag.key)}">
            <div class="bag-head">
                <strong>${esc(bag.name)}</strong> ${note}
                <span class="muted">${bag.used}/${bag.max}</span>
                <div class="meter${overflow ? ' over' : ''}"><div style="width:${Math.min(100, pct)}%"></div></div>
                ${send}
            </div>
            <ul class="chips">${chips || '<li class="empty drop-hint">Drop items here</li>'}</ul>
        </div>`;
    }

    function summaryHtml() {
        if (!L.plan) return 'Planning…';
        const p = L.plan;
        let user = 0, def = 0;
        p.moves.forEach((m) => { if (m.parked) return; if (m.source === 'user') user++; else def++; });
        const parts = [`<strong>${user + def}</strong> item(s) will move`];
        if (user || def) parts.push(`${user} by your rules, ${def} by defaults`);
        if (p.blocked.length) parts.push(`<span class="bad">${p.blocked.length} blocked</span>`);
        return parts.join(' &middot; ');
    }

    function render() {
        const grid = document.getElementById('lay-grid');
        if (!grid) return;
        indexItems();

        const filter = document.getElementById('lay-filter').value.trim().toLowerCase();
        const hideEmpty = document.getElementById('lay-hide-empty').checked;
        const facts = planFacts();

        let bags = state.bags;
        if (L.view === 'after' && L.proj) bags = L.proj.bags;

        // Empty bags are shown by default: they are exactly where you want to
        // drop things. Hiding them is an opt-in for tidying a long page.
        const cards = bags
            .filter((b) => !(hideEmpty && b.items.length === 0))
            .map((b) => bagCardHtml(b, facts, L.view, filter));

        grid.innerHTML = cards.join('') ||
            '<p class="empty">No accessible bags. Are you logged in?</p>';

        const missing = state.catalog.filter((c) => !c.available).map((c) => c.name);
        document.getElementById('lay-missing').textContent =
            missing.length ? 'Not accessible right now: ' + missing.join(', ') + '.' : '';

        document.getElementById('lay-summary').innerHTML = summaryHtml();
        document.getElementById('lay-selcount').textContent =
            L.selected.size ? `${L.selected.size} selected` : '';
        document.getElementById('lay-clear').classList.toggle('hidden', !L.selected.size);

        document.querySelectorAll('#lay-view button').forEach((b) =>
            b.classList.toggle('on', b.dataset.view === L.view));
        document.querySelectorAll('#lay-mode button').forEach((b) =>
            b.classList.toggle('on', b.dataset.mode === L.mode));
    }

    /* ------------------------------------------------------------ planning */

    async function refreshPlan() {
        const mine = ++L.rev;
        try {
            const plan = await call('preview', {
                method: 'POST',
                body: JSON.stringify({
                    rules: window.cleanRules(),
                    defaults: state.options.defaults,
                }),
            });
            if (mine !== L.rev) return;            // a newer request superseded this one
            L.plan = plan;
            L.proj = R.project(state.bags, plan.moves);
        } catch (err) {
            if (mine !== L.rev) return;
            L.plan = null; L.proj = null;
            document.getElementById('lay-summary').textContent = 'Could not plan: ' + err.message;
            return;
        }
        render();
    }

    function schedule() {
        clearTimeout(L.timer);
        L.timer = setTimeout(refreshPlan, 200);
    }

    /* ------------------------------------------------------- creating rules */

    function applyDrop(items, destKey, modeOverride) {
        const dest = state.catalog.find((c) => c.key === destKey);
        const bag = Object.assign({ accepts: 'any' }, dest || {});
        const mode = modeOverride || L.mode;
        const counts = { added: 0, updated: 0, unchanged: 0 };
        const refused = [];

        items.forEach((it) => {
            const ok = R.legality(bag, it);
            if (!ok.ok) { refused.push(it.name); return; }
            const res = R.upsert(state.rules, R.ruleFor(it, mode, destKey));
            state.rules = res.rules;
            counts[res.action]++;
        });

        const msg = [];
        if (counts.added) msg.push(`${counts.added} rule(s) added`);
        if (counts.updated) msg.push(`${counts.updated} updated`);
        if (refused.length) msg.push(`${refused.length} refused (${bag.name} cannot hold ${refused[0]}${refused.length > 1 ? ' and others' : ''})`);
        if (!msg.length) msg.push('No change — those rules already exist');
        toast(msg.join(', '), refused.length ? 'warn' : 'ok');

        if (counts.added || counts.updated) {
            L.selected.clear();
            L.view = 'after';
            renderRules();      // also notifies us through rulesChanged()
        }
    }

    function dragItems(uid) {
        const uids = L.selected.has(uid) ? Array.from(L.selected) : [uid];
        return uids.map((u) => L.items[u]).filter((it) => it && !it.locked);
    }

    /* Mode for this drop: Shift widens to the category, Alt to the slot. */
    function modeFor(e) {
        if (e.shiftKey) return 'category';
        if (e.altKey) return 'slot';
        return L.mode;
    }

    /* -------------------------------------------------------------- events */

    function wire() {
        const grid = document.getElementById('lay-grid');

        grid.addEventListener('click', (e) => {
            const send = e.target.closest('[data-send]');
            if (send) {
                const items = Array.from(L.selected).map((u) => L.items[u]).filter(Boolean);
                applyDrop(items, send.dataset.send);
                return;
            }
            const chip = e.target.closest('.chip');
            if (!chip || chip.classList.contains('locked')) return;
            const uid = chip.dataset.uid;
            if (L.selected.has(uid)) L.selected.delete(uid); else L.selected.add(uid);
            render();
        });

        grid.addEventListener('dragstart', (e) => {
            const chip = e.target.closest('.chip');
            if (!chip) return;
            L.dragging = dragItems(chip.dataset.uid);
            if (!L.dragging.length) { e.preventDefault(); return; }
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', 'autosort');
            chip.classList.add('dragging');
            grid.classList.add('is-dragging');
        });

        grid.addEventListener('dragend', () => {
            L.dragging = [];
            grid.classList.remove('is-dragging');
            grid.querySelectorAll('.dragging, .over, .over-bad')
                .forEach((n) => n.classList.remove('dragging', 'over', 'over-bad'));
        });

        function legalCount(card) {
            const dest = state.catalog.find((c) => c.key === card.dataset.bag);
            const bag = Object.assign({ accepts: 'any' }, dest || {});
            return L.dragging.filter((it) => R.legality(bag, it).ok).length;
        }

        grid.addEventListener('dragover', (e) => {
            const card = e.target.closest('.bag-card');
            if (!card || !L.dragging.length) return;
            const legal = legalCount(card);
            card.classList.toggle('over', legal > 0);
            card.classList.toggle('over-bad', legal === 0);
            if (legal > 0) { e.preventDefault(); e.dataTransfer.dropEffect = 'move'; }
            else e.dataTransfer.dropEffect = 'none';
        });

        grid.addEventListener('dragleave', (e) => {
            const card = e.target.closest('.bag-card');
            if (card && !card.contains(e.relatedTarget)) card.classList.remove('over', 'over-bad');
        });

        grid.addEventListener('drop', (e) => {
            const card = e.target.closest('.bag-card');
            if (!card || !L.dragging.length) return;
            e.preventDefault();
            const items = L.dragging.slice();
            L.dragging = [];
            applyDrop(items, card.dataset.bag, modeFor(e));
        });

        document.getElementById('lay-view').addEventListener('click', (e) => {
            const b = e.target.closest('button'); if (!b) return;
            L.view = b.dataset.view; render();
        });
        document.getElementById('lay-mode').addEventListener('click', (e) => {
            const b = e.target.closest('button'); if (!b) return;
            L.mode = b.dataset.mode; render();
        });
        document.getElementById('lay-filter').addEventListener('input', render);
        document.getElementById('lay-hide-empty').addEventListener('change', render);
        document.getElementById('lay-clear').addEventListener('click', () => { L.selected.clear(); render(); });
        document.getElementById('lay-refresh').addEventListener('click', async () => {
            await loadStatus(); L.selected.clear(); refreshPlan();
        });
        document.getElementById('lay-save').addEventListener('click',
            () => window.saveAll().catch((err) => toast(err.message, 'bad')));
        document.getElementById('lay-revert').addEventListener('click', () => window.revertAll());
    }

    document.addEventListener('DOMContentLoaded', wire);

    /* ---------------------------------------------------------- public API */

    return {
        onShow: async function () { await loadStatus(); refreshPlan(); },
        onRulesChanged: schedule,
        refresh: refreshPlan,
        _state: L,   // exposed for tests
    };
})();

window.Layout = Layout;

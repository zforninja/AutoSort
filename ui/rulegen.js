/*
    rulegen.js — Pure logic behind the Layout page.

    No DOM in here, so it can be tested on its own. It answers four questions:
      * what rule does a drop create?          ruleFor
      * where does that rule belong in the     upsert
        list of existing rules?
      * may this item live in that bag?        legality
      * where does everything end up after     project
        a sort?
*/

(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.RuleGen = factory();
})(typeof self !== 'undefined' ? self : this, function () {
    'use strict';

    // Equipment slot names the engine understands as categories.
    const SLOTS = ['Main', 'Sub', 'Ranged', 'Ammo', 'Head', 'Body', 'Hands',
        'Legs', 'Feet', 'Neck', 'Waist', 'Ear', 'Ring', 'Back'];

    /* How specific a rule is. Rules are first-match-wins, so a more specific
       rule has to sit above a broader one or it would never fire:
         0  names an item            ("Warp Ring")
         1  names an equipment slot  ("Head")
         2  names a broad category   ("Armor")                              */
    function tier(rule) {
        if (rule.match) return 0;
        if (rule.category && SLOTS.indexOf(rule.category) !== -1) return 1;
        return 2;
    }

    /* The rule a drop creates.
         mode  'item' | 'category' | 'slot'
       A slot rule falls back to the category for items with no slot.        */
    function ruleFor(item, mode, destKey) {
        if (mode === 'category') return { category: item.category, to: destKey };
        if (mode === 'slot') {
            return item.slot_name
                ? { category: item.slot_name, to: destKey }
                : { category: item.category, to: destKey };
        }
        return { match: item.name, to: destKey };
    }

    function sameTarget(a, b) {
        return (a.match || '') === (b.match || '') &&
               (a.category || '') === (b.category || '');
    }

    /* Add a rule, or retarget an existing rule with the same match, without
       ever creating a duplicate. Returns { rules, action } where action is
       'added', 'updated' or 'unchanged'. Never mutates its input.            */
    function upsert(rules, rule) {
        const list = rules.map((r) => Object.assign({}, r));
        const at = list.findIndex((r) => sameTarget(r, rule));
        if (at !== -1) {
            if (list[at].to === rule.to) return { rules: list, action: 'unchanged' };
            list[at].to = rule.to;
            return { rules: list, action: 'updated' };
        }
        const mine = tier(rule);
        let insertAt = list.findIndex((r) => tier(r) > mine);
        if (insertAt === -1) insertAt = list.length;
        list.splice(insertAt, 0, Object.assign({}, rule));
        return { rules: list, action: 'added' };
    }

    /* May `item` live in `bag`? Mirrors the engine's own legality check.     */
    function legality(bag, item) {
        if (bag.accepts === 'equipment' && !item.equippable) {
            return { ok: false, reason: bag.name + ' only holds equipment' };
        }
        if (bag.accepts === 'furniture' && !item.furniture) {
            return { ok: false, reason: bag.name + ' only holds furniture' };
        }
        return { ok: true };
    }

    function uid(bagKey, slot) { return bagKey + ':' + slot; }

    /* Where does everything end up? `bags` is the live layout, `moves` is a
       plan from the server. An item is followed from its ORIGINAL bag and slot
       to the destination of the last move that touched it, so a two-step move
       through Inventory shows up as one clean relocation.

       Returns {
         bags:     the projected layout (arrivals flagged `moved`, with `from`)
         leaving:  { uid: destinationKey } for items that will move
       }                                                                       */
    function project(bags, moves) {
        const dest = {};
        (moves || []).forEach((m) => { dest[uid(m.orig_key, m.orig_slot)] = m.to_key; });

        const byKey = {};
        const out = bags.map((b) => {
            const copy = Object.assign({}, b, { items: [] });
            byKey[b.key] = copy;
            return copy;
        });

        const leaving = {};
        const arrivals = {};   // destination key -> items

        bags.forEach((b) => {
            b.items.forEach((it) => {
                const to = dest[uid(b.key, it.slot)];
                if (to && to !== b.key && byKey[to]) {
                    leaving[uid(b.key, it.slot)] = to;
                    (arrivals[to] = arrivals[to] || []).push(
                        Object.assign({}, it, { moved: true, from: b.key, from_name: b.name }));
                } else {
                    byKey[b.key].items.push(Object.assign({}, it));
                }
            });
        });

        Object.keys(arrivals).forEach((key) => {
            arrivals[key].sort((a, b) => a.name.localeCompare(b.name));
            byKey[key].items = byKey[key].items.concat(arrivals[key]);
        });
        out.forEach((b) => { b.used = b.items.length; b.free = Math.max(0, b.max - b.used); });

        return { bags: out, leaving: leaving };
    }

    return { SLOTS, tier, ruleFor, upsert, legality, uid, project };
});

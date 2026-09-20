--[[
    planner.lua — Decide where every item belongs, then order the moves so
    capacity is never exceeded.

    Flow:
      1. CLASSIFY. Match each item to a rule (yours first, then the built-in
         defaults). An item is left alone if it is locked, protected, pinned by
         'keep', or already in an acceptable bag for its rule. Everything else
         becomes a mover with an ordered list of candidate bags.
      2. SCHEDULE. Move items in waves against a simulated copy of every bag's
         free space, so a bag about to be emptied can accept new items and a
         bag is never overfilled. Each mover takes the first candidate bag
         that currently has room. Two full bags that must swap contents are
         resolved by parking an item in Inventory.
      3. RELIEVE. Soft rules (consumables) only move out of Inventory when it
         is crowded, and only enough to reach the free-slot target.

    Stacking is accounted for: merging into a partial stack of the same item
    consumes no slot in the destination.
]]

local bags = require('lib/bags')
local inventory = require('lib/inventory')
local rules = require('lib/rules')
local baseline = require('lib/baseline')

local planner = {}

local INV = bags.INVENTORY_ID

-- ---------------------------------------------------------------------------
-- Space accounting
-- ---------------------------------------------------------------------------

-- Slots needed in a bag for an item: zero when it merges into a partial stack.
local function slots_needed(item, bag_state)
    if item.stack and item.stack > 1 then
        local room = bag_state.partial[item.id]
        if room and room > 0 then return 0 end
    end
    return 1
end

local function apply_arrival(item, bag_state)
    if slots_needed(item, bag_state) == 0 then
        bag_state.partial[item.id] = bag_state.partial[item.id] - item.count
        if bag_state.partial[item.id] <= 0 then bag_state.partial[item.id] = nil end
    else
        bag_state.free = bag_state.free - 1
        if item.stack and item.stack > 1 then
            local room = item.stack - item.count
            if room > 0 then bag_state.partial[item.id] = room end
        end
    end
end

local function apply_departure(_, bag_state)
    bag_state.free = bag_state.free + 1
end

-- Free slots in a bag that a sort may actually use.
local function usable_free(bag_state)
    return bag_state.free - (bag_state.reserved or 0)
end

-- ---------------------------------------------------------------------------
-- Rule resolution
-- ---------------------------------------------------------------------------

-- Bags an item may go to under a rule, in preference order.
-- Returns candidates plus the first reason any bag was rejected.
local function candidates(item, rule, state)
    local out, why = {}, nil
    for _, key in ipairs(rule.targets or { rule.to }) do
        local b = bags.get_by_key(key)
        if not b then
            why = why or ('unknown bag ' .. tostring(key))
        elseif not state[b.id] then
            why = why or (b.name .. ' is not accessible')
        else
            local ok, reason = bags.accepts(b, item)
            if not ok then
                why = why or reason
            elseif item.gear_pinned and not b.equip then
                -- GearSwap can only equip from Inventory and Wardrobes.
                why = why or 'used by GearSwap'
            else
                out[#out + 1] = b
            end
        end
    end
    return out, why
end

-- Is the item already somewhere acceptable under this rule?
local function acceptable_here(item, rule, cands)
    for _, b in ipairs(cands) do
        if b.id == item.bag_id then return true end
    end
    for _, key in ipairs(rule.stay or {}) do
        local b = bags.get_by_key(key)
        if b and b.id == item.bag_id then return true end
    end
    return false
end

local function chain_names(cands)
    local names = {}
    for _, b in ipairs(cands) do names[#names + 1] = b.name end
    return table.concat(names, ', ')
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

--- Build a plan.
-- `config` is { rules, options, gear_ids }. `only_bag` optionally limits the
-- SOURCE to one bag key.
--
-- Returns:
--   moves     ordered array; each has item, from/to ids and names, hops,
--             source ('user'|'default'), rule_label, group
--   blocked   items that should move but cannot, with a reason
--   skipped   items left alone on purpose (locked, protected, no bag reachable)
--   unmatched_count
--   capacity  per bag before/after/max
--   inventory { target, free_after, max }
--   warnings
function planner.build(config, only_bag)
    local opts = config.options or {}
    local plan = {
        moves = {}, blocked = {}, skipped = {},
        unmatched_count = 0, capacity = {}, warnings = {},
        inventory = nil,
    }

    local snapshot = inventory.snapshot()
    if #snapshot == 0 then
        plan.warnings[#plan.warnings + 1] = 'No bags are readable right now.'
        return plan
    end

    -- Simulated free space per bag, including partial-stack room.
    local state, before = {}, {}
    for _, bag in ipairs(snapshot) do
        local partial = {}
        for _, it in ipairs(bag.items) do
            if it.stack and it.stack > 1 and it.count < it.stack then
                partial[it.id] = (partial[it.id] or 0) + (it.stack - it.count)
            end
        end
        state[bag.id] = { free = bag.free, max = bag.max, partial = partial, name = bag.name }
        before[bag.id] = bag.used
    end

    local keep_free = tonumber(opts.keep_free) or 0
    if keep_free > 0 and state[INV] then state[INV].reserved = keep_free end

    local rule_list = rules.effective(config)

    -- ---- 1. Classify -------------------------------------------------------
    local movers, soft = {}, {}

    for _, bag in ipairs(snapshot) do
        if not only_bag or bag.key == only_bag then
            for _, item in ipairs(bag.items) do
                local reason
                if item.locked then
                    reason = 'equipped or in use'
                elseif rules.protected(item, opts.protect) then
                    reason = 'protected'
                end

                if opts.protect_gear and config.gear_ids and config.gear_ids[item.id] then
                    item.gear_pinned = true
                end

                if reason then
                    plan.skipped[#plan.skipped + 1] = { item = item, reason = reason }
                else
                    local rule = rules.match(item, rule_list)
                    if not rule then
                        plan.unmatched_count = plan.unmatched_count + 1
                    elseif rule.keep then
                        -- Pinned where it is.
                    else
                        local cands, why = candidates(item, rule, state)
                        if acceptable_here(item, rule, cands) then
                            -- Already in a good place.
                        elseif #cands == 0 then
                            local entry = { item = item, reason = why or 'no accessible bag' }
                            if rule.source == 'default' or item.gear_pinned then
                                -- Defaults never nag; a GearSwap pin is deliberate.
                                plan.skipped[#plan.skipped + 1] = entry
                            else
                                plan.blocked[#plan.blocked + 1] = entry
                            end
                        else
                            local m = { item = item, item0 = item, rule = rule, cands = cands }
                            if rule.soft and item.bag_id == INV then
                                soft[#soft + 1] = m
                            else
                                movers[#movers + 1] = m
                            end
                        end
                    end
                end
            end
        end
    end

    -- Deterministic order: rule priority first, then category and name, so the
    -- same inventory always yields the same plan.
    local rule_rank = {}
    for i, r in ipairs(rule_list) do rule_rank[r] = i end
    local function order(a, b)
        local ra, rb = rule_rank[a.rule] or 0, rule_rank[b.rule] or 0
        if ra ~= rb then return ra < rb end
        if a.item.category ~= b.item.category then return a.item.category < b.item.category end
        if a.item.name ~= b.item.name then return a.item.name < b.item.name end
        return a.item.slot < b.item.slot
    end
    table.sort(movers, order)
    table.sort(soft, order)

    -- ---- 2. Schedule -------------------------------------------------------
    local function hops_for(item, target)
        return (item.bag_id == INV or target.id == INV) and 1 or 2
    end

    local function record(m, target, hops, parked)
        local item = m.item
        plan.moves[#plan.moves + 1] = {
            item = item, name = item.name, count = item.count, item_id = item.id,
            from_id = item.bag_id, from_name = item.bag_name, from_slot = item.slot,
            from_key = (bags.get_by_id(item.bag_id) or {}).key,
            -- Identity of the ORIGINAL item, unaffected by parking: lets a UI
            -- follow one item through a multi-step move to its final bag.
            orig_key = (bags.get_by_id(m.item0.bag_id) or {}).key,
            orig_slot = m.item0.slot,
            to_id = target.id, to_key = target.key, to_name = target.name,
            hops = hops, parked = parked or false,
            source = m.rule.source, rule_label = m.rule.label,
            group = m.rule.group, rule_index = m.rule.index,
        }
    end

    -- Place one mover into the first candidate that has room right now.
    local function try_place(m)
        local item = m.item
        local src = state[item.bag_id]
        for _, target in ipairs(m.cands) do
            local dest = state[target.id]
            local need = slots_needed(item, dest)
            local hops = hops_for(item, target)
            local room_ok = usable_free(dest) >= need
            local stage_ok = true
            if hops == 2 and state[INV] then stage_ok = usable_free(state[INV]) > 0 end

            if room_ok and stage_ok then
                apply_arrival(item, dest)
                apply_departure(item, src)
                record(m, target, hops)
                return true
            end
        end
        return false
    end

    -- Break a swap deadlock by parking one item in Inventory. Two full bags
    -- that must trade contents stall because neither has room until the other
    -- gives one up, and Inventory is the only scratch space there is.
    local function try_park(remaining)
        local inv_state = state[INV]
        if not inv_state or usable_free(inv_state) <= 0 then return false end

        local wanted = {}
        for _, m in ipairs(remaining) do
            for _, b in ipairs(m.cands) do wanted[b.id] = true end
        end

        for _, m in ipairs(remaining) do
            if wanted[m.item.bag_id] and m.item.bag_id ~= INV then
                local parked = m.item
                record(m, bags.get_by_id(INV), 1, true)
                apply_departure(parked, state[parked.bag_id])
                apply_arrival(parked, inv_state)
                -- For its real move, the item now starts from Inventory.
                m.item = setmetatable(
                    { bag_id = INV, bag_name = 'Inventory' }, { __index = parked })
                return true
            end
        end
        return false
    end

    local function schedule(list, allow_park)
        local remaining = list
        while #remaining > 0 do
            local progressed, deferred = false, {}
            for _, m in ipairs(remaining) do
                if try_place(m) then progressed = true else deferred[#deferred + 1] = m end
            end
            remaining = deferred
            if not progressed and #remaining > 0 and allow_park then
                progressed = try_park(remaining)
            end
            if not progressed then break end
        end
        return remaining
    end

    local function snapshot_state()
        local copy = {}
        for id, s in pairs(state) do
            local partial = {}
            for k, v in pairs(s.partial) do partial[k] = v end
            copy[id] = { free = s.free, max = s.max, name = s.name,
                         reserved = s.reserved, partial = partial }
        end
        return copy
    end

    -- Parking is all-or-nothing. If a parked item cannot be delivered, the
    -- whole attempt is undone rather than leaving it stranded in Inventory.
    local saved_state, saved_moves = snapshot_state(), #plan.moves
    local leftover = schedule(movers, true)

    local stranded = false
    for _, m in ipairs(leftover) do
        if m.item ~= m.item0 then stranded = true; break end
    end
    if stranded then
        state = saved_state
        for i = #plan.moves, saved_moves + 1, -1 do plan.moves[i] = nil end
        for _, m in ipairs(movers) do m.item = m.item0 end
        leftover = schedule(movers, false)
    end

    -- ---- 3. Relieve Inventory pressure --------------------------------------
    local moves_before_relief = #plan.moves
    local inv_state = state[INV]
    local target_free = 0
    if inv_state then
        local d = config.options and config.options.defaults
        target_free = baseline.inventory_target(d, inv_state.max)
        if #soft > 0 then
            local deficit = target_free - inv_state.free
            for _, m in ipairs(soft) do
                if deficit <= 0 then break end
                if try_place(m) then deficit = deficit - 1 end
            end
        end
        plan.inventory = {
            target = target_free, max = inv_state.max,
            free_after = inv_state.free, free_before = inv_state.max - before[INV],
        }
    end

    -- Relief may have opened room that mandatory moves were waiting for (for
    -- example a rule sending gear into a full Inventory), so give anything
    -- still stuck one more chance before reporting it as blocked.
    if #leftover > 0 and #plan.moves > moves_before_relief then
        leftover = schedule(leftover, false)
    end

    for _, m in ipairs(leftover) do
        local reason
        local inv_state = state[INV]
        local needs_stage = m.item.bag_id ~= INV
            and not (#m.cands == 1 and m.cands[1].id == INV)
        if needs_stage and inv_state and usable_free(inv_state) <= 0 then
            reason = ('no free Inventory slot to stage through (keep_free = %d)')
                :format(inv_state.reserved or 0)
        elseif #m.cands == 1 then
            local d = state[m.cands[1].id]
            reason = ('%s is full (%d/%d)'):format(m.cands[1].name, d.max - d.free, d.max)
        else
            reason = 'all destination bags are full: ' .. chain_names(m.cands)
        end
        -- A swap between full bags needs two free Inventory slots to work.
        if needs_stage and inv_state and usable_free(inv_state) < 2 and usable_free(inv_state) > -1
            and not reason:find('Inventory') then
            reason = reason .. '; swapping full bags needs 2 free Inventory slots'
        end
        plan.blocked[#plan.blocked + 1] = { item = m.item0, reason = reason, rule = m.rule }
    end

    if plan.inventory and state[INV] then plan.inventory.free_after = state[INV].free end

    -- ---- Capacity report ---------------------------------------------------
    for _, bag in ipairs(snapshot) do
        local s = state[bag.id]
        plan.capacity[bag.key] = {
            name = bag.name, before = before[bag.id], after = s.max - s.free, max = s.max,
        }
    end

    return plan
end

--- One-line summary of a plan, for chat output.
function planner.summary(plan)
    local user, default = 0, 0
    for _, m in ipairs(plan.moves) do
        if m.source == 'user' then user = user + 1 else default = default + 1 end
    end
    return ('%d move(s) (%d from your rules, %d from defaults), %d blocked, %d left alone')
        :format(#plan.moves, user, default, #plan.blocked, #plan.skipped)
end

--- Explain what would happen to the first item whose name matches `glob`.
-- Returns a table of facts, or nil when nothing matches.
function planner.explain(config, glob)
    local snapshot = inventory.snapshot()
    local state = {}
    for _, bag in ipairs(snapshot) do state[bag.id] = true end
    local rule_list = rules.effective(config)
    local opts = config.options or {}

    for _, bag in ipairs(snapshot) do
        for _, item in ipairs(bag.items) do
            if rules.name_matches(item.name, glob) then
                if opts.protect_gear and config.gear_ids and config.gear_ids[item.id] then
                    item.gear_pinned = true
                end
                local out = { item = item, bag = bag.name }
                if item.locked then
                    out.verdict = 'equipped or in use, so it will not move'
                elseif rules.protected(item, opts.protect) then
                    out.verdict = 'on your protect list, so it will not move'
                else
                    local rule = rules.match(item, rule_list)
                    out.rule = rule
                    if not rule then
                        out.verdict = 'matches no rule, so it stays put'
                    elseif rule.keep then
                        out.verdict = 'pinned in place by ' .. rule.label
                    else
                        local cands, why = candidates(item, rule, state)
                        out.chain = chain_names(cands)
                        if acceptable_here(item, rule, cands) then
                            out.verdict = 'already in an acceptable bag'
                        elseif #cands == 0 then
                            out.verdict = 'cannot move: ' .. (why or 'no accessible bag')
                        elseif rule.soft and item.bag_id == INV then
                            out.verdict = 'stays in Inventory unless it gets crowded'
                        else
                            out.verdict = 'will move to the first bag with room'
                        end
                    end
                end
                return out
            end
        end
    end
    return nil
end

return planner

--[[
    sorter.lua — Rule matching, move planning, and execution.

    KEY CONSTRAINT (FFXI game rule):
        You cannot move an item directly between two non-Inventory bags.
        Every transfer must pass through Inventory (bag id 0):
            source(non-inv) -> Inventory -> target(non-inv)
        If the source IS Inventory:           Inventory -> target        (1 hop)
        If the target IS Inventory:            source    -> Inventory     (1 hop)
        If both source and target are non-inv: source -> Inventory -> target (2 hops)

    Planning is capacity-aware: it simulates slot usage as moves are applied so
    the preview reflects realistic before/after fill levels and flags any bag
    that would overflow. Inventory free slots are also tracked because the
    two-hop moves temporarily consume Inventory space.

    Execution is performed one hop at a time with a configurable delay between
    packets (default 0.7s) to avoid the server rejecting rapid item moves.
]]

local bags = require('lib/bags')
local inventory = require('lib/inventory')

local sorter = {}

-- ---------------------------------------------------------------------------
-- Rule matching
-- ---------------------------------------------------------------------------

-- Convert a wildcard pattern (using '*' as "any sequence") into a Lua pattern.
-- Matching is case-insensitive.
local function wildcard_match(text, pattern)
    if not text or not pattern then return false end
    text = text:lower()
    pattern = pattern:lower()

    if not pattern:find('*', 1, true) then
        -- No wildcard: exact (case-insensitive) match.
        return text == pattern
    end

    -- Escape Lua magic characters, then turn '*' into '.*'.
    local escaped = pattern:gsub('([%^%$%(%)%%%.%[%]%+%-%?])', '%%%1')
    escaped = escaped:gsub('%*', '.*')
    return text:match('^' .. escaped .. '$') ~= nil
end

--- Return the first matching rule for an item, or nil.
-- Rules are evaluated top-to-bottom; first match wins.
function sorter.match_rule(item, rules)
    for _, rule in ipairs(rules) do
        if rule.match_type == 'category' then
            if item.category and item.category:lower() == rule.pattern:lower() then
                return rule
            end
        else -- name (supports wildcards)
            if wildcard_match(item.name, rule.pattern) then
                return rule
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Planning
-- ---------------------------------------------------------------------------

--- Build a move plan given current settings.
-- Returns:
--   {
--     moves = {                      -- ordered list of planned item transfers
--        { name, count, item_id,
--          from_id, from_key, from_name, from_slot,
--          to_id, to_key, to_name,
--          hops = 1 or 2 },
--        ...
--     },
--     unmatched = { {name, count, bag_name}, ... },
--     capacity = {                   -- per target bag, keyed by bag key
--        [key] = { name, before, after, max, over },
--        ...
--     },
--     warnings = { "text", ... },
--   }
function sorter.build_plan(settings)
    local rules = settings.rules or {}
    local enabled = settings.enabled_bags or {}

    local snapshot = inventory.snapshot(enabled)

    -- Track simulated usage per bag id so capacity math reflects the plan.
    local usage = {}   -- bag_id -> { used, max }
    for _, bag in ipairs(snapshot) do
        usage[bag.id] = { used = bag.used, max = bag.max }
    end

    local plan = { moves = {}, unmatched = {}, capacity = {}, warnings = {} }
    local inv_id = bags.INVENTORY_ID

    -- Ensure inventory usage is tracked even if it has no items.
    if not usage[inv_id] then
        local used, max = inventory.usage(inv_id)
        usage[inv_id] = { used = used, max = max }
    end

    for _, bag in ipairs(snapshot) do
        for _, item in ipairs(bag.items) do
            local rule = sorter.match_rule(item, rules)
            if not rule then
                -- No rule -> leave the item where it is.
                plan.unmatched[#plan.unmatched + 1] = {
                    name = item.name, count = item.count, bag_name = bag.name,
                }
            else
                local target = bags.get_by_key(rule.target)
                if not target then
                    plan.warnings[#plan.warnings + 1] =
                        ('Rule for "%s" points to unknown bag "%s" — skipped.'):format(item.name, tostring(rule.target))
                elseif not enabled[target.key] then
                    plan.warnings[#plan.warnings + 1] =
                        ('Target bag "%s" for "%s" is disabled — skipped.'):format(target.name, item.name)
                elseif target.id == bag.id then
                    -- Item already in the correct bag: skip silently.
                else
                    -- Determine hops.
                    local hops = 2
                    if bag.id == inv_id or target.id == inv_id then
                        hops = 1
                    end

                    -- Capacity check on the final target bag.
                    local tu = usage[target.id]
                    if not tu then
                        local used, max = inventory.usage(target.id)
                        tu = { used = used, max = max }
                        usage[target.id] = tu
                    end

                    if tu.used >= tu.max then
                        plan.warnings[#plan.warnings + 1] =
                            ('%s is full — cannot move "%s" there. Skipped.'):format(target.name, item.name)
                    else
                        -- For 2-hop moves, inventory must have a temporary free slot.
                        local inv_usage = usage[inv_id]
                        if hops == 2 and inv_usage.used >= inv_usage.max then
                            plan.warnings[#plan.warnings + 1] =
                                ('Inventory is full — cannot stage "%s" through Inventory. Skipped.'):format(item.name)
                        else
                            -- Record the move.
                            plan.moves[#plan.moves + 1] = {
                                name = item.name,
                                count = item.count,
                                item_id = item.id,
                                from_id = bag.id,
                                from_key = bag.key,
                                from_name = bag.name,
                                from_slot = item.slot,
                                to_id = target.id,
                                to_key = target.key,
                                to_name = target.name,
                                hops = hops,
                            }

                            -- Update simulated usage:
                            -- final target gains one, source loses one.
                            tu.used = tu.used + 1
                            usage[bag.id].used = math.max(0, usage[bag.id].used - 1)
                            -- (Inventory nets zero for a 2-hop move: +1 then -1.)
                        end
                    end
                end
            end
        end
    end

    -- Build capacity impact report for every enabled bag.
    for _, bag in ipairs(snapshot) do
        local u = usage[bag.id]
        local before = 0
        for _, b in ipairs(snapshot) do
            if b.id == bag.id then before = b.used end
        end
        local after = u and u.used or before
        local over = (after > (u and u.max or bag.max))
        plan.capacity[bag.key] = {
            name = bag.name,
            before = before,
            after = after,
            max = u and u.max or bag.max,
            over = over,
            pct = math.floor((after / math.max(1, (u and u.max or bag.max))) * 100),
        }
    end

    return plan
end

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

-- State for an in-progress execution (driven frame-by-frame by the main addon
-- so we never block the game thread).
sorter.exec = {
    running = false,
    plan = nil,
    index = 0,          -- current move index
    stage = 1,          -- current hop within the move (1 or 2)
    next_time = 0,      -- os.clock() timestamp for the next action
    delay = 0.7,
    log = {},           -- human-readable progress log
    done = false,
    total = 0,
    completed = 0,
}

--- Begin executing a plan. Non-blocking; call sorter.tick() every frame.
function sorter.start(plan, delay)
    sorter.exec = {
        running = true,
        plan = plan,
        index = 1,
        stage = 1,
        next_time = os.clock(),
        delay = delay or 0.7,
        log = {},
        done = false,
        total = plan and #plan.moves or 0,
        completed = 0,
    }
    if sorter.exec.total == 0 then
        sorter.exec.running = false
        sorter.exec.done = true
        sorter.exec.log[1] = 'No moves to execute.'
    end
end

-- Perform the actual item move packet for a single hop.
-- Returns true on success, false + reason otherwise.
local function do_move(from_id, from_slot, to_id, count)
    -- Find a free slot in the destination.
    local free = inventory.first_free_slot(to_id)
    if not free then
        return false, bags.name_for(to_id) .. ' is full'
    end
    -- windower.ffxi.move_item(from_bag, from_slot, to_bag, count)
    -- The API auto-selects the destination slot; we validated free space above.
    local ok = pcall(windower.ffxi.move_item, from_id, from_slot, to_id, count or 1)
    if not ok then
        return false, 'move_item failed'
    end
    return true
end

--- Advance execution. Call once per frame. Returns true while still running.
function sorter.tick()
    local e = sorter.exec
    if not e.running then return false end

    local now = os.clock()
    if now < e.next_time then
        return true
    end

    local move = e.plan.moves[e.index]
    if not move then
        e.running = false
        e.done = true
        e.log[#e.log + 1] = ('Sort complete. %d/%d moves executed.'):format(e.completed, e.total)
        return false
    end

    local inv_id = bags.INVENTORY_ID

    if move.hops == 1 then
        -- Single hop: source -> target directly (one of them is inventory).
        local ok, reason = do_move(move.from_id, move.from_slot, move.to_id, move.count)
        if ok then
            e.log[#e.log + 1] = ('Moved %s: %s -> %s'):format(move.name, move.from_name, move.to_name)
            e.completed = e.completed + 1
        else
            e.log[#e.log + 1] = ('SKIP %s (%s -> %s): %s'):format(move.name, move.from_name, move.to_name, reason)
        end
        e.index = e.index + 1
        e.stage = 1
    else
        -- Two hops via inventory.
        if e.stage == 1 then
            -- Hop 1: source -> inventory.
            local ok, reason = do_move(move.from_id, move.from_slot, inv_id, move.count)
            if ok then
                e.log[#e.log + 1] = ('Staging %s: %s -> Inventory'):format(move.name, move.from_name)
                e.stage = 2
                -- We need the item's new slot in inventory for hop 2; recompute
                -- on the next tick by locating it fresh.
                e._staged_item_id = move.item_id
            else
                e.log[#e.log + 1] = ('SKIP %s (%s -> Inventory): %s'):format(move.name, move.from_name, reason)
                e.index = e.index + 1
                e.stage = 1
            end
        else
            -- Hop 2: inventory -> target. Locate the staged item in inventory.
            local from_slot = nil
            local inv = windower.ffxi.get_items(inv_id)
            if type(inv) == 'table' then
                local max = (type(inv.max) == 'number' and inv.max > 0) and inv.max or 80
                for slot = 1, max do
                    local entry = inv[slot]
                    if type(entry) == 'table' and entry.id == e._staged_item_id then
                        from_slot = slot
                        break
                    end
                end
            end

            if from_slot then
                local ok, reason = do_move(inv_id, from_slot, move.to_id, move.count)
                if ok then
                    e.log[#e.log + 1] = ('Moved %s: Inventory -> %s'):format(move.name, move.to_name)
                    e.completed = e.completed + 1
                else
                    e.log[#e.log + 1] = ('SKIP %s (Inventory -> %s): %s'):format(move.name, move.to_name, reason)
                end
            else
                e.log[#e.log + 1] = ('SKIP %s: lost track of item after staging.'):format(move.name)
            end
            e.index = e.index + 1
            e.stage = 1
        end
    end

    e.next_time = now + e.delay
    return e.running
end

--- Return a serialisable snapshot of current execution progress.
function sorter.progress()
    local e = sorter.exec
    return {
        running = e.running,
        done = e.done,
        total = e.total,
        completed = e.completed,
        log = e.log,
    }
end

--- Abort any in-progress execution.
function sorter.stop()
    sorter.exec.running = false
    sorter.exec.done = true
end

return sorter

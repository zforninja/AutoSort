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

-- Convert a wildcard pattern (using '*' as "any sequence") into a Lua pattern.
-- Matching is case-insensitive.
local function wildcard_match(text, pattern)
    if not text or not pattern then return false end
    text = text:lower()
    pattern = pattern:lower()

    if not pattern:find('*', 1, true) then
        return text == pattern
    end

    local escaped = pattern:gsub('([%^%$%(%)%%%.%[%]%+%-%?])', '%%%1')
    escaped = escaped:gsub('%*', '.*')
    return text:match('^' .. escaped .. '$') ~= nil
end

--- Return the first matching rule for an item, or nil.
-- Rules are evaluated top-to-bottom; first match wins.
function sorter.match_rule(item, rules)
    for _, rule in ipairs(rules) do
        -- 1. Check Category Match
        local cat_match = true
        if rule.category and rule.category ~= "ALL" then
            cat_match = (item.category and item.category:lower() == rule.category:lower())
        end
        
        -- 2. Check Wildcard Pattern Match
        local name_match = true
        if rule.wildcard and rule.wildcard ~= "" and rule.wildcard ~= "*" then
            name_match = wildcard_match(item.name, rule.wildcard)
        end
        
        -- 3. If both conditions apply, this rule matches
        if cat_match and name_match then
            return rule
        end
    end
    return nil
end

function sorter.build_plan(settings)
    local rules = settings.rules or {}
    local enabled = settings.enabled_bags or {}

    local snapshot = inventory.snapshot(enabled)

    local usage = {}   
    for _, bag in ipairs(snapshot) do
        usage[bag.id] = { used = bag.used, max = bag.max }
    end

    local plan = { moves = {}, unmatched = {}, capacity = {}, warnings = {} }
    local inv_id = bags.INVENTORY_ID

    if not usage[inv_id] then
        local used, max = inventory.usage(inv_id)
        usage[inv_id] = { used = used, max = max }
    end

    for _, bag in ipairs(snapshot) do
        for _, item in ipairs(bag.items) do
            local rule = sorter.match_rule(item, rules)
            if not rule then
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
                    local hops = 2
                    if bag.id == inv_id or target.id == inv_id then
                        hops = 1
                    end

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
                        local inv_usage = usage[inv_id]
                        if hops == 2 and inv_usage.used >= inv_usage.max then
                            plan.warnings[#plan.warnings + 1] =
                                ('Inventory is full — cannot stage "%s" through Inventory. Skipped.'):format(item.name)
                        else
                            plan.moves[#plan.moves + 1] = {
                                name = item.name,
                                count = item.count,
                                item_id = item.id,
                                id = item.id,               
                                category = item.category,
                                description = item.description,
                                item_level = item.item_level,
                                level = item.level,
                                jobs = item.jobs,
                                slots = item.slots,
                                from_id = bag.id,
                                from_key = bag.key,
                                from_name = bag.name,
                                from_slot = item.slot,
                                to = target.key,            
                                to_id = target.id,
                                to_key = target.key,
                                to_name = target.name,
                                hops = hops,
                            }

                            tu.used = tu.used + 1
                            usage[bag.id].used = math.max(0, usage[bag.id].used - 1)
                        end
                    end
                end
            end
        end
    end

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

sorter.exec = {
    running = false,
    plan = nil,
    index = 0,          
    stage = 1,          
    next_time = 0,      
    delay = 0.7,
    log = {},           
    done = false,
    total = 0,
    completed = 0,
}

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

local function do_move(from_id, from_slot, to_id, count)
    local free = inventory.first_free_slot(to_id)
    if not free then
        return false, bags.name_for(to_id) .. ' is full'
    end
    local ok = pcall(windower.ffxi.move_item, from_id, from_slot, to_id, count or 1)
    if not ok then
        return false, 'move_item failed'
    end
    return true
end

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
        if e.stage == 1 then
            local ok, reason = do_move(move.from_id, move.from_slot, inv_id, move.count)
            if ok then
                e.log[#e.log + 1] = ('Staging %s: %s -> Inventory'):format(move.name, move.from_name)
                e.stage = 2
                e._staged_item_id = move.item_id
            else
                e.log[#e.log + 1] = ('SKIP %s (%s -> Inventory): %s'):format(move.name, move.from_name, reason)
                e.index = e.index + 1
                e.stage = 1
            end
        else
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

function sorter.stop()
    sorter.exec.running = false
    sorter.exec.done = true
end

return sorter
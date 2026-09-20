--[[
    api.lua — JSON API handlers for the Web UI.

    These run on the game thread (called from server.tick, which the add-on
    drives from prerender), so they may call windower.ffxi.* directly.

    Everything returned here is built explicitly rather than handed straight
    from the planner, because plan entries share item tables and some carry
    metatables, neither of which survive JSON encoding cleanly.
]]

local bags      = require('lib/bags')
local items     = require('lib/items')
local inventory = require('lib/inventory')
local rules     = require('lib/rules')
local baseline  = require('lib/baseline')
local planner   = require('lib/planner')
local executor  = require('lib/executor')

local api = {}

-- Supplied by the add-on so handlers can reach shared state.
-- { get_config = fn, reload = fn, char_name = fn }
api.host = nil

local function config()
    return api.host.get_config()
end

-- Flatten one item for the UI.
local function item_json(it)
    return {
        id = it.id,
        slot = it.slot,
        equippable = it.equippable and true or false,
        furniture = it.furniture and true or false,
        name = it.name,
        count = it.count,
        category = it.category,
        slot_name = it.slot_name,
        stack = it.stack,
        locked = it.locked and true or false,
        rare = it.rare and true or false,
        ex = it.ex and true or false,
        bag_key = bags.get_by_id(it.bag_id) and bags.get_by_id(it.bag_id).key,
        bag_name = it.bag_name,
    }
end

-- ---------------------------------------------------------------------------
-- GET /api/status — every accessible bag with its contents
-- ---------------------------------------------------------------------------
function api.status()
    if not windower.ffxi.get_info().logged_in then
        return { ok = false, error = 'Not logged in.' }
    end

    local out = {}
    for _, bag in ipairs(inventory.snapshot()) do
        local list = {}
        for _, it in ipairs(bag.items) do
            list[#list + 1] = item_json(it)
        end
        out[#out + 1] = {
            key = bag.key, name = bag.name, id = bag.id,
            used = bag.used, max = bag.max, free = bag.free,
            accepts = (bags.get_by_id(bag.id) or {}).accepts,
            items = list,
        }
    end

    return {
        ok = true,
        character = api.host.char_name(),
        bags = out,
        running = executor.state.running and true or false,
    }
end

-- ---------------------------------------------------------------------------
-- GET /api/settings — rules, options, and everything the UI needs for pickers
-- ---------------------------------------------------------------------------
function api.get_settings()
    local cfg = config()

    local catalog = {}
    for _, b in ipairs(bags.list) do
        catalog[#catalog + 1] = {
            key = b.key, name = b.name, id = b.id,
            accepts = b.accepts,
            available = inventory.available(b.id),
        }
    end

    local rule_list = {}
    for _, r in ipairs(cfg.rules) do
        rule_list[#rule_list + 1] = {
            match = r.match, category = r.category, to = r.to,
        }
    end

    local d = cfg.options.defaults or baseline.default_settings()
    local groups = baseline.describe(d, function(key)
        local b = bags.get_by_key(key)
        return b and inventory.available(b.id)
    end)
    -- Name each chain entry so the UI need not look bags up.
    for _, g in ipairs(groups) do
        for _, link in ipairs(g.chain) do
            local b = bags.get_by_key(link.key)
            link.name = b and b.name or link.key
        end
    end
    local inv_max = inventory.bag_info(bags.INVENTORY_ID).max

    return {
        ok = true,
        character = api.host.char_name(),
        rules = rule_list,
        options = {
            delay = cfg.options.delay,
            keep_free = cfg.options.keep_free,
            protect_gear = cfg.options.protect_gear,
            protect = cfg.options.protect,
            defaults = d,
        },
        defaults = {
            enabled = d.enabled,
            inventory_free = d.inventory_free,
            inventory_free_effective = baseline.inventory_target(d, inv_max),
            groups = groups,
        },
        has_rule_file = cfg.exists,
        categories = items.CATEGORIES,
        slots = items.SLOTS,
        bags = catalog,
        problems = cfg.problems,
        rule_file = cfg.path,
        gear_protected = (function()
            local n = 0
            for _ in pairs(cfg.gear_ids or {}) do n = n + 1 end
            return n
        end)(),
    }
end

-- ---------------------------------------------------------------------------
-- POST /api/settings — write the rule file, then reload it
-- ---------------------------------------------------------------------------
function api.save_settings(data)
    if type(data) ~= 'table' then
        return { ok = false, error = 'no payload' }
    end
    if executor.state.running then
        return { ok = false, error = 'A sort is running. Stop it before saving.' }
    end

    local char = api.host.char_name()
    if not char then return { ok = false, error = 'Not logged in.' } end

    local ok, result, problems = rules.save(char, {
        rules = data.rules, options = data.options,
    })
    if not ok then return { ok = false, error = tostring(result) } end

    api.host.reload()
    local settings = api.get_settings()
    settings.saved_to = result
    settings.dropped = problems
    return settings
end

-- ---------------------------------------------------------------------------
-- POST /api/preview — build a plan without moving anything
-- ---------------------------------------------------------------------------
function api.preview(data)
    if not windower.ffxi.get_info().logged_in then
        return { ok = false, error = 'Not logged in.' }
    end

    local only = data and data.bag
    if only and not bags.get_by_key(only) then only = nil end

    -- The Layout page previews rules that are not saved yet. Build a private
    -- copy of the config for that; the saved rules are never touched, and the
    -- payload is validated exactly like a rule file would be.
    local cfg = config()
    local scratch = false
    if data and (type(data.rules) == 'table' or type(data.defaults) == 'table') then
        scratch = true
        local copy = {}
        for k, v in pairs(cfg) do copy[k] = v end
        copy.options = {}
        for k, v in pairs(cfg.options) do copy.options[k] = v end
        if type(data.rules) == 'table' then
            copy.rules = rules.validate(data.rules)
        end
        if type(data.defaults) == 'table' then
            copy.options.defaults = baseline.sanitize(data.defaults)
        end
        cfg = copy
    end

    local plan = planner.build(cfg, only)
    -- A scratch plan must never become the plan a later /api/execute reuses.
    if not scratch then api.host.set_plan(plan, only) end

    local moves = {}
    for _, m in ipairs(plan.moves) do
        moves[#moves + 1] = {
            name = m.name, count = m.count, item_id = m.item_id,
            from_name = m.from_name, to_name = m.to_name, to_key = m.to_key,
            from_key = m.from_key, orig_key = m.orig_key, orig_slot = m.orig_slot,
            hops = m.hops, parked = m.parked and true or false,
            source = m.source, rule_label = m.rule_label, group = m.group,
        }
    end

    local function entry(e)
        local b = bags.get_by_id(e.item.bag_id)
        return { name = e.item.name, item_id = e.item.id, reason = e.reason,
                 bag_key = b and b.key, slot = e.item.slot }
    end
    local blocked, skipped = {}, {}
    for _, b in ipairs(plan.blocked) do blocked[#blocked + 1] = entry(b) end
    for _, sk in ipairs(plan.skipped) do skipped[#skipped + 1] = entry(sk) end

    local capacity = {}
    for key, c in pairs(plan.capacity) do
        capacity[#capacity + 1] = {
            key = key, name = c.name, before = c.before, after = c.after,
            max = c.max, over = c.after > c.max,
        }
    end

    return {
        ok = true, scratch = scratch,
        moves = moves, blocked = blocked, skipped = skipped,
        capacity = capacity, warnings = plan.warnings,
        unmatched = plan.unmatched_count,
        inventory = plan.inventory,
    }
end

-- ---------------------------------------------------------------------------
-- POST /api/execute — run the plan, rebuilt against live state
-- ---------------------------------------------------------------------------
function api.execute()
    if executor.state.running then
        return { ok = false, error = 'A sort is already running.' }
    end
    if not windower.ffxi.get_info().logged_in then
        return { ok = false, error = 'Not logged in.' }
    end

    -- Never execute a stale plan: inventory may have changed since preview.
    local plan = planner.build(config(), api.host.get_plan_bag())
    if #plan.moves == 0 then
        return { ok = true, total = 0, message = 'Nothing to move.' }
    end

    executor.start(plan, config().options)
    return { ok = true, total = #plan.moves }
end

-- ---------------------------------------------------------------------------
-- GET /api/progress
-- ---------------------------------------------------------------------------
function api.progress()
    local p = executor.progress()
    p.ok = true
    return p
end

-- ---------------------------------------------------------------------------
-- POST /api/stop
-- ---------------------------------------------------------------------------
function api.stop_sort()
    if executor.state.running then
        executor.stop('stopped from the Web UI')
        return { ok = true, stopped = true }
    end
    return { ok = true, stopped = false }
end

-- ---------------------------------------------------------------------------
-- POST /api/reload — re-read the rule file from disk
-- ---------------------------------------------------------------------------
function api.reload()
    api.host.reload()
    return api.get_settings()
end

return api

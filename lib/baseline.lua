--[[
    baseline.lua — The built-in default rule set.

    Out of the box AutoSort should do something sensible without any rules
    written. Your own rules always win: they are evaluated first, and these
    only catch what you did not cover.

    Design decisions worth knowing:

    CHAINS, NOT FIXED BAGS. Each group names an ordered list of bags. An item
    goes to the first bag in the list that exists, is reachable right now, and
    has room. A player with one Wardrobe and one with eight get the right
    behaviour from the same rules, and Mog House-only bags simply drop out of
    the chain when you are not at home.

    STABILITY. An item already sitting in any bag of its chain, or in a
    long-term bag (Safe, Locker, Safe 2, Storage), stays put. Running a sort
    twice never reshuffles, and a stash you built on purpose is left alone.

    INVENTORY IS A WORKING BAG. Consumables are "soft": they stay in Inventory
    (you must hold an item in Inventory to use it) and only overflow into the
    Satchel or Sack when Inventory is crowded. Gear, crystals and general
    clutter always leave Inventory.

    GEAR STAYS EQUIPPABLE. Only Inventory and Wardrobes can supply gear to an
    equip command, so gear goes to Wardrobes first.

    Item names below use * wildcards and match case-insensitively.
]]

local baseline = {}

local WARDROBES = {
    'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
}

-- Bags a player fills on purpose. Anything already there is left alone.
local LONG_TERM = { 'safe', 'safe2', 'locker', 'storage' }

local function concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do out[#out + 1] = v end
    end
    return out
end

-- Emergency and utility items you want in reach when something goes wrong.
local ESSENTIALS = {
    'Echo Drops', 'Holy Water', 'Remedy', 'Panacea', 'Antidote', 'Eye Drops',
    'Prism Powder', 'Silent Oil', 'Instant Warp', 'Instant Reraise',
}

-- Ordered by priority: when two groups could match, the earlier one wins, and
-- earlier groups also get first claim on scarce space.
baseline.groups = {
    {
        id = 'essentials',
        label = 'Keep essentials in Inventory',
        description = 'Echo Drops, Remedy, Holy Water, Instant Warp and similar stay exactly where they are.',
        names = ESSENTIALS,
        keep = true,
    },
    {
        id = 'currency',
        label = 'Leave currency items alone',
        description = 'Currency-type items stay where they are.',
        category = 'Currency',
        keep = true,
    },
    {
        id = 'crystals',
        label = 'Crystals and clusters',
        description = 'Go to Mog Case, then Sack, then Satchel.',
        names = { '*Crystal', '*Cluster' },
        targets = { 'case', 'sack', 'satchel' },
        stay = LONG_TERM,
    },
    {
        id = 'furniture',
        label = 'Furniture',
        description = 'Goes to Furniture Storage, then Safe and Locker.',
        category = 'Furniture',
        targets = { 'storage', 'safe', 'locker', 'safe2' },
        stay = LONG_TERM,
    },
    {
        id = 'gear',
        label = 'Gear',
        description = 'Goes to Wardrobes 1 to 8 in order. If they are full, spills to Safe, Locker and Safe 2.',
        category = 'Equipment',
        targets = concat(WARDROBES, { 'safe', 'safe2', 'locker' }),
        stay = LONG_TERM,
    },
    {
        id = 'consumables',
        label = 'Consumables',
        description = 'Stay in Inventory until it gets crowded, then overflow to Satchel, Sack, then Case.',
        category = 'Usable',
        targets = { 'satchel', 'sack', 'case' },
        stay = LONG_TERM,
        soft = true,
    },
    {
        id = 'misc',
        label = 'Everything else',
        description = 'General items go to Case, then Safe and Locker, then Sack and Satchel.',
        category = 'General',
        targets = { 'case', 'safe', 'locker', 'safe2', 'sack', 'satchel' },
        stay = LONG_TERM,
    },
}

baseline.by_id = {}
for _, g in ipairs(baseline.groups) do baseline.by_id[g.id] = g end

--- The default settings block: everything on, Inventory target chosen for you.
function baseline.default_settings()
    local d = { enabled = true, inventory_free = 'auto' }
    for _, g in ipairs(baseline.groups) do d[g.id] = true end
    return d
end

--- Clean a settings block from a file or the UI. Unknown keys are dropped.
function baseline.sanitize(raw)
    local d = baseline.default_settings()
    if type(raw) ~= 'table' then return d end

    if raw.enabled ~= nil then d.enabled = raw.enabled and true or false end
    for _, g in ipairs(baseline.groups) do
        if raw[g.id] ~= nil then d[g.id] = raw[g.id] and true or false end
    end

    local free = raw.inventory_free
    if type(free) == 'number' then
        d.inventory_free = math.max(0, math.floor(free))
    elseif type(free) == 'string' and free:lower() ~= 'auto' and tonumber(free) then
        d.inventory_free = math.max(0, math.floor(tonumber(free)))
    else
        d.inventory_free = 'auto'
    end
    return d
end

--- The rule list the planner evaluates after the player's own rules.
-- `settings` is a sanitized defaults block; nil or disabled yields nothing.
function baseline.rules(settings)
    local out = {}
    if type(settings) ~= 'table' or settings.enabled == false then return out end

    for _, g in ipairs(baseline.groups) do
        if settings[g.id] ~= false then
            local function add(match)
                out[#out + 1] = {
                    match = match,
                    category = g.category,
                    to = g.targets and g.targets[1] or 'keep',
                    targets = g.targets,
                    stay = g.stay,
                    keep = g.keep and true or false,
                    soft = g.soft and true or false,
                    source = 'default',
                    group = g.id,
                    label = 'default: ' .. g.label,
                }
            end
            if g.names then
                for _, name in ipairs(g.names) do add(name) end
            else
                add(nil)
            end
        end
    end
    return out
end

--- How many Inventory slots the baseline should try to keep free.
-- 'auto' is a quarter of the bag, never fewer than five.
function baseline.inventory_target(settings, inventory_max)
    local want = settings and settings.inventory_free
    if type(want) == 'number' then return want end
    return math.max(5, math.floor((inventory_max or 80) * 0.25))
end

--- Describe each group for display: state plus its chain with availability.
-- `is_available(key)` tells whether a bag can be used right now.
function baseline.describe(settings, is_available)
    local info = {}
    for _, g in ipairs(baseline.groups) do
        local chain = {}
        for _, key in ipairs(g.targets or {}) do
            chain[#chain + 1] = { key = key, available = is_available(key) and true or false }
        end
        info[#info + 1] = {
            id = g.id,
            label = g.label,
            description = g.description,
            enabled = settings == nil or settings[g.id] ~= false,
            soft = g.soft and true or false,
            keep = g.keep and true or false,
            chain = chain,
        }
    end
    return info
end

return baseline

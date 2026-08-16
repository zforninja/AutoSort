--[[
    inventory.lua — Read bag contents and expose them in a UI-friendly shape.

    Wraps the Windower FFXI item APIs:
        windower.ffxi.get_items(bag_id)       -> raw item table for a bag
        windower.ffxi.get_bag_count(bag_id)    -> capacity of a bag (max slots)
        res.items[item_id]                     -> static item resource data

    Item categories are derived from the resource data so sort rules can match
    on broad types (Weapon, Armor, Food, Currency, etc.) as well as names.
]]

local res = require('resources')
local bags = require('lib/bags')

local inventory = {}

-- Map a resource item to a coarse, human-friendly category used by rules.
-- The FFXI item resource exposes `category` ('Weapon', 'Armor', 'General',
-- 'Usable', 'Crystal', ...) and `type`. We normalise these into buckets that
-- make sense for sorting.
local function derive_category(item_res)
    if not item_res then return 'Unknown' end

    local category = item_res.category or 'General'
    local skill = item_res.skill

    if category == 'Weapon' then
        return 'Weapon'
    elseif category == 'Armor' then
        return 'Armor'
    elseif category == 'Ranged Weapon' then
        return 'Ranged'
    elseif category == 'Ammunition' then
        return 'Ammo'
    elseif category == 'Usable' then
        -- Food, potions, scrolls, etc.
        if item_res.type == 4 or (item_res.name and item_res.name:lower():find('food')) then
            return 'Food'
        end
        return 'Usable'
    elseif category == 'Crystal' then
        return 'Crystal'
    elseif category == 'Currency' then
        return 'Currency'
    end

    -- Fall back on flags for a few common types.
    if skill and skill ~= 0 then
        return 'Weapon'
    end
    return category or 'General'
end

-- Windower resources expose job/slot/race bitfields via helper tables that
-- carry a :name()/string form. We defensively stringify whatever we get so a
-- resources build that stores plain strings, tables, or bitfields all work.
local function stringify_set(value)
    if value == nil then return nil end
    if type(value) == 'string' then return value end
    if type(value) == 'table' then
        -- Try a few common shapes: array of strings, or map with a tostring.
        local parts = {}
        for _, v in ipairs(value) do
            parts[#parts + 1] = tostring(v)
        end
        if #parts > 0 then return table.concat(parts, ' ') end
        -- Fall back to tostring of the table (some res use metatables).
        local ok, s = pcall(tostring, value)
        if ok and s and not s:find('^table:') then return s end
        return nil
    end
    return tostring(value)
end

-- Human-readable equippable slot names from the resources slot bitfield.
local SLOT_NAMES = {
    [0] = 'Main', [1] = 'Sub', [2] = 'Range', [3] = 'Ammo',
    [4] = 'Head', [5] = 'Body', [6] = 'Hands', [7] = 'Legs',
    [8] = 'Feet', [9] = 'Neck', [10] = 'Waist', [11] = 'L.Ear',
    [12] = 'R.Ear', [13] = 'L.Ring', [14] = 'R.Ring', [15] = 'Back',
}
local function slots_from_bitfield(slots)
    if type(slots) ~= 'number' or slots == 0 then return nil end
    local names = {}
    for bit = 0, 15 do
        if bit32 and bit32.band(slots, bit32.lshift(1, bit)) ~= 0 then
            names[#names + 1] = SLOT_NAMES[bit]
        elseif not bit32 and math.floor(slots / (2 ^ bit)) % 2 == 1 then
            names[#names + 1] = SLOT_NAMES[bit]
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ', ')
end

--- Return details for a single item resource id.
-- Returns a table with id, name, category, stack plus rich metadata
-- (description, jobs, level, slots) sourced from the local Windower
-- `resources` library. No network calls are made here.
function inventory.item_info(item_id)
    local r = res.items[item_id]
    if not r then
        return {
            id = item_id,
            name = 'Unknown (' .. tostring(item_id) .. ')',
            category = 'Unknown',
            stack = 1,
            description = nil,
        }
    end

    -- Description: Windower resources expose this as `description` on modern
    -- builds. Some builds nest the English text; guard every access.
    local description = r.description
    if type(description) == 'table' then
        description = description.en or description.english or description[1]
    end
    if type(description) ~= 'string' then description = nil end
    if description then
        -- DAT descriptions use \n line breaks; normalize to spaces for tooltips.
        description = description:gsub('\r', ''):gsub('\n', ' '):gsub('%s+', ' ')
    end

    return {
        id = item_id,
        name = r.english or r.name or ('Item ' .. tostring(item_id)),
        category = derive_category(r),
        stack = r.stack or 1,
        description = description,
        item_level = r.item_level,
        level = r.level,
        jobs = stringify_set(r.jobs),
        races = stringify_set(r.races),
        slots = slots_from_bitfield(r.slots),
        skill = r.skill,
    }
end

--- Read the capacity (max slots) of a bag. Falls back to the definition max.
function inventory.bag_capacity(bag_id)
    local def = bags.get_by_id(bag_id)
    local cap = nil
    if windower.ffxi.get_bag_count then
        -- get_bag_count returns { count, max } on some builds; guard it.
        local ok, result = pcall(windower.ffxi.get_bag_count, bag_id)
        if ok and type(result) == 'number' then
            cap = result
        end
    end
    return cap or (def and def.max_slots) or 80
end

--- Read all items currently in a bag.
-- Returns { items = { {slot, id, count, name, category, stack}, ... },
--           used = N, max = M }.
function inventory.read_bag(bag_id)
    local result = { items = {}, used = 0, max = inventory.bag_capacity(bag_id) }

    local raw = windower.ffxi.get_items(bag_id)
    if type(raw) ~= 'table' then
        return result
    end

    -- The Windower items table for a bag has numeric slot keys plus metadata
    -- fields like `count`, `max`, `enabled`. Use `max` when present.
    if type(raw.max) == 'number' and raw.max > 0 then
        result.max = raw.max
    end

    for slot = 1, (result.max or 80) do
        local entry = raw[slot]
        if type(entry) == 'table' and entry.id and entry.id ~= 0 then
            local info = inventory.item_info(entry.id)
            result.items[#result.items + 1] = {
                slot = slot,
                id = entry.id,
                count = entry.count or 1,
                name = info.name,
                category = info.category,
                stack = info.stack,
                description = info.description,
                item_level = info.item_level,
                level = info.level,
                jobs = info.jobs,
                slots = info.slots,
            }
            result.used = result.used + 1
        end
    end

    return result
end

--- Build a full status snapshot for every enabled bag.
-- `enabled_bags` is a table keyed by bag key -> boolean.
-- Returns an ordered array of bag snapshots.
function inventory.snapshot(enabled_bags)
    enabled_bags = enabled_bags or {}
    local out = {}
    for _, b in ipairs(bags.list) do
        if enabled_bags[b.key] then
            local data = inventory.read_bag(b.id)
            out[#out + 1] = {
                id = b.id,
                key = b.key,
                name = b.name,
                used = data.used,
                max = data.max,
                items = data.items,
            }
        end
    end
    return out
end

--- Probe a single bag's live accessibility via the Windower API.
-- Returns { available = bool, enabled = bool, count = N, max = M }.
--
-- Detection strategy:
--   * windower.ffxi.get_bag_info(id) reports { count, enabled, max }. The
--     `enabled` flag is the game's own "is this container accessible right
--     now" signal (e.g. Safe/Locker are only enabled inside the Mog House).
--   * That flag is known to false-negative on higher wardrobes on some
--     clients (it derives from an old packet). So we ALSO treat a bag as
--     available whenever it currently holds items (count > 0) — you can't
--     have items in a container you don't have access to.
--   * Inventory (id 0) is always available.
function inventory.detect_bag(bag_id)
    local result = { available = false, enabled = false, count = 0, max = 0 }

    if bag_id == bags.INVENTORY_ID then
        result.available = true
        result.enabled = true
    end

    if windower and windower.ffxi and windower.ffxi.get_bag_info then
        local ok, info = pcall(windower.ffxi.get_bag_info, bag_id)
        if ok and type(info) == 'table' then
            result.enabled = info.enabled and true or false
            result.count = tonumber(info.count) or 0
            result.max = tonumber(info.max) or 0
            if result.enabled or result.count > 0 then
                result.available = true
            end
        end
    end

    -- Fallback: if get_bag_info is unavailable, infer from readable items.
    if not result.available and bag_id ~= bags.INVENTORY_ID then
        local ok, raw = pcall(windower.ffxi.get_items, bag_id)
        if ok and type(raw) == 'table' then
            if raw.enabled == true then
                result.available = true
                result.enabled = true
            elseif type(raw.count) == 'number' and raw.count > 0 then
                result.available = true
            end
        end
    end

    return result
end

--- Detect accessibility for every known bag.
-- Returns a table keyed by bag key -> { available, enabled, count, max }.
function inventory.detect_available()
    local out = {}
    for _, b in ipairs(bags.list) do
        out[b.key] = inventory.detect_bag(b.id)
    end
    return out
end

--- Find the first free slot in a bag, or nil if full.
function inventory.first_free_slot(bag_id)
    local raw = windower.ffxi.get_items(bag_id)
    if type(raw) ~= 'table' then return nil end
    local max = (type(raw.max) == 'number' and raw.max > 0) and raw.max or inventory.bag_capacity(bag_id)
    for slot = 1, max do
        local entry = raw[slot]
        if not (type(entry) == 'table' and entry.id and entry.id ~= 0) then
            return slot
        end
    end
    return nil
end

--- Count used / free slots for a bag.
function inventory.usage(bag_id)
    local data = inventory.read_bag(bag_id)
    return data.used, data.max, (data.max - data.used)
end

return inventory

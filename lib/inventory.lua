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

-- Map specific slot IDs to human-readable granular categories
local SLOT_CATEGORIES = {
    [0] = 'Main', [1] = 'Sub', [2] = 'Ranged', [3] = 'Ammo',
    [4] = 'Head', [5] = 'Body', [6] = 'Hands', [7] = 'Legs',
    [8] = 'Feet', [9] = 'Neck', [10] = 'Waist', [11] = 'Earring',
    [12] = 'Earring', [13] = 'Ring', [14] = 'Ring', [15] = 'Back',
}

-- Extract the primary equipment category from the slots bitfield
local function get_equip_category(slots)
    if type(slots) ~= 'number' or slots == 0 then return nil end
    for bit = 0, 15 do
        if bit32 and bit32.band(slots, bit32.lshift(1, bit)) ~= 0 then
            return SLOT_CATEGORIES[bit]
        elseif not bit32 and math.floor(slots / (2 ^ bit)) % 2 == 1 then
            return SLOT_CATEGORIES[bit]
        end
    end
    return nil
end

-- Map a resource item to a coarse, human-friendly category used by rules.
local function derive_category(item_res)
    if not item_res then return 'Unknown' end

    -- 1. Check for specific equipment slots first
    local equip_cat = get_equip_category(item_res.slots)
    if equip_cat then return equip_cat end

    -- 2. Fall back to generic categories
    local category = item_res.category or 'General'
    if category == 'Usable' then
        if item_res.type == 4 or (item_res.name and item_res.name:lower():find('food')) then
            return 'Food'
        end
        return 'Usable'
    elseif category == 'Crystal' then
        return 'Crystal'
    elseif category == 'Currency' then
        return 'Currency'
    end

    return category or 'General'
end

local function stringify_set(value)
    if value == nil then return nil end
    if type(value) == 'string' then return value end
    if type(value) == 'table' then
        local parts = {}
        for _, v in ipairs(value) do
            parts[#parts + 1] = tostring(v)
        end
        if #parts > 0 then return table.concat(parts, ' ') end
        local ok, s = pcall(tostring, value)
        if ok and s and not s:find('^table:') then return s end
        return nil
    end
    return tostring(value)
end

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

    local description = r.description
    if type(description) == 'table' then
        description = description.en or description.english or description[1]
    end
    if type(description) ~= 'string' then description = nil end
    if description then
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

function inventory.bag_capacity(bag_id)
    local def = bags.get_by_id(bag_id)
    local cap = nil
    if windower.ffxi.get_bag_count then
        local ok, result = pcall(windower.ffxi.get_bag_count, bag_id)
        if ok and type(result) == 'number' then
            cap = result
        end
    end
    return cap or (def and def.max_slots) or 80
end

function inventory.read_bag(bag_id)
    local result = { items = {}, used = 0, max = inventory.bag_capacity(bag_id) }

    local raw = windower.ffxi.get_items(bag_id)
    if type(raw) ~= 'table' then
        return result
    end

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

function inventory.detect_available()
    local out = {}
    for _, b in ipairs(bags.list) do
        out[b.key] = inventory.detect_bag(b.id)
    end
    return out
end

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

function inventory.usage(bag_id)
    local data = inventory.read_bag(bag_id)
    return data.used, data.max, (data.max - data.used)
end

return inventory
--[[
    items.lua — Item metadata and category derivation.

    Wraps Windower's `resources` library so the rest of the add-on sees one
    stable item shape regardless of which resources build is installed.

    Every item exposes TWO categories so rules can be broad or precise:
      category  broad type:  Weapon Armor General Usable Crystal Currency Furniture
      slot      equipment slot: Main Sub Ranged Ammo Head Body Hands Legs Feet
                Neck Waist Ear Ring Back   (nil for non-equipment)

    A rule may match on either, so both `Armor -> wardrobe` and
    `Head -> wardrobe2` work.
]]

local res = require('resources')

local items = {}

local SLOT_NAMES = {
    [0] = 'Main', [1] = 'Sub',  [2] = 'Ranged', [3]  = 'Ammo',
    [4] = 'Head', [5] = 'Body', [6] = 'Hands',  [7]  = 'Legs',
    [8] = 'Feet', [9] = 'Neck', [10] = 'Waist', [11] = 'Ear',
    [12] = 'Ear', [13] = 'Ring', [14] = 'Ring', [15] = 'Back',
}

-- Broad categories a rule may name. Kept in sync with the slot list above.
items.CATEGORIES = {
    'Equipment', 'Weapon', 'Armor', 'General', 'Usable', 'Crystal', 'Currency', 'Furniture',
}
items.SLOTS = {
    'Main', 'Sub', 'Ranged', 'Ammo', 'Head', 'Body', 'Hands', 'Legs',
    'Feet', 'Neck', 'Waist', 'Ear', 'Ring', 'Back',
}

-- Lua 5.1 in Windower has no bitwise operators; use arithmetic.
local function has_bit(value, bit)
    if type(value) ~= 'number' then return false end
    return math.floor(value / (2 ^ bit)) % 2 == 1
end

-- Lowest set bit of the slots bitfield -> canonical slot name.
local function primary_slot(slots)
    if type(slots) ~= 'number' or slots == 0 then return nil end
    for bit = 0, 15 do
        if has_bit(slots, bit) then return SLOT_NAMES[bit] end
    end
    return nil
end

-- All slot names an item can be equipped in, for display.
local function slot_list(slots)
    if type(slots) ~= 'number' or slots == 0 then return nil end
    local out, seen = {}, {}
    for bit = 0, 15 do
        local n = SLOT_NAMES[bit]
        if has_bit(slots, bit) and n and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    return #out > 0 and table.concat(out, '/') or nil
end

-- Windower stores English names under `en` on modern builds; older builds and
-- some forks use `english` or `name`. Try each.
local function english(r)
    return r.en or r.english or r.name
end

--- Look up an item id. Always returns a table, even for unknown ids.
function items.info(id)
    local r = res.items and res.items[id]
    if not r then
        return {
            id = id, name = 'Unknown (' .. tostring(id) .. ')',
            category = 'General', slot = nil, stack = 1,
            equippable = false, furniture = false, rare = false, ex = false,
        }
    end

    local slots = tonumber(r.slots) or 0
    local slot = primary_slot(slots)
    local equippable = slot ~= nil

    -- `category` in Windower resources is a string such as 'Weapon', 'Armor',
    -- 'General', 'Usable', 'Crystal', 'Currency'. Normalize to our list and
    -- fall back to the slot bitfield when the string is missing or unexpected.
    local raw = tostring(r.category or '')
    local category
    if raw == 'Weapon' or raw == 'Armor' or raw == 'Usable'
        or raw == 'Crystal' or raw == 'General' then
        category = raw
    elseif raw:find('^Currency') then
        category = 'Currency'
    elseif equippable then
        category = (slot == 'Main' or slot == 'Sub' or slot == 'Ranged' or slot == 'Ammo')
            and 'Weapon' or 'Armor'
    else
        category = 'General'
    end

    -- Furniture is a General item whose resource type marks it as placeable.
    -- Windower exposes this as type 10 on current builds; the name check is a
    -- backstop for builds that do not set `type`.
    local furniture = (tonumber(r.type) == 10)
    if furniture then category = 'Furniture' end

    -- Rare / Exclusive live in the flags bitfield: bit 15 = Rare, bit 14 = Ex.
    local flags = tonumber(r.flags) or 0

    return {
        id = id,
        name = english(r) or ('Item ' .. tostring(id)),
        category = category,
        slot = slot,
        slots_text = slot_list(slots),
        stack = tonumber(r.stack) or 1,
        level = tonumber(r.level),
        item_level = tonumber(r.item_level),
        equippable = equippable,
        furniture = furniture,
        rare = has_bit(flags, 15),
        ex = has_bit(flags, 14),
    }
end

-- Cache: item metadata never changes during a session.
local cache = {}
function items.get(id)
    local hit = cache[id]
    if not hit then
        hit = items.info(id)
        cache[id] = hit
    end
    return hit
end

--- True when the named string is a category or slot AutoSort understands.
function items.is_valid_category(name)
    if type(name) ~= 'string' then return false end
    local want = name:lower()
    if want == 'all' or want == '' then return true end
    for _, list in ipairs({ items.CATEGORIES, items.SLOTS }) do
        for _, c in ipairs(list) do
            if c:lower() == want then return true end
        end
    end
    return false
end

return items

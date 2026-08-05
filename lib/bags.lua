--[[
    bags.lua — Storage container (bag) definitions for AutoSort.

    Contains the canonical list of every FFXI storage container that the
    Windower 4 API exposes, keyed by the internal bag id used by
    windower.ffxi.get_items / put_item.

    Bag ids verified against the Windower FFXI Lua API and BG Wiki:
        0  inventory  (Gobbiebag)
        1  safe       (Mog Safe 1)
        2  storage    (Furniture Storage)
        3  locker     (Mog Locker)
        4  temporary  (Temporary items — NOT sortable, excluded)
        5  satchel    (Mog Satchel)
        6  sack       (Mog Sack)
        7  case       (Mog Case)
        8  wardrobe   (Mog Wardrobe 1)
        9  wardrobe2  (Mog Wardrobe 2)
        10 safe2      (Mog Safe 2)
        11 wardrobe3  (Mog Wardrobe 3)
        12 wardrobe4  (Mog Wardrobe 4)
        13 wardrobe5  (Mog Wardrobe 5)
        14 wardrobe6  (Mog Wardrobe 6)
        15 wardrobe7  (Mog Wardrobe 7)
        16 wardrobe8  (Mog Wardrobe 8)

    Note: bag id 4 (temporary items) is intentionally omitted because items
    there cannot be freely moved and should never be part of a sort plan.
]]

local bags = {}

-- Ordered list so the UI and iteration are deterministic.
bags.list = {
    { id = 0,  key = 'inventory', name = 'Inventory',      max_slots = 80, note = 'Gobbiebag. Always accessible. 30-80 slots depending on unlocks.' },
    { id = 1,  key = 'safe',      name = 'Mog Safe 1',     max_slots = 80, note = 'Accessible in Mog House.' },
    { id = 2,  key = 'storage',   name = 'Furniture Storage', max_slots = 80, note = 'Uses placed furniture. Slot count depends on furniture.' },
    { id = 3,  key = 'locker',    name = 'Mog Locker',     max_slots = 80, note = 'Requires a paid lease (Imperial Bronze Pieces).' },
    { id = 5,  key = 'satchel',   name = 'Mog Satchel',    max_slots = 80, note = 'Remote-access. Requires Security Token / 2FA.' },
    { id = 6,  key = 'sack',      name = 'Mog Sack',       max_slots = 80, note = 'Remote-access. Purchased from Artisan Moogles.' },
    { id = 7,  key = 'case',      name = 'Mog Case',       max_slots = 80, note = 'Remote-access. Default 80 slots.' },
    { id = 8,  key = 'wardrobe',  name = 'Mog Wardrobe 1', max_slots = 80, note = 'Equipment can be worn directly from a wardrobe.' },
    { id = 9,  key = 'wardrobe2', name = 'Mog Wardrobe 2', max_slots = 80, note = 'Equipment wardrobe.' },
    { id = 10, key = 'safe2',     name = 'Mog Safe 2',     max_slots = 80, note = 'Requires Mog House 2nd floor upgrade.' },
    { id = 11, key = 'wardrobe3', name = 'Mog Wardrobe 3', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
    { id = 12, key = 'wardrobe4', name = 'Mog Wardrobe 4', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
    { id = 13, key = 'wardrobe5', name = 'Mog Wardrobe 5', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
    { id = 14, key = 'wardrobe6', name = 'Mog Wardrobe 6', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
    { id = 15, key = 'wardrobe7', name = 'Mog Wardrobe 7', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
    { id = 16, key = 'wardrobe8', name = 'Mog Wardrobe 8', max_slots = 80, note = 'Requires unlock. Equipment wardrobe.' },
}

-- Lookup tables built from the ordered list.
bags.by_id = {}
bags.by_key = {}
for _, b in ipairs(bags.list) do
    bags.by_id[b.id] = b
    bags.by_key[b.key] = b
end

-- The bag id that acts as the mandatory intermediate for all transfers.
bags.INVENTORY_ID = 0

--- Return the bag definition for a given id, or nil.
function bags.get_by_id(id)
    return bags.by_id[id]
end

--- Return the bag definition for a given key (e.g. 'sack'), or nil.
function bags.get_by_key(key)
    return bags.by_key[key]
end

--- Return the human-readable name for a bag id.
function bags.name_for(id)
    local b = bags.by_id[id]
    return b and b.name or ('Bag ' .. tostring(id))
end

--- Return the list of all bag ids (excluding temporary/4).
function bags.all_ids()
    local ids = {}
    for _, b in ipairs(bags.list) do
        ids[#ids + 1] = b.id
    end
    return ids
end

return bags

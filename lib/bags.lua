--[[
    bags.lua — Storage container definitions.

    Each bag carries:
      id         Windower bag id (get_items / get_item / put_item)
      key        short name used in rules and commands
      name       display name
      accepts    what the container will hold:
                   'any'       anything
                   'equipment' equippable gear only (Wardrobes)
                   'furniture' furniture only (Storage)
      mog_house  true if the bag is only reachable inside a Mog House
      remote     true if reachable anywhere (Satchel/Sack/Case/Wardrobes)

    Bag 3 (temporary items) is excluded: those items cannot be moved.
]]

local bags = {}

bags.INVENTORY_ID = 0

bags.list = {
    { id = 0,  key = 'inventory', name = 'Inventory',         accepts = 'any',       remote = true },
    { id = 1,  key = 'safe',      name = 'Mog Safe',          accepts = 'any',       mog_house = true },
    { id = 2,  key = 'storage',   name = 'Furniture Storage', accepts = 'furniture', mog_house = true },
    { id = 4,  key = 'locker',    name = 'Mog Locker',        accepts = 'any',       mog_house = true },
    { id = 5,  key = 'satchel',   name = 'Mog Satchel',       accepts = 'any',       remote = true },
    { id = 6,  key = 'sack',      name = 'Mog Sack',          accepts = 'any',       remote = true },
    { id = 7,  key = 'case',      name = 'Mog Case',          accepts = 'any',       remote = true },
    { id = 8,  key = 'wardrobe',  name = 'Mog Wardrobe',      accepts = 'equipment', remote = true },
    { id = 9,  key = 'safe2',     name = 'Mog Safe 2',        accepts = 'any',       mog_house = true },
    { id = 10, key = 'wardrobe2', name = 'Mog Wardrobe 2',    accepts = 'equipment', remote = true },
    { id = 11, key = 'wardrobe3', name = 'Mog Wardrobe 3',    accepts = 'equipment', remote = true },
    { id = 12, key = 'wardrobe4', name = 'Mog Wardrobe 4',    accepts = 'equipment', remote = true },
    { id = 13, key = 'wardrobe5', name = 'Mog Wardrobe 5',    accepts = 'equipment', remote = true },
    { id = 14, key = 'wardrobe6', name = 'Mog Wardrobe 6',    accepts = 'equipment', remote = true },
    { id = 15, key = 'wardrobe7', name = 'Mog Wardrobe 7',    accepts = 'equipment', remote = true },
    { id = 16, key = 'wardrobe8', name = 'Mog Wardrobe 8',    accepts = 'equipment', remote = true },
}

bags.by_id, bags.by_key = {}, {}
for i, b in ipairs(bags.list) do
    -- Only Inventory and Wardrobes can supply gear to an equip command.
    b.equip = (b.id == 0) or (b.accepts == 'equipment')
    b.order = i
    bags.by_id[b.id] = b
    bags.by_key[b.key] = b
end

function bags.get_by_id(id)   return bags.by_id[id] end
function bags.get_by_key(key) return key and bags.by_key[tostring(key):lower()] end
function bags.name_for(id)
    local b = bags.by_id[id]
    return b and b.name or ('Bag ' .. tostring(id))
end

--- Can this bag physically hold this item?
-- Returns true, or false plus a reason string.
function bags.accepts(bag, item)
    if type(bag) ~= 'table' then return false, 'unknown bag' end
    if bag.accepts == 'equipment' then
        if not item.equippable then
            return false, bag.name .. ' only holds equipment'
        end
    elseif bag.accepts == 'furniture' then
        if not item.furniture then
            return false, bag.name .. ' only holds furniture'
        end
    end
    return true
end

return bags

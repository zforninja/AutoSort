#!/usr/bin/env python3
"""
Mock server for AutoSort Web UI demo
Serves the static UI and provides mock API responses
"""

from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS
import os

app = Flask(__name__)
CORS(app)

# Mock data storage
mock_settings = {
    "port": 9898,
    "move_delay": 0.7,
    "mule_bag": "sack",  # Designate Mog Sack as mule bag for demo
    "icon_base_url": "https://static.ffxiah.com/images/icon/",
    "show_icons": True,
    "enabled_bags": {
        "inventory": True,
        "safe": True,
        "sack": True,
        "case": True,
        "wardrobe": True,
        "wardrobe2": True,
        "wardrobe3": False,
        "wardrobe4": False,
        "wardrobe5": False,
        "wardrobe6": False,
        "wardrobe7": False,
        "wardrobe8": False,
        "storage": False,
        "locker": False,
        "satchel": True,
        "safe2": False
    },
    "rules": [
        {"match_type": "name", "pattern": "*Sword*", "target": "wardrobe"},
        {"match_type": "name", "pattern": "*Shield*", "target": "wardrobe"},
        {"match_type": "category", "pattern": "Armor", "target": "wardrobe2"},
        {"match_type": "name", "pattern": "*Potion*", "target": "sack"},
        {"match_type": "category", "pattern": "Food", "target": "sack"}
    ]
}

# Mock inventory data
mock_inventory = {
    "inventory": {
        "name": "Inventory",
        "id": 0,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 16769, "name": "Bronze Sword", "count": 1, "category": "Weapon"},
            {"slot": 1, "id": 4509, "name": "Hi-Potion", "count": 12, "category": "Usable"},
            {"slot": 2, "id": 4422, "name": "Meat Mithkabob", "count": 6, "category": "Food"},
            {"slot": 3, "id": 12416, "name": "Bronze Harness", "count": 1, "category": "Armor"},
            {"slot": 4, "id": 16897, "name": "Mythril Sword", "count": 1, "category": "Weapon"},
            {"slot": 5, "id": 17123, "name": "Kite Shield", "count": 1, "category": "Armor"},
            {"slot": 8, "id": 4509, "name": "Hi-Potion", "count": 8, "category": "Usable"},
            {"slot": 10, "id": 646, "name": "Fire Crystal", "count": 12, "category": "Crystal"},
            {"slot": 12, "id": 4545, "name": "Beastman Seal", "count": 5, "category": "Currency"}
        ]
    },
    "safe": {
        "name": "Mog Safe",
        "id": 1,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 16641, "name": "Long Sword", "count": 1, "category": "Weapon"},
            {"slot": 1, "id": 12417, "name": "Chainmail", "count": 1, "category": "Armor"},
            {"slot": 2, "id": 16769, "name": "Bronze Sword", "count": 1, "category": "Weapon"},
            {"slot": 3, "id": 17152, "name": "Longbow", "count": 1, "category": "Ranged"},
            {"slot": 4, "id": 18700, "name": "Arquebus", "count": 1, "category": "Ranged"},
            {"slot": 5, "id": 4509, "name": "Hi-Potion", "count": 20, "category": "Usable"}
        ]
    },
    "sack": {
        "name": "Mog Sack",
        "id": 6,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 4422, "name": "Meat Mithkabob", "count": 12, "category": "Food"},
            {"slot": 2, "id": 4468, "name": "Ether", "count": 6, "category": "Usable"}
        ]
    },
    "case": {
        "name": "Mog Case",
        "id": 7,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 1449, "name": "Copper Ore", "count": 12, "category": "General"},
            {"slot": 1, "id": 1450, "name": "Tin Ore", "count": 8, "category": "General"}
        ]
    },
    "satchel": {
        "name": "Mog Satchel",
        "id": 5,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 646, "name": "Fire Crystal", "count": 12, "category": "Crystal"},
            {"slot": 1, "id": 647, "name": "Ice Crystal", "count": 12, "category": "Crystal"}
        ]
    },
    "wardrobe": {
        "name": "Mog Wardrobe",
        "id": 8,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 12416, "name": "Bronze Harness", "count": 1, "category": "Armor"},
            {"slot": 1, "id": 12545, "name": "Bronze Subligar", "count": 1, "category": "Armor"}
        ]
    },
    "wardrobe2": {
        "name": "Mog Wardrobe 2",
        "id": 10,
        "max": 80,
        "enabled": True,
        "items": [
            {"slot": 0, "id": 15040, "name": "Brass Cap", "count": 1, "category": "Armor"}
        ]
    }
}

# Item metadata lookup (description + attributes) keyed by item id.
# In the live add-on this comes FREE from Windower's local `resources` library.
ITEM_META = {
    16769: {"description": "DMG:7 Delay:240", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "Main", "skill": "Sword"},
    16897: {"description": "DMG:16 Delay:240", "item_level": 0, "level": 12, "jobs": "WAR RDM PLD DRK BRD BST", "slots": "Main", "skill": "Sword"},
    16641: {"description": "DMG:11 Delay:264", "item_level": 0, "level": 5, "jobs": "All Jobs", "slots": "Main", "skill": "Sword"},
    17152: {"description": "DMG:12 Delay:480 Ranged", "item_level": 0, "level": 6, "jobs": "WAR RNG", "slots": "Ranged", "skill": "Archery"},
    18700: {"description": "DMG:20 Delay:600 Ranged", "item_level": 0, "level": 30, "jobs": "COR", "slots": "Ranged", "skill": "Marksmanship"},
    17123: {"description": "DEF:24 Shield Size: 3", "item_level": 0, "level": 20, "jobs": "WAR PLD DRK", "slots": "Sub", "skill": ""},
    12416: {"description": "DEF:12", "item_level": 0, "level": 9, "jobs": "WAR MNK RDM THF", "slots": "Body", "skill": ""},
    12417: {"description": "DEF:20", "item_level": 0, "level": 13, "jobs": "WAR PLD DRK", "slots": "Body", "skill": ""},
    12545: {"description": "DEF:6", "item_level": 0, "level": 9, "jobs": "WAR MNK THF", "slots": "Legs", "skill": ""},
    15040: {"description": "DEF:8", "item_level": 0, "level": 11, "jobs": "All Jobs", "slots": "Head", "skill": ""},
    4509:  {"description": "Restores 150 HP. Recast: 90 sec.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    4468:  {"description": "Restores 150 MP. Recast: 90 sec.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    4422:  {"description": "HP+15% MP+15% while healing (max 25). Duration: 30 min.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    646:   {"description": "A crystal imbued with the power of fire.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    647:   {"description": "A crystal imbued with the power of ice.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    4545:  {"description": "A seal dropped by beastmen. Trade to Shami/Nanaa Mihgo.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    1449:  {"description": "A chunk of unrefined copper ore.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
    1450:  {"description": "A chunk of unrefined tin ore.", "item_level": 0, "level": 1, "jobs": "All Jobs", "slots": "", "skill": ""},
}

def enrich_item(item):
    """Merge stored metadata into an item dict (mimics live resources lookup)."""
    meta = ITEM_META.get(item.get("id"), {})
    out = dict(item)
    for k, v in meta.items():
        out.setdefault(k, v)
    return out

# Full bag catalog (mirrors lib/bags.lua) so the UI can render every container,
# not just the handful that hold demo items.
BAG_CATALOG = [
    {"key": "inventory", "id": 0,  "name": "Inventory",     "note": "Always on — the required intermediate for every move."},
    {"key": "safe",      "id": 1,  "name": "Mog Safe",      "note": "Mog House only."},
    {"key": "storage",   "id": 2,  "name": "Storage",       "note": "Mog House only."},
    {"key": "locker",    "id": 4,  "name": "Mog Locker",    "note": "Mog House only (rented)."},
    {"key": "satchel",   "id": 5,  "name": "Mog Satchel",   "note": "Accessible anywhere."},
    {"key": "sack",      "id": 6,  "name": "Mog Sack",      "note": "Accessible anywhere."},
    {"key": "case",      "id": 7,  "name": "Mog Case",      "note": "Accessible anywhere."},
    {"key": "wardrobe",  "id": 8,  "name": "Mog Wardrobe",  "note": "Equippable storage."},
    {"key": "safe2",     "id": 9,  "name": "Mog Safe 2",    "note": "Mog House only."},
    {"key": "wardrobe2", "id": 10, "name": "Mog Wardrobe 2","note": "Equippable storage."},
    {"key": "wardrobe3", "id": 11, "name": "Mog Wardrobe 3","note": "Equippable storage."},
    {"key": "wardrobe4", "id": 12, "name": "Mog Wardrobe 4","note": "Equippable storage."},
    {"key": "wardrobe5", "id": 13, "name": "Mog Wardrobe 5","note": "Equippable storage."},
    {"key": "wardrobe6", "id": 14, "name": "Mog Wardrobe 6","note": "Equippable storage."},
    {"key": "wardrobe7", "id": 15, "name": "Mog Wardrobe 7","note": "Equippable storage."},
    {"key": "wardrobe8", "id": 16, "name": "Mog Wardrobe 8","note": "Equippable storage."},
]

# Simulates "what the game reports as accessible right now". We pretend the
# player is out in the field, so Mog-House-only bags read as NOT accessible.
MOCK_AVAILABLE = {
    "inventory", "satchel", "sack", "case",
    "wardrobe", "wardrobe2", "wardrobe3", "wardrobe4",
}

# Tracks which bags AutoSort has already auto-enabled (mirrors seen_bags).
# Seed with only the bags currently ON, so accessible-but-off bags
# (wardrobe3/wardrobe4 here) demonstrate auto-enable on the first detect.
mock_seen_bags = {k for k, v in mock_settings["enabled_bags"].items() if v}


def build_catalog_with_detection():
    """Catalog entries enriched with live availability + used/max, like the add-on."""
    out = []
    for b in BAG_CATALOG:
        inv = mock_inventory.get(b["key"])
        used = len(inv["items"]) if inv else 0
        out.append({
            "id": b["id"], "key": b["key"], "name": b["name"], "note": b["note"],
            "enabled": bool(mock_settings["enabled_bags"].get(b["key"], False)),
            "available": b["key"] in MOCK_AVAILABLE,
            "used": used, "max": 80,
        })
    return out

# API Routes
@app.route('/api/status')
def api_status():
    """Returns current inventory status"""
    bags = []
    for key, data in mock_inventory.items():
        if mock_settings["enabled_bags"].get(key, False):
            used = len(data["items"])
            bags.append({
                "key": key,
                "name": data["name"],
                "id": data["id"],
                "max": data["max"],
                "used": used,
                "enabled": data["enabled"],
                "items": [enrich_item(it) for it in data["items"]]
            })
    return jsonify({"bags": bags, "catalog": build_catalog_with_detection()})


@app.route('/api/detect', methods=['POST'])
def api_detect():
    """Auto-enable any newly-accessible bag we haven't seen before.

    Mirrors config.apply_detection: available + not-yet-seen => enable + mark
    seen. Bags already seen keep whatever the user last set, so a manual toggle
    is never overridden.
    """
    global mock_seen_bags
    newly = []
    for b in BAG_CATALOG:
        key = b["key"]
        if key in MOCK_AVAILABLE and key not in mock_seen_bags:
            mock_settings["enabled_bags"][key] = True
            mock_seen_bags.add(key)
            newly.append(key)
    mock_settings["enabled_bags"]["inventory"] = True
    detection = {b["key"]: {"available": b["key"] in MOCK_AVAILABLE}
                 for b in BAG_CATALOG}
    return jsonify({"ok": True, "settings": mock_settings,
                    "detection": detection, "newly": newly})

@app.route('/api/settings', methods=['GET'])
def api_get_settings():
    """Returns current settings"""
    # Full catalog so every container shows in the toggle list + dropdowns.
    catalog = [
        {"key": b["key"], "name": b["name"], "id": b["id"], "note": b["note"]}
        for b in BAG_CATALOG
    ]

    return jsonify({
        "settings": mock_settings,
        "catalog": catalog,
        "categories": ["Weapon", "Armor", "Ranged", "Ammo", "Food", "Usable", "Crystal", "Currency", "General"]
    })

@app.route('/api/settings', methods=['POST'])
def api_save_settings():
    """Saves settings"""
    global mock_settings
    data = request.json
    if data:
        # Update only the fields provided
        if "enabled_bags" in data:
            mock_settings["enabled_bags"] = data["enabled_bags"]
        if "rules" in data:
            mock_settings["rules"] = data["rules"]
        if "move_delay" in data:
            mock_settings["move_delay"] = data["move_delay"]
        if "mule_bag" in data:
            mock_settings["mule_bag"] = data["mule_bag"]
        return jsonify({"ok": True, "settings": mock_settings})
    return jsonify({"ok": False, "error": "Invalid data"}), 400

@app.route('/api/preview', methods=['POST'])
def api_preview():
    """Generates a preview of moves based on current rules"""
    # Mock preview data
    moves = [
        {
            "name": "Bronze Sword",
            "count": 1,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "wardrobe",
            "to_name": "Mog Wardrobe",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "wardrobe", "item": "Bronze Sword"}
            ]
        },
        {
            "name": "Hi-Potion",
            "count": 12,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "sack",
            "to_name": "Mog Sack",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "sack", "item": "Hi-Potion"}
            ]
        },
        {
            "name": "Meat Mithkabob",
            "count": 6,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "sack",
            "to_name": "Mog Sack",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "sack", "item": "Meat Mithkabob"}
            ]
        },
        {
            "name": "Bronze Harness",
            "count": 1,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "wardrobe2",
            "to_name": "Mog Wardrobe 2",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "wardrobe2", "item": "Bronze Harness"}
            ]
        },
        {
            "name": "Mythril Sword",
            "count": 1,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "wardrobe",
            "to_name": "Mog Wardrobe",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "wardrobe", "item": "Mythril Sword"}
            ]
        },
        {
            "name": "Kite Shield",
            "count": 1,
            "from": "inventory",
            "from_name": "Inventory",
            "to": "wardrobe",
            "to_name": "Mog Wardrobe",
            "hops": 1,
            "steps": [
                {"from": "inventory", "to": "wardrobe", "item": "Kite Shield"}
            ]
        },
        {
            "name": "Long Sword",
            "count": 1,
            "from": "safe",
            "from_name": "Mog Safe",
            "to": "wardrobe",
            "to_name": "Mog Wardrobe",
            "hops": 2,
            "steps": [
                {"from": "safe", "to": "inventory", "item": "Long Sword"},
                {"from": "inventory", "to": "wardrobe", "item": "Long Sword"}
            ]
        },
        {
            "name": "Chainmail",
            "count": 1,
            "from": "safe",
            "from_name": "Mog Safe",
            "to": "wardrobe2",
            "to_name": "Mog Wardrobe 2",
            "hops": 2,
            "steps": [
                {"from": "safe", "to": "inventory", "item": "Chainmail"},
                {"from": "inventory", "to": "wardrobe2", "item": "Chainmail"}
            ]
        }
    ]
    
    # Enrich each move with item id + metadata (mimics live sorter output)
    name_lookup = {}
    for data in mock_inventory.values():
        for it in data["items"]:
            name_lookup.setdefault(it["name"], it)
    for mv in moves:
        base = name_lookup.get(mv["name"], {})
        if "id" in base:
            mv.setdefault("id", base["id"])
        if "category" in base:
            mv.setdefault("category", base["category"])
        meta = ITEM_META.get(base.get("id"), {})
        for k, v in meta.items():
            mv.setdefault(k, v)

    capacity_impact = [
        {"bag": "wardrobe", "before": 2, "after": 6, "max": 80, "percent": 7.5, "warning": False},
        {"bag": "wardrobe2", "before": 1, "after": 3, "max": 80, "percent": 3.75, "warning": False},
        {"bag": "sack", "before": 2, "after": 4, "max": 80, "percent": 5.0, "warning": False}
    ]
    
    unmatched = [
        {"item": "Fire Crystal", "bag": "inventory", "category": "Crystal"},
        {"item": "Beastman Seal", "bag": "inventory", "category": "Currency"}
    ]
    
    return jsonify({
        "ok": True,
        "plan": {
            "moves": moves,
            "capacity_impact": capacity_impact,
            "unmatched": unmatched,
            "total_moves": len(moves),
            "total_hops": sum(m["hops"] for m in moves),
            "warnings": []
        }
    })

@app.route('/api/execute', methods=['POST'])
def api_execute():
    """Starts execution of the sort"""
    return jsonify({"success": True, "message": "Sort started (mock)"})

@app.route('/api/progress')
def api_progress():
    """Returns current progress"""
    return jsonify({
        "running": False,
        "current": 0,
        "total": 0,
        "current_move": None
    })

@app.route('/api/stop', methods=['POST'])
def api_stop():
    """Stops the current sort"""
    return jsonify({"success": True, "message": "Sort stopped"})

# Static file serving
@app.route('/')
def index():
    return send_from_directory('ui', 'index.html')

@app.route('/<path:path>')
def serve_static(path):
    return send_from_directory('ui', path)

if __name__ == '__main__':
    print("Starting AutoSort Mock Server...")
    print("Web UI will be available at: http://localhost:9898")
    print("Press Ctrl+C to stop")
    app.run(host='0.0.0.0', port=9898, debug=False)

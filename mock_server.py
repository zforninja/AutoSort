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
    return jsonify({"bags": bags})

@app.route('/api/settings', methods=['GET'])
def api_get_settings():
    """Returns current settings"""
    # Build catalog from mock inventory
    catalog = []
    for key, data in mock_inventory.items():
        catalog.append({
            "key": key,
            "name": data["name"],
            "id": data["id"],
            "max": data["max"],
            "note": data.get("note", "")
        })
    
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

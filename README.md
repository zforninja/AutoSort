# AutoSort

**Automatic FFXI inventory sorting for [Windower 4](https://www.windower.net/).**

AutoSort moves items across every FFXI storage container using rules you define, driven by a clean local Web UI. Because FFXI does not allow moving an item directly between two non‑Inventory bags, AutoSort automatically routes every transfer through your Inventory as an intermediate.

---

## Features

- **Local Web UI** at `http://127.0.0.1:9898` — opens in your normal browser when the add‑on loads.
- **Inventory Status** — live view of every enabled bag, slot usage, and contents.
- **Bag Settings** — toggle exactly which of the 16 storage containers you own (Wardrobe 3–8, Locker, Satchel, Sack, etc.).
- **Sort Rules** — map item **names** (with `*` wildcards) or **categories** to a target bag. Rules are evaluated top‑to‑bottom, first match wins. **No default rules — you define everything.**
- **Preview & Execute** — see every planned move, per‑bag capacity impact (before → after, with over‑capacity warnings), and a list of unmatched items *before* anything moves.
- **Safe execution** — moves run one at a time with a configurable delay to avoid server rejections. Full bags and inaccessible containers are skipped with a warning.
- **Persistent settings** — everything is saved to `data/settings.json` and survives reloads.

---

## Installation

1. Locate your Windower `addons` folder, typically:
   ```
   <Windower4>\addons\
   ```
2. Copy the entire `AutoSort` folder into it so you have:
   ```
   <Windower4>\addons\AutoSort\AutoSort.lua
   <Windower4>\addons\AutoSort\lib\...
   <Windower4>\addons\AutoSort\ui\...
   ```
3. In game, load the add‑on:
   ```
   //lua load AutoSort
   ```
4. AutoSort prints the Web UI URL to chat. Open it with:
   ```
   //autosort open
   ```

To load automatically at launch, add `lua load AutoSort` to your `scripts/init.txt`.

---

## Commands

| Command | Description |
|---|---|
| `//autosort open` | Open the Web UI in your default browser. |
| `//autosort url` | Print the Web UI URL to chat. |
| `//autosort start` | (Re)start the HTTP server. |
| `//autosort stop` | Stop the HTTP server. |
| `//autosort reload` | Reload settings from `data/settings.json`. |
| `//autosort port <n>` | Change the server port (then `//autosort start`). |
| `//autosort sort` | Preview and immediately execute a sort from chat. |

Short alias: `//asort` works everywhere `//autosort` does.

---

## Usage

1. **Bag Settings tab** — enable the storage containers you actually own. Inventory is always on because it is the required intermediate for every move.
2. **Sort Rules tab** — add rules. For each rule choose:
   - **Type**: `Name` (matches the item name, supports `*` wildcards) or `Category` (matches a broad item type).
   - **Match**: the pattern or category.
   - **Target Bag**: where matching items should go.
   Use the ↑ / ↓ buttons to order rules — the **first** matching rule wins. Click **Save Rules**.
3. **Preview & Execute tab** — click **Generate Preview** to see all planned moves, capacity impact, and unmatched items. When you're happy, click **Execute Sort** and watch the progress log.

---

## Rule configuration examples

| Type | Match | Target Bag | Effect |
|---|---|---|---|
| Name | `*Sword*` | Mog Sack | Any item with "Sword" in its name → Mog Sack |
| Name | `Excalibur` | Mog Wardrobe 1 | Exactly "Excalibur" → Wardrobe 1 |
| Category | `Food` | Mog Satchel | All food items → Satchel |
| Category | `Crystal` | Mog Sack | All crystals → Sack |
| Name | `*Ore` | Mog Case | Any item ending in "Ore" → Case |
| Category | `Currency` | Mog Safe 1 | Currency items → Safe 1 |

**Wildcards:** `*` matches any sequence of characters. Matching is case‑insensitive.
- `*Potion*` → matches "Hi‑Potion", "Potion +1", etc.
- `Fire *` → matches "Fire Crystal", "Fire Cluster".
- `Excalibur` (no `*`) → exact match only.

**Categories** available: `Weapon`, `Armor`, `Food`, `Usable`, `Crystal`, `Currency`, `General`.

---

## How sorting works (the Inventory intermediate)

FFXI forbids moving an item directly between two non‑Inventory bags. AutoSort handles this automatically:

- **Source is Inventory** → `Inventory → target` (1 hop)
- **Target is Inventory** → `source → Inventory` (1 hop)
- **Both are other bags** → `source → Inventory → target` (2 hops)

The preview shows a **hops** badge on each move. Two‑hop moves temporarily consume an Inventory slot, so the planner also verifies Inventory has room and warns you if it doesn't.

### Edge cases handled

- **Bag not accessible / unreadable** — skipped, with a warning.
- **Target bag full** — the move is skipped and reported; other moves continue.
- **Item already in the correct bag** — silently skipped (no wasted move).
- **No matching rule** — the item is left exactly where it is and listed under *Unmatched*.
- **Inventory full during a 2‑hop move** — that move is skipped and reported.

---

## Project structure

```
AutoSort/
├── AutoSort.lua        Main add-on: events, commands, API glue
├── lib/
│   ├── bags.lua        Storage container definitions (bag ids/names)
│   ├── config.lua      Load/save data/settings.json
│   ├── inventory.lua   Read bag contents & capacities
│   ├── sorter.lua      Rule matching, move planning, execution
│   └── server.lua      Non-blocking HTTP server + JSON API
├── ui/
│   ├── index.html      Single-page, tabbed Web UI
│   ├── app.js          Frontend logic (vanilla JS)
│   └── style.css       Dark theme
├── data/
│   └── settings.json   Your saved bags + rules (auto-created)
└── README.md
```

## HTTP API (for reference)

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/status` | All items in enabled bags + full bag catalog |
| GET | `/api/settings` | Current settings, bag catalog, categories |
| POST | `/api/settings` | Save enabled bags + rules |
| POST | `/api/preview` | Build a move plan from current rules |
| POST | `/api/execute` | Begin executing the last previewed plan |
| GET | `/api/progress` | Live execution progress + log |
| POST | `/api/stop` | Abort a running sort |

---

## Notes & safety

- The HTTP server binds to `127.0.0.1` only — it is **not** reachable from other machines.
- Item moves are throttled (default **0.7s** apart, adjustable in Bag Settings) to avoid server‑side rejection.
- Always run a **Preview** first so you can see exactly what will move.
- AutoSort never deletes or drops items — it only relocates them between your own storage.

## Supported storage containers

Inventory, Mog Safe 1, Furniture Storage, Mog Locker, Mog Satchel, Mog Sack, Mog Case, Mog Wardrobe 1–8, Mog Safe 2. (Temporary items are intentionally excluded — they cannot be freely moved.)

---

## License

MIT — see `LICENSE` if included, otherwise free to use and modify.

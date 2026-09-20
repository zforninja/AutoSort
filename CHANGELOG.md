# Changelog

All notable changes to AutoSort are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0]

A ground-up rewrite. Sorting is now driven by chat commands and a per-character
rule file with sensible built-in defaults; the Web UI becomes a drag-and-drop
rule editor rather than the primary interface; and every move is verified after
it happens instead of being fired and assumed.

### Added

- **Built-in default rule set (`lib/baseline.lua`).** AutoSort does something
  sensible with no rules written. Defaults are organized as **chains** — an
  ordered list of bags per group (Essentials, Currency, Crystals, Furniture,
  Gear, Consumables, Everything else). An item goes to the first bag in its
  chain that exists, is reachable, and has room; unreachable bags drop out
  quietly instead of raising errors.
- **Per-character rule file (`data/<Character>.lua`).** Plain, hand-editable Lua
  with `options`, `defaults`, and `rules` sections. Created by `//as setup` or
  by saving from the UI. The previous file is kept as `.bak` on every save.
- **GearSwap protection.** Gear referenced by your GearSwap files is never moved
  anywhere but Inventory and Wardrobes, so a sort can't leave it un-equippable.
  Re-scan with `//as gear`. Toggle with `options.protect_gear`.
- **Move verification (`lib/executor.lua`).** Each hop re-reads the bags and
  confirms the item actually landed by comparing the destination total before
  and after. A hop that does not land within five seconds is reported as failed
  and the run continues.
- **Capacity-aware wave scheduling (`lib/planner.lua`).** Moves are simulated
  against a copy of every bag's free space and scheduled in waves so a bag is
  never overfilled. Full-bag swaps are broken by parking an item in Inventory
  (needs two free Inventory slots; otherwise reported as blocked, never
  attempted). A parked item is never left stranded.
- **Two categories per item (`lib/items.lua`).** Every item exposes a broad
  `category` (Weapon, Armor, General, Usable, Crystal, Currency, Furniture) and,
  for equipment, an equipment `slot` (Main, Sub, Ranged, Ammo, Head, Body,
  Hands, Legs, Feet, Neck, Waist, Ear, Ring, Back). Rules may match on either.
- **New chat commands:** `preview [bag|all]`, `sort [bag]` + `yes`, `go [bag]`,
  `stop`, `status`, `rules`, `defaults ...`, `explain <item>`, `check`, `setup`,
  `reload`, `gear`, plus the existing `open` / `url` / `start` / `port`.
- **`//as explain <item>` and `//as check`** — diagnostics that report which
  rule applies to an item and how your items are being categorized.
- **Web UI drag-to-rule editor (`ui/layout.js`, `ui/rulegen.js`).** Drag an
  item (or a multi-select) onto a bag to generate a rule for the item, its
  category, or its slot (switch, or hold Shift / Alt while dragging). Drops onto
  bags that can't hold the item are refused. Generated rules are auto-ordered
  (item > slot > category) so a specific rule is never hidden by a broad one.
- **"Current / After sort" view.** The UI re-plans on every change using your
  *unsaved* rules, showing exactly where everything ends up before anything is
  saved or moved, with arrows for moved items and their origin.
- **Session-key security for the Web UI.** The server binds to `127.0.0.1` only
  and requires a random session key that changes each start; `//as open` embeds
  it in the URL, so a bare `localhost:9898` is refused by design.
- **`data/.gitkeep`** so the rule-file directory exists in a fresh checkout.
- **`CHANGELOG.md`** (this file) and a **`LICENSE`** file (MIT).

### Changed

- **Interaction model.** Sorting is now command- and rule-file-driven; the Web
  UI is a rule editor rather than the required control surface.
- **Sort stability.** Items already in an acceptable bag of their chain (or in
  Safe/Locker/Safe 2/Storage) stay put — sorting twice never reshuffles, and
  deliberate stashes are left alone.
- **Inventory treated as a working bag.** Consumables leave Inventory only when
  it is crowded, and only enough to reach the free-slot target
  (`auto` = a quarter of Inventory, minimum five).
- **Rewritten README** with quick start, requirements, defaults table,
  rule-file reference, command reference, troubleshooting, and project layout.
- **`.gitignore`** now excludes per-character rule files (`data/*.lua`) while
  keeping `data/.gitkeep`.

### Removed

- **`mock_server.py`** — the standalone Python UI stub. The add-on's own
  non-blocking Lua server (`lib/server.lua`) plus `lib/api.lua` now serve the UI
  directly.
- **`lib/config.lua`** — replaced by the per-character rule file and
  `lib/rules.lua`.
- **`lib/sorter.lua`** — split into `lib/planner.lua` (planning) and
  `lib/executor.lua` (verified execution).

### Migration from 1.x

- On first load, run `//as setup` to create `data/<Character>.lua`, then
  `//as check` to confirm your items categorize correctly.
- Old `data/settings.json` from 1.x is no longer read; recreate your bag
  choices and rules in the new rule file (or via the UI, which writes it for
  you). The built-in defaults mean most players need few or no custom rules.
- Rules moved from the old `{category, wildcard, target}` shape to
  `{ match = '...', to = '...' }` / `{ category = '...', to = '...' }`. `match`
  takes `*` wildcards; `to` is a bag key or `keep`.

## [1.0.0]

Initial Web-UI-driven release.

### Added

- Local Web UI (served by `lib/server.lua`) with tabs for live Inventory
  Status, Bag Settings, Sort Rules, and Preview & Execute.
- User-defined sort rules with slot-based item categories and dual-condition
  matching (category + name wildcard); first-match-wins.
- Capacity-aware preview and execution routing all non-Inventory transfers
  through Inventory as a 1-hop / 2-hop intermediate, with a configurable delay.
- Automatic bag detection with auto-enable and manual override.
- Persistent settings in `data/settings.json`.
- `//autosort` (`//asort`) commands: `open`, `url`, `start`, `stop`, `reload`,
  `port <n>`, `detect`.

[2.2.0]: https://github.com/zforninja/AutoSort/releases/tag/v2.2.0
[1.0.0]: https://github.com/zforninja/AutoSort/releases/tag/v1.0.0

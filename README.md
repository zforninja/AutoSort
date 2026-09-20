# AutoSort 2.2

**Rule-driven inventory sorting for [Windower 4](https://www.windower.net/) that
works out of the box.** Load it, type `//as sort`, and it sorts based on the
items you own and the bags you can actually reach. Add your own rules only where
you disagree.

![Platform](https://img.shields.io/badge/platform-Windower%204-blue)
![Game](https://img.shields.io/badge/FFXI-retail-9cf)
![Lua](https://img.shields.io/badge/Lua-5.1%20%2F%20LuaJIT-000080)
![Version](https://img.shields.io/badge/version-2.2.0-brightgreen)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

> **Upgrading from 1.x?** 2.0 is a ground-up rewrite: sorting is now driven by
> chat commands and a per-character rule file with sensible built-in defaults,
> the Web UI is a drag-and-drop editor rather than the primary interface, and
> every move is verified after it happens. See [CHANGELOG.md](CHANGELOG.md) for
> the full list and a migration note.

## Table of contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [The built-in defaults](#the-built-in-defaults)
- [Overriding the defaults](#overriding-the-defaults)
- [The Web UI](#the-web-ui)
- [The rule file](#the-rule-file)
- [Commands](#commands)
- [How it works](#how-it-works)
- [What AutoSort will not move](#what-autosort-will-not-move)
- [Troubleshooting](#troubleshooting)
- [Known limits](#known-limits)
- [Project structure](#project-structure)
- [Changelog](#changelog)
- [License](#license)

## Quick start

Copy this folder to `<Windower4>\addons\AutoSort\`, then in game:

```
//lua load AutoSort
//as preview        see what a sort would do; nothing moves
//as sort           preview, then confirm with //as yes
```

For a visual editor: `//as open` (drag items onto bags to make rules).

## Requirements

- **Windower 4** with the `resources` library it ships with (used for item
  names, categories, and furniture detection).
- **Final Fantasy XI** (retail). No third-party servers are targeted.
- **Lua 5.1 / LuaJIT** — the runtime Windower 4 already embeds. Nothing to
  install separately.
- **GearSwap (optional).** If present, gear referenced by your GearSwap files is
  automatically protected so a sort never leaves it un-equippable. Without
  GearSwap, everything else still works; only that protection is skipped.

## The built-in defaults

With no rules written, AutoSort applies these, in order. Each group names a
**chain** of bags. An item goes to the first bag in its chain that exists, is
reachable right now, and has room. Bags you do not own, or cannot reach outside
your Mog House, simply drop out of the chain.

| Group | What it matches | Where it goes |
| --- | --- | --- |
| Essentials | Echo Drops, Remedy, Holy Water, Instant Warp, ... | Stays put |
| Currency | Currency-type items | Stays put |
| Crystals | `*Crystal`, `*Cluster` | Case, Sack, Satchel |
| Furniture | Furniture | Storage, Safe, Locker, Safe 2 |
| Gear | Anything equippable | Wardrobes 1 to 8, then Safe, Locker, Safe 2 |
| Consumables | Usable items | Stay in Inventory; overflow to Satchel, Sack, Case only if Inventory is crowded |
| Everything else | General items | Case, Safe, Locker, Safe 2, Sack, Satchel |

Design choices worth knowing:

* **Stable.** An item already in a bag of its chain, or in Safe, Locker, Safe 2
  or Storage, stays put. Sorting twice never reshuffles, and a stash you built
  on purpose is left alone.
* **Inventory is a working bag.** You must hold an item in Inventory to use it,
  so consumables leave only when Inventory is crowded, and only enough to reach
  the free-slot target (`auto` is a quarter of your Inventory, at least five).
* **Gear stays equippable.** Only Inventory and Wardrobes can supply gear to an
  equip command, so gear goes to Wardrobes first, and gear your GearSwap files
  reference is never moved anywhere else.
* **Never nags.** If a default group has no reachable bag (say, no Wardrobes
  yet), those items are left alone quietly rather than reported as errors.

## Overriding the defaults

Your rules are checked first and the first match wins, so anything you write
overrides the defaults. Defaults still handle everything you did not cover.

```
//as defaults              show every group, its state, and its chain
//as defaults gear off     switch one group off
//as defaults off          switch all defaults off (your rules only)
//as defaults free 15      keep 15 Inventory slots free (or: auto)
//as explain iron sword    which rule applies to an item, and what happens
//as check                 how your items are being categorized
```

## The Web UI

`//as open` launches it in your browser.

**Layout** shows every bag with its items.

* **Drag an item onto a bag** to make a rule that keeps it there.
* **Click items to select several,** then drag any one of them, or press
  *Move here* on a bag.
* A drop makes a rule for **the item**, **its category**, or **its slot**.
  Choose with the switch, or press **Shift** (category) or **Alt** (slot)
  *while dragging*.
* Dropping something onto a bag that cannot hold it (a crystal onto a
  gear-only Wardrobe) is refused.
* Rules land in the right order automatically: item rules above slot rules
  above category rules, so a specific rule is never hidden by a broad one.
* **Current / After sort.** Every change re-plans with your *unsaved* rules, so
  *After sort* shows exactly where everything will end up before anything is
  saved or moved. Items that will move carry an arrow; arrivals show where they
  came from.

**Rules** has the defaults card (toggle groups, see each chain with unreachable
bags struck through) and your own rule list. **Preview & Sort** shows every
planned move tagged *your rule* or the default group responsible.

Rules save to `data/<Character>.lua` and the UI and chat commands share that
one file. The previous file is kept as `.bak` on every save.

Security: the server binds to `127.0.0.1` only and needs a random session key
that changes each time it starts. `//as open` includes it in the URL, so
typing `localhost:9898` by hand will not work. This is deliberate.

## The rule file

`data/<Character>.lua` (created by `//as setup`, or by saving from the UI):

```lua
return {
    options = {
        delay        = 0.8,   -- seconds between moves
        keep_free    = 2,     -- inventory slots never filled by a sort
        protect_gear = true,  -- keep GearSwap-referenced gear equippable
        protect      = { 'Warp Ring' },
    },

    defaults = {
        enabled        = true,
        inventory_free = "auto",     -- or a number
        essentials = true, currency = true, crystals = true, furniture = true,
        gear = true, consumables = true, misc = true,
    },

    rules = {
        { match = 'Hi-Potion', to = 'keep'     },
        { match = '*Ninja Tool*', to = 'sack'  },
        { category = 'Head',   to = 'wardrobe2' },
    },
}
```

**Fields.** `match` is an item name with `*` wildcards, case-insensitive.
`category` is `Equipment`, `Weapon`, `Armor`, `General`, `Usable`, `Crystal`,
`Currency`, `Furniture`, or a slot: `Main Sub Ranged Ammo Head Body Hands Legs
Feet Neck Waist Ear Ring Back`. `to` is a bag key or `keep`.

**Bags:** `inventory safe storage locker satchel sack case wardrobe wardrobe2
... wardrobe8 safe2`.

A rule with neither `match` nor `category` matches everything, so the UI never
saves one.

## Commands

| Command | What it does |
| --- | --- |
| `//as preview [bag\|all]` | Show planned moves without moving anything |
| `//as sort [bag]` | Preview, then confirm with `//as yes` |
| `//as go [bag]` | Sort immediately, no confirmation |
| `//as stop` | Abort a running sort |
| `//as status` | Slot usage for every accessible bag |
| `//as rules` | List your rules |
| `//as defaults ...` | Show or change the built-in defaults |
| `//as explain <item>` | What a sort would do with an item, and why |
| `//as check` | How your items are being categorized |
| `//as setup` / `reload` | Create / re-read the rule file |
| `//as open` / `url` | Open the Web UI / print its address |
| `//as start` / `stop server` / `port <n>` | Control the Web UI server |
| `//as gear` | Re-scan GearSwap for protected gear |

`//as` and `//autosort` are interchangeable.

## How it works

FFXI cannot move items directly between two non-Inventory bags, so those moves
go through Inventory in two hops. The planner simulates free space and schedules
moves in waves so a bag is never overfilled. If two full bags must swap
contents, it parks an item in Inventory to break the deadlock; this needs **two
free Inventory slots**, and if they are not there the moves are reported as
blocked rather than attempted. A parked item is never left stranded.

Every hop is verified by comparing the destination's total of that item before
and after. A hop that does not land within five seconds is reported as failed
and the run continues. A running sort aborts on zone change or logout.

## What AutoSort will not move

* Equipped items, or anything else the game marks as in use
* Items on your `protect` list
* Gear referenced by your GearSwap files, anywhere but Inventory and Wardrobes
* Items into a bag that cannot hold them
* Anything matching no rule

AutoSort never drops, sells, or deletes anything.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| **Almost everything reads as `General`** | Run `//as check`. If categories look wrong across the board, your Windower `resources` build is likely stale — update Windower. Report it if updating does not help. |
| **A default group moves nothing** | The group's whole chain may be unreachable (e.g. no Wardrobes, or you are outside your Mog House). That is intentional — AutoSort leaves those items alone rather than erroring. Use `//as status` to see which bags are reachable. |
| **`localhost:9898` shows nothing** | The Web UI needs the random session key in the URL. Always launch it with `//as open` (or copy the address from `//as url`); a bare `localhost` URL is refused by design. |
| **Moves reported as blocked** | A full-bag swap needs at least two free Inventory slots to park an item. Free some Inventory and sort again, or raise `keep_free`. |
| **Gear I use went to a Wardrobe I did not want** | GearSwap-referenced gear is protected only from leaving Inventory/Wardrobes. Pin specific pieces with a rule (`{ match = 'My Item', to = 'keep' }`) or add them to `options.protect`. |
| **A sort seems stuck** | `//as stop` aborts immediately. Sorts also abort automatically on zone change or logout. |

## Known limits

* Rules that pull items *into* Inventory compete with the defaults' free-slot
  target. Your rule wins, so repeated sorts converge slowly.
* Item categories and furniture detection depend on Windower's resource data.
  Run `//as check`; if nearly everything reads as General, tell the developer.
* The default lists (essentials, chains) are opinionated. Every group can be
  switched off, and any item can be overridden.

## Project structure

```
AutoSort/
├── AutoSort.lua          Add-on entry point: commands, event loop, wiring
├── lib/
│   ├── bags.lua          Canonical bag list, IDs, keys, reachability
│   ├── items.lua         Item metadata + category / slot derivation
│   ├── inventory.lua     Reading bag contents and capacities
│   ├── rules.lua         Rule matching + per-character rule-file load/save
│   ├── baseline.lua      Built-in default rule set (chains)
│   ├── planner.lua       Classify items, then schedule capacity-safe moves
│   ├── executor.lua      Perform each hop and verify it landed
│   ├── api.lua           JSON API handlers for the Web UI
│   ├── server.lua        Non-blocking localhost HTTP server
│   └── jsonutil.lua      JSON encode/decode helper
├── ui/
│   ├── index.html        Web UI shell
│   ├── app.js            UI state + API client
│   ├── layout.js         Bag/item layout + Current / After-sort view
│   ├── rulegen.js        Drag-to-rule generation
│   └── style.css         Dark theme
├── data/
│   └── .gitkeep          Rule files (data/<Character>.lua) live here, gitignored
├── README.md
└── CHANGELOG.md
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history, including the
1.x → 2.x rewrite and migration notes.

## License

Released under the [MIT License](LICENSE).

# targethud

Ashita v4 addon that bundles three HUDs into one, with per-character settings and an ImGui settings window:

- **Bar**: HP bars for your target, sub-target and pet, plus cast, job ability and menu-hover recast panels. Based on targetbar.
- **Ring**: ground rings under the target and sub-target, with facing arrow, runes and in-range fill. Also draws GEO bubble rings that track which mobs inside a Geo-/Indi-/Entrust bubble already have enmity. Ported from Broguypal's targetring.
- **AAEV**: auto-attack chart (per swing or per round) with accuracy, crit, average, zone accuracy and weaponskill log. Optional pet chart for BST, DRG, SMN and PUP. Ported from darkewaffle's AAEV.

## Install

1. Clone or copy this repo into `Ashita/addons/targethud/`. The folder name must be `targethud`.
2. In game: `/addon load targethud`

```
Ashita/addons/targethud/
  targethud.lua        entry point (events, commands, settings)
  hud_bar.lua          target / cast / JA / menu bars
  hud_ring.lua         ground rings + GEO bubbles
  hud_aaev.lua         auto-attack chart
  hud_aaev_data.lua    AAEV message / skill tables
  hud_gui.lua          settings window
```

## Commands

```
/targethud                      toggle settings window
/targethud ring                 ring status
/targethud ring on|off|depth|arrow|runes|fade|flip
/targethud ring scale <n> | slices <n>
/targethud ring range on|off|geo|hitbox | base <n> | fill <n>
/targethud geo [on|off|buffs|cure|bubble|clear | radius|cap|scan|slices <n>]
/targethud aaev on|off          enable / disable auto-attack chart
/targethud aaev                 toggle charts
/targethud aaev show|hide|demo|lock|unlock|simple|full
/targethud aaev bars <n> | delay <n> | autohide | always
/targethud aaev zone | zonereset | config | reload | help
```

Anything else after `/targethud` prints the command list.

## Settings

Settings are saved per character by Ashita's settings library:

```
Ashita/config/addons/targethud/<Name>_<id>/bar.lua
Ashita/config/addons/targethud/<Name>_<id>/ring.lua
Ashita/config/addons/targethud/<Name>_<id>/aaev.lua
```

Before login they go to `.../targethud/defaults/`. Use the settings window (`/targethud`) rather than editing these files by hand.

- **Bar position:** in the Bar tab, uncheck *Lock position* to drag the bar, then check it again.
- **AAEV chart position:** use `/targethud aaev unlock`, drag the chart, then `/targethud aaev lock`.
- **AAEV is off by default.** Turn it on with `/targethud aaev on` or in the AAEV tab.

### Importing old addon settings

Old settings are imported once per character, the first time each block loads:

| From | Read from | Into |
|---|---|---|
| targetbar | `config/addons/targetbar/<Name>_<id>/settings.lua` | `bar.lua` |
| targetring | `config/addons/targetring/<Name>_<id>/settings.lua` | `ring.lua` |
| aaev | `addons/aaev/aaev_settings.lua`, `aaev_saved.lua`, `aaev_positions.lua` | `aaev.lua` (also turns AAEV on) |

## Notes

- **Ring depth test:** off by default. Turn it on with `/targethud ring depth` to hide rings behind terrain. If rings disappear when it is on, Ashita's present-time render target has no depth surface, so turn it back off.
- **Ring range fill:** distance is measured center to center. With *Add both hitboxes* on, the range edge is base range + your hitbox + the target's hitbox.
- **GEO Indicolure timer:** 180s base + gear seconds + 2s per Indicolure Spell Effect Dur. job point level, then multiplied by augment %. Job point levels are read from packet 0x08D.
- **Rings hide** when the game interface is hidden, during cutscenes, and while the map or expanded log menus are open.

## Credits

- targetbar: aryl
- targetring: Broguypal (Windower original); Ashita v4 port
- AAEV: darkewaffle (Windower original); Ashita v4 port
- Packet layouts: atom0s' [XiPackets](https://github.com/atom0s/XiPackets). Augment and mob-skill lookups follow Thorny's [LuAshitacast](https://github.com/ThornyFFXI/LuAshitacast).

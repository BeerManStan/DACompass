# DACompass

A crafting compass for FFXI / Ashita v4, by **BeerManStan**. Named for DASoccer, who says facing doesn't matter. Naturally, that called for a compass and a spreadsheet.

DACompass puts the old community "Synthing Compass" chart on screen, shows which way you're facing, and records your synth results. The chart's arrow and crescent headings are a crafting theory, not a promise of better results. The ledger keeps the breaks as well as the HQs.

Version **0.1.2**. Prepared for Phoenix XI review; publishing this repository does not mean the addon has server approval.

## Install

1. Download this repository using **Code > Download ZIP**, then extract it.
2. Copy the **dacompass** folder into your Ashita `addons` folder.
3. In game, run `/addon load dacompass`.

The installed files should look like this:

```text
Ashita/
  addons/
    dacompass/
      dacompass.lua
      compass.lua
      sounds/
        xylophone_e4.wav
```

You only need that folder to run the addon. The tests and development tools stay outside your game installation.

## Using the compass

Choose a crystal with `/dac fire` (or another element), then choose `/dac safe` for the chart's arrow heading or `/dac hq` for its crescent heading. The dial shows your heading to 0.1 degrees and tells you how far to turn. A chime sounds when you enter the target band, which defaults to +/-3 degrees.

The addon can pick up the crystal automatically when you confirm a synth. It cannot see that choice just from opening the synthesis menu, so select it manually if you want guidance before your first synth.

| Crystal | Arrow / safe | Crescent / HQ and skill-ups |
| --- | --- | --- |
| Fire | NW | W |
| Earth | S | SE |
| Water | W | SW |
| Wind | SE | E |
| Ice | E | NW |
| Lightning | SW | S |
| Light | NE | N |
| Dark | N | NE |

These are the community chart's directions. They are not verified server mechanics.

| Command | What it does |
| --- | --- |
| `/dac` | Show or hide the compass |
| `/dac <crystal>` | Select fire, earth, water, wind, ice, lightning, light, or dark; thunder also works |
| `/dac none` | Clear the selection; auto selection can still pick up the next synth |
| `/dac safe` or `/dac hq` | Choose the arrow or crescent heading |
| `/dac north` or `/dac heading` | Keep north at the top, or rotate the dial with your heading |
| `/dac config` | Open the settings window |
| `/dac status` | Print your heading and target in chat |
| `/dac tol 1` | Set the target band to +/-1 degree |
| `/dac chime on` or `/dac chime off` | Enable or disable the chime |
| `/dac auto on` or `/dac auto off` | Enable or disable crystal selection from synth packets |
| `/dac ledger on` or `/dac ledger off` | Enable or disable writing synths to disk |
| `/dac stats` | Show synth counts, break/HQ rates, and total skill gains |
| `/dac lock` or `/dac unlock` | Lock or unlock the window position |
| `/dac size 200` | Set the dial size in pixels |
| `/dac cal` | Print raw yaw and the calculated bearing |
| `/dac setnorth` | Use your current facing as north |
| `/dac help` | Show command help |

If the heading is wrong on your client, face a known north direction and run `/dac setnorth`.

## Synth ledger

Results are saved locally to `dacompass/dacompass_ledger.csv`. Each row includes the crystal, goal, facing, distance from both chart headings, Vana'diel day, moon percentage, result, item, quantity, and total skill gain in tenths. Heading is sampled when you confirm the synth.

Stats group synths into the arrow sector, crescent sector, or everywhere else, per crystal and overall. These groups use the nearest 45-degree compass point; changing the chime tolerance does not change the groups. HQ and break percentages use all synths in the group as their denominator. Main and sub-craft skill gains are added together.

The addon waits about 1.5 seconds after the result packet before saving, so a late skill-up message can attach to the same synth. When ledger writing is disabled, current-session stats still update, but those new results are not saved for the next load. These counts are observational; different recipes, skills, and conditions can affect comparisons.

## For reviewers

- Reads the local player's heading through Ashita's entity API and day/moon through `ffxi.time`.
- Observes outgoing `0x096` synthesis requests and incoming `0x030`, `0x06F`, and `0x029` packets to track your synths.
- Does not inject or modify game packets, turn the character, start synths, or automate inputs. Its command handler consumes its own `/dac` and `/dacompass` commands.
- Draws an ImGui overlay, plays a bundled local sound, saves addon settings, and optionally writes the local CSV ledger.
- Makes no network requests and uploads no ledger data.

Earlier development notes report live Phoenix XI checks of item, result, day, and moon percentage. The moon phase **name** still needs an in-game check. The automated tests use a fake Ashita host and do not replace an in-game compatibility check.

## Development

Requires LuaJIT on your PATH, or in one of the Windows locations checked by `check.ps1`.

```powershell
.\check.ps1
.\check.ps1 -SyntaxOnly
```

To run only the DACompass tests:

```text
luajit tests/dacompass_spec.lua
```

The suite currently has 157 assertions covering the chart, bearings, packet decoding, chime, crystal selection, synth results, skill gains, CSV output, and commands.

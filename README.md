Retakes for Counter-Strike: Source
==================================

A port of [splewis/csgo-retakes](https://github.com/splewis/csgo-retakes) (v0.3.4) from CS:GO to **Counter-Strike: Source**. [Русская версия](README.ru.md).

Retakes: the terrorists spawn inside a bombsite with the bomb, the counter-terrorists spawn on the rotation routes and have to retake the site and defuse. It can be played by humans, by bots, or by a mix of both.

> **Status.** The port was tested on a live CS:S server during development: the core, the warmup, the spawn editor, bots, the `retakes_allocator` allocator, the autoplant and the autodefuse. Still open: `retakes_bothelper` on a 64-bit server (it was tested on a 32-bit Windows server). Such places are marked with `// CSS-VERIFY:` comments in the code. How the port works and how CS:S differs from CS:GO for a plugin is described in [PORTING.md](PORTING.md).

## Requirements

- A Counter-Strike: Source dedicated server (post February 2025 update, 64-bit).
- Metamod:Source 1.12+ and SourceMod 1.12+.
- No extra extensions, gamedata or libraries: only `sdktools`, `sdkhooks`, `cstrike` and `clientprefs` that ship with SourceMod.

The plugin refuses to load on any other game.

## Installation

1. Build the plugins with `./build.sh` (see [Building](#building)); the compiled `.smx` files end up in `build/`. The repository has no prebuilt plugins.
2. Copy to the server's `cstrike/` directory (or unpack the archive made by `./dist.sh`, see [Building](#building): it has everything below except `warmup.smx`):
   - `build/retakes.smx` → `addons/sourcemod/plugins/`
   - `warmup.smx` → `addons/sourcemod/plugins/` (optional: without it there is no warmup; it lives in a separate repository, see [Warmup plugin](#warmup-plugin))
   - `translations/` → `addons/sourcemod/translations/`
   - `cfg/sourcemod/retakes/` → `cfg/sourcemod/retakes/`
   - `configs/retakes/` → `addons/sourcemod/configs/retakes/`
3. A weapon allocator, one of the three (see [Addon plugins](#addon-plugins)); the main one is `build/retakes_allocator.smx` → `addons/sourcemod/plugins/`. The `retakes-css-server.zip` archive already has it in `plugins/` (next to `retakes_autoplant` and `retakes_autodefuse`, which are switched off by their cvars, and `retakes_sitepicker`, which does nothing until an admin runs `sm_site a|b`), with the other two allocators in `plugins/disabled/`.
4. Start a map with two bombsites and create the spawns (see below). The mode does not start without spawns; the plugin says so in chat every round.

`cfg/sourcemod/retakes/retakes.cfg` is generated on the first run. `cfg/sourcemod/retakes/retakes_game.cfg` is executed on every map start and sets the game up (team balancing, limits, bot behaviour); the previous values are restored when the plugin is disabled.

The same file switches the map rotation to its own list: `mapcyclefile "mapcycle_retakes.txt"`. The list is not shipped: create `mapcycle_retakes.txt` next to the standard `mapcycle.txt` of your server and put the maps that have spawns in it, one per line (for the shipped spawns: `de_dust2`, `de_cache`, `de_nuke`, `de_strike_mirage`). To keep the usual rotation, delete this line from `retakes_game.cfg`.

## Spawns

Spawn configs are included for `de_dust2`, `de_cache`, `de_nuke`, and `de_strike_mirage` (`configs/retakes/`). If you have spawns for the CS:GO or CS2 version of a map, you can port them to CS:S with the [spawn radar](https://kolka2.github.io/css-retakes/). Open the source file, align the points with the CS:S radar, and export a `.cfg`. If you adjusted the radar binding to align the points, **use the target CS:S map’s original binding** from its `overview.txt` when exporting.

The radar only lets you verify **X and Y**. A spawn can look right from above and still be at the wrong height. Check and adjust its **Z** in the in-game editor. For a first approximation, stand at the intended spawn location in CS:S and read your Z coordinate with `getpos` or `cl_showpos 1`. With Z scaling off, subtract the source spawn’s Z from that value and enter the difference in the “Z offset” field when exporting. The offset applies to every exported point, so check each spawn’s final height in-game.

The in-game editor requires the `changemap` admin flag `g`.

| Chat | Console | What it does |
|---|---|---|
| `!edit` | `sm_edit` | enter the editor and open its menu; in the editor everybody respawns, the round never ends, there are no bots |
| `!endedit` | `sm_endedit` | leave the editor and start the game; the same as "Exit edit mode" in the menu. Unsaved spawns stay in memory until the map changes; only `!savespawns` writes them to the file, and leaving the editor reminds about them |
| `!show a` / `!show b` | `sm_show a` / `sm_show b` | show the spawns of a site (rings: blue — CT, red — T, green — T "bomb carrier only", yellow — T "never bomb carrier") |
| `!new ct a`, `!new t b` … | `sm_new ct a`, `sm_new t b` … | create a spawn where you stand (the view angle is saved); the menu also lets you pick the T spawn type |
| `!delete` | `sm_delete` | delete the nearest spawn of the shown site |
| `!goto 10`, `!nearest` | `sm_goto 10`, `sm_nearest` | teleport to a spawn by index (an index that does not exist is reported; the shown site switches to the spawn's one) / to the nearest spawn of the shown site |
| `!next`, `!prev` | `sm_next`, `sm_prev` | teleport to the next / previous spawn in index order, wrapping around; the shown site switches to the spawn's one; also in the `!edit` menu |
| `!iteratespawns` | `sm_iteratespawns` | visit every spawn in turn (the shown site switches to each spawn's one) |
| `!savespawns`, `!reloadspawns` | `sm_savespawns`, `sm_reloadspawns` | save (replies with the number of spawns written) / reload from the file, discarding changes |
| `!deletemapspawns` | `sm_deletemapspawns` | delete all spawns of the map; like any other edit it reaches the file only on `!savespawns`, until then `!reloadspawns` or a map change brings everything back |
| `!retakes_validatespawns` | `sm_retakes_validatespawns` | check the spawns and print a report |

Each site needs:

- T spawns **inside the bomb target area** — the bomb carrier only spawns on such a spawn;
- a few more T spawns around it and CT spawns on the rotation routes;
- the map needs at least `sm_retakes_maxplayers` spawns in total, otherwise the plugin does not set the teams.

T spawn types (same as in the original plugin):

| Type | Ring | Who spawns there |
|---|---|---|
| Normal | red | any terrorist, **the bomb carrier included** if the spawn is inside the bomb target area |
| Bomb-carrier only | green | the bomb carrier only; only makes sense inside the bomb target area |
| Never bomb-carrier | yellow | any terrorist except the bomb carrier |

"Bomb-carrier only" does not tie the bomb carrier to that spot, it only closes the spot for everybody else. The bomb carrier is picked at random among all green **and red** spawns inside the bomb target area. To make the bomb carrier spawn on dedicated spots only, mark the other T spawns inside the bomb target area as "Never bomb-carrier". The type of an existing spawn cannot be edited: delete it (`!delete`) and create it again through `!edit` → "Add a spawn".

Leave the editor with "Exit edit mode" in the `!edit` menu; the game restarts. Spawns are stored in `addons/sourcemod/configs/retakes/<map>.cfg`; the file changes only on an explicit save (`!savespawns` or "Save map spawns" in the menu), unsaved changes are lost on map change.

## How it plays

- **Warmup.** A warmup of `sm_retakes_warmuptime` seconds follows the map start. It is run by the separate `warmup.smx` plugin (see [Warmup plugin](#warmup-plugin)); Retakes only starts it and stays out of the way while it runs: no teams or spawns, no waiting queue, no money or bomb handling, no weapon allocation. When the warmup ends the first retake begins. Without `warmup.smx` there is no warmup.
- **Teams.** After the warmup the plugin manages the teams. A joining player is put in the waiting queue (spectators) and enters the game on the next round. Players cannot switch sides themselves: picking T or CT in the team menu while on a team does nothing; going to spectators is allowed and takes the player out of the queue, and picking a team from spectators puts them back in it. The share of terrorists is `sm_retakes_ratio_constant`. Players earn round points (damage, kills, bomb, winning); the top scorers play the next round as T. After `sm_retakes_scramble_rounds` T wins in a row the teams are scrambled.
- **Round.** The plugin picks a site, moves the players to the spawns, gives weapons, armor and defuse kits and zeroes the money — there is no buying. One T standing in the bombsite has the bomb and `sm_retakes_round_time` seconds to plant it, otherwise the CTs win.
- **Weapons.** Without an allocator: T — AK-47 and Glock, CT — M4A1 and USP, armor and helmet for everybody. `!guns` opens the allocator menu if one is installed; in that case a joining player is told about it once per connection.

## Bots

Bots are full participants, but humans always come first.

- The plugin manages the number of bots through `bot_quota`: while there are fewer humans (playing or queued) than `sm_retakes_bots_total`, bots fill the game up to that number. Do not set `bot_quota` yourself.
- A human never waits because of a bot: when a human arrives, one bot leaves on the next round.
- No humans — no bots. There are no bots in the spawn editor either.
- A bot can be the bomb carrier and plants with the stock AI. `sm_retakes_bots_carry_bomb 0` gives the bomb to a human whenever there is one among the terrorists.
- `sm_retakes_bots 0` — no bots at all (the plugin keeps `bot_quota 0`).
- Bot difficulty and behaviour are set with the usual cvars (`bot_difficulty` etc.) in `retakes_game.cfg`.

Bots need a navigation file (`.nav`) for the map.

## Cvars

Stored in `cfg/sourcemod/retakes/retakes.cfg`.

| Cvar | Default | Description |
|---|---|---|
| `sm_retakes_enabled` | `1` | whether the plugin is enabled |
| `sm_retakes_maxplayers` | `9` | maximum number of participants in a round (humans + bots) |
| `sm_retakes_ratio_constant` | `0.425` | share of the participants that play as T |
| `sm_retakes_round_time` | `12` | seconds the terrorists have to plant the bomb |
| `sm_retakes_warmuptime` | `25` | warmup length on map start, seconds; `0` disables the warmup. Needs `warmup.smx`; everything else about the warmup is set with its `sm_warmup_*` cvars |
| `sm_retakes_scramble_rounds` | `10` | consecutive T wins that cause a team scramble; `0` — never |
| `sm_retakes_random_teams` | `0` | `1` — random teams every round |
| `sm_retakes_auto_set_teams` | `1` | `0` — the plugin does not touch the teams |
| `sm_retakes_editor_enabled` | `1` | whether the spawn editor can be launched |
| `sm_retake_message_prefix` | `[{GREEN}Retakes{NORMAL}]` | chat message prefix |
| `sm_retakes_bots` | `1` | **new.** `0` — no bots, `1` — fill the game with bots |
| `sm_retakes_bots_total` | `6` | **new.** how many participants (humans + bots) to keep while there are fewer humans; capped by `sm_retakes_maxplayers` |
| `sm_retakes_bots_carry_bomb` | `1` | **new.** whether a bot can carry the bomb; with `0` a bot only carries it when there are no humans among the terrorists |
| `sm_retakes_debug` | `0` | **new.** `1` — detailed log of the plugin's decisions in `addons/sourcemod/logs/retakes_debug.log` |

Other commands:

- `sm_guns` / `!guns` — weapon menu;
- `sm_scramble` — scramble the teams on the next round (admin);
- `sm_retakes_warmup [seconds]` — start a warmup without changing the map and reset the Retakes progress: round points, win streak, round counter (admin). Without a number `sm_retakes_warmuptime` is used, `0` ends the warmup right away. Needs `warmup.smx`; does not work in the spawn editor.

## Addon plugins

Optional plugins, installed next to `retakes.smx`. Use only one allocator.

- `retakes_standardallocator` — rifle choice through `!guns`: CT — M4A1 / AUG / FAMAS, T — AK-47 / SG 552 / Galil; players may opt in for the AWP (one per team at most); armor, helmet and a random grenade for everybody.
- `retakes_pistolallocator` — pistol rounds: Glock and USP (with armor), P228, Five-SeveN, Desert Eagle, Dual Elites (no armor) or random.
- `retakes_allocator` — rounds of different types: pistol, bonus, force buy, buy and "free choice" of any weapon, in a circle or in a random order; grenades chosen by the player. See [Round type allocator](#round-type-allocator-retakes_allocator).
- `retakes_sitepicker` — admin command `sm_site a|b|any` to play a single site.
- `retakes_autoplant` — autoplant: the bomb is planted for the bomb carrier (human or bot) where the carrier stands, and is already ticking when the round goes live. The game itself does the plant: when the freezetime ends, the plugin switches the carrier to the C4, keeps them in place, holds the attack button for them and cuts the C4 draw time and the three-second arming time to zero. No gamedata is needed. Cvars (config `cfg/sourcemod/retakes/retakes_autoplant.cfg`):
  - `sm_retakes_autoplant_enabled` (default `0`) — turns the autoplant on; with `0` the plugin is loaded but does nothing, the carrier plants by hand;
  - `sm_retakes_autoplant_progressbar` (default `1`) — a human carrier sees a progress bar (the one of the defuse) in the last three seconds of the freezetime, the time a plant by hand takes; it fills up by the moment of the plant. With `mp_freezetime` 1 or 2 the bar is one or two seconds long; with 0 there is none;
  - `sm_retakes_autoplant_sound` (default `1`) — in the last seconds of the freezetime the keypad clicks of a bomb being armed are played at the carrier (human or bot), all seven of them, as in a plant by hand. With a freezetime shorter than three seconds the clicks start right after the round start and may end after the bomb is planted.

  The carrier sees no planting animation: the game client does not show it when the button is "pressed" by the server. The game drops the fraction of `mp_freezetime` (with `1.5` the freezetime lasts 1 second), and so does the plugin.

  The bomb is planted in an instant the moment the freezetime ends. A carrier who starts outside a bomb target gets no progress bar, keypad clicks or early switch to the C4. The addon can still plant if the carrier enters a target within its five-second retry window after freezetime. If the bomb is still unplanted at the deadline, the plugin backs off and the carrier plants by hand. With `sm_retakes_debug 1` it writes `logs/retakes_autoplant_debug.log`. The game only plants from a C4 that is in the hands, so a human carrier holding another weapon is switched to the C4 a second before the end of the freezetime. The planting animation of the player model (crouching and putting the bomb down), as the other players see it, is played in the last 2.8 seconds of the freezetime: the carrier (human or bot) is switched to the C4 3.3 seconds before the end, and the game's own animation, which would come after the plant, is held back. With `mp_freezetime` below 4, or if the C4 is not in the hands in time, there is no animation at all (and no early switch to the C4): it would end in the live round. Without this (the planting temp entity not found, see the error log) the switch is a second ahead, as before, and the animation plays in the live round. The animation and its timing were checked on a live server. The muzzle flash and the ejected shell during the planting animation are the game's own: they are there in a plant by hand too. The plant, the progress bar and the clicks were checked on a live server; the prebuilt archive has the plugin in `plugins/`, switched off by the cvar.
- `retakes_autodefuse` — autodefuse: when a CT starts defusing while no terrorist is alive and the bomb has more time left than that defuse needs, the defuse is finished at once. The defuse kit counts: a defuse takes 5 seconds with a kit and 10 without, so with 7 seconds left a CT with a kit defuses in an instant, while a CT without one defuses as usual (and is late). With a terrorist alive or not enough time the plugin stays out. The game itself ends the defuse (the plugin only moves the moment it is complete to "now"), no gamedata is needed. Cvar (config `cfg/sourcemod/retakes/retakes_autodefuse.cfg`):
  - `sm_retakes_autodefuse_enabled` (default `0`) — turns the autodefuse on; with `0` the plugin is loaded but does nothing.

  The check is made once, when the defuse starts: if the last terrorist dies while a CT is already defusing, that defuse runs its normal course (or the CT may let go and start again). The plugin does nothing during the warmup and in the spawn editor. With `sm_retakes_debug 1` it writes `logs/retakes_autodefuse_debug.log`. Checked on a live server with bots; the server archive has the plugin in `plugins/`, switched off by the cvar.
- `retakes_bothelper` — bot helper: the CT bots go straight to the planted bomb instead of checking the bombsites one by one. See [Bot helper](#bot-helper-retakes_bothelper). **Needs a gamedata file.** Checked on a 32-bit Windows server; not checked on 64-bit servers (Windows, Linux) yet. The prebuilt archive has it in `plugins/`, switched on, with the gamedata in `addons/sourcemod/gamedata/`.

### Bot helper (retakes_bothelper)

A CS:S CT bot learns from the plant event that the bomb was planted, but not where: it only finds out when it gets within 1500 units of the beeping bomb or when another bot reports it over the radio. Until then the bots check the bombsites one by one. The moment the bomb shows up, the plugin writes its position and bombsite to every living CT bot — into the same fields of the bot's memory the game fills in when a bot finds the bomb. The stock AI does the rest: the bot plans a path and goes to defuse. The plugin does not touch the bots' movement, aim or shooting, nor humans or terrorist bots.

- It acts once per round: on the `bomb_planted` event or when a `planted_c4` entity appears, whichever comes first. A CT bot that spawns after the plant is told 0.1 s after its spawn.
- It works without Retakes too (on any CS:S server). With Retakes it only acts in a live game: nothing happens in the warmup, in the spawn editor or with `sm_retakes_enabled 0`.
- It needs `addons/sourcemod/gamedata/retakes_bothelper.games.txt` (`gamedata/` in the repository). The file holds the offsets of the fields in the bot's memory; they are there for Windows servers (32 and 64 bit: `srcds.exe` and `srcds_win64.exe`) and 64-bit Linux (game version 11003710), each with its own. The plugin does not work on a 32-bit Linux server.
- SourceMod 1.12 cannot call the game's function directly on a 64-bit server, so the plugin writes the fields itself. Before every write it checks that the memory at those offsets holds what is expected. If the gamedata is missing, has no entry for your system or the check fails, the plugin writes **one error** to `logs/errors_*.log` and does nothing more; the server runs as usual.
- Do not combine it with plugins that create "bots" through `CreateFakeClient` (other than SourceTV): those are not bots of the game, the plugin will see the mismatch and switch itself off until it is reloaded.

Cvars (config `cfg/sourcemod/retakes/retakes_bothelper.cfg`):

| Cvar | Default | Meaning |
|---|---|---|
| `sm_retakes_bothelper_enabled` | `1` | switch |
| `sm_retakes_bothelper_delay` | `0.0` | seconds between the bomb showing up and the bots being told |
| `sm_retakes_bothelper_debug` | `0` | log `logs/retakes_bothelper_debug.log`: which bots were told, the position, the failed checks |
| `sm_retakes_bothelper_version` | — | version |

On load the plugin writes one line to the SourceMod log: its version, whether the gamedata was loaded and whether Retakes was found.

**After a game update.** The offsets may move. Signs: a line `The game state of … does not look right` or `has no offset` in `errors_*.log`, or the bots checking the bombsites again. What to do:

1. Do not edit by guess: with wrong offsets the plugin refuses to work by itself, and that does not harm the server.
2. The easiest way is to send the developer the new server binary (`cstrike/bin/linux64/server.so` or `cstrike/bin/x64/server.dll`) and the `PatchVersion` line of `cstrike/steam.inf`.
3. To check it yourself you need a disassembler (Ghidra, IDA; `objdump` is enough on Linux):
   - find the string `ERROR: Bomb planted outside of a zone!` and the small (about 100 bytes) function that refers to it — that is `CSGameState::UpdatePlantedBomb`. On Linux it is found by name: `objdump -d -M intel server.so | grep -A40 '<_ZN11CSGameState17UpdatePlantedBombERK6Vector>:'`;
   - the end of that function has four writes relative to its first argument: the bombsite index (`m_plantedBombsite`), the three numbers of the position in a row (`m_plantedBombPos`), the byte `1` (`m_isPlantedBombPosKnown`) and the number `2` (`m_bombState`). Their offsets are the values of the gamedata keys of the same names;
   - find where that function is called from (`CCSBot::OnBombBeep`): right before the call there is `lea rcx, [register + N]` (`lea rdi, …` on Linux). `N` is `CCSBot::m_gameState`;
   - `m_isRoundOver`, `m_bombsiteSearchOrder` and `m_bombsiteCount` come earlier in the same object (8, 52 and 68 now); if the four offsets of the function have not changed, neither have they.
4. Write the values to the gamedata file as **decimal numbers** under the key of your system (`windows`, `windows64` or `linux64`), run `sm plugins reload retakes_bothelper` and look at the load line in the log.
5. Set `sm_retakes_bothelper_debug 1` and play a round: the log should have a `told … bombsite N, position …` line for every CT bot and no `check failed` line.

### Round type allocator (retakes_allocator)

Every round has a type. A player "buys" within the budget of the type at CS:S prices; no real money is spent.

| Type | Budget | What a player gets |
|---|---|---|
| `pistol` | $800 | one of: the starting pistol (Glock for T, USP for CT) with kevlar; a P228, Desert Eagle, Five-SeveN (CT) or Dual Elites (T) without armor; no helmet |
| `bonus` | $1700 | a better pistol and kevlar, a helmet with what is left |
| `force` | $3300 | a random primary weapon that fits the budget (no AWP, auto snipers, SG 552, AUG or M249), the starting pistol, as much armor as the money allows: none with an AK-47 or an M4A1, no helmet with a P90, both with the rest (a CT with a FAMAS and a kit has no helmet). The budget prices are not always the game's: Scout $1750, XM1014 $2000, AK-47 $2700 |
| `buy` | covers everything | the rifle chosen in `!guns` (T: AK-47 / Galil / SG 552, CT: M4A1 / FAMAS / AUG), the AWP for one player per team that opted in, the starting pistol, armor and helmet |
| `free` | covers everything | a primary weapon and a pistol out of every weapon of the game, whatever the side: the ones chosen in `!guns`, or random ones every round (the default); armor and helmet |

Defuse kit: every CT in `buy` and `free`; in the other types half of the CTs try to buy one (if $200 are left).

The table describes a player who chose nothing. In `!guns` a weapon can be chosen for every round type and side:

- `pistol` and `bonus` — the pistol (the starting pistol of the side is free, the others cost their price);
- `force` — a primary weapon out of those that fit the budget;
- `buy` — the rifle and the AWP opt-in; `free` — the weapon and the pistol.

The default everywhere but the `buy` rifles is "Random every round", and the loadout is then built as in the table. With a weapon chosen, the kevlar, then the helmet, then the kit are bought after it, so the armor depends on the weapon alone; the menu shows it next to every option, e.g. "AK-47 (no armor)", "Galil (kevlar and helmet)".

The `!guns` menu is grouped by round type ("Pistol round", "Bonus round", "Force buy", "Buy round", "Free choice round") and only lists the types of `sm_retakes_alloc_rounds`; when just one type has anything to set up, its settings are in the main menu itself.

Cvars (`cfg/sourcemod/retakes/retakes_allocator.cfg` is created on the first run):

| Cvar | Default | What it does |
|---|---|---|
| `sm_retakes_alloc_rounds` | `pistol:2,bonus:2,force:3,buy:12` | round types and how many rounds each lasts: `type:rounds,type:rounds,…`; `:rounds` may be left out (1). A single type makes every round the same: `buy` (like the standard allocator), `free` ("chaos") |
| `sm_retakes_alloc_order` | `cycle` | `cycle` — the types are played in a circle, in the order of the list; `random` — the type of every round is drawn anew and the round counts work as weights (by default `buy` comes up in 12 rounds out of 19) |
| `sm_retakes_alloc_random_types` | empty | round types, separated by commas, in which the weapons are always random and what the players chose in `!guns` is ignored: `force`, `pistol,bonus,force,buy,free`. The saved choices are kept, the lines of these types are hidden in the menu. In `buy` it is a random rifle of the side; the AWP still goes only to a player who opted in |
| `sm_retakes_alloc_nades` | `choice` | `choice` — players set up their grenades in `!guns`; `random` — random grenades for everybody |
| `sm_retakes_alloc_nades_count` | empty | grenades per player: empty — by the round type (`pistol` 0–1, `bonus` 1, `force` 0–1, `buy` 1–2, `free` 0–4); a number (`1`) or a range (`0-4`) — the same in every round |

- The position in the cycle comes from the number of Retakes rounds played: it starts over after a map change, `mp_restartgame` and the warmup.
- The round type is announced in chat when the round starts ("Pistol round (1/2)"). With a single type in the list nothing is announced.
- Grenades in the `choice` mode, `!guns` → "Grenades":
  - "Random every round" — the default;
  - "Choose grenades by priority" — a list of up to four grenades (HE, two flashbangs, smoke); in a round the player gets the first N of the list, N being the number of grenades of that round;
  - "Ask me every round" — a menu opens in the pause before the round and takes picks until the end of the freeze time; the grenades the player did not pick by then (all or some of them) are given at random when the freeze time ends. The menu does not replace another open menu (`!guns`, for one) and comes up when that one is closed; it closes by itself when the freeze time ends.
- Presets: "up to one random" — `random` and `0-1`; "one of your choice" — `choice` and `1`; "any set of your choice" — `choice` and `4`; "fully random" — `random` and `0-4`.
- Bots get the default rifles, random weapons in the other round types and random grenades.

### Where weapon choices are stored

A choice made in the `!guns` menu is saved with SourceMod's stock clientprefs mechanism (cookies). It is tied to the player's Steam ID and survives reconnects, map changes and server restarts.

- The data lives in the clientprefs database. By default this is the SQLite file `addons/sourcemod/data/sqlite/clientprefs-sqlite.sq3`; another database can be set in `addons/sourcemod/configs/databases.cfg`, section `clientprefs`.
- `retakes_standardallocator` stores three values: `retakes_ctriflechoice` (CT rifle), `retakes_triflechoice` (T rifle), `retakes_awpchoice` (AWP opt-in).
- `retakes_pistolallocator` stores one: `retakes_pistolchoice` (index of the pistol in the menu).
- `retakes_allocator` uses the same three values as `retakes_standardallocator` (the rifle and AWP choices carry over between the two) and ten more: `retakes_alloc_freeprimary` and `retakes_alloc_freepistol` (the weapon and the pistol for `free` rounds, `random` for random ones), `retakes_alloc_pistol_t` / `_ct`, `retakes_alloc_bonus_t` / `_ct` (the pistols for `pistol` and `bonus` rounds), `retakes_alloc_force_t` / `_ct` (the weapon for `force`), `retakes_alloc_nades` (the grenade list as the letters `h`, `f`, `s`; empty for random), `retakes_alloc_nadesask` (ask every round).
- A value that does not exist in CS:S (for example one left over from the CS:GO version of the plugin) is replaced by the default weapon.
- Bots have no saved choice: they always get the default (in `retakes_allocator` that is random weapons in `free` rounds and random grenades).
- If the clientprefs extension is not loaded or its database is unavailable, a choice only lasts until the player disconnects.

Spawns are stored separately, in `addons/sourcemod/configs/retakes/<map>.cfg` — see [Spawns](#spawns).

## Warmup plugin

The warmup is run by `warmup.smx`, a separate general-purpose plugin for CS:S (CS:S has no warmup of its own). It is not tied to Retakes and lives in the [css-plugins](https://github.com/Kolka2/css-plugins) repository: sources, cvars, commands and API are described in its [README](https://github.com/Kolka2/css-plugins/blob/master/docs/warmup/README.md). Build it there and install `warmup.smx` and its translations (`warmup.phrases.txt`, English and `ru/`).

Retakes uses it as an optional dependency:

- on map start Retakes starts a warmup of `sm_retakes_warmuptime` seconds; leave `sm_warmup_autostart 0`;
- while the warmup runs, Retakes stays out of everything: no teams, spawns, queue, money, bomb or weapon allocation;
- when the warmup ends, the first retake starts;
- while the spawn editor is open the warmup does not end;
- without `warmup.smx` there is no warmup and the map starts with a retake round.

`scripting/include/warmup.inc` in this repository is a copy of the plugin's API, needed to build Retakes.

## Known limitations

- Not everything is tested on a live server — see the status note above.
- During a retake the carrier can start planting by hand once freezetime ends. The `retakes_autoplant` addon plants the bomb automatically.
- The teams of the next round are set right after a round ends, not right before the respawn as in CS:GO: CS:S has no event for that moment, and the end of the previous round is the last chance to switch the teams before the game respawns everybody. So during the pause after a round the players are already shown on their new sides (on the scoreboard, with the new team's models).
- A bot added by the game in the middle of a round sits in spectators until the next round. Because of this the first round after leaving the spawn editor, or after joining an empty server, may be played 1 vs 1: the game adds bots one at a time and the teams are set when only the first one has joined.
- CS:S only has three grenades: HE, flashbang and smoke. The letters `m`, `i`, `d` in third-party allocator loadouts are ignored; CS:GO weapon class names are not given (an error is logged).
- The CS:GO cvars of the original `retakes_game.cfg` (`mp_halftime`, `mp_match_can_clinch`, cash awards and so on) do not exist in CS:S; the halftime side swap and the PugSetup integration were removed.

## For plugin developers

How a plugin talks to the game, how CS:S differs from CS:GO and why the port is built the way it is: see [PORTING.md](PORTING.md).

The addon API is described in [scripting/include/retakes.inc](scripting/include/retakes.inc) and matches the original (native, forward and cvar names are unchanged). Differences:

- `Retakes_InWarmup()` returns `Warmup_IsActive()` of the `warmup` plugin if it is loaded and `false` otherwise (not the game state, as it did in CS:GO);
- the player lists in the forwards (`Retakes_OnTeamsSet`, `Retakes_OnWeaponsAllocated`, `Retakes_OnRoundWon`) and the ranking queue contain bots; `Retakes_IsJoined()` returns `true` for a bot on a team;
- weapons are CS:S classes (`weapon_usp`, `weapon_p228`, `weapon_sg552`, `weapon_galil`, `weapon_famas`, …), grenades are `h`, `f`, `s` only.

Sources of the main plugin: `scripting/retakes.sp` (variables, cvars, command and event registration) and the files in `scripting/retakes/`:

| File | What it holds |
|---|---|
| `round.sp` | the round flow: preparation after `round_end`, placing the players at `round_start`, the round result |
| `teams.sp` | team switching, joining players, the ranking queue, the teams of a round |
| `bots.sp` | how many bots to keep on the server (`bot_quota`) |
| `spawns.sp` | bomb targets, the spawn file, picking a spawn |
| `equipment.sp` | weapons and armor, the purchase block |
| `bomb.sp` | picking the bomb carrier, handing out the C4 |
| `points.sp` | round points |
| `commands.sp` | `!guns`, `sm_scramble`, `sm_retakes_warmup` |
| `editor*.sp`, `validate.sp` | the spawn editor and the spawn check |
| `warmup_link.sp` | the link to the `warmup` plugin |
| `natives.sp`, `generic.sp`, `debug.sp`, `roundtime.sp` | the addon API and shared helpers |

The allocator `scripting/retakes_allocator.sp` only uses this API; its files are in `scripting/retakes_allocator/`: `weapons.sp` (the weapon table: price, side, category), `rounds.sp` (the round type table, the cycle, buying within a budget), `choices.sp` (player choices and cookies), `nades.sp` (grenades and their menus), `menus.sp` (the `!guns` menu). A new round type is one row in `g_RoundTypes` and a `RoundType_<name>` phrase in `translations/retakes_allocator.phrases.txt`.

## Building

The SourcePawn compiler and the SourceMod include files are not in the repository. Take them from the SourceMod 1.12 package (<https://www.sourcemod.net/downloads.php>): from its `addons/sourcemod/scripting/` folder copy the compiler (`spcomp` on Linux, `spcomp64.exe` or `spcomp.exe` on Windows) and the whole `include/` folder into `tools/` of this repository, the latter as `tools/include/`.

```
./build.sh            # every plugin → build/*.smx
./build.sh retakes    # a single plugin
```

On Windows run it from Git Bash. Another compiler can be set with `SPCOMP=/path/to/spcomp`. No external dependencies are needed.

`./dist.sh` builds the plugins and packs `build/dist/retakes-css-server.zip`, laid out to be unpacked into `cstrike/` of a server, plus a source archive. The files are taken from the last commit (`git archive HEAD`); it needs `7z` or `zip`.

## License

GPLv3, same as the original — see [LICENSE](LICENSE). The original plugin was written by splewis.

# Retakes for CS:S: how the port works

This document is for whoever reads or changes the code. [Русская версия](PORTING.ru.md). It covers three things:

1. how a SourceMod plugin talks to the game at all (with examples from this repository);
2. how CS:S differs from CS:GO where it affected Retakes;
3. which decisions the port made and why.

What is not here: installation and cvars (they are in [README.md](README.md)), the addon API (it is in [scripting/include/retakes.inc](scripting/include/retakes.inc) and [warmup.inc](scripting/include/warmup.inc)) and retelling of the code comments. Where a mechanism is already explained in a comment, there is a link to the file.

The base of the port is `splewis/csgo-retakes`, commit `9aae157` (v0.3.4, May 2023). The target is CS:S after the February 2025 update, SourceMod 1.12 and Metamod:Source 1.12. "Confirmed on a server" below means the behaviour was checked on a live CS:S server, not derived from documentation.

## 1. How a SourceMod plugin talks to the game

### A plugin as a program

The `spcomp` compiler turns a `.sp` source into a `.smx`, and the server loads `.smx` files from `addons/sourcemod/plugins/`. One plugin is built from one `.sp`; everything pulled in with `#include` is pasted into it as text. So the files in `scripting/retakes/` are not modules: they share one global namespace with `retakes.sp`, and the order of the includes matters. A variable or function can be hidden inside a file with `static`.

A plugin is single-threaded and does nothing on its own: the server calls its functions in response to what happened. The main entry points, in call order:

| Function | When | What goes there |
|---|---|---|
| `AskPluginLoad2` | before loading | natives and the library name are declared; the plugin may refuse to load here (the port checks `GetEngineVersion() == Engine_CSS`) |
| `OnPluginStart` | once on load | cvars, commands, event subscriptions |
| `OnAllPluginsLoaded` | when all plugins are loaded | optional dependencies are checked |
| `OnMapStart` | on every map | precaching, resetting the map state |
| `OnConfigsExecuted` | after `server.cfg` and the plugin `.cfg` files | cvar values are read: before this point they still hold the defaults |
| `OnClientPutInServer`, `OnClientDisconnect` | a player joins and leaves | hooks on the player, resetting their data |
| `OnMapEnd`, `OnPluginEnd` | end of map, unload | a log note about unsaved spawns, restoring changed cvars |

A plugin can be loaded in the middle of a map (`sm plugins load`), and then `OnMapStart` and `OnClientPutInServer` for players already on the server do not arrive by themselves. If that matters, the plugin walks over the clients in `OnPluginStart`.

### "Now" and "later"

The server simulates the world in steps (ticks, also called frames). A handler runs inside the step where something happened, and the game is often halfway through at that moment: the event is already sent, while the related data is not written yet. Hence the main technique of all engine work: do things not now, but a little later.

- `RequestFrame(function, data)` calls the function on the next frame. It means "as soon as the game finishes what it is doing".
- `CreateTimer(seconds, function, data)` calls it after a delay. A timer is off by up to a frame, and it cannot be relied on when two events are fractions of a second apart.

During the delay the player may leave, and someone else may take their place (the same client index). So a delayed call gets `GetClientUserId(client)` or `GetClientSerial(client)` instead of the index and converts it back in the handler; if the player is gone, the result is 0. The same for entities: `EntIndexToEntRef` and `EntRefToEntIndex`. For "is this still the same round?" the core has the `g_RoundSerial` counter: a delayed call remembers its value and compares.

### Clients and entities

Everything in the world (a player, a weapon, the bomb, a bomb target zone) is an entity with an index. Indexes 1 to `MaxClients` belong to players, so a client index is also the index of its entity. Entities are found by class name (`FindEntityByClassname(…, "func_bomb_target")`) and created by it (`GivePlayerItem(client, "weapon_ak47")`). Weapon class names differ between CS:S and CS:GO, and that is half of the cosmetic part of the port.

A bot is a client like any other to a plugin; `IsFakeClient` tells it apart. The original treated only humans as participants. The port has two checks: `IsPlayer` (a human; chat, menus, cookies) and `IsParticipant` (a human or a bot; the queue, teams, points, the bomb carrier).

### Five ways to learn something from the game and to influence it

From the safest to the most fragile.

**1. Events** (`HookEvent`). The game reports: "the round started", "a player died", "the bomb was planted". An event has a name and fields (`event.GetInt("userid")`). It is a notice of what has happened: almost nothing can be undone through it. Subscribing in `EventHookMode_Pre` gives only one right: to change the event or not to send it to the clients. Every game has its own list of events (the game's `resource/modevents.res` and the engine's `gameevents.res`, `serverevents.res`). `HookEvent` on a name the game does not have throws an error, and the plugin does not load; `HookEventEx` returns `false` in that case.

**2. Entity properties** (`GetEntProp`, `SetEntProp` and their float, vector, string and entity variants). This is direct reading and writing of fields of a game object by name. There are two tables:

- `Prop_Send` (network properties, netprops): what the server sends to the clients. Writing such a field changes both the state on the server and what the player sees. That is how the round time (`m_iRoundTime`), money (`m_iAccount`), armor (`m_ArmorValue`) and the progress bar on the screen are set.
- `Prop_Data` (datamap): server fields that are not sent to the clients.

The game rules have their own functions: `GameRules_GetProp` and `GameRules_SetProp`. If there is no property with the given name, the call throws an error, and the handler stops right there. Existence is checked with `HasEntProp` or `FindSendPropInfo`. The property lists of your own server are dumped with `sm_dump_netprops file` and `sm_dump_datamaps file`.

It is important to understand that writing a field does not call game code. It changes a number, and the game reads it when it gets to it. Fields the game rereads every frame work well (deadlines of the "at this game time" kind, flags). Fields the game only computes as the result of its own actions work poorly.

**3. Cvars and commands.** Game cvars are read and written through `FindConVar`; your own are created with `CreateConVar`. `AutoExecConfig` creates a file in `cfg/sourcemod/` for your cvars and executes it on every map, but it does not add new cvars to an existing file. Changes of a cvar are tracked with `AddChangeHook`.

Commands come in two kinds, and they are easy to confuse. Server commands are sent by the client to the server (`jointeam`, `joinclass`, `buy`, `say`): a plugin can intercept them (`AddCommandListener`) and refuse them by returning `Plugin_Handled`, and it can run them on behalf of a player (`FakeClientCommand`). Client commands are executed by the client itself (`use weapon_c4`, `slot5`): the server does not know about them, and `FakeClientCommand` does nothing with them.

**4. Hooks.** A hook puts a plugin function inside the work of the game and often gives a veto.

- `OnPlayerRunCmd` is called for every movement command of every player. It can replace the buttons, the view angles and the `weapon` field (which weapon to switch to). It is the only server-side way to "press a button" for a player.
- SDKHooks (`SDKHook(entity, type, function)`) attach to virtual functions of an entity: `SDKHook_WeaponCanUse` (may the weapon be picked up), `SDKHook_WeaponSwitch` (may the weapon be switched), `SDKHook_PostThinkPost` (after the player thinks, every frame), `SDKHook_SpawnPost` (the entity has appeared). A hook is set on a particular entity, so player hooks go into `OnClientPutInServer`.
- Forwards of the `cstrike` extension: `CS_OnTerminateRound` (the game wants to end the round; can be cancelled) and `CS_OnBuyCommand` (a player buys; can be cancelled).
- User messages (`HookUserMessage`): packets the server uses to draw text, menus and hints for the client (`HintText`, `TextMsg`, `SayText2`, `ShowMenu`). They can be kept from the client or sent by the plugin.

**5. Game memory** (gamedata, `SDKCall`, offsets). When what you need is neither in events nor in properties, what is left is to work with the internals of `server.dll` / `server.so`: call internal functions or read fields at an offset from the start of an object. Addresses and offsets are stored in a gamedata file for each platform separately and stop being valid after a game update. A mistake here means writing into foreign memory and a server crash. More in section 4, about `retakes_bothelper`.

The `cstrike` extension (natives `CS_TerminateRound`, `CS_SwitchTeam`, `CS_RespawnPlayer`, `CS_UpdateClientModel`) works exactly this way, but its gamedata is maintained by the SourceMod team and updated together with SourceMod. To a plugin they are ordinary functions.

### Plugins and each other

- **Natives.** A plugin declares a function (`CreateNative` in `AskPluginLoad2`), and others call it like an ordinary one. Its description lives in an `.inc` file that both include.
- **Forwards.** The other direction: a plugin declares an event (`CreateGlobalForward`), and every other plugin with a `public` function of that name gets called. A forward can collect answers: `Warmup_OnEnding` lets a plugin veto the end of the warmup, and `Retakes_OnSitePicked` lets it change the site.
- **Libraries and optional dependencies.** A plugin names itself (`RegPluginLibrary("retakes")`). A consumer for which the dependency is optional is built without `REQUIRE_PLUGIN`, marks the natives with `MarkNativeAsOptional` and checks `LibraryExists` before the call (or follows `OnLibraryAdded` / `OnLibraryRemoved`). Calling a native of a missing plugin throws an error. Example: [retakes/warmup_link.sp](scripting/retakes/warmup_link.sp).
- **Cookies** (the `clientprefs` extension): a string tied to a Steam ID and a cookie name, stored in the server database. The value is not available right after joining, only after `OnClientCookiesCached`. Bots have no cookies.
- **Translations.** Phrases live in `translations/*.phrases.txt` (English at the root, other languages in subfolders) and are picked by the client language through `%t` / `%T`. A missing phrase throws an error every time it is shown.

## 2. How CS:S differs from CS:GO

Both games run on Source, but CS:S is a whole engine generation older, and almost everything CS:GO exposes as settings and events is hard-coded in CS:S.

### The round flow

| | CS:GO | CS:S |
|---|---|---|
| Before the respawn | the `round_prestart` event | no event |
| After the respawn | `round_poststart`, then `round_start` | only `round_start`: by the time it arrives the game has spawned everybody |
| Pause after `round_end` | `mp_round_restart_delay` | about 5 s, not configurable |
| Side switch, halftime | `announce_phase_end`, `mp_halftime` | none |
| Player fully connected | `player_connect_full` | none |
| Freezetime | `round_freeze_end` | `round_freeze_end`; arrives every round, also with `mp_freezetime 0`; the fractional part of `mp_freezetime` is dropped |

The CS:S sequence: `round_end` → pause → the game respawns everybody and gives out the C4 → `round_start` → freezetime → `round_freeze_end`. A round that ends during the freezetime (e.g. everybody of one side is killed) breaks it: `round_end` comes first, and `round_freeze_end` of that round arrives right after it, already in the pause (seen on a live server). A handler of `round_freeze_end` must not act on a round that has ended: `retakes_allocator` ignores it after `round_end`, `retakes_autoplant` does not start a plant. The original built the teams in `round_prestart`, that is after the pause and right before the respawn. CS:S has no such moment, and that defined the round scheme of the port (section 3).

There is also "Game Commencing": when the first player joins an empty server (or a team stops being empty), the game ends the round itself with reason 15 and restarts the game with a score reset. `mp_restartgame` does the same. The plugin detects a restart by a `round_start` that had no `round_end` before it.

### Warmup

In CS:GO the warmup is built in: the `mp_warmup_*` cvars, `mp_do_warmup_period`, the `m_bWarmupPeriod` property. CS:S has none of that. Everything the port calls a warmup is done by a plugin: a round that does not end (`CS_OnTerminateRound` returns `Plugin_Handled`, and `m_iRoundTime` is extended), respawn after death (`CS_RespawnPlayer`), money, bomb removal.

### Weapons and equipment

| | CS:GO | CS:S |
|---|---|---|
| Knife | `weapon_knife`, `weapon_knife_t` for T | a single `weapon_knife` |
| Starting pistols | `hkp2000` / `usp_silencer`, `glock` | `usp`, `glock` |
| Other pistols | `p250`, `tec9`, `cz75a`, … | `p228`, `elite`, `fiveseven`, `deagle` |
| Rifles | `m4a1`, `m4a1_silencer`, `sg556`, `galilar`, … | `m4a1` (silencer on right click), `sg552`, `galil`, `famas`, `aug` |
| Snipers | `ssg08`, `awp`, … | `scout`, `awp`, `sg550`, `g3sg1` |
| Grenades | HE, flashbang, smoke, molotov, incendiary, decoy | HE, flashbang, smoke |

`GivePlayerItem` with a class name the game does not have gives nothing. That is why the grenade letters `m`, `i`, `d` in third-party allocator loadouts are skipped, and cookies with CS:GO weapon names are read as "default".

Grenades in CS:S are weapons with ammo: there is one item in the hands, and the count is stored in the player's ammo reserve (the `m_iAmmo` array, indexed by the weapon's `m_iPrimaryAmmoType`). Two consequences, both found on a server: removing the grenade item does not clear the reserve, so the next grenade of the same type gives two; and "refill ammo for every weapon" adds grenades. That is why `RemoveAllWeapons` zeroes the reserve of every removed type, and ammo is refilled only for the primary and the pistol.

### The bomb

CS:GO has `mp_give_player_c4`. In CS:S the hand-out cannot be switched off: on a round restart the game gives the C4 to a random terrorist and separately sends them the "you have the bomb" hint. It also gives the C4 to bots as they join the server. The port cannot prevent the hand-out and fixes its consequences (section 3).

The `use` and `slot5` commands are client commands, so the only way to put the C4 in a player's hands is the `weapon` field in `OnPlayerRunCmd`.

### Money and buying

In CS:GO the economy is switched off with cvars (`mp_startmoney 0`, `mp_*cashawards`, `mp_buytime 0`). CS:S has no award cvars, and the minimum of `mp_buytime` is 0.25 minutes. Money lives in `m_iAccount`; the kill award is paid after the `player_death` event. The only way to forbid buying is `CS_OnBuyCommand`.

### Teams and models

In CS:S a player picks a model (`joinclass`) after picking a team, and until the model is picked (`m_iClass` is 0) they do not spawn. A plugin that moves a player from spectators to a team itself must set the class itself, otherwise the player gets the model menu. A second `joinclass` kills a living player.

A player can join a team in the warmup and leave the model menu open. When the match starts, the game does not spawn such a player, and Retakes respawns them itself (they are on a team for the round). Before that it sets a random class of the team and hides the menu (`ShowVGUIPanel` with `class_ter` / `class_ct`), otherwise the menu would stay on the screen during the round. The menu is hidden wherever the plugin gives a class to a player who had none (also when it moves such a player to the other side) and when such a player goes to spectators (moved by the plugin, picked spectators, or pressed auto-select and was put in the waiting queue). Both panels are hidden: the open one belongs to the team the player picked, which may not be their team any more. A player the plugin moves in from spectators never had the menu open and gets no panel messages.

`CS_SwitchTeam` changes the team without death and without a model change (the model is updated by `CS_UpdateClientModel` or the next respawn). `ChangeClientTeam` kills the player; the port uses it to move players to spectators.

The `player_team` event in CS:S has a `silent` field, but the client ignores it and still prints "player joined team" in chat.

### Chat, HUD, menus

| | CS:GO | CS:S |
|---|---|---|
| Chat colors | a fixed palette, codes `\x01`–`\x10` | `\x01` normal, `\x03` team color, `\x04` green, `\x05` olive, `\x07RRGGBB` any color |
| Hint message | supports HTML | plain text; every message comes with the `UI/hint.wav` sound |
| Menus | radio menu, keys 1–9 | the same (`ShowMenu`), 0 closes |

The color tags in the translations (`{GREEN}`, `{LIGHT_RED}`, …) stayed the same; only the code table in [retakes/generic.sp](scripting/retakes/generic.sp) changed. The `\x07RRGGBB` code takes 7 bytes, not 1: this matters when computing string length.

A SourceMod menu lives on the server. `Menu.Cancel()` closes it there only; on the screen it stays until its display time runs out or the client gets another menu. A menu sent at the moment of a game restart does not reach the screen.

### Bots

CS:S bots know the bomb scenario: they plant and defuse on their own (confirmed on a server). But their number is set by the game through `bot_quota`, the game adds them one by one over a frame or two rather than all at once, and a plugin cannot "add a bot to this team now". Control comes down to the quota cvar and kicking the extra ones.

After the plant a CT bot does not know which site the bomb is on. It learns the exact spot only from the bomb beep, if it stands closer than 1500 units, or over the radio from such a bot. The others walk the sites one after another. With 40 seconds for the CTs this is noticeable; hence the `retakes_bothelper` addon.

### The server

After the 2025 update a CS:S server can be 32-bit or 64-bit. For plugins without gamedata it makes no difference. For memory work it is essential: pointer sizes and all offsets change.

## 3. How the port deals with these differences

### A round without `round_prestart`

The round steps and flags are described in the comment above `g_PreparePending` in [retakes.sp](scripting/retakes.sp); the code is in [retakes/round.sp](scripting/retakes/round.sp). Here is only why the scheme is what it is.

The teams have to change before the game spawns the players, otherwise everybody appears on their old sides. The only event before the respawn in CS:S is the `round_end` of the previous round. So the teams of the next round are built on the frame after `round_end`, and the players spend the whole pause between rounds already in their new teams. This is a visible difference from the original, and it cannot be removed.

- Why the next frame and not a timer. A variant "0.3 s before the restart" was made and reverted: switching the teams and respawning back to back gives a noticeable jerk before the round starts.
- Why the weapons are not removed during the preparation. The players would stand unarmed for the whole pause. The weapons are removed and given out when the players are placed.
- Why players are placed only in `round_start`. Placement used to be split between `player_spawn` and a fallback in `round_start`, and on a manual `mp_restartgame` the players were placed twice. Now spawn points, teleport, weapons and respawn of the dead happen once. A consequence: a player spawned mid-round by something else stays on a standard spawn.
- If a round starts without preparation (the first round, `mp_restartgame`), the preparation runs right in `round_start`: the living players are switched to their teams without dying and placed in the same handler, so nobody spawns twice. Only a player the game did not spawn (moved in from spectators at this moment) is respawned by the plugin.
- A `round_start` without a preceding `round_end` and a `round_end` with the "Game Commencing" reason count as a game restart and reset the progress (points, the T win streak, the round counter).

`CS_SwitchTeam` on a living player between rounds does not kill them, and after the restart everybody is in their new team: the whole scheme rests on this, confirmed on a server.

### Round time

`mp_roundtime` in CS:S is in minutes and does not go down to the values the mode needs, so the plugin writes seconds directly into `m_iRoundTime` of the game rules in `round_start`. Changing it mid-round moves both the timer on the screen and the moment the round ends (confirmed). The warmup and the editor make the round endless the same way: they extend `m_iRoundTime` and cancel the round end in `CS_OnTerminateRound`.

### Warmup and the spawn editor

The warmup lives in a separate plugin, `warmup`, with its own API, and it knows nothing about Retakes. It was written for this port and later moved to the [css-plugins](https://github.com/Kolka2/css-plugins) repository, so other modes can use it; this repository keeps only a copy of its include file. Retakes uses it as an optional library: it starts the warmup on map start, stays out of everything while it runs, and starts the first retake when it ends. Without `warmup.smx` there is simply no warmup. `Retakes_InWarmup()` now returns the state of that plugin, not of the game.

The spawn editor also needs a round without an end, and it has its own ([retakes/editor_freeplay.sp](scripting/retakes/editor_freeplay.sp)): the editor must work without the warmup plugin too. The duplication is deliberate. While the editor is open, Retakes keeps the warmup from ending through `Warmup_OnEnding`.

Game cvars the warmup changes temporarily (`mp_buytime`) are remembered and restored at the end of the warmup, on map change and on unload. The core uses the same technique: `retakes_game.cfg` is executed through `ExecuteAndSaveCvars`, and the previous values come back when the plugin is disabled ([include/restorecvars.inc](scripting/include/restorecvars.inc)).

### The bomb

The plugin picks the bomb carrier itself, while the game gives the C4 to a random T on restart. The fix has four parts, and each one closes its own symptom (all of them checked on a server separately):

1. `FixBomb()` 0.1 s after `round_start` takes the C4 from everybody except the carrier and gives it to the carrier if they do not have it.
2. Until then `SDKHook_WeaponCanUse` lets nobody but the carrier take the C4. Without it a random T sees the "you picked up the bomb" message.
3. A filter on the `HintText` / `TextMsg` messages keeps the "you have the bomb" hint from players without the bomb. The game sends it regardless of the pickup, and the ban from part 2 does not stop it.
4. A human carrier gets the C4 in their hands through the `weapon` field in `OnPlayerRunCmd`.

Parts 2 and 3 look like duplicates and were once removed by mistake. Both are needed.

### Money

Buying in a live round is refused in `CS_OnBuyCommand`; the money is zeroed when the weapons are given out at the start of the round. The kill award stays on the HUD until the end of the round: it cannot be spent, and zeroing it every second or on the frame after a kill was judged unnecessary. Buying is allowed during the warmup.

### Bots

- A bot is a full participant (`IsParticipant`): it stands in the ranking queue, gets points and can carry the bomb (`sm_retakes_bots_carry_bomb`).
- There is no penalty to bot points, although the plan had one. The rank decides not only who plays but also the side: with a penalty a human would always play T. Human priority comes from elsewhere: the order in which the queue is filled, and the bot quota going down while a human waits.
- The plugin sets the number of bots through `bot_quota`, and kicks the extra ones itself during the preparation: left to the game, a bot would vanish from an already built team.
- `bot_join_after_player 0`. The plugin keeps the "no humans, no bots" rule itself; with `1` the bots would not join while the only human waits in spectators.
- The game adds bots one at a time, and the first one triggers "Game Commencing". So after joining an empty server and after leaving the editor the first round may be 1 vs 1, with the other bots waiting in spectators. Three workarounds were written and removed for simplicity: it is one round and only bots.

### Chat and events

The "player joined team" messages on every side switch are gone because the `player_team` event is not broadcast to the clients (`event.BroadcastDisabled = true` in `Pre` mode). Server listeners still get it, and the scoreboard stays correct (confirmed).

### Kept as in the original on purpose

The general principle of the port: the behaviour of the original does not change without a clear reason. In particular:

- a normal T spawn inside the bomb target area suits the bomb carrier just like a "bomb-carrier only" spawn. A change "dedicated spawns first" was made and reverted;
- `retakes_standardallocator` has no pistol choice; `sm_deletemapspawns` works outside the editor too; damage is not disabled in the pause between rounds;
- the bomb carrier is picked at random among the Ts, and the team scramble is random (both checked against logs: they work as intended);
- the names of cvars, commands, natives, forwards and paths (`cfg/sourcemod/retakes`, `configs/retakes`) are the same.

### Changed compared to the original

- The "failed to plant" message and the `Retakes_OnFailToPlant` forward fire from the first round (from the third in the original).
- The site is picked only among those that have enough spawns for the current teams.
- Editor: the `!next` / `!prev` commands; `!show` and `!goto` report a wrong argument; `!savespawns` prints the real number of spawns; deleting all spawns counts as an unsaved change; `!goto` switches the shown site, open menus are redrawn; the spawn file is written only on an explicit save (`!savespawns`, the menu item), not on map change as in the original: unsaved edits are dropped with the map or on plugin unload, leaving the editor reminds about them, the server log notes the drop.
- New commands and cvars: `sm_retakes_validatespawns`, `sm_retakes_warmup`, `sm_retakes_debug`, `sm_retakes_bots*`.
- A hint about `!guns` on join, if an allocator is loaded.
- In a live game a player cannot pick their own team again or change the model (in CS:S that killed the player).
- The player lists in the forwards and the ranking queue contain bots.
- Removed: the smlib dependency, the PugSetup integration and the CS:GO map spawns (the coordinates do not fit even maps with the same name).

## 4. Addons: how they are made

All addons use only the API from `retakes.inc`; the core was not changed for them.

### retakes_allocator

Every round has a type (a row of the table in [retakes_allocator/rounds.sp](scripting/retakes_allocator/rounds.sp)), and a type has a budget. A loadout is the result of "buying" within that budget from a price table rather than a list of ready sets; that is why a new round type is one row. The round number comes from `Retakes_GetRetakeRoundsPlayed()`, there is no counter of its own. The prices in the table are only used for the budget and in places differ from the game for the sake of side balance.

Grenades in the "ask every round" mode showed two engine traits: a grenade given to a player holding the C4 switches them to the grenade and breaks the plant (the weapon switch is refused through `SDKHook_WeaponSwitch` while the grenade is given); and a menu cannot be closed on the client by cancelling it on the server (the client gets a `ShowMenu` without keys for 1 s).

### retakes_autoplant

The bomb is planted by the game code; the plugin only sets up the conditions: in `OnPlayerRunCmd` it selects the C4 for the carrier, zeroes their movement, moves the end of the C4 draw (`m_flNextAttack` of the player) and then the arming deadline `m_fArmedTime` to "now", and holds the attack button. On the next tick the game plants the bomb itself, with all the usual consequences: a real `planted_c4`, the `bomb_planted` event, the sounds, what the bots know.

The other way, used by CS:GO plugins, is to create a `planted_c4` entity. That does not work in CS:S: the bomb gets its timer and its think function from an internal function that only the planting code calls. An entity created by name does not tick.

The attempts to show the planting animation failed, and it is an instructive case. The client draws the first-person weapon itself, predicting the result from its own buttons. An attack held by the server does not exist for it: the bomb goes down, but the hands do not move. This cannot be fixed from the server. Instead of the animation the carrier gets a progress bar (`m_iProgressBarDuration`, `m_flProgressBarStartTime`) and the stock code-entry clicks.

The third-person animation (the model crouches and puts the bomb down) works differently: it is not predicted, the server sends it to the other players as a temp entity when the arming starts (`FX_PlantBomb` → `TE_PlantBomb`). With an instant plant after the freezetime this produced a bug: the clients played the whole animation in the live round, next to a bomb that was already planted. The plugin hooks that temp entity (`AddTempEntHook`), holds back the game's one while it is planting, and sends the same temp entity itself 2.8 seconds before the end of the freezetime (the length of the animation, fitted on a live server). The clients pick the animation by the weapon in the carrier's hands, so the carrier (bots included) is switched to the C4 half a second before that. A bot's own weapon choice puts the C4 away again at once, and the two kept taking turns; so while a bot carrier is to hold the C4, other weapons are refused through `SDKHook_WeaponSwitch`. The `m_iPlayer` field of this temp entity is the client index minus one, as in `Shotgun Shot`: with the plain index the animation went to the next player. With a freezetime shorter than 4 s there is no animation: below 3 s it would end in the live round, and with 3 s the carrier (looked for 0.2 s after the round start) gets the C4 on the same tick the animation is sent, with no time for the clients to show the C4 in the hands. The muzzle flash and the shell seen during the planting animation are drawn by the client itself: they are there in a plant by hand and in a single player game. `AddTempEntHook` throws on an unknown name, so it is called through `Call_StartFunction`/`Call_Finish`: if the name is wrong, the plugin still loads and works as before.

### retakes_autodefuse

A defuse in the game is a deadline: `m_flDefuseCountDown` of the `planted_c4` holds the moment it finishes. On the frame after `bomb_begindefuse` (at the moment of the event the game has not written the defuse parameters yet) the plugin checks the conditions and writes the current time into that field. The game finishes the defuse itself: the event, the sound and the end of the round are the stock ones.

### retakes_bothelper

The only plugin with gamedata. What a bot knows about the bomb lives in its internal object, which is neither in events nor in properties. The game fills it with a function that writes four fields; the plugin writes the same four fields itself, at the offsets from [gamedata/retakes_bothelper.games.txt](gamedata/retakes_bothelper.games.txt).

Why not a function call through `SDKCall`: in SourceMod 1.12 on a 64-bit server addresses are 32-bit "pseudo-addresses", and a real pointer to an object inside the bot cannot be passed to a call. Writing with `SetEntData` goes from the real entity pointer and does not depend on that.

Before every write the plugin checks that the offset holds what it expects (a pointer to the owner, flag values within their limits). On the first mismatch it logs one error and stops writing anything until reloaded. That is how a game update that moved the offsets is survived: the plugin goes quiet and the server does not crash. What to do after an update is described in the README.

## 5. How to check assumptions about the engine

Half of the bugs of the port came from being sure how the game "should" behave. What actually helps:

- `sm_dump_netprops file`, `sm_dump_datamaps file`: which properties exist on this server and on which classes. `cvarlist`: which cvars exist.
- `HasEntProp` before the first access to a property whose existence is uncertain. Once a dump confirms the property, the check is removed.
- The debug logs of the plugins: `sm_retakes_debug 1` (the core and the addons, files `logs/retakes*_debug.log`), `sm_warmup_debug 1`. They record the plugin's decisions per round: teams, the bomb carrier, the bot quota, refusals. Almost all bug causes were found through them, not through descriptions "by eye".
- SourceMod's `logs/errors_*.log`: every native error gets there with the function name and the line.
- The engine sources available online are unofficial and older than the current server. They are good as a hint where to look, but not as proof: every property or behaviour taken from them was checked on a server.

A practical rule that took shape during the port: first look at what the game does itself and fit into it (move a deadline, cancel an action, replace the input). Replacing the game's work with your own (creating entities, sending events by hand) costs more and breaks more often.

Retakes для Counter-Strike: Source
==================================

Порт плагина [splewis/csgo-retakes](https://github.com/splewis/csgo-retakes) (v0.3.4) с CS:GO на **Counter-Strike: Source**. [English version below](#retakes-for-counter-strike-source).

Режим Retakes: террористы появляются на бомбплейсе с бомбой, контр-террористы — на путях подхода и должны отбить точку и разминировать бомбу. Играть можно людьми, ботами и вперемешку.

> **Статус.** Код собирается компилятором SourcePawn 1.12 без предупреждений, но на живом сервере автором порта **не проверялся**. Всё, что зависит от поведения движка, помечено в коде комментариями `// CSS-VERIFY:` и вынесено в [PORT/TEST_CHECKLIST.md](PORT/TEST_CHECKLIST.md). Ход работ и отклонения от плана — в [PORT/PROGRESS.md](PORT/PROGRESS.md).

## Требования

- Выделенный сервер Counter-Strike: Source (после обновления февраля 2025, 64-бит).
- Metamod:Source 1.12+ и SourceMod 1.12+.
- Никаких дополнительных расширений, gamedata и библиотек: используются только `sdktools`, `sdkhooks`, `cstrike` и `clientprefs` из состава SourceMod.

Плагин откажется загружаться на любой другой игре.

## Установка

1. Соберите плагины (`./build.sh`, см. [Сборка](#сборка)) или возьмите готовые `build/*.smx`.
2. Скопируйте на сервер, в каталог `cstrike/`:
   - `build/retakes.smx` → `addons/sourcemod/plugins/`
   - `translations/` → `addons/sourcemod/translations/`
   - `cfg/sourcemod/retakes/` → `cfg/sourcemod/retakes/`
   - `configs/retakes/` → `addons/sourcemod/configs/retakes/`
3. По желанию — один из аллокаторов оружия (см. [Аддоны](#аддоны)).
4. Запустите карту с двумя бомбплейсами и расставьте спавны (см. ниже). Без спавнов режим не начнётся: плагин раз в раунд пишет об этом в чат.

При первом запуске создаётся `cfg/sourcemod/retakes/retakes.cfg` с кварами плагина. Файл `cfg/sourcemod/retakes/retakes_game.cfg` выполняется на старте каждой карты и настраивает игру (балансировку команд, лимиты, поведение ботов); прежние значения возвращаются при выключении плагина.

## Спавны

Готовых спавнов нет: файлы оригинала сделаны для карт CS:GO и к картам CS:S не подходят. Их нужно один раз расставить встроенным редактором (нужен админ-флаг смены карты, `g`):

| Команда | Что делает |
|---|---|
| `!edit` (`sm_edit`) | войти в редактор и открыть меню; в редакторе все респаунятся, раунд не кончается, ботов нет |
| `!show a` / `!show b` | показать спавны сайта A или B (кольца: синие — CT, красные — T, зелёные — T «только бомбер», жёлтые — T «никогда бомбер») |
| `!new ct a`, `!new t b` … | создать спавн там, где стоите (взгляд сохраняется); через меню можно выбрать тип T-спавна |
| `!delete` | удалить ближайший спавн |
| `!goto 10`, `!nearest` | телепорт к спавну по номеру / к ближайшему |
| `sm_iteratespawns` | по очереди облететь все спавны |
| `!savespawns`, `!reloadspawns` | сохранить / перечитать из файла, отбросив изменения |
| `sm_deletemapspawns` | удалить все спавны карты |
| `sm_retakes_validatespawns` | проверить спавны и вывести отчёт |

Что нужно на каждый сайт:

- T-спавны **внутри зоны закладки** — бомбер появляется только на таком спавне;
- ещё несколько T-спавнов рядом и CT-спавны на путях подхода;
- всего на карте не меньше `sm_retakes_maxplayers` спавнов, иначе плагин не расставляет команды.

Типы T-спавнов (как в оригинальном плагине):

| Тип | Кольцо | Кто появляется |
|---|---|---|
| обычный (Normal) | красное | любой T; **в том числе бомбер**, если спавн стоит внутри зоны закладки |
| только бомбер (Bomb-carrier only) | зелёное | только бомбер; имеет смысл только внутри зоны закладки |
| никогда бомбер (Never bomb-carrier) | жёлтое | любой T, кроме бомбера |

Тип «только бомбер» не привязывает бомбера к этой точке: он лишь закрывает её для остальных. Бомбер выбирается случайно среди всех зелёных **и красных** спавнов внутри зоны закладки. Если нужно, чтобы бомбер появлялся только на выделенных точках, пометьте остальные T-спавны внутри зоны закладки как «никогда бомбер». Тип существующего спавна не редактируется: удалите его (`!delete`) и создайте заново через меню `!edit` → «Add a spawn».

Выход из редактора — пункт «Exit edit mode» в меню `!edit`, игра при этом перезапускается. Спавны лежат в `addons/sourcemod/configs/retakes/<карта>.cfg` (формат — в [configs/retakes/README.md](configs/retakes/README.md)); несохранённые изменения записываются при смене карты.

## Как идёт игра

- **Разминка.** После старта карты идёт разминка (`sm_retakes_warmuptime` секунд): свободный выбор и смена команды, у всех 16000 денег и закупка открыта всё время, респаун через пару секунд после смерти, раунд не заканчивается. Отсчёт идёт, только когда на сервере есть хотя бы один человек. В CS:S нет встроенной разминки, её ведёт сам плагин.
- **Команды.** После разминки командами управляет плагин. Зашедший игрок попадает в очередь (наблюдатели) и входит в игру со следующего раунда. Доля T задаётся `sm_retakes_ratio_constant`. За раунд начисляются очки (урон, убийства, бомба, победа); лучшие по очкам играют следующий раунд за T. После `sm_retakes_scramble_rounds` побед T подряд команды перемешиваются.
- **Раунд.** Плагин выбирает сайт, ставит игроков на спавны, выдаёт оружие, броню и кусачки и обнуляет деньги — закупаться нельзя. Бомба у одного T, который стоит на бомбплейсе; на установку даётся `sm_retakes_round_time` секунд, иначе побеждают CT.
- **Оружие.** Без аллокатора: T — AK-47 и Glock, CT — M4A1 и USP, у всех броня с каской. Команда `!guns` открывает меню аллокатора, если он установлен.

## Боты

Боты — полноценные участники, но люди всегда в приоритете.

- Плагин сам управляет числом ботов через `bot_quota`: пока людей (играющих и ждущих в очереди) меньше `sm_retakes_bots_total`, состав добирается ботами до этого числа. Вручную менять `bot_quota` не нужно.
- Человек никогда не ждёт из-за бота: когда приходит человек, со следующего раунда один бот уходит.
- Без людей ботов на сервере нет. В редакторе спавнов ботов тоже нет.
- Бот может быть бомбером и ставит бомбу сам, штатным ИИ. `sm_retakes_bots_carry_bomb 0` — отдавать бомбу человеку, если он есть среди T.
- `sm_retakes_bots 0` — режим без ботов (плагин держит `bot_quota 0`).
- Сложность и поведение ботов настраиваются обычными кварами (`bot_difficulty` и т. д.) в `retakes_game.cfg`.

Для ботов карте нужен файл навигации (`.nav`).

## Квары

Лежат в `cfg/sourcemod/retakes/retakes.cfg`.

| Квар | По умолчанию | Описание |
|---|---|---|
| `sm_retakes_enabled` | `1` | включён ли плагин |
| `sm_retakes_maxplayers` | `9` | максимум участников раунда (люди + боты) |
| `sm_retakes_ratio_constant` | `0.425` | доля участников, играющих за T |
| `sm_retakes_round_time` | `12` | сколько секунд у T на установку бомбы |
| `sm_retakes_warmuptime` | `25` | длительность разминки на старте карты, секунды; `0` — без разминки |
| `sm_retakes_scramble_rounds` | `10` | после скольких побед T подряд перемешать команды; `0` — никогда |
| `sm_retakes_random_teams` | `0` | `1` — случайные команды каждый раунд |
| `sm_retakes_auto_set_teams` | `1` | `0` — плагин не трогает команды (игроки и боты остаются там, куда зашли) |
| `sm_retakes_editor_enabled` | `1` | можно ли запускать редактор спавнов |
| `sm_retake_message_prefix` | `[{GREEN}Retakes{NORMAL}]` | префикс сообщений в чате |
| `sm_retakes_bots` | `1` | **новый.** `0` — без ботов, `1` — добирать состав ботами |
| `sm_retakes_bots_total` | `6` | **новый.** сколько участников (люди + боты) держать, пока людей меньше; не больше `sm_retakes_maxplayers` |
| `sm_retakes_bots_carry_bomb` | `1` | **новый.** может ли бот быть бомбером; при `0` бот несёт бомбу, только если среди T нет людей |
| `sm_retakes_debug` | `0` | **новый.** `1` — подробный лог решений плагина в `addons/sourcemod/logs/retakes_debug.log` |

Прочие команды:

- `sm_guns` / `!guns` — меню оружия;
- `sm_scramble` — перемешать команды со следующего раунда (админ);
- `sm_retakes_warmup [секунды]` — запустить разминку без смены карты и обнулить прогресс: очки, серию побед, счётчик раундов (админ). Без числа берётся `sm_retakes_warmuptime`, `0` — сразу закончить разминку. В редакторе спавнов не работает.

## Аддоны

Необязательные плагины, ставятся рядом с `retakes.smx`. Аллокатор нужен только один.

- `retakes_standardallocator` — выбор винтовки через `!guns`: CT — M4A1 / AUG / FAMAS, T — AK-47 / SG 552 / Galil; можно разрешить себе AWP (не больше одной на команду); у всех броня с каской и случайная граната.
- `retakes_pistolallocator` — пистолетные раунды: Glock и USP (с бронёй), P228, Five-SeveN, Desert Eagle, Dual Elites (без брони) или случайный.
- `retakes_sitepicker` — админ-команда `sm_site a|b|any`: играть только на одном сайте.

## Известные ограничения

- Не проверено на живом сервере — см. статус в начале и [PORT/TEST_CHECKLIST.md](PORT/TEST_CHECKLIST.md).
- Автозакладки бомбы нет: бомбу ставит бомбер (человек или бот), как в оригинале.
- Между концом раунда и началом следующего игроки уже переведены в новые команды: в CS:S нет события «перед началом раунда», и это единственный момент, когда команды можно сменить до респауна.
- Первый раунд после разминки и после `mp_restartgame` игроки появляются дважды подряд (игра спаунит, затем плагин переспаунивает на спавнах ретейка).
- Если игра добавила бота посреди раунда, он до следующего раунда сидит в наблюдателях.
- В CS:S только три гранаты: осколочная, световая и дымовая. Буквы `m`, `i`, `d` в раскладках сторонних аллокаторов игнорируются; имена оружия CS:GO не выдаются (ошибка в логе).
- Кваров тайм-аутов, halftime и т. п. в CS:S нет; интеграция с PugSetup удалена.

## Для разработчиков

API аддонов описан в [scripting/include/retakes.inc](scripting/include/retakes.inc) и совпадает с оригинальным (имена нативов, форвардов и кваров не менялись). Отличия:

- `Retakes_InWarmup()` возвращает флаг разминки плагина, а не состояние игры;
- списки игроков в форвардах (`Retakes_OnTeamsSet`, `Retakes_OnWeaponsAllocated`, `Retakes_OnRoundWon`) и очередь рангов содержат ботов; `Retakes_IsJoined()` для бота в команде возвращает `true`;
- оружие — классы CS:S (`weapon_usp`, `weapon_p228`, `weapon_sg552`, `weapon_galil`, `weapon_famas`, …), гранаты — только `h`, `f`, `s`.

## Сборка

```
./build.sh            # все плагины → build/*.smx
./build.sh retakes    # один плагин
```

Компилятор SourcePawn 1.12 и include-файлы SourceMod 1.12 лежат в `tools/`. На Windows запускать из Git Bash. Внешние зависимости (smlib и т. п.) не нужны.

## Лицензия

GPLv3, как и оригинал — см. [LICENSE](LICENSE). Автор оригинального плагина — splewis.

---

Retakes for Counter-Strike: Source
==================================

A port of [splewis/csgo-retakes](https://github.com/splewis/csgo-retakes) (v0.3.4) from CS:GO to **Counter-Strike: Source**.

Retakes: the terrorists spawn inside a bombsite with the bomb, the counter-terrorists spawn on the rotation routes and have to retake the site and defuse. It can be played by humans, by bots, or by a mix of both.

> **Status.** The code compiles with the SourcePawn 1.12 compiler without warnings, but the port author has **not tested it on a live server**. Everything that depends on engine behaviour is marked with `// CSS-VERIFY:` comments in the code and listed in [PORT/TEST_CHECKLIST.md](PORT/TEST_CHECKLIST.md) (in Russian).

## Requirements

- A Counter-Strike: Source dedicated server (post February 2025 update, 64-bit).
- Metamod:Source 1.12+ and SourceMod 1.12+.
- No extra extensions, gamedata or libraries: only `sdktools`, `sdkhooks`, `cstrike` and `clientprefs` that ship with SourceMod.

The plugin refuses to load on any other game.

## Installation

1. Build the plugins (`./build.sh`) or take the prebuilt `build/*.smx`.
2. Copy to the server's `cstrike/` directory:
   - `build/retakes.smx` → `addons/sourcemod/plugins/`
   - `translations/` → `addons/sourcemod/translations/`
   - `cfg/sourcemod/retakes/` → `cfg/sourcemod/retakes/`
   - `configs/retakes/` → `addons/sourcemod/configs/retakes/`
3. Optionally add one of the weapon allocators (see [Addon plugins](#addon-plugins)).
4. Start a map with two bombsites and create the spawns (see below). The mode does not start without spawns; the plugin says so in chat every round.

`cfg/sourcemod/retakes/retakes.cfg` is generated on the first run. `cfg/sourcemod/retakes/retakes_game.cfg` is executed on every map start and sets the game up (team balancing, limits, bot behaviour); the previous values are restored when the plugin is disabled.

## Spawns

No spawn files are shipped: the original ones were made for the CS:GO maps and do not fit the CS:S maps. Create them once with the built-in editor (map-change admin flag, `g`):

| Command | What it does |
|---|---|
| `!edit` (`sm_edit`) | enter the editor and open its menu; in the editor everybody respawns, the round never ends, there are no bots |
| `!show a` / `!show b` | show the spawns of a site (rings: blue — CT, red — T, green — T "bomb carrier only", yellow — T "never bomb carrier") |
| `!new ct a`, `!new t b` … | create a spawn where you stand (the view angle is saved); the menu also lets you pick the T spawn type |
| `!delete` | delete the nearest spawn |
| `!goto 10`, `!nearest` | teleport to a spawn by index / to the nearest one |
| `sm_iteratespawns` | visit every spawn in turn |
| `!savespawns`, `!reloadspawns` | save / reload from the file, discarding changes |
| `sm_deletemapspawns` | delete all spawns of the map |
| `sm_retakes_validatespawns` | check the spawns and print a report |

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

Leave the editor with "Exit edit mode" in the `!edit` menu; the game restarts. Spawns are stored in `addons/sourcemod/configs/retakes/<map>.cfg`; unsaved changes are written on map change.

## How it plays

- **Warmup.** A warmup of `sm_retakes_warmuptime` seconds follows the map start: players freely pick and change teams, everybody has $16000 and can buy the whole time, respawn a couple of seconds after death, the round never ends. The countdown only runs while at least one human is on the server. CS:S has no built-in warmup, the plugin runs its own.
- **Teams.** After the warmup the plugin manages the teams. A joining player is put in the waiting queue (spectators) and enters the game on the next round. The share of terrorists is `sm_retakes_ratio_constant`. Players earn round points (damage, kills, bomb, winning); the top scorers play the next round as T. After `sm_retakes_scramble_rounds` T wins in a row the teams are scrambled.
- **Round.** The plugin picks a site, moves the players to the spawns, gives weapons, armor and defuse kits and zeroes the money — there is no buying. One T standing in the bombsite has the bomb and `sm_retakes_round_time` seconds to plant it, otherwise the CTs win.
- **Weapons.** Without an allocator: T — AK-47 and Glock, CT — M4A1 and USP, armor and helmet for everybody. `!guns` opens the allocator menu if one is installed.

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
| `sm_retakes_warmuptime` | `25` | warmup length on map start, seconds; `0` disables the warmup |
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
- `sm_retakes_warmup [seconds]` — start the warmup without changing the map and reset the progress: round points, win streak, round counter (admin). Without a number `sm_retakes_warmuptime` is used, `0` ends the warmup right away. Does not work in the spawn editor.

## Addon plugins

Optional plugins, installed next to `retakes.smx`. Use only one allocator.

- `retakes_standardallocator` — rifle choice through `!guns`: CT — M4A1 / AUG / FAMAS, T — AK-47 / SG 552 / Galil; players may opt in for the AWP (one per team at most); armor, helmet and a random grenade for everybody.
- `retakes_pistolallocator` — pistol rounds: Glock and USP (with armor), P228, Five-SeveN, Desert Eagle, Dual Elites (no armor) or random.
- `retakes_sitepicker` — admin command `sm_site a|b|any` to play a single site.

## Known limitations

- Not tested on a live server yet — see the status note above.
- There is no auto-plant: the bomb carrier (human or bot) plants the bomb, as in the original.
- Between the end of a round and the start of the next one the players are already on their new teams: CS:S has no "before round start" event, and this is the only moment the teams can be changed before the respawn.
- On the first round after the warmup and after `mp_restartgame` the players spawn twice in a row (the game spawns them, then the plugin respawns them on the retake spawns).
- A bot added by the game in the middle of a round sits in spectators until the next round.
- CS:S only has three grenades: HE, flashbang and smoke. The letters `m`, `i`, `d` in third-party allocator loadouts are ignored; CS:GO weapon class names are not given (an error is logged).
- The PugSetup integration was removed.

## For plugin developers

The addon API is described in [scripting/include/retakes.inc](scripting/include/retakes.inc) and matches the original (native, forward and cvar names are unchanged). Differences:

- `Retakes_InWarmup()` returns the plugin's own warmup flag instead of the game state;
- the player lists in the forwards (`Retakes_OnTeamsSet`, `Retakes_OnWeaponsAllocated`, `Retakes_OnRoundWon`) and the ranking queue contain bots; `Retakes_IsJoined()` returns `true` for a bot on a team;
- weapons are CS:S classes (`weapon_usp`, `weapon_p228`, `weapon_sg552`, `weapon_galil`, `weapon_famas`, …), grenades are `h`, `f`, `s` only.

## Building

```
./build.sh            # every plugin → build/*.smx
./build.sh retakes    # a single plugin
```

The SourcePawn 1.12 compiler and the SourceMod 1.12 includes are vendored in `tools/`. On Windows run it from Git Bash. No external dependencies are needed.

## License

GPLv3, same as the original — see [LICENSE](LICENSE). The original plugin was written by splewis.

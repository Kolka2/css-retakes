# Retakes spawns / Спавны Retakes

**EN.** One spawn file per map lives here: `<mapname>.cfg` (`addons/sourcemod/configs/retakes/` on the server).

Spawns are shipped for four maps: `de_dust2`, `de_cache`, `de_nuke` and `de_strike_mirage`. They were made for the Counter-Strike: Source versions of these maps. The files of the original csgo-retakes were made for the CS:GO maps and do not fit the CS:S maps (even de_dust2, de_inferno, de_nuke, de_train and de_aztec have different geometry), so they were removed. Create the spawns for other maps with the built-in editor:

1. Join the server as an admin with the map-change flag (`g`) and type `!edit` in chat.
2. `!show a` / `!show b` picks the bombsite being edited; the rings show the existing spawns.
3. Stand on the spot, look where the player should look and type `!new ct a`, `!new t a`, `!new ct b`, `!new t b`, or use the `!edit` menu → "Add a spawn" (it also picks the T spawn type: normal, bomb-carrier only, never bomb-carrier).
4. Each site needs T spawns inside the bomb target area (the bomb carrier only spawns there), a few more T spawns around it and CT spawns on the rotation routes. The map needs at least `sm_retakes_maxplayers` spawns in total; in practice 5+ per team for each site.
5. `!savespawns` saves them, then `sm_retakes_validatespawns` checks them. Leave the editor with "Exit edit mode" in the `!edit` menu.

About the T spawn types: the bomb carrier is picked at random among all T spawns inside the bomb target area, both "bomb-carrier only" (green) and **normal** (red) ones. The "bomb-carrier only" type merely closes the spot for the other terrorists. To make the bomb carrier spawn on dedicated spots only, mark the other T spawns inside the bomb target area as "never bomb-carrier" (yellow). The full table is in the project `README.md`.

**RU.** Здесь лежат файлы спавнов: по одному на карту, `<имя_карты>.cfg` (на сервере — `addons/sourcemod/configs/retakes/`).

В комплекте есть спавны для четырёх карт: `de_dust2`, `de_cache`, `de_nuke` и `de_strike_mirage`. Они сделаны для версий этих карт из Counter-Strike: Source. Спавны из оригинального csgo-retakes сделаны для карт CS:GO, и к картам CS:S их координаты не подходят (даже у de_dust2, de_inferno, de_nuke, de_train, de_aztec геометрия другая), поэтому они удалены. Спавны для остальных карт нужно расставить встроенным редактором:

1. Зайдите на сервер админом с флагом смены карты (`g`) и напишите в чат `!edit`.
2. `!show a` / `!show b` — какой бомбплейс редактируется; кольца показывают уже созданные спавны.
3. Встаньте в нужную точку, повернитесь, куда должен смотреть игрок, и напишите `!new ct a`, `!new t a`, `!new ct b`, `!new t b` — или пользуйтесь меню `!edit` → «Add a spawn» (там же выбирается тип T-спавна: обычный, только для бомбера, никогда для бомбера).
4. На каждый сайт нужно: T-спавны внутри бомбплейса (бомбер появляется только на спавне внутри зоны закладки), ещё несколько T-спавнов рядом и CT-спавны на путях подхода. Всего спавнов на карте — не меньше `sm_retakes_maxplayers`, а на практике по 5+ на команду на каждый сайт.
5. `!savespawns` — сохранить, затем `sm_retakes_validatespawns` — проверить. Выход из редактора — пункт «Exit edit mode» в меню `!edit`.

Важно про типы T-спавнов: бомбер выбирается случайно среди всех T-спавнов внутри зоны закладки — и «только бомбер» (зелёных), и **обычных** (красных). Тип «только бомбер» лишь закрывает точку для остальных T. Чтобы бомбер появлялся только на выделенных точках, остальные T-спавны внутри зоны закладки нужно пометить «никогда бомбер» (жёлтые). Подробная таблица — в `README.ru.md` проекта.

## File format / Формат файла

```
"Spawns"
{
    "0"
    {
        "origin"    "1235.99 2348.03 99.69"
        "angle"     "1.49 -159.26 0.00"
        "bombsite"  "A"        // A or B
        "team"      "T"        // T or CT
        "type"      "1"        // T only: 0 - normal (inside the bomb target area it also suits the bomb carrier),
                               // 1 - bomb-carrier only, 2 - never bomb-carrier
    }
}
```

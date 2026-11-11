# Спавны Retakes / Retakes spawns

**RU.** Здесь лежат файлы спавнов: по одному на карту, `<имя_карты>.cfg` (на сервере — `addons/sourcemod/configs/retakes/`).

В комплекте есть только `de_dust2.cfg` (тестовый набор для CS:S). Для остальных карт готовых файлов нет. Спавны из оригинального csgo-retakes сделаны для карт CS:GO, и к картам Counter-Strike: Source их координаты не подходят (даже у de_dust2, de_inferno, de_nuke, de_train, de_aztec геометрия другая), поэтому они удалены. Спавны для своих карт нужно расставить встроенным редактором:

1. Зайдите на сервер админом с флагом смены карты (`g`) и напишите в чат `!edit`.
2. `!show a` / `!show b` — какой бомбплейс редактируется; кольца показывают уже созданные спавны.
3. Встаньте в нужную точку, повернитесь, куда должен смотреть игрок, и напишите `!new ct a`, `!new t a`, `!new ct b`, `!new t b` — или пользуйтесь меню `!edit` → «Add a spawn» (там же выбирается тип T-спавна: обычный, только для бомбера, никогда для бомбера).
4. На каждый сайт нужно: T-спавны внутри бомбплейса (бомбер появляется только на спавне внутри зоны закладки), ещё несколько T-спавнов рядом и CT-спавны на путях подхода. Всего спавнов на карте — не меньше `sm_retakes_maxplayers`, а на практике по 5+ на команду на каждый сайт.
5. `!savespawns` — сохранить, затем `sm_retakes_validatespawns` — проверить. Выход из редактора — пункт «Exit edit mode» в меню `!edit`.

Важно про типы T-спавнов: бомбер выбирается случайно среди всех T-спавнов внутри зоны закладки — и «только бомбер» (зелёных), и **обычных** (красных). Тип «только бомбер» лишь закрывает точку для остальных T. Чтобы бомбер появлялся только на выделенных точках, остальные T-спавны внутри зоны закладки нужно пометить «никогда бомбер» (жёлтые). Подробная таблица — в `README.md` проекта.

**EN.** One spawn file per map lives here: `<mapname>.cfg` (`addons/sourcemod/configs/retakes/` on the server).

Only `de_dust2.cfg` (a test set for CS:S) is shipped; there are no files for other maps. The ones from the original csgo-retakes were made for the CS:GO maps and do not fit the Counter-Strike: Source maps, so they were removed. Create your own with the built-in editor: `!edit` in chat (map-change admin flag), `!show a|b`, `!new <ct|t> <a|b>` where you stand, `!savespawns`, then `sm_retakes_validatespawns`. Each site needs T spawns inside the bomb target area (the bomb carrier only spawns there), a few more T spawns around it and CT spawns on the rotation routes; the map needs at least `sm_retakes_maxplayers` spawns in total.

## Формат файла / File format

```
"Spawns"
{
    "0"
    {
        "origin"    "1235.99 2348.03 99.69"
        "angle"     "1.49 -159.26 0.00"
        "bombsite"  "A"        // A или B
        "team"      "T"        // T или CT
        "type"      "1"        // только для T: 0 - обычный (внутри зоны закладки годится и бомберу),
                               // 1 - только бомбер, 2 - никогда бомбер
    }
}
```

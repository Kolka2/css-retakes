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
   - `build/warmup.smx` → `addons/sourcemod/plugins/` (необязательно: без него не будет разминки, см. [Плагин разминки](#плагин-разминки-warmup))
   - `translations/` → `addons/sourcemod/translations/`
   - `cfg/sourcemod/retakes/` → `cfg/sourcemod/retakes/`
   - `configs/retakes/` → `addons/sourcemod/configs/retakes/`
3. Аллокатор оружия — один из трёх (см. [Аддоны](#аддоны)); основной — `build/retakes_allocator.smx` → `addons/sourcemod/plugins/`. В готовом архиве `retakes-css-server.zip` он уже лежит в `plugins/`, два других аллокатора и `retakes_sitepicker` — в `plugins/disabled/`.
4. Запустите карту с двумя бомбплейсами и расставьте спавны (см. ниже). Без спавнов режим не начнётся: плагин раз в раунд пишет об этом в чат.

При первом запуске создаётся `cfg/sourcemod/retakes/retakes.cfg` с кварами плагина. Файл `cfg/sourcemod/retakes/retakes_game.cfg` выполняется на старте каждой карты и настраивает игру (балансировку команд, лимиты, поведение ботов); прежние значения возвращаются при выключении плагина.

## Спавны

В комплекте есть спавны только для de_dust2 (`configs/retakes/de_dust2.cfg`, тестовый набор). Для остальных карт их нет: файлы оригинала сделаны для карт CS:GO и к картам CS:S не подходят. Их нужно один раз расставить встроенным редактором (нужен админ-флаг смены карты, `g`):

| Команда | Что делает |
|---|---|
| `!edit` (`sm_edit`) | войти в редактор и открыть меню; в редакторе все респаунятся, раунд не кончается, ботов нет |
| `!endedit` (`sm_endedit`) | выйти из редактора и начать игру; то же, что пункт «Exit edit mode» в меню. Несохранённые спавны остаются в памяти и запишутся при смене карты или по `!savespawns` |
| `!show a` / `!show b` | показать спавны сайта A или B (кольца: синие — CT, красные — T, зелёные — T «только бомбер», жёлтые — T «никогда бомбер») |
| `!new ct a`, `!new t b` … | создать спавн там, где стоите (взгляд сохраняется); через меню можно выбрать тип T-спавна |
| `!delete` | удалить ближайший спавн показанного сайта |
| `!goto 10`, `!nearest` | телепорт к спавну по номеру (о несуществующем номере команда сообщит; показ переключается на сайт этого спавна) / к ближайшему спавну показанного сайта |
| `!next`, `!prev` | телепорт к следующему / предыдущему спавну по порядку номеров, по кругу; показ переключается на сайт спавна; то же есть в меню `!edit` |
| `sm_iteratespawns` | по очереди облететь все спавны (показ переключается на сайт каждого спавна) |
| `!savespawns`, `!reloadspawns` | сохранить (в ответ — число записанных точек) / перечитать из файла, отбросив изменения |
| `sm_deletemapspawns` | удалить все спавны карты; как и любая правка, попадает в файл при `!savespawns` или при смене карты, до этого `!reloadspawns` всё вернёт |
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

- **Разминка.** После старта карты идёт разминка (`sm_retakes_warmuptime` секунд). Её ведёт отдельный плагин `warmup.smx` (см. [Плагин разминки](#плагин-разминки-warmup)); Retakes только запускает её и, пока она идёт, ни во что не вмешивается: не расставляет команды и спавны, не ведёт очередь, не трогает деньги и бомбу, не выдаёт оружие. Когда разминка заканчивается, начинается первый ретейк. Без `warmup.smx` разминки нет.
- **Команды.** После разминки командами управляет плагин. Зашедший игрок попадает в очередь (наблюдатели) и входит в игру со следующего раунда. Доля T задаётся `sm_retakes_ratio_constant`. За раунд начисляются очки (урон, убийства, бомба, победа); лучшие по очкам играют следующий раунд за T. После `sm_retakes_scramble_rounds` побед T подряд команды перемешиваются.
- **Раунд.** Плагин выбирает сайт, ставит игроков на спавны, выдаёт оружие, броню и кусачки и обнуляет деньги — закупаться нельзя. Бомба у одного T, который стоит на бомбплейсе; на установку даётся `sm_retakes_round_time` секунд, иначе побеждают CT.
- **Оружие.** Без аллокатора: T — AK-47 и Glock, CT — M4A1 и USP, у всех броня с каской. Команда `!guns` открывает меню аллокатора, если он установлен; в этом случае зашедшему игроку один раз за подключение показывается подсказка о ней.

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
| `sm_retakes_warmuptime` | `25` | длительность разминки на старте карты, секунды; `0` — без разминки. Нужен `warmup.smx`; остальные настройки разминки — его квары `sm_warmup_*` |
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
- `sm_retakes_warmup [секунды]` — запустить разминку без смены карты и обнулить прогресс Retakes: очки, серию побед, счётчик раундов (админ). Без числа берётся `sm_retakes_warmuptime`, `0` — сразу закончить разминку. Нужен `warmup.smx`; в редакторе спавнов не работает.

## Аддоны

Необязательные плагины, ставятся рядом с `retakes.smx`. Аллокатор нужен только один.

- `retakes_standardallocator` — выбор винтовки через `!guns`: CT — M4A1 / AUG / FAMAS, T — AK-47 / SG 552 / Galil; можно разрешить себе AWP (не больше одной на команду); у всех броня с каской и случайная граната.
- `retakes_pistolallocator` — пистолетные раунды: Glock и USP (с бронёй), P228, Five-SeveN, Desert Eagle, Dual Elites (без брони) или случайный.
- `retakes_allocator` — раунды разных типов: пистолетные, бонусные, форс-бай, закупочные и «свободный выбор» любого оружия, по кругу или в случайном порядке; гранаты по выбору игрока. Подробно — в разделе [Аллокатор с типами раундов](#аллокатор-с-типами-раундов-retakes_allocator).
- `retakes_sitepicker` — админ-команда `sm_site a|b|any`: играть только на одном сайте.
- `retakes_autoplant` — автоплент: бомба закладывается за бомбера там, где он стоит (бомбер-человек или бот), и к началу раунда уже тикает. Закладку выполняет сама игра (плагин только «зажимает» бомберу атаку с C4 в руках и убирает трёхсекундное ожидание), gamedata не нужна. Квары (файл `cfg/sourcemod/retakes/retakes_autoplant.cfg`):
  - `sm_retakes_autoplant_enabled` (по умолчанию `1`) — включить;
  - `sm_retakes_autoplant_progressbar` (по умолчанию `1`) — бомбер-человек во фризтайме видит шкалу прогресса (как при разминировании); она заполняется к моменту закладки. При `mp_freezetime` меньше 1 шкалы нет, при большем 15 она появляется за 15 секунд до конца;
  - `sm_retakes_autoplant_sound` (по умолчанию `1`) — в последние секунды фризтайма от бомбера (человека или бота) слышны щелчки набора кода, как при ручной закладке.

  Бомба закладывается мгновенно в момент конца фризтайма. Если бомбер стоит вне зоны закладки или бомба не заложилась за 5 секунд после конца фризтайма, плагин отступает и бомбер ставит бомбу сам. С `sm_retakes_debug 1` пишет лог `logs/retakes_autoplant_debug.log`. Закладка проверена на сервере, шкала и щелчки — пока не подтверждены; в готовом архиве плагин лежит в `plugins/disabled/`.

### Аллокатор с типами раундов (retakes_allocator)

У каждого раунда есть тип. Игрок «закупается» на бюджет типа по ценам CS:S; деньги настоящие не тратятся.

| Тип | Бюджет | Что получает игрок |
|---|---|---|
| `pistol` | $800 | одно из: стартовый пистолет (Glock у T, USP у CT) с кевларом; P228, Desert Eagle, Five-SeveN (CT) или Dual Elites (T) без брони; без шлема |
| `bonus` | $1700 | улучшенный пистолет и кевлар, на сдачу шлем |
| `force` | $3300 | случайное основное оружие, которое влезает в бюджет (без AWP, автоматических снайперских, SG 552, AUG и M249), стартовый пистолет, броня и шлем — на сколько хватит: с AK-47 и M4A1 брони нет, с P90 нет шлема, с остальным есть и то и другое (у CT с FAMAS и китом — без шлема). Цены в бюджете не всегда игровые: Scout $1750, XM1014 $2000, AK-47 $2700 |
| `buy` | хватает на всё | винтовка, выбранная в `!guns` (T: AK-47 / Galil / SG 552, CT: M4A1 / FAMAS / AUG), AWP одному согласившемуся игроку команды, стартовый пистолет, броня со шлемом |
| `free` | хватает на всё | основное оружие и пистолет из всего оружия игры независимо от стороны — те, что игрок выбрал в `!guns`, либо случайные каждый раунд (так по умолчанию); броня со шлемом |

Кит: в `buy` и `free` у всех CT, в остальных типах его пробует купить половина CT (если остались $200).

Таблица описывает игрока, который ничего не выбирал. В `!guns` для каждого типа раунда и каждой стороны можно выбрать оружие:

- `pistol` и `bonus` — пистолет (стартовый своей стороны бесплатный, остальные по цене);
- `force` — основное оружие из тех, что влезают в бюджет;
- `buy` — винтовка и согласие на AWP; `free` — оружие и пистолет.

По умолчанию везде, кроме винтовок `buy`, стоит «Случайное каждый раунд» — раскладка тогда собирается как в таблице. Если оружие выбрано, после него покупаются кевлар, затем шлем, затем кит, поэтому броня зависит только от оружия; меню показывает её рядом с каждым вариантом, например «AK-47 (без брони)», «Galil (кевлар и шлем)».

Меню `!guns` сгруппировано по типам раундов («Пистолетный раунд», «Бонусный раунд», «Форс-бай», «Закупочный раунд», «Свободный выбор») и показывает только типы из `sm_retakes_alloc_rounds`; если настраивать можно лишь один тип, его настройки стоят прямо в главном меню.

Квары (файл `cfg/sourcemod/retakes/retakes_allocator.cfg` создаётся при первом запуске):

| Квар | По умолчанию | Что делает |
|---|---|---|
| `sm_retakes_alloc_rounds` | `pistol:2,bonus:2,force:3,buy:12` | типы раундов и число раундов каждого: `тип:раунды,тип:раунды,…`; `:раунды` можно опустить (1). Один тип — все раунды одинаковые: `buy` (как стандартный аллокатор), `free` («хаос») |
| `sm_retakes_alloc_order` | `cycle` | `cycle` — типы идут по кругу в порядке списка; `random` — тип каждого раунда разыгрывается заново, числа из списка работают как веса (по умолчанию `buy` выпадает в 12 раундах из 19) |
| `sm_retakes_alloc_random_types` | пусто | типы раундов через запятую, в которых оружие всегда случайное, а выбор игроков из `!guns` не действует: `force`, `pistol,bonus,force,buy,free`. Сохранённый выбор не стирается, строки этих типов в меню скрываются. В `buy` это случайная винтовка своей стороны; AWP по-прежнему получает только согласившийся |
| `sm_retakes_alloc_nades` | `choice` | `choice` — игрок настраивает гранаты в `!guns`; `random` — у всех случайные |
| `sm_retakes_alloc_nades_count` | пусто | сколько гранат получает игрок: пусто — по типу раунда (`pistol` 0–1, `bonus` 1, `force` 0–1, `buy` 1–2, `free` 0–4); число (`1`) или диапазон (`0-4`) — одинаково во всех раундах |

- Место в цикле считается от числа сыгранных раундов Retakes: после смены карты, `mp_restartgame` и разминки цикл начинается сначала.
- В начале раунда тип объявляется в чате («Пистолетный раунд (1/2)»). Если в списке один тип, объявления нет.
- Гранаты в режиме `choice`, меню `!guns` → «Гранаты»:
  - «Случайные каждый раунд» — так по умолчанию;
  - «Выбрать гранаты по приоритету» — список до четырёх гранат (осколочная, две световые, дымовая); в раунде игрок получает первые N из списка, где N — число гранат этого раунда;
  - «Спрашивать каждый раунд» — меню открывается в паузе перед раундом и принимает выбор до конца фризтайма; гранаты, которые игрок не успел выбрать (все или часть), в конце фризтайма выдаются случайно. Меню не вытесняет другое открытое меню (например, `!guns`) и появляется, когда то закрыто; в конце фризтайма оно закрывается само.
- Как повторить варианты: «до одной случайной» — `random` и `0-1`; «одна по выбору» — `choice` и `1`; «любой набор по выбору» — `choice` и `4`; «полный рандом» — `random` и `0-4`.
- Боты получают винтовки по умолчанию, случайное оружие в остальных типах раундов и случайные гранаты.

### Где хранится выбор оружия

Выбор, сделанный в меню `!guns`, сохраняется штатным механизмом SourceMod — clientprefs (cookie). Он привязан к Steam ID игрока и переживает переподключение, смену карты и перезапуск сервера.

- Данные лежат в базе clientprefs. По умолчанию это файл SQLite `addons/sourcemod/data/sqlite/clientprefs-sqlite.sq3`; другую базу можно указать в `addons/sourcemod/configs/databases.cfg`, секция `clientprefs`.
- `retakes_standardallocator` хранит три значения: `retakes_ctriflechoice` (винтовка CT), `retakes_triflechoice` (винтовка T), `retakes_awpchoice` (согласие на AWP).
- `retakes_pistolallocator` хранит одно: `retakes_pistolchoice` (номер пистолета в меню).
- `retakes_allocator` использует те же три значения, что и `retakes_standardallocator` (выбор винтовок и AWP переносится между ними), и ещё десять: `retakes_alloc_freeprimary` и `retakes_alloc_freepistol` (оружие и пистолет для раундов `free`, `random` — случайные), `retakes_alloc_pistol_t` / `_ct`, `retakes_alloc_bonus_t` / `_ct` (пистолеты для раундов `pistol` и `bonus`), `retakes_alloc_force_t` / `_ct` (оружие для `force`), `retakes_alloc_nades` (список гранат буквами `h`, `f`, `s`; пусто — случайные), `retakes_alloc_nadesask` (спрашивать каждый раунд).
- Значение, которого в CS:S нет (например, оставшееся от CS:GO-версии плагина), заменяется оружием по умолчанию.
- У ботов сохранённого выбора нет: они всегда получают вариант по умолчанию (в `retakes_allocator` это случайное оружие в раундах `free` и случайные гранаты).
- Если расширение clientprefs не загружено или база недоступна, выбор действует только до отключения игрока.

Спавны хранятся отдельно, в файлах `addons/sourcemod/configs/retakes/<карта>.cfg` — см. раздел [Спавны](#спавны).

## Плагин разминки (warmup)

`warmup.smx` — отдельный общий плагин разминки для CS:S. Он не привязан к Retakes: его может использовать любой режим через `scripting/include/warmup.inc`, и он работает сам по себе (`sm_warmup_autostart 1`). Retakes использует его как необязательную зависимость: без `warmup.smx` разминки просто нет и карта начинается сразу с ретейка.

Что происходит в разминке:

- раунд не заканчивается, убитые появляются снова через `sm_warmup_respawn_time` секунд;
- у всех $16000 при появлении и снова после каждой покупки, закупка открыта всё время (плагин на время разминки поднимает `mp_buytime`);
- бомбы нет: C4 убирается у игроков, с земли и установленная;
- команду можно выбирать и менять свободно, в том числе переходить между T и CT;
- разминка заканчивается по таймеру и/или когда набралось нужное число людей, после чего игра перезапускается.

Все игровые квары, которые плагин меняет на время разминки, запоминаются при её старте и возвращаются при её конце, при смене карты и при выгрузке плагина.

Квары лежат в `cfg/sourcemod/warmup.cfg` (создаётся при первом запуске):

| Квар | По умолчанию | Описание |
|---|---|---|
| `sm_warmup_enabled` | `1` | можно ли вообще запускать разминку; `0` также завершает идущую |
| `sm_warmup_autostart` | `0` | `1` — запускать разминку на старте каждой карты. Оставьте `0`, если разминку запускает режим (Retakes делает это сам по `sm_retakes_warmuptime`) |
| `sm_warmup_time` | `25` | длительность по умолчанию, секунды; `0` — без ограничения по времени. Используется автозапуском и командой `sm_warmup` без аргумента |
| `sm_warmup_min_players` | `1` | сколько людей нужно на сервере. Если время ограничено, отсчёт идёт только пока их не меньше (и начинается заново, если стало меньше). Если время не ограничено, разминка заканчивается, как только их набралось. `0` — людей не ждать |
| `sm_warmup_respawn_time` | `1.5` | через сколько секунд после смерти игрок появляется снова |
| `sm_warmup_infinite_money` | `1` | `1` — $16000 при появлении и после каждой покупки; `0` — деньги не трогать |
| `sm_warmup_buy_anywhere` | `0` | `1` — покупать можно в любой точке карты, а не только в зоне закупки. На живом сервере не проверено |
| `sm_warmup_restart_delay` | `1` | через сколько секунд после конца разминки перезапускается игра (`mp_restartgame`); `0` — не перезапускать |
| `sm_warmup_debug` | `0` | `1` — писать в `addons/sourcemod/logs/warmup_debug.log`, что делает разминка: старт и конец, заблокированные концы раунда, рестарты раунда внутри разминки, опустевшие команды, удалённые и отвергнутые бомбы |

Время и число людей сочетаются так:

| `sm_warmup_time` | `sm_warmup_min_players` | Когда заканчивается разминка |
|---|---|---|
| > 0 | > 0 | через заданное время, которое идёт только пока людей достаточно |
| > 0 | 0 | через заданное время, которое идёт пока на сервере есть хотя бы один человек |
| 0 | > 0 | как только набралось нужное число людей |
| 0 | 0 | только по команде `sm_warmup_end` или по вызову режима |

Админ-команды (флаг смены карты): `sm_warmup [секунды]` — начать или перезапустить разминку (`0` — без ограничения по времени, без аргумента — `sm_warmup_time`); `sm_warmup_end` — закончить.

Для разработчиков режимов — `scripting/include/warmup.inc`: нативы `Warmup_IsActive()`, `Warmup_Start(seconds)`, `Warmup_End(restartGame)` и форварды `Warmup_OnStart`, `Warmup_OnEnding` (верните `Plugin_Handled`, чтобы продлить разминку; спрашивается заново каждую секунду), `Warmup_OnEnd(reason)`.

## Известные ограничения

- Не проверено на живом сервере — см. статус в начале и [PORT/TEST_CHECKLIST.md](PORT/TEST_CHECKLIST.md).
- Автозакладки бомбы нет: бомбу ставит бомбер (человек или бот), как в оригинале.
- Между концом раунда и началом следующего игроки уже переведены в новые команды: в CS:S нет события «перед началом раунда», и это единственный момент, когда команды можно сменить до респауна.
- Первый раунд после разминки и после `mp_restartgame` игроки появляются дважды подряд (игра спаунит, затем плагин переспаунивает на спавнах ретейка).
- Если игра добавила бота посреди раунда, он до следующего раунда сидит в наблюдателях. Из-за этого после выхода из редактора спавнов и при входе на пустой сервер первый раунд может пройти 1 на 1: игра добавляет ботов по одному, и команды собираются, когда зашёл только первый.
- В CS:S только три гранаты: осколочная, световая и дымовая. Буквы `m`, `i`, `d` в раскладках сторонних аллокаторов игнорируются; имена оружия CS:GO не выдаются (ошибка в логе).
- Кваров тайм-аутов, halftime и т. п. в CS:S нет; интеграция с PugSetup удалена.

## Для разработчиков

API аддонов описан в [scripting/include/retakes.inc](scripting/include/retakes.inc) и совпадает с оригинальным (имена нативов, форвардов и кваров не менялись). Отличия:

- `Retakes_InWarmup()` возвращает `Warmup_IsActive()` плагина `warmup`, если он загружен, иначе всегда `false` (а не состояние игры, как в CS:GO);
- списки игроков в форвардах (`Retakes_OnTeamsSet`, `Retakes_OnWeaponsAllocated`, `Retakes_OnRoundWon`) и очередь рангов содержат ботов; `Retakes_IsJoined()` для бота в команде возвращает `true`;
- оружие — классы CS:S (`weapon_usp`, `weapon_p228`, `weapon_sg552`, `weapon_galil`, `weapon_famas`, …), гранаты — только `h`, `f`, `s`.

Исходники основного плагина: `scripting/retakes.sp` (переменные, квары, регистрация команд и событий) и файлы в `scripting/retakes/`:

| Файл | Что в нём |
|---|---|
| `round.sp` | ход раунда: подготовка после `round_end`, расстановка игроков в `round_start`, итог раунда |
| `teams.sp` | смена команд, вход игрока, очередь рангов, составы на раунд |
| `bots.sp` | сколько ботов держать на сервере (`bot_quota`) |
| `spawns.sp` | зоны закладки, файл спавнов, выбор точки |
| `equipment.sp` | выдача оружия и брони, запрет покупок |
| `bomb.sp` | выбор бомбера, раздача C4 |
| `points.sp` | очки за раунд |
| `commands.sp` | `!guns`, `sm_scramble`, `sm_retakes_warmup` |
| `editor*.sp`, `validate.sp` | редактор спавнов и проверка спавнов |
| `warmup_link.sp` | связка с плагином `warmup` |
| `natives.sp`, `generic.sp`, `debug.sp`, `roundtime.sp` | API для аддонов и общие функции |

Аллокатор `scripting/retakes_allocator.sp` пользуется только этим API; его файлы в `scripting/retakes_allocator/`: `weapons.sp` (таблица оружия: цена, сторона, категория), `rounds.sp` (таблица типов раундов, цикл, закупка на бюджет), `choices.sp` (выбор игроков и cookie), `nades.sp` (гранаты и их меню), `menus.sp` (меню `!guns`). Новый тип раунда — одна строка в `g_RoundTypes` и фраза `RoundType_<имя>` в `translations/retakes_allocator.phrases.txt`.

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
   - `build/warmup.smx` → `addons/sourcemod/plugins/` (optional: without it there is no warmup, see [Warmup plugin](#warmup-plugin))
   - `translations/` → `addons/sourcemod/translations/`
   - `cfg/sourcemod/retakes/` → `cfg/sourcemod/retakes/`
   - `configs/retakes/` → `addons/sourcemod/configs/retakes/`
3. A weapon allocator, one of the three (see [Addon plugins](#addon-plugins)); the main one is `build/retakes_allocator.smx` → `addons/sourcemod/plugins/`. The prebuilt `retakes-css-server.zip` already has it in `plugins/`, with the other two allocators and `retakes_sitepicker` in `plugins/disabled/`.
4. Start a map with two bombsites and create the spawns (see below). The mode does not start without spawns; the plugin says so in chat every round.

`cfg/sourcemod/retakes/retakes.cfg` is generated on the first run. `cfg/sourcemod/retakes/retakes_game.cfg` is executed on every map start and sets the game up (team balancing, limits, bot behaviour); the previous values are restored when the plugin is disabled.

## Spawns

Spawns are shipped for de_dust2 only (`configs/retakes/de_dust2.cfg`, a test set). There are none for other maps: the original files were made for the CS:GO maps and do not fit the CS:S maps. Create them once with the built-in editor (map-change admin flag, `g`):

| Command | What it does |
|---|---|
| `!edit` (`sm_edit`) | enter the editor and open its menu; in the editor everybody respawns, the round never ends, there are no bots |
| `!endedit` (`sm_endedit`) | leave the editor and start the game; the same as "Exit edit mode" in the menu. Unsaved spawns stay in memory and are written on map change or by `!savespawns` |
| `!show a` / `!show b` | show the spawns of a site (rings: blue — CT, red — T, green — T "bomb carrier only", yellow — T "never bomb carrier") |
| `!new ct a`, `!new t b` … | create a spawn where you stand (the view angle is saved); the menu also lets you pick the T spawn type |
| `!delete` | delete the nearest spawn of the shown site |
| `!goto 10`, `!nearest` | teleport to a spawn by index (an index that does not exist is reported; the shown site switches to the spawn's one) / to the nearest spawn of the shown site |
| `!next`, `!prev` | teleport to the next / previous spawn in index order, wrapping around; the shown site switches to the spawn's one; also in the `!edit` menu |
| `sm_iteratespawns` | visit every spawn in turn (the shown site switches to each spawn's one) |
| `!savespawns`, `!reloadspawns` | save (replies with the number of spawns written) / reload from the file, discarding changes |
| `sm_deletemapspawns` | delete all spawns of the map; like any other edit it reaches the file on `!savespawns` or on a map change, until then `!reloadspawns` brings everything back |
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

- **Warmup.** A warmup of `sm_retakes_warmuptime` seconds follows the map start. It is run by the separate `warmup.smx` plugin (see [Warmup plugin](#warmup-plugin)); Retakes only starts it and stays out of the way while it runs: no teams or spawns, no waiting queue, no money or bomb handling, no weapon allocation. When the warmup ends the first retake begins. Without `warmup.smx` there is no warmup.
- **Teams.** After the warmup the plugin manages the teams. A joining player is put in the waiting queue (spectators) and enters the game on the next round. The share of terrorists is `sm_retakes_ratio_constant`. Players earn round points (damage, kills, bomb, winning); the top scorers play the next round as T. After `sm_retakes_scramble_rounds` T wins in a row the teams are scrambled.
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
- `retakes_autoplant` — autoplant: the bomb is planted for the bomb carrier (human or bot) where the carrier stands, and is already ticking when the round goes live. The game itself does the plant (the plugin only holds the attack button for the carrier with the C4 out and removes the three-second wait), no gamedata is needed. Cvars (config `cfg/sourcemod/retakes/retakes_autoplant.cfg`):
  - `sm_retakes_autoplant_enabled` (default `1`) — on/off;
  - `sm_retakes_autoplant_progressbar` (default `1`) — a human carrier sees a progress bar (the one of the defuse) during the freezetime; it fills up by the moment of the plant. No bar with `mp_freezetime` below 1; above 15 it shows up 15 seconds before the end;
  - `sm_retakes_autoplant_sound` (default `1`) — in the last seconds of the freezetime the keypad clicks of a bomb being armed are played at the carrier (human or bot), as in a plant by hand.

  The bomb is planted in an instant the moment the freezetime ends. If the carrier is outside a bomb target or the bomb is not planted within 5 seconds after the freezetime, the plugin backs off and the carrier plants by hand. With `sm_retakes_debug 1` it writes `logs/retakes_autoplant_debug.log`. The plant was checked on a live server, the progress bar and the clicks are not confirmed yet; the prebuilt archive has the plugin in `plugins/disabled/`.

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

`warmup.smx` is a separate, general-purpose warmup plugin for CS:S. It is not tied to Retakes: any game mode can use it through `scripting/include/warmup.inc`, and it also works on its own (`sm_warmup_autostart 1`). Retakes uses it as an optional dependency: without `warmup.smx` there is simply no warmup and the map starts with a retake round.

During a warmup:

- the round never ends, the dead respawn after `sm_warmup_respawn_time` seconds;
- everybody has $16000 on spawn and again after every purchase, and buying stays open the whole time (the plugin raises `mp_buytime` for the duration);
- there is no bomb: the C4 is removed from players, from the ground and when planted;
- players pick and change teams freely, including T <-> CT;
- the warmup ends by time and/or when enough humans have joined, then the game restarts.

Every game cvar the plugin changes for the warmup is remembered when the warmup starts and restored when it ends, on a map change and when the plugin is unloaded.

The cvars are stored in `cfg/sourcemod/warmup.cfg` (generated on the first run):

| Cvar | Default | Description |
|---|---|---|
| `sm_warmup_enabled` | `1` | whether warmups can be started at all; `0` also ends a running one |
| `sm_warmup_autostart` | `0` | `1` — start a warmup on every map start. Leave at `0` when a game mode starts it (Retakes does, using `sm_retakes_warmuptime`) |
| `sm_warmup_time` | `25` | default length in seconds; `0` — no time limit. Used by the autostart and by `sm_warmup` without an argument |
| `sm_warmup_min_players` | `1` | humans needed on the server. With a time limit the countdown only runs while at least this many are present (and starts over if there are fewer). Without a time limit the warmup ends as soon as this many are present. `0` — do not wait for players |
| `sm_warmup_respawn_time` | `1.5` | seconds between a death and the respawn |
| `sm_warmup_infinite_money` | `1` | `1` — $16000 on spawn and after every purchase; `0` — leave the money alone |
| `sm_warmup_buy_anywhere` | `0` | `1` — players can buy anywhere on the map, not only in the buy zones. Not verified on a live server |
| `sm_warmup_restart_delay` | `1` | seconds until the game restarts after the warmup (`mp_restartgame`); `0` — do not restart |
| `sm_warmup_debug` | `0` | `1` — write what the warmup does (start and end, blocked round ends, round restarts inside the warmup, emptied teams, removed and refused bombs) to `addons/sourcemod/logs/warmup_debug.log` |

How the time and the player count combine:

| `sm_warmup_time` | `sm_warmup_min_players` | When the warmup ends |
|---|---|---|
| > 0 | > 0 | after the given time, which only runs while enough humans are present |
| > 0 | 0 | after the given time, which runs while at least one human is on the server |
| 0 | > 0 | as soon as enough humans are present |
| 0 | 0 | only by `sm_warmup_end` or when the game mode ends it |

Admin commands (map-change flag): `sm_warmup [seconds]` — start or restart the warmup (`0` — no time limit, no argument — `sm_warmup_time`); `sm_warmup_end` — end it.

For game mode developers — `scripting/include/warmup.inc`: natives `Warmup_IsActive()`, `Warmup_Start(seconds)`, `Warmup_End(restartGame)` and forwards `Warmup_OnStart`, `Warmup_OnEnding` (return `Plugin_Handled` to extend the warmup; asked again every second), `Warmup_OnEnd(reason)`.

## Known limitations

- Not tested on a live server yet — see the status note above.
- There is no auto-plant: the bomb carrier (human or bot) plants the bomb, as in the original.
- Between the end of a round and the start of the next one the players are already on their new teams: CS:S has no "before round start" event, and this is the only moment the teams can be changed before the respawn.
- On the first round after the warmup and after `mp_restartgame` the players spawn twice in a row (the game spawns them, then the plugin respawns them on the retake spawns).
- A bot added by the game in the middle of a round sits in spectators until the next round. Because of this the first round after leaving the spawn editor, or after joining an empty server, may be played 1 vs 1: the game adds bots one at a time and the teams are set when only the first one has joined.
- CS:S only has three grenades: HE, flashbang and smoke. The letters `m`, `i`, `d` in third-party allocator loadouts are ignored; CS:GO weapon class names are not given (an error is logged).
- The PugSetup integration was removed.

## For plugin developers

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

```
./build.sh            # every plugin → build/*.smx
./build.sh retakes    # a single plugin
```

The SourcePawn 1.12 compiler and the SourceMod 1.12 includes are vendored in `tools/`. On Windows run it from Git Bash. No external dependencies are needed.

## License

GPLv3, same as the original — see [LICENSE](LICENSE). The original plugin was written by splewis.

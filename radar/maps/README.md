# Radar assets for the spawn radar site

*Русский — ниже.*

The site (`radar/build-site.mjs`, published by `.github/workflows/radar-pages.yml`) shows the
spawns of every map that has a config in `configs/retakes/<map>.cfg`. To draw them on the map
radar it needs two files from the game for each map, in a folder named exactly like the config
without `.cfg` (case matters: the site is built on Linux):

```
radar/maps/<map>/
    radar.png       the radar image (or radar.webp, radar.jpg, radar.vtf, radar.dds)
    overview.txt    the radar binding: pos_x, pos_y, scale
```

| File | Where to take it in CS:S |
|---|---|
| `radar.*` | `materials/overviews/<map>.vtf` (`<map>_radar.vtf` on some maps; the `.vmt` next to it names the texture) |
| `overview.txt` | `resource/overviews/<map>.txt`, copied as is |

- The files of the stock maps are either in the `cstrike/` folder or inside the game VPK
  archives (`cstrike/cstrike_pak_dir.vpk`): extract them with a VPK tool, for example GCFScape
  or `vpk.exe` from the Source SDK. Custom
  maps keep them in the map package or in the `.bsp` itself.
- The VTF can be put here as is: the page decodes it. A PNG or WebP converted from it (VTFEdit,
  `VTFCmd`) weighs several times less and loads faster.
- Only one radar file per map is used; if there are several, the first of png, webp, jpg,
  jpeg, vtf, dds wins.
- A map without a radar or an overview is still published: the build only prints a warning.
  Without an overview the page cannot place the points; it remembers a binding typed by hand in
  the browser.
- A folder without a matching config is not published (the build warns about it).

---

# Ассеты радаров для сайта

Сайт (`radar/build-site.mjs`, публикует `.github/workflows/radar-pages.yml`) показывает спауны
каждой карты, у которой есть конфиг `configs/retakes/<map>.cfg`. Чтобы нарисовать их на радаре,
ему нужны два файла из игры на каждую карту, в папке с тем же именем, что у конфига без `.cfg`
(регистр важен: сайт собирается на Linux):

```
radar/maps/<map>/
    radar.png       картинка радара (или radar.webp, radar.jpg, radar.vtf, radar.dds)
    overview.txt    привязка радара: pos_x, pos_y, scale
```

| Файл | Где взять в CS:S |
|---|---|
| `radar.*` | `materials/overviews/<map>.vtf` (у части карт `<map>_radar.vtf`; имя текстуры указано в `.vmt` рядом) |
| `overview.txt` | `resource/overviews/<map>.txt`, скопировать как есть |

- Файлы стандартных карт лежат либо в папке `cstrike/`, либо внутри архивов VPK игры
  (`cstrike/cstrike_pak_dir.vpk`): достать их можно программой для VPK, например GCFScape или
  `vpk.exe` из Source SDK. У сторонних карт они
  лежат в архиве карты или внутри самого `.bsp`.
- VTF можно положить как есть: страница декодирует его сама. PNG или WebP, сконвертированный из
  него (VTFEdit, `VTFCmd`), весит в несколько раз меньше и грузится быстрее.
- На карту берётся один файл радара; если их несколько, побеждает первый из png, webp, jpg,
  jpeg, vtf, dds.
- Карта без радара или без overview всё равно публикуется, сборка только пишет предупреждение.
  Без overview страница не может расставить точки; привязку, введённую вручную, она запоминает в
  браузере.
- Папка без конфига с тем же именем не публикуется (сборка предупреждает).

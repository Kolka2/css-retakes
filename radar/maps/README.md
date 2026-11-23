# Radar assets for the spawn radar site

*Русский — ниже.*

The site (`radar/build-site.mjs`, published by `.github/workflows/radar-pages.yml`) shows the
spawns of every map that has a config in `configs/retakes/<map>.cfg`. To load the radar image
and its binding automatically, put the two files below in a folder named exactly like the config
without `.cfg`. The name is case-sensitive on the Linux build runner.

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
- The page can open a VTF directly if its decoder supports the texture format. Converting the
  radar to PNG or WebP can reduce its file size. The result depends on the image and encoder settings.
- Only one radar file per map is used; if there are several, the first of png, webp, jpg,
  jpeg, vtf, dds wins.
- A map without a radar or an overview is still published: the build only prints a warning.
  To position spawns on the radar, the editor needs a binding. If the repository has no
  `overview.txt` for the map, the editor uses its saved binding when available. You can also
  load an overview file, select a matching preset, or enter `pos_x`, `pos_y` and `scale` manually.
- A folder without a matching config is not published (the build warns about it).

---

# Ассеты радаров для сайта

Сайт (`radar/build-site.mjs`, публикует `.github/workflows/radar-pages.yml`) показывает спауны
каждой карты, у которой есть конфиг `configs/retakes/<map>.cfg`. Чтобы изображение радара
и его привязка загружались автоматически, положите оба файла в папку с именем конфига без `.cfg`.
Учитывайте регистр букв при сборке на Linux.

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
- Страница открывает VTF напрямую, если её декодер поддерживает формат текстуры. Конвертация
  радара в PNG или WebP может уменьшить размер файла. Результат зависит от изображения и настроек сжатия.
- На карту берётся один файл радара; если их несколько, побеждает первый из png, webp, jpg,
  jpeg, vtf, dds.
- Карта без радара или без overview всё равно публикуется, сборка только пишет предупреждение.
  Для отображения спавнов на радаре нужна привязка. Если в репозитории для карты нет
  `overview.txt`, редактор использует привязку, сохранённую для этой карты в браузере, если она есть.
  Можно также загрузить файл overview, выбрать подходящий пресет или ввести `pos_x`, `pos_y` и `scale` вручную.
- Папка без конфига с тем же именем не публикуется (сборка предупреждает).

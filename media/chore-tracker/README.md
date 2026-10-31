# Chore Tracker gallery images

The Mod.io media for Chore Tracker: four 1920x1080 PNGs in `out/`, made by
`scripts/gallery.py` (its docstring has the commands) from the crops in `raw/`, the backdrop
`bg.png` and the captions and callouts in `specs.json`.

| Image | Shows |
| --- | --- |
| `out/01-overview.png` | Plugin name, tagline, four features, the list. Also the Profile's listing image (16:9) |
| `out/02-list.png` | The list: ticking, period counts, grips, shop-run counts, fold and settings buttons |
| `out/03-settings.png` | Settings: celebration toggles, shops needed per run, chores grouped by kind |
| `out/04-strip-and-popup.png` | The collapsed strip and the DAILIES COMPLETE popup |

Upload them in that order (Media, `docs/submission.md`).

## Changing the text

Edit `specs.json`, then `python3 scripts/gallery.py compose media/chore-tracker` (or name pages
after the folder to render only those). No client needed. Each page has a `layout`: `hero`
(`tagline`, `features`, optional `eyebrow`) or `annotated` (`title`, `desc`, optional
`note`). Its `images` place a raw crop at `scale` and `x`,`y` on the page. Each callout draws a box round
`box` (`[x, y, w, h]` in raw-crop pixels) and puts its `text` on one `side` at page `x`, the
label's edge nearest the screenshot. Labels never wrap on their own, so break long ones with
`<br>`. Moving a box means reading its coordinates off the raw crop.

## Retaking the screenshots

`media/chore-tracker/capture.sh` retakes `raw/*.png` and `bg.png`; then compose as above. It
needs the beta client on screen at interface scale 100, the dev bridge connected and
Chore Tracker in its list view. It checks the state below and stops if it differs, rather than
changing your picks.

- **Picks**, in this order: Dream of Iaia Resources (daily), Dream of Iaia XP (weekly), Feather
  Shop Run, Rune Shop Run, Daily Challenge, Herb Run, Sinkholes, Divine Locations, Tears of
  Guthix, Penguin Hide and Seek, Sand from Bert, Giant Oyster, God Statues.
- **Ticks**: Dream of Iaia Resources, Daily Challenge and Herb Run (Daily 3/5); Dream of Iaia
  XP, Feather Shop Run and Tears of Guthix (Weekly 3/6); no monthlies (0/2). After a reset,
  re-tick them, e.g. `scripts/rsdev.py eval --plugin chore-tracker 'press("Herb Run")'` in the
  list view. In settings view the same `press(name)` picks or drops a chore.
- **Window**: expanded, wide and tall enough to show all 13 rows without scrolling (it was
  345x574). The crops follow the window wherever it is; the backdrop is the game scene at
  window pixels 0-1120 x 140-770, so keep game interfaces out of that area.

The script ticks the last two dailies from the strip to show the popup (and its jingle), then
unticks them. The full screenshots it takes show chat and names, so they stay in gitignored
`dumps/`; only the crops of plugin UI and the blurred backdrop are kept here.

The insets in `capture.sh` trim the game pixels round each frame. If a PrettyUI update changes
a frame, check the crop's edges zoomed in (`magick raw/list.png -crop 24x24+0+0 -scale 800%
x.png`) and adjust them.

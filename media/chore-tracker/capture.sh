#!/usr/bin/env bash
# Retake Chore Tracker's raw gallery crops (raw/*.png) and backdrop (bg.png) from the beta
# client, then render with `scripts/gallery.py compose media/chore-tracker`. README.md here has
# the state the client must be in first; this checks it and stops if it differs.
# It clicks only plugin UI (rsdev.py click refuses anything else) and ends with the list as it
# found it. The popup step plays the DAILIES COMPLETE jingle.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

media=media/chore-tracker
# The full shot shows chat and names, so it stays in gitignored dumps/, never in media/.
full=dumps/gallery-build/chore-tracker-full.png
mkdir -p dumps/gallery-build

rsdev() { scripts/rsdev.py "$@"; }
gallery() { python3 scripts/gallery.py "$@"; }

rsdev status | grep -q '^bridge: connected' || {
    echo "capture: the dev bridge isn't connected (console: pon dev-bridge)" >&2
    exit 2
}

# The picks, in the order they were picked (README.md), and the list's period counts.
rsdev eval --plugin chore-tracker '
local want = { "dream-of-iaia-resource-daily", "dream-of-iaia-xp-weekly", "feather-shop-run",
    "rune-shop-run", "daily-challenge", "herb-run", "sinkholes", "divine-locations",
    "tears-of-guthix", "penguin-hide-and-seek", "bert-sand", "giant-oyster", "god-statues" }
local m = exposed.main()
assert(m.mode == "list", "open the list view first, not " .. tostring(m.mode))
local got = m.tracker.selected
local same = #got == #want
for i, id in ipairs(want) do same = same and got[i] == id end
assert(same, "picks differ from README.md: " .. table.concat(got, ", "))
return true' >/dev/null
tree=$(rsdev ui)
for heading in 'Daily  3/5' 'Weekly  3/6' 'Monthly  0/2'; do
    grep -qF "'$heading'" <<<"$tree" || {
        echo "capture: the list doesn't show '$heading'; tick as README.md says" >&2
        exit 1
    }
done

# The window's box. Its buttons sit at fixed offsets from its corners, and the frame is drawn
# a pixel or so inside the box, hence the insets.
read -r L T W H < <(gallery box --text Chores)
gear_x=$((L + 32)) gear_y=$((T + 54))
menu_x=$((L + W - 17)) menu_y=$((T + 17)) # the menu button, the back button and the strip's

gallery grab "$media/raw/list.png" --text Chores --inset 2,1,3,1 --full "$full"
# Backdrop: game scene left of the window, blurred past recognising anything (or anyone).
magick "$full" -crop 1120x630+0+140 +repage -resize '1920x1080!' -blur 0x18 -modulate 70,85 \
    "$media/bg.png"

rsdev click "$gear_x" "$gear_y" && sleep 1
gallery grab "$media/raw/settings.png" --text Chores --inset 2,1,3,1
rsdev click "$menu_x" "$menu_y" && sleep 1 # back to the list
rsdev click "$menu_x" "$menu_y" && sleep 1 # fold into the strip
gallery grab "$media/raw/strip.png" --text 'Daily:' --inset 0,0,1,0

# Ticking the last two dailies from the strip shows the period popup, for about 4 s.
rsdev click --text 'Daily:' && sleep 1.5
rsdev click --text 'Daily:' && sleep 0.5
gallery grab "$media/raw/popup.png" --text COMPLETE --inset 1,0,1,1

# Back as found: open the window and untick those two dailies.
rsdev click "$menu_x" "$menu_y" && sleep 1
rsdev eval --plugin chore-tracker 'press("Sinkholes"); press("Divine Locations")' >/dev/null
echo "capture: done; now run: python3 scripts/gallery.py compose $media"

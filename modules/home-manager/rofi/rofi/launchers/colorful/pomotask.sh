#!/usr/bin/env bash

# PomoTask launcher.
#
# Lists the app's timer habits. Enter on a match starts that habit's timer.
# Type a name that matches nothing and hit Enter: it becomes a QUICK TASK
# (calendar-tracked, not added to the habit list).
#
# Backend: pomotask-backend.py (rofi script mode; ROFI_RETV 1=match 2=custom).

theme="style_10"
dir="$HOME/.config/rofi/launchers/colorful"

# colors (same palette as launcher.sh)
ALPHA="#00000000"
BG="#000000BB"
FG="#FFFFFFff"
SELECT="#101010ff"

COLORS=('#EC7875' '#61C766' '#FDD835' '#42A5F5' '#BA68C8' '#4DD0E1' '#00B19F' \
	'#FBC02D' '#E57C46' '#AC8476' '#6D8895' '#EC407A' '#B9C244' '#6C77BB')
ACCENT="${COLORS[8]}ff"

cat > $dir/colors.rasi <<- EOF
	/* colors */

	* {
	  al:  $ALPHA;
	  bg:  $BG;
	  se:  $SELECT;
	  fg:  $FG;
	  ac:  $ACCENT;
	}
EOF

if [ $XDG_SESSION_TYPE == "wayland" ]; then
	rofi -no-lazy-grab -show pomotask -modes "pomotask:$dir/pomotask-backend.py" -theme $dir/"$theme"
else
	rofi -show pomotask -modes "pomotask:$dir/pomotask-backend.py" -theme $dir/"$theme"
fi

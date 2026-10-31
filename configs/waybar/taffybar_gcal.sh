#!/usr/bin/env bash

# Adapter: waybar JSON custom module -> pango markup for taffybar.
# taffybar's commandRunner renders markup, so the class becomes a text colour.
set -o pipefail

json=$(/etc/nixos/configs/waybar/waybar_gcal.sh 2>/dev/null)
if [[ -z "$json" ]]; then
  class=none
  text="󰃭 No current event"
else
  class=$(jq -r '.class // "none"' <<<"$json" 2>/dev/null)
  text=$(jq -r '.text // "󰃭 No current event"' <<<"$json" 2>/dev/null)
fi

case "$class" in
  now) color="#51afef" ;;
  *) color="#5c6370" ;;
esac

# Pango must not see raw event-title markup.
escaped=$(printf '%s' "$text" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
printf '<span color="%s">%s</span>\n' "$color" "$escaped"

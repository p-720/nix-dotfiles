#!/usr/bin/env bash

export XAUTHORITY=$(ls /var/run/sddm/xauth_* | head -n 1)
export DISPLAY=:0
xset dpms 3600 3600 3600
xset s 3600
xset dpms force on

DEVICE=$(aplay -L | rg "hdmi.+0" | tail -n 1 | awk '{print $1}') # Your ALSA device
SOUND_FILE="/etc/nixos/homecoming_40.wav"                 # Your sound file
PID_FILE="/tmp/loop_sound.pid"
echo $DEVICE;

# Store the PID
echo $$ > "$PID_FILE"

# Loop the sound with volume control
while true; do
    if [ -f /tmp/stop_alarm ]; then
        break
    fi
    aplay -D "$DEVICE" "$SOUND_FILE"
done

rm /tmp/stop_alarm

# restore the dwm session defaults; blanking is xidlehook's job (video aware)
xset s off
xset dpms 0 0 0

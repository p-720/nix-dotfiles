#!/usr/bin/env bash

# 1. Launch Emacs
# We set the frame name to "emacs-todo" so we can detect it later.
# Note: I adjusted the quoting slightly to ensure the alist is valid ((key . val)).

# 2. Launch Brave (Notion Calendar)
# brave --disable-features=WaylandWpColorManagerV1 --new-window --app=https://calendar.notion.so/ &
emacsclient -c -F '((name . "emacs-todo"))' &
firefox-pwa https://calendar.notion.so/
# firefoxpwa site launch 01KHGFZJW5A9WBS3CZPFAFKXPJ
# 3. Wait loop (Max 10 seconds)
# We poll hyprctl clients to check if the windows actually exist before proceeding.
MAX_RETRIES=20
i=0

while [ $i -lt $MAX_RETRIES ]; do
    # Get current window list
    CLIENTS=$(hyprctl clients)

    # Check if BOTH "emacs-todo" and "Notion" (or the URL) are present in the client list
    if echo "$CLIENTS" | grep -q "emacs-todo" && echo "$CLIENTS" | grep -q "firefox"; then
        break
    fi

    sleep 0.5
    ((i++))
done

# 4. Small safety buffer
# Sometimes windows are "listed" before they are fully rendered/moveable.
sleep 0.2

# 5. Run the positioning script
/etc/nixos/configs/hypr/position-emacs.py

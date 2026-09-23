#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p "python3.withPackages (ps: with ps; [ websocket-client ])"
"""Polybar module for PomoTask timer/pomodoro.

Usage:
    python3 polybar-pomotask.py          # Tail mode (continuous output)
    python3 polybar-pomotask.py --stop   # Stop the running timer

Dependencies are provided by the Nix shebang.

Add to polybar config:
    [module/pomotask]
    type = custom/script
    exec = python3 /path/to/polybar-pomotask.py
    tail = true
    click-left = python3 /path/to/polybar-pomotask.py --stop
"""

import json
import signal
import sys
import threading
import time

try:
    import websocket
except ImportError:
    print(
        "Error: websocket-client not installed. Run: pip install websocket-client",
        file=sys.stderr,
    )
    sys.exit(1)

WS_URL = "wss://ug.kyrgyzstan.kg/pomotask/ws"
POMODORO_DURATION = 1500  # 25 minutes


def format_timer(state):
    """Format timer state for polybar display."""
    if not state or not state.get("running"):
        return ""

    mode = state.get("mode", "stopwatch")
    start_time = state.get("startTime")
    elapsed_before = state.get("elapsedBefore", 0)
    # Quick-task timers carry a name (habit timers: no name, unchanged output)
    prefix = f"{state['name']} " if state.get("name") else ""

    if start_time:
        elapsed = int((time.time() * 1000 - start_time) / 1000) + elapsed_before
    else:
        elapsed = elapsed_before

    if mode == "timed":
        remaining = max(0, POMODORO_DURATION - elapsed)
        mins = remaining // 60
        secs = remaining % 60
        return f"{prefix}\U0001F345 {mins:02d}:{secs:02d}"
    else:
        mins = elapsed // 60
        secs = elapsed % 60
        return f"{prefix}\U000023F0 {mins}m {secs}s"


def tail_mode():
    """Run in tail mode: maintain WS connection and print updates."""
    state_lock = threading.Lock()
    current_state = {}
    running = True
    ws_ref = [None]
    ticker_thread = [None]

    def print_state():
        with state_lock:
            s = dict(current_state)
        print(format_timer(s), flush=True)

    def ticker():
        while running:
            with state_lock:
                is_running = current_state.get("running", False)
            if is_running:
                print_state()
            time.sleep(1)

    def on_message(_, message):
        try:
            msg = json.loads(message)
        except json.JSONDecodeError:
            return
        if msg.get("type") in ("timer:sync", "timer:update"):
            data = msg.get("data", {})
            with state_lock:
                current_state.clear()
                current_state.update(data)
            print_state()

    def on_error(_, error):
        with state_lock:
            current_state.clear()
        print("", flush=True)

    def on_close(_, code, reason):
        with state_lock:
            current_state.clear()
        print("", flush=True)

    def connect():
        ws_ref[0] = websocket.WebSocketApp(
            WS_URL,
            on_message=on_message,
            on_error=on_error,
            on_close=on_close,
        )
        ws_ref[0].run_forever()

    def signal_handler(sig, frame):
        nonlocal running
        running = False
        if ws_ref[0]:
            ws_ref[0].close()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    ticker_thread[0] = threading.Thread(target=ticker, daemon=True)
    ticker_thread[0].start()

    while running:
        try:
            connect()
        except Exception:
            with state_lock:
                current_state.clear()
            print("", flush=True)
        time.sleep(3)


def stop_mode():
    """Send stop signal via WebSocket."""
    try:
        ws = websocket.create_connection(WS_URL)
        ws.send(json.dumps({"type": "timer:stop"}))
        ws.close()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--stop":
        stop_mode()
    else:
        tail_mode()

# Qtile config ported from configs/hypr (keybindings, workspaces, specials,
# window rules) and configs/waybar (bar layout/colors).

import os
import re
import subprocess
import time

from libqtile import bar, hook, layout, qtile, widget
from libqtile.backend.wayland import InputConfig
from libqtile.config import Click, Drag, Group, Key, KeyChord, Match, Rule, Screen
from libqtile.lazy import lazy
from qtile_extras import widget as extras_widget

MOD = "mod4"
ALT = "mod1"

TERMINAL = "/etc/nixos/bin/xterm-foot"
FILE_MANAGER = "nautilus"
LAUNCHER = os.path.expanduser("~/.config/rofi/launchers/colorful/launcher.sh")
POMOTASK = os.path.expanduser("~/.config/rofi/launchers/colorful/pomotask.sh")
LIGHT_CONTROL = os.path.expanduser("~/.config/polybar/light_control.sh")
FIREFOX = "firefox --new-window"

BAR_HEIGHT = 30
BAR_BG = "#000000"
BAR_OPACITY = 0.5
FONT = "ShureTechMono Nerd Font"
FONT_SIZE = 16
FG = "#ffffff"
ACCENT = "#51afef"
URGENT = "#7bc275"
DARK = "#2a2e38"
BORDER_ACTIVE = "#33ccff"
BORDER_INACTIVE = "#595959"

NUMERIC_GROUPS = 12
SCREEN_0_GROUPS = 6


def _on_wayland():
    # XDG_SESSION_TYPE lies when a session is nested; the backend does not
    return getattr(qtile, "core", None) is not None and qtile.core.name == "wayland"

# hyprland special workspaces: (group, spawn command, layout, margin)
SPECIALS = {
    "default": ("special-default", "qbittorrent", "monadtall", 25),
    "emacs": ("special-emacs", """emacsclient -c -F '((name . "emacs-todo"))'""", "monadtall", 25),
    "speedcrunch": ("special-speedcrunch", "speedcrunch", "floating", 0),
    "term": ("special-term", TERMINAL, "monadtall", 40),
    "openai": ("special-openai", f"{FIREFOX} https://chatgpt.com/", "monadtall", 25),
    "deepseek": ("special-deepseek", f"{FIREFOX} https://chat.deepseek.com/", "monadtall", 25),
    "grok": ("special-grok", f"{FIREFOX} https://grok.com/", "monadtall", 25),
    "otherai": ("special-otherai", f"{FIREFOX} https://claude.ai/", "monadtall", 25),
    "gemini": ("special-gemini", f'{FIREFOX} "https://aistudio.google.com/prompts/new_chat"', "monadtall", 25),
    "music": ("special-music", f"{FIREFOX} https://open.spotify.com/", "monadtall", 25),
}

_special_spawned: dict[str, float] = {}


@lazy.function
def go_to_group(qtile, name):
    group = qtile.groups_map[name]
    if len(qtile.screens) > 1:
        target = 0 if int(name) <= SCREEN_0_GROUPS else 1
        if target < len(qtile.screens):
            qtile.focus_screen(target)
    group.toscreen()


@lazy.function
def move_group_to_screen(qtile, screen_index):
    if screen_index < len(qtile.screens):
        qtile.current_group.toscreen(screen_index)


@lazy.function
def toggle_special(qtile, name):
    group_name, cmd, _layout, _margin = SPECIALS[name]
    group = qtile.groups_map[group_name]
    screen = qtile.current_screen

    if screen.group is group:
        screen.toggle_group(group)
        return

    group.toscreen()
    if not group.windows:
        now = time.time()
        # key repeat must not spawn a second window while the first one maps
        if now - _special_spawned.get(group_name, 0) > 5:
            _special_spawned[group_name] = now
            qtile.spawn(cmd, group=group_name)


@lazy.function
def layout_call(qtile, name, fallback=None):
    # monadtall and columns expose different resize/move commands
    for candidate in (name, fallback):
        if candidate is None:
            continue
        method = getattr(qtile.current_layout, candidate, None)
        if callable(method):
            method()
            return


@lazy.function
def lock_screen(qtile):
    qtile.spawn("swaylock -c 000000" if qtile.core.name == "wayland" else "i3lock -c 000000")


@lazy.function
def fit_to_screen(qtile):
    win = qtile.current_window
    if win is None:
        return
    screen = qtile.current_screen
    if not win.floating:
        win.toggle_floating()
    win.place(
        screen.x,
        screen.y + 15,
        screen.width,
        screen.height - BAR_HEIGHT - 15,
        win.borderwidth,
        win.bordercolor,
        above=True,
    )


def _padded_master(margin):
    # Group.layout_opts is only applied to dynamic groups, so specials need
    # their own layout instances to get hyprland's gaps
    return [
        layout.MonadTall(
            ratio=0.5,
            border_focus=BORDER_ACTIVE,
            border_normal=BORDER_INACTIVE,
            border_width=2,
            margin=margin,
        )
    ]


groups = [
    Group(str(i), label=str(i), screen_affinity=0 if i <= SCREEN_0_GROUPS else 1)
    for i in range(1, NUMERIC_GROUPS + 1)
]
groups += [
    Group(
        group_name,
        label="",
        layout=group_layout,
        layouts=_padded_master(margin) if group_layout == "monadtall" else None,
    )
    for group_name, _cmd, group_layout, margin in SPECIALS.values()
]

keys = [
    # apps
    Key([MOD], "Return", lazy.spawn(TERMINAL), desc="Terminal"),
    Key([MOD], "q", lazy.spawn(TERMINAL), desc="Terminal"),
    Key([MOD], "x", lazy.window.kill(), desc="Close window"),
    Key([MOD, "shift"], "q", lazy.shutdown(), desc="Exit qtile"),
    Key([MOD, "shift"], "r", lazy.reload_config(), desc="Reload config"),
    Key([MOD, "control"], "r", lazy.reload_config(), desc="Reload config"),
    Key([MOD, "shift"], "l", lock_screen(), desc="Lock screen"),
    Key([MOD], "e", lazy.spawn(FILE_MANAGER), desc="File manager"),
    Key([MOD], "t", lazy.window.toggle_floating(), desc="Toggle floating"),
    Key([MOD], "d", lazy.spawn(LAUNCHER), desc="Launcher"),
    Key([MOD], "p", lazy.spawn(POMOTASK), desc="Pomotask"),
    Key([MOD], "z", lazy.spawn(POMOTASK), desc="Pomotask"),
    Key([MOD], "bracketright", lazy.spawn(LIGHT_CONTROL), desc="Lights"),
    Key([MOD], "f", lazy.window.toggle_fullscreen(), desc="Fullscreen"),
    Key([MOD], "period", lazy.window.bring_to_front(), desc="Raise window"),
    Key([MOD], "Tab", lazy.next_layout(), desc="Next layout"),
    Key([MOD], "apostrophe", layout_call("flip", "normalize"), desc="Flip master"),
    # move focus
    Key([MOD], "h", layout_call("left", "next"), desc="Focus left"),
    Key([MOD], "l", layout_call("right", "next"), desc="Focus right"),
    Key([MOD], "j", layout_call("down", "next"), desc="Focus down"),
    Key([MOD], "k", layout_call("up", "next"), desc="Focus up"),
    Key([MOD], "space", lazy.layout.next(), desc="Next window"),
    # move window; hypr moves by direction, master layout only swaps stacks
    Key([MOD, ALT], "h", layout_call("shuffle_left", "shuffle_up"), desc="Move window left"),
    Key([MOD, ALT], "l", layout_call("shuffle_right", "shuffle_down"), desc="Move window right"),
    Key([MOD, ALT], "j", layout_call("shuffle_down"), desc="Move window down"),
    Key([MOD, ALT], "k", layout_call("shuffle_up"), desc="Move window up"),
    # resize
    Key([MOD, "control"], "h", layout_call("shrink", "grow_left"), desc="Shrink window"),
    Key([MOD, "control"], "l", layout_call("grow", "grow_right"), desc="Grow window"),
    Key([MOD, "control"], "j", layout_call("shrink", "grow_down"), desc="Shrink window"),
    Key([MOD, "control"], "k", layout_call("grow", "grow_up"), desc="Grow window"),
    Key([MOD, "control"], "n", layout_call("normalize"), desc="Reset sizes"),
    # hypr SUPER+bracketleft: resize to the monitor, center, keep the bar clear
    Key([MOD], "bracketleft", fit_to_screen(), desc="Fit window to screen"),
    # media and screenshots
    Key([], "XF86AudioRaiseVolume", lazy.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")),
    Key([], "XF86AudioLowerVolume", lazy.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")),
    Key([], "XF86AudioMute", lazy.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")),
    Key([], "XF86Search", lazy.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")),
    Key([], "XF86AudioMicMute", lazy.spawn("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")),
    Key([], "XF86MonBrightnessUp", lazy.spawn("brightnessctl s 10%+")),
    Key([], "XF86MonBrightnessDown", lazy.spawn("brightnessctl s 10%-")),
    Key([], "XF86AudioNext", lazy.spawn("playerctl next")),
    Key([], "XF86AudioPause", lazy.spawn("playerctl play-pause")),
    Key([], "XF86AudioPlay", lazy.spawn("playerctl play-pause")),
    Key([], "XF86AudioPrev", lazy.spawn("playerctl previous")),
    Key([], "Print", lazy.spawn("flameshot gui --delay=1000")),
    Key([], "Scroll_Lock", lazy.spawn("fish -c 'record_screen_replay_sound'")),
    Key(["shift"], "Scroll_Lock", lazy.spawn("fish -c 'trim_last_replay'")),
    Key(["control"], "Scroll_Lock", lazy.spawn("fish -c 'copy_last_replay'")),
    Key(["control", "shift"], "Scroll_Lock",
        lazy.spawn("fish -c 'record_screen_replay_sound_stop'")),
    Key(["control"], "Print", lazy.spawn("fish -c 'flameshot full -c'")),
    Key(["shift"], "Print", lazy.spawn("sh -c 'flameshot screen -c'")),
    Key(["control", "shift"], "Print",
        lazy.spawn("sh -c '~/.config/i3/screenshot_window.sh activewindow'")),
    Key([], "Pause", lazy.spawn("fish -c 'record'")),
    Key(["shift"], "Pause", lazy.spawn("fish -c 'trim_video_from_clipboard'")),
    Key(["control", "shift"], "u", lazy.spawn("fish -c 'shorten-url'")),
    # specials
    Key([MOD], "s", toggle_special("default"), desc="Special: qbittorrent"),
    Key([MOD], "n", toggle_special("emacs"), desc="Special: emacs"),
    Key([MOD], "c", toggle_special("speedcrunch"), desc="Special: calculator"),
    Key([], "F12", toggle_special("term"), desc="Special: terminal"),
    Key([MOD], "g", toggle_special("openai"), desc="Special: chatgpt"),
    Key([MOD], "o", toggle_special("deepseek"), desc="Special: deepseek"),
    Key([MOD], "u", toggle_special("grok"), desc="Special: grok"),
    Key([MOD], "i", toggle_special("otherai"), desc="Special: claude"),
    Key([MOD], "b", toggle_special("gemini"), desc="Special: gemini"),
    Key([MOD], "m", toggle_special("music"), desc="Special: spotify"),
]

GROUP_KEYS = list("1234567890") + ["minus", "equal"]
for group_number, key in enumerate(GROUP_KEYS, start=1):
    keys += [
        Key([MOD], key, go_to_group(str(group_number)), desc=f"Group {group_number}"),
        Key([MOD, "shift"], key, lazy.window.togroup(str(group_number)),
            desc=f"Move window to group {group_number}"),
    ]

keys += [
    # hypr: ALT+SUPER+1/0 -> monitor 0, ALT+SUPER+2/9 -> monitor 1
    Key([ALT, MOD], "1", move_group_to_screen(0)),
    Key([ALT, MOD], "0", move_group_to_screen(0)),
    Key([ALT, MOD], "2", move_group_to_screen(1)),
    Key([ALT, MOD], "9", move_group_to_screen(1)),
    Key([ALT, MOD], "minus", move_group_to_screen(2)),
    # hypr resize submap
    KeyChord(
        [MOD],
        "r",
        [
            Key([], "h", layout_call("shrink", "grow_left")),
            Key([], "left", layout_call("shrink", "grow_left")),
            Key([], "l", layout_call("grow", "grow_right")),
            Key([], "right", layout_call("grow", "grow_right")),
            Key([], "k", layout_call("shuffle_up")),
            Key([], "up", layout_call("shuffle_up")),
            Key([], "j", layout_call("shuffle_down")),
            Key([], "down", layout_call("shuffle_down")),
            Key([MOD], "r", lazy.ungrab_chord()),
        ],
        mode=True,
        name="resize",
        desc="Resize windows",
    ),
]

mouse = [
    Drag([MOD], "Button1", lazy.window.set_position_floating(),
         start=lazy.window.get_position()),
    Drag([MOD], "Button3", lazy.window.set_size_floating(),
         start=lazy.window.get_size()),
    Click([MOD], "Button2", lazy.window.bring_to_front()),
    # hypr: scroll down = previous workspace, up = next
    Click([MOD], "Button5", lazy.screen.prev_group()),
    Click([MOD], "Button4", lazy.screen.next_group()),
]

layouts = [
    layout.MonadTall(
        ratio=0.70,
        align=layout.MonadTall._left,
        border_focus=BORDER_ACTIVE,
        border_normal=BORDER_INACTIVE,
        border_width=2,
        margin=0,
    ),
    layout.Columns(
        border_focus=BORDER_ACTIVE,
        border_normal=BORDER_INACTIVE,
        border_width=2,
        margin=0,
    ),
    layout.Max(
        border_focus=BORDER_ACTIVE,
        border_normal=BORDER_INACTIVE,
        border_width=2,
    ),
    layout.Floating(
        border_focus=BORDER_ACTIVE,
        border_normal=BORDER_INACTIVE,
        border_width=2,
    ),
]

floating_layout = layout.Floating(
    border_focus=BORDER_ACTIVE,
    border_normal=BORDER_INACTIVE,
    border_width=2,
    float_rules=[
        *layout.Floating.default_float_rules,
        Match(wm_class="confirmreset"),
        Match(wm_class="makebranch"),
        Match(wm_class="maketag"),
        Match(wm_class="ssh-askpass"),
        Match(title="branchdialog"),
        Match(title="pinentry"),
        Match(wm_class="steam"),
        Match(wm_class="Steam"),
        Match(wm_class="anki"),
        Match(wm_class="Anki"),
        Match(wm_class="org.pulseaudio.pavucontrol"),
        Match(wm_class="Pavucontrol"),
        Match(wm_class="blueman-manager"),
        Match(wm_class=".blueman-manager-wrapped"),
        Match(wm_class="guake"),
        Match(wm_class="Yad"),
        Match(wm_class="xdg-desktop-portal-gtk"),
        Match(wm_class="Gpick"),
        Match(wm_class="chatterino"),
        Match(wm_class="anydesk"),
        Match(wm_class="file-jpeg"),
        Match(wm_class="org.kde.kdenlive"),
        Match(wm_class="Kdenlive"),
        Match(title="Library"),
        Match(title=re.compile(r"^Choose.+")),
        Match(title="Picture-in-Picture"),
        Match(title="Media viewer"),
        Match(title="flameshot"),
    ],
)

dgroups_app_rules = [
    # wayland app id vs X11 WM_CLASS
    Rule(Match(wm_class=re.compile(r"^(org\.telegram\.desktop|TelegramDesktop)$")), group="11"),
    Rule(Match(wm_class="max"), group="12"),
    Rule(Match(wm_instance_class="calendar.google.com"), group="10"),
    Rule(Match(wm_class="qBittorrent"), group="special-default"),
    Rule(Match(wm_class="SpeedCrunch"), group="special-speedcrunch"),
    Rule(Match(title="emacs-todo"), group="special-emacs"),
]

AUTOSTART = [
    "dunst",
    "gammastep -c ~/.config/gammastep.conf",
    "pasystray",
    "blueman-applet",
    "flameshot",
]
AUTOSTART_X11 = [
    # taffybar's SNI tray crashes on stale watcher state
    "rm -f ~/.cache/status-notifier-item/*.json; status-notifier-watcher",
    "while xset q >/dev/null 2>&1; do taffybar; sleep 2; done",
    "xsetroot -cursor_name left_ptr",
    # hypridle turned DPMS off after 180s
    "xset s off",
    "xset dpms 0 0 180",
    "picom --daemon",
    'if [ "$(darkman get 2>/dev/null)" = dark ]; then '
    "feh --bg-fill /etc/nixos/bg_old.png; else feh --bg-fill /etc/nixos/light.jpg; fi",
]
AUTOSTART_WAYLAND = [
    "awww-daemon",
    'sleep 1 && if [ "$(darkman get 2>/dev/null)" = dark ]; then '
    "awww img /etc/nixos/bg_old.png; else awww img /etc/nixos/light.jpg; fi",
]


@hook.subscribe.startup_once
def _autostart():
    commands = AUTOSTART + (AUTOSTART_WAYLAND if _on_wayland() else AUTOSTART_X11)
    for cmd in commands:
        subprocess.Popen(
            ["sh", "-c", cmd],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


def _groupbox(visible):
    return widget.GroupBox(
        visible_groups=visible,
        disable_drag=True,
        highlight_method="block",
        rounded=False,
        borderwidth=0,
        margin_x=0,
        margin_y=0,
        padding_x=10,
        padding_y=4,
        active=FG,
        inactive=FG,
        block_highlight_text_color=DARK,
        this_current_screen_border=ACCENT,
        this_screen_border=ACCENT,
        other_current_screen_border=DARK,
        other_screen_border=DARK,
        urgent_text=DARK,
        urgent_border=URGENT,
    )


def _make_bar(widgets):
    return bar.Bar(
        widgets,
        BAR_HEIGHT,
        background=BAR_BG,
        opacity=BAR_OPACITY,
        margin=0,
    )


def _make_widgets(visible, with_tray):
    widgets = [
        _groupbox(visible),
        widget.WindowName(format="{name}", max_chars=60, padding=10),
        widget.Chord(
            name_transform=lambda name: f" {name} ",
            chords_colors={"resize": (URGENT, DARK)},
        ),
        widget.Spacer(),
        widget.Clock(format="%a, %d %b %H:%M", padding=10),
        widget.Spacer(),
        widget.CPU(format="{load_percent:.0f}% ", update_interval=2, padding=8),
        widget.Memory(
            format="󰍛 {MemUsed:.1f}/{MemTotal:.1f}{mm}", update_interval=2, padding=8
        ),
        widget.PulseVolume(
            unmute_format=" {volume}%",
            mute_format=" mute",
            padding=8,
            mouse_callbacks={"Button1": lazy.spawn("pavucontrol")},
        ),
    ]
    if with_tray:
        widgets.append(extras_widget.StatusNotifier(icon_size=18, padding=4))
    return widgets


def generate_screens(outputs):
    if not _on_wayland():
        # taffybar is an X11 dock and Qtile reserves its strut itself
        return [Screen() for _ in outputs]

    if len(outputs) > 1:
        visible = [
            [str(i) for i in range(1, SCREEN_0_GROUPS + 1)],
            [str(i) for i in range(SCREEN_0_GROUPS + 1, NUMERIC_GROUPS + 1)],
        ]
        tray_index = 1
    else:
        visible = [[str(i) for i in range(1, NUMERIC_GROUPS + 1)]]
        tray_index = 0

    screens = []
    for index, _output in enumerate(outputs):
        groups_on_bar = visible[index] if index < len(visible) else visible[-1]
        screens.append(
            Screen(bottom=_make_bar(_make_widgets(groups_on_bar, index == tray_index)))
        )
    return screens


widget_defaults = dict(
    font=FONT,
    fontsize=FONT_SIZE,
    padding=8,
    foreground=FG,
)
extension_defaults = widget_defaults.copy()

# hyprland input: accel_profile = flat, sensitivity = 0
wl_input_rules = {
    "type:pointer": InputConfig(accel_profile="flat", pointer_accel=0.0),
    "type:touchpad": InputConfig(accel_profile="flat", pointer_accel=0.0),
}

dgroups_key_binder = None
follow_mouse_focus = True
bring_front_click = False
cursor_warp = False
auto_fullscreen = True
focus_on_window_activation = "smart"
reconfigure_screens = True
auto_minimize = True
wmname = "LG3D"

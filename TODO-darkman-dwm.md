# TODO: make darkman switching do something under dwm

## Goal

Dark/light transitions actually change the wallpaper and the GTK theme in the X11 dwm
session, while hyprland/dwl hosts keep their awww behaviour.

## Diagnosis (measured on the live session)

Every transition runs both scripts and both fail:

```
gtk-theme:  No schemas installed
hyprpaper:  Error: Socket file '/run/user/1000/wayland-0-awww-daemon.sock' not found
```

- `modules/nixos/darkman/default.nix` only ships a Wayland wallpaper tool (`awww`); dwm is X11.
- No compiled `gschemas.compiled` is reachable in this session: `/run/current-system/sw/share/glib-2.0`
  does not exist, so `gsettings` fails for the whole dwm session, not just for darkman.
  `programs.dconf.enable = true` already works (dconf dbus activation, `~/.config/dconf/user` present),
  so only the schema side is missing.
- Reproduced fix for the schema side: `NIX_GSETTINGS_OVERRIDES_DIR=<schemas>/share/gsettings-schemas/gsettings-desktop-schemas-50.1/glib-2.0/schemas`
  makes `gsettings get org.gnome.desktop.interface color-scheme` return `'prefer-dark'` with `XDG_DATA_DIRS` cleared.
  glib is patched (`pkgs/by-name/gl/glib/schema-override-variable.patch`) to search that dir.
- `environment.sessionVariables` do reach both the dwm session and the `darkman.service` user unit
  (verified via `/proc/<pid>/environ` marker `NAUTILUS_4_EXTENSION_DIR`).

## Tasks

### 1. Make gsettings usable in the dwm session

- [x] In `modules/nixos/darkman/default.nix`, set
      `environment.sessionVariables.NIX_GSETTINGS_OVERRIDES_DIR`
      to `${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pname}-${version}/glib-2.0/schemas`
      under `mkIf cfg.enable`.
- [x] Confirm `pkgs.gsettings-desktop-schemas` version matches the one GNOME apps in this closure already use
      (50.1 for both) so the prepended schema source cannot hide a key an app expects.
      `nix-store -qR /run/current-system/sw/bin/nautilus` → `gsettings-desktop-schemas-50.1`,
      `pkgs.gsettings-desktop-schemas.version` → `50.1`.
- [x] Also set it on the service itself (`systemd.user.services.darkman.serviceConfig.Environment`),
      because pam_env only feeds `environment.sessionVariables` to sessions that go through PAM.
      Verified the override reaches the generated unit file (same route the existing `Unit.After` took).

### 2. Make the wallpaper script pick the right compositor

- [x] Replace the `hyprpaper` dark/light scripts with `wallpaper` scripts that branch at runtime:
      `awww img … --transition-type center` when `WAYLAND_DISPLAY` is set,
      `feh --bg-fill` when only `DISPLAY` is set, no-op when neither exists.
- [x] Same images as before (`bg_old.png` dark, `light.jpg` light), now copied to the store instead of
      read from `/etc/nixos`.

### 3. Verify without touching the live session

- [x] Re-check the module's exact `NIX_GSETTINGS_OVERRIDES_DIR` string with `env -u XDG_DATA_DIRS`
      (read-only `gsettings get`, no writes to dconf): returns `'Adwaita'` / `'prefer-dark'`.
- [~] Run the generated X11 branch on the headless Xvfb `:2` rig: script exits 0 and picks feh.
      **feh itself sets no root pixmap under Xvfb** (no `_XROOTPMAP_ID`, pixels unchanged) even though it
      exits 0 — the same binary/flags do set `_XROOTPMAP_ID` on the live `:0` from the login command, so
      this is an Xvfb gap, not a fix gap. Wallpaper repaint is only provable on the real display.

### 4. Post-rebuild check (after your `rebuild-default` + re-login)

- [ ] `darkman toggle` twice and read `journalctl --user -u darkman`: no `No schemas installed`,
      no awww socket error, both scripts exit 0.
- [ ] `dconf read /org/gnome/desktop/interface/gtk-theme` flips `Adwaita` ↔ `Adwaita-dark`,
      and `darkman get` matches.

## Notes

- Cron `00 19 * * * andrew darkman set dark` stays as it is (your call).
- dwm chrome (config.h bar/border colours, dunst, taffybar CSS) stays static — out of scope by your answer.
- No dwm keybinding added.
- The session variable only lands in a process's env at login, so the first test needs a fresh dwm
  session after the rebuild; already-running apps keep the env they started with.
- glib prepends `NIX_GSETTINGS_OVERRIDES_DIR` as the highest-priority schema source, which is why the
  version match in task 1 matters.

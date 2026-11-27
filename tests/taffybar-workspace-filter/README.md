# taffybar workspace-filter checks

`./run.sh` — 23 assertions, no display needed, ~1 min for the first compile.

`filter.hs` transcribes the three pure parts of
`modules/nixos/taffybar/taffybar.hs` — the `hyprctl -j` `FromJSON` rows, the
geometry matcher, and `barScopedWorkspaces` — and runs them against
`fixtures/{monitors,workspaces}.json`, which are `hyprctl -j` output from
Hyprland 0.56.2 on this box with serials and physical sizes dropped.

**It is a copy, so it cannot fail when the real thing drifts.** The config is a
`Main` module with a GTK main loop, so there is nothing here to import. Change
the filter, the JSON fields, or the numeric fallback in `taffybar.hs` and this
file has to change in the same commit; the point of the list is that each case is
written down and named, not that CI catches the edit.

What the list is really guarding, in order:

- `01-04` the JSON fields the parser depends on still exist, and Hyprland's
  monitor **id order is the opposite of its layout order** here (`DP-5 id=1 x=0`,
  `HDMI-A-3 id=0 x=2560`) — the reason nothing may key off an id.
- `05-09` monitor matching by layout position, surviving array reorder (GDK's
  Wayland monitor list renumbers on hotplug), a size-only fallback when a scaled
  monitor reports a different origin, and a refusal to match a box that is not
  there.
- `10-13` the per-bar split that is the whole feature: `1-6` on one bar, `7-12`
  on the other, no overlap, no `special:` buttons.
- `14-15` moving a workspace to another output moves its button.
- `16-17, 22-23` the fallbacks. Before the compositor answers, the primary bar
  narrows to `1-5` only when a second bar exists to hold `6-12`; with one screen
  it keeps everything (`1-11`), which is what dwm did before this config branched.
- `18-21` odd rows: a workspace mid-drag has no `monitor` field (empty string →
  numeric), non-numeric names, and the `special:` rows hyprland reports with real
  monitor names.

Regenerate fixtures with:

```
hyprctl -j monitors > /tmp/monitors.json && hyprctl -j workspaces > /tmp/workspaces.json
```

and drop identifiers before committing (see the python in the commit that added
this directory, or just keep the fields `filter.hs` reads).

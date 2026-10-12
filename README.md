# Relaunch

A full-screen, paged app launcher for macOS 14 and later. It brings back the
grid you swipe left and right that Launchpad used to provide, including
folders, drag to rearrange, search, and page dots.

On first run it **restores your old Launchpad layout** from the database
macOS left on disk. See [docs/RESEARCH.md](docs/RESEARCH.md) for how Apple's
version worked and what replaced it.

> Not affiliated with or endorsed by Apple Inc. "Launchpad" and "macOS" are
> trademarks of Apple Inc. This project contains no Apple code or artwork.

## Build and install

Requires only the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/build.sh            # builds build/Relaunch.app
scripts/build.sh --install  # also copies it to /Applications
```

Drag `Relaunch.app` into the Dock. Clicking it opens and closes the launcher,
like Launchpad's Dock tile.

## Using it

| Action | How |
| --- | --- |
| Open / close | Dock icon, **⌥Space**, or a hot corner (see Settings) |
| Change page | Two-finger swipe, mouse wheel, ⌘← / ⌘→, or click a page dot |
| Search | Just type. Matches prefixes, words, initials (`vsc`) and ignores accents |
| Launch | Click, or arrow keys then Return |
| Rearrange | Drag an icon. Hold it at a screen edge to change page |
| Make a folder | Drop an app onto another app and hold briefly |
| Rename a folder | Open it and click the title |
| Leave a folder | Drag the app out of the panel |
| Edit mode (jiggle) | Hold ⌥ |
| Close | Esc, click empty space, ⌘W |
| More | Right-click the background: Open at Login, Restore Launchpad Layout, Reset, Quit |

## Settings

```sh
defaults write com.ahmedalghali.Relaunch hotkey "ctrl+opt+l"   # "" disables it
defaults write com.ahmedalghali.Relaunch hotCorner bottomLeft  # topLeft|topRight|bottomLeft|bottomRight
defaults write com.ahmedalghali.Relaunch columns -int 8        # default 7
defaults write com.ahmedalghali.Relaunch rows -int 6           # default 5
```

Restart Relaunch after changing settings. The layout is stored in
`~/Library/Application Support/Relaunch/layout.json`.

## Performance

Measured on an Apple-silicon MacBook running macOS 27.0, with 115 apps:

- **Startup:** app discovery takes about 50 ms. Icons render to bitmaps in
  parallel in the background.
- **Opening:** the process stays resident and the window is built once, so
  opening is a single frame followed by a 0.24 s zoom-and-fade. Launchpad got
  the same effect by living inside the Dock.
- **Paging:** the finger offset lives in its own observable object, so a
  swipe re-renders only the view that applies the translation, not the grid.
  Dragging works the same way: cursor motion redraws only the floating icon.
- **Idle:** 0 % CPU, about 100–145 MB resident, 0.9 MB binary.
- **No permissions:** the hotkey uses Carbon `RegisterEventHotKey`, and hot
  corners use mouse-move monitors, so Accessibility access isn't needed.

## How it differs from Launchpad

- Restores your Launchpad pages and folders automatically.
- Search is more forgiving: word prefixes, initials and accent-insensitive.
- New folders are named after the apps' App Store category.
- Folders can be ungrouped in one step (right-click).
- Liquid Glass on macOS 26+, materials on 14–15.
- Install and uninstall are detected live.

**Limitation:** the four-finger pinch and the F4 key stay with the system,
because both are captured by the Dock (see the research notes).

## License

MIT. See [LICENSE](LICENSE).
# relaunch

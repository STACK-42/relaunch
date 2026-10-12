# How Apple built Launchpad, and what replaced it

These findings come from inspecting a macOS 27.0 (build 26A428) system with
stock tools: `strings`, `nm -u`, `otool -L`, `plutil` and `sqlite3`. Nothing
was disassembled or decompiled, and no Apple code or artwork is in this
repository. Each command below can be re-run to check a claim.

## 1. Launchpad.app is gone, and its replacement is a stub

```
$ ls -d /System/Applications/Launchpad.app
ls: /System/Applications/Launchpad.app: No such file or directory

$ plutil -p /System/Applications/Apps.app/Contents/Info.plist
  "CFBundleIdentifier" => "com.apple.apps.launcher"
  "LSUIElement" => true
  ...
$ ls -la /System/Applications/Apps.app/Contents/MacOS/Apps
-rwxr-xr-x  1 root  wheel  133488 ...  Apps
$ nm -u /System/Applications/Apps.app/Contents/MacOS/Apps
_CoreDockSendNotification
___CFConstantStringClassReference
$ strings -a /System/Applications/Apps.app/Contents/MacOS/Apps
@(#)PROGRAM:Apps  PROJECT:Docklets-102.0.3
com.apple.launchpad.toggle
```

`Apps.app` imports one function, the private `CoreDockSendNotification`, and
contains one meaningful string, `com.apple.launchpad.toggle`. Its project name
is "Docklets". So the app only asks the Dock to toggle. The old Launchpad.app
worked the same way: **Launchpad never lived in its own app. It ran inside
`Dock.app`.**

## 2. The Dock still takes the toggle, but sends it to Spotlight

```
$ strings -a /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock | grep -i launchpad
com.apple.launchpad.toggle

$ strings -a .../Dock | grep -iE 'spotlight|FluidGesture'
_TtC8DockCore20SpotlightXPCListener
_TtCE8DockCoreCSo9Spotlight12FluidGesture
_TtC8DockCore22FluidGestureController
com.apple.dock.spotlight
SpotlightXPCClientMessage
```

The Dock's own Launchpad code is gone. Every `springboard-*` defaults key
(`springboard-columns`, `springboard-rows`, …) that used to tune Launchpad's
grid is missing from the binary. What remains is a Swift `DockCore` module
with a `SpotlightXPCListener` and a `Spotlight.FluidGesture`, which suggests
the toggle and the pinch gesture now drive Spotlight's Apps view over XPC.
The trackpad setting is still on (`TrackpadFourFingerPinchGesture = 2`), so
the gesture survives but opens the new UI.

## 3. Launchpad's data model, from the database it left behind

The Dock kept Launchpad's state in SQLite at
`$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db`. On this machine
the file is still there. `dbinfo.build = 24G84` shows macOS 15 (Sequoia)
last wrote it.

```
items        (rowid, uuid, flags, type, parent_id, ordering)
apps         (item_id, title, bundleid, storeid, category_id, moddate, bookmark)
groups       (item_id, category_id, title)          -- folders
image_cache  (item_id, size_big, size_mini, image_data, image_data_mini)
dbinfo       launchpad_root=1, version=13, build=24G84, ...
```

`items` is a tree in which `type` means 1 = root, 2 = folder, 3 = page,
4 = app and 5 = an app still downloading. Pages hang off the root, apps and
folders hang off pages, and **folders hold their own pages**. Triggers keep
`ordering` dense when items move:

```sql
CREATE TRIGGER update_items_order BEFORE UPDATE OF ordering ON items ...
  UPDATE items SET ordering = ordering - 1
   WHERE parent_id = old.parent_id AND ordering BETWEEN old.ordering AND new.ordering;
```

Apps are identified by **bundle id**, plus a bookmark blob to find the file.
Icons were pre-rendered into `image_cache` at up to 192 px, about 25 KB each.

On this machine the root page holds 35 items (7 × 5, the default grid) and
there are two folders, "Other" (29 apps) and "Games".

## 4. What this means for a re-implementation

| Launchpad (Dock) | Relaunch (this repo) |
| --- | --- |
| Stayed resident inside the Dock, so it opened instantly | Resident `LSUIElement` agent with a window that is built once |
| Tree of root → pages → items in SQLite | `[[Entry]]` pages with folders, stored as JSON |
| Bundle id as the app identity | Bundle id (falls back to the path) |
| Pre-rendered icon cache | Icons rendered to bitmaps once, concurrently, at launch |
| Overflow cascades to the next page | `Layout.normalize` does the same |
| Toggled by Dock tile, F4 key, pinch gesture | Dock tile (reopen event), global hotkey, optional hot corner |

Because the old database is still on disk, Relaunch **imports it on first
run** (`LegacyLaunchpad.swift`). Your own pages and folders come back. The
file is opened with SQLite's `immutable=1`, so Apple's file is never written.

## Not reproducible without private API

- **Four-finger pinch.** The Dock consumes the gesture before any app sees it.
  Taking it over would mean private Dock/SkyLight interfaces or disabling the
  system gesture, so Relaunch uses a hotkey and the Dock tile instead.
- **The F4 / Launchpad key.** The Dock handles it as a system-defined event.
  Intercepting it would need an event tap and the Accessibility permission.

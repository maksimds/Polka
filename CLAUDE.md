# Polka

Personal macOS menu bar app (Swift/SwiftUI + AppKit) that turns the MacBook notch into a hover-to-open shelf for files and links. Hover the notch to see stored items, drag files or links onto it to store them, drag items out into any app. Personal use, private repo.

`PolkaPRD.md` is the source of truth for goals, scope, requirements (FR-1 to FR-15), the data model, risks, and milestones. Read it before planning feature work.

## Settled decisions

- Dev machine: macOS 15.7.4, Xcode 16.3. Code is edited in VS Code; Xcode is for project settings and debugging.
- App deployment target: macOS 14.0. Swift 5 language mode. Bundle ID `com.maksimds.Polka`, personal team signing.
- Unsandboxed agent app (`LSUIElement = YES`, no Dock icon) with a `MenuBarExtra` Quit item.
- Launch at login is an "Open at Login" checkmark in the menu bar menu and a switch in Settings, both backed by one `LoginItem` using `SMAppService.mainApp`. It's off until turned on. macOS keeps the setting (it's Polka's row in System Settings > Login Items), so Polka reads it again whenever a menu opens or Polka becomes the active app.
- Settings is an AppKit window (`SettingsWindowController`) holding a SwiftUI grouped form, opened from the menu bar menu ("Settings…", Cmd-comma) or the gear at the expanded panel's top right, which collapses the panel first. It is not a SwiftUI `Settings` scene, so Polka controls how it comes forward and goes away. It opens on the pointer's screen, and closing it hands focus back to the app you were in.
- The panel follows the pointer. There is one panel, and it moves to whatever screen the pointer is on while it's collapsed or open as a drop zone, but never while expanded or during a drag out. A screen without a notch gets the top-center pill (FR-14).
- The panel is drawn with `NotchShape`: rounded bottom corners, and top corners that curve outward into the screen edge (14 pt open). On a notch screen the closed shape has no outward curves and hides inside the notch. On a screen without one it's a 160 pt pill as tall as the menu bar, with a round bottom and 6 pt outward curves.
- The open panel's strip beside the notch shows "Polka" at the top left and the Settings gear at the top right, both in dim white (0.55) and centered on the notch's height. The strip is laid out on the tiles' grid (`ShelfGridView.columns`, the same 16 pt side inset, each end held to the 52 pt picture square `ShelfItemTile.imageSide`), so "Polka" starts where the first column's pictures start and the gear ends where the last column's pictures end. The gear's frame is just the symbol, with an 8 pt larger click area.
- Motion: opening is one spring (0.42 s, bounce 0.12) shared by the shape and the shelf, which scales up from 0.92 at the top and fades in, so it grows out of the notch as one piece; closing is a quicker spring without bounce, with the shelf fading out first; the closed notch swells 14 × 4 pt in the last 100 ms of the hover delay with the same spring, so it flows into the opening (started earlier, it read as two separate steps); the open panel's shadow fades in once the opening settles; tiles grow in and shrink out as the grid reflows; corner buttons and selection fade; the drop zone has a tray icon that bounces once when a drag arrives. With Reduce Motion on, all of it becomes plain fades and the notch doesn't swell.
- Storage is a plain JSON file for v1, not SwiftData.
- Hybrid storage: items reference the original by default, with an optional "keep a copy" for permanent items.
- Deleting an item never deletes the original file.
- New items are permanent by default. Temporary is opt-in per item and lasts 24 hours unless changed in Settings (1, 6 or 12 hours, 1 or 3 days, 1 week), stored under `temporaryLifetimeSeconds`. A new lifetime only applies to items made temporary afterwards. A value set by hand with `defaults write` shows up as an extra choice.
- An incoming drag from another app opens the drop zone after 0.5 s, or right away when the pointer reaches the notch's hover area (the Settings hover area). A drag that ends sooner never opens it. Opening instantly on every drag was distracting.
- Items stay on the shelf after being dragged out.
- File tiles use Quick Look's plain thumbnail. A dark drawing on a transparent background (at least 20% see-through, visible part at most 0.35 brightness, measured on a 32 × 32 copy) would vanish on the black shelf, so it's asked for again in Quick Look's icon mode, which draws it on a white page with a thin border like Finder. Icon mode isn't used for everything because it also frames photos.
- Hover is tuned in Settings: "Open after" (0 to 800 ms in 50 ms steps, 250 by default, stored as `hoverDelayMilliseconds`) and "Hover area" (Small is just the notch and is the default, Medium adds 12 pt at the sides and 4 below, Large adds 32 and 12; stored as `hoverArea`). Every area keeps 4 pt above the notch. Changes apply on the next hover.
- Multi-select works like Finder's icon view (FR-10): click selects one tile, Command-click adds or removes, Shift-click selects the range from the last plain click, a click on empty space clears. Dragging a selected tile carries the whole selection (missing files stay behind); dragging an unselected tile selects it alone. Selected tiles get a grey square behind the picture and an accent capsule around the name. Collapsing the panel clears the selection.
- Drag out offers copy only, so a drop into Finder can never move the original.
- Dropping something already on the shelf adds nothing and shows a message inside the panel. The message only closes with its × button. While it is up, the panel collapses after the pointer has been away for 3 seconds, and the message is still there on the next hover.
- Link tiles show the site's icon (from LinkPresentation, else the site's `/favicon.ico`) and are titled "site/address path", like `GitHub/apple/swift`. The site name is the one the page declares (`og:site_name`), otherwise the capitalized domain (`Linkedin`). Requests are never disguised as a browser: a site that refuses Polka (LinkedIn) just gets the fallbacks.
- A file whose original can't be found stays on the shelf as "Unavailable" and can't be dragged. Anything Polka deletes from disk must be inside its own Application Support folder.
- "Keep a copy" lives in the tile's right-click menu, as a checkmark item for files and folders. Checking it copies the original in the background and points the item at the copy. Unchecking it goes back to the original and deletes the copy, but only if the original can still be found; otherwise the copy stays and a message says so.
- Copies live in `Copies/<UUID>/<file name>` inside Polka's folder, one folder per copy, so a copy keeps its real name when dragged out. A copy is deleted once no item uses it (removed, expired, or back on its original). Leftover folders are cleared at launch, except when shelf.json couldn't be read.
- Files that apps hand over as a promise (Photos, Mail, browser images) are written into a new copy folder and stored as copies with no original. They aren't checked for duplicates.
- A drop is read as real files first, then file promises, then links. A browser image offers both its address and a promise, and the image wins. A promise of a .webloc or .url file means the link.
- The Xcode project uses synchronized folders: new files under `Polka/Polka/` join the target automatically. Don't hand-edit `project.pbxproj` unless necessary.
- `buildServer.json` and `.vscode/settings.json` are local-only and git-ignored.

## Layout

Layers follow the PRD. Keep them separated.

- `Polka/Polka.xcodeproj`
- `Polka/Polka/PolkaApp.swift`: app entry, `MenuBarExtra`, `@NSApplicationDelegateAdaptor`
- `Polka/Polka/App/`: `AppDelegate` (builds the store and helpers, owns the `LoginItem`, opens Settings), `Log` (os.Logger, one category per layer), `ExpirySweeper` (removes expired items), `LinkPreviewFetcher` (site names and icons for links), `CopyKeeper` (makes kept copies, receives promised files, deletes unused copies), `LoginItem` (Open at Login), `SettingsWindowController` (the Settings window)
- `Polka/Polka/Window/`: `NotchGeometry` (notch rect, top-center fallback, hover areas, which screen the pointer is on), `NotchPanel` (borderless non-activating `NSPanel`, all Spaces, never key), `NotchPanelController` (state machine, hover, layout, following the pointer between screens, screen changes)
- `Polka/Polka/Input/`: `GlobalDragMonitor` (detects a drag starting anywhere via drag pasteboard `changeCount`, global mouse monitors, and a 0.05 s mouse-button poll for drag end that also reports the pointer while a drag goes on)
- `Polka/Polka/DragDrop/`: `DropTargetView` (AppKit `NSDraggingDestination` wrapping the SwiftUI content), `DropReceiver` (reads file URLs, links and file promises from the pasteboard), `ShelfDragSource` (`NSDraggingSource` owned by the panel controller), `TileDragView` (AppKit layer on each tile that starts drags, reports clicks and hover, and shows the right-click menu)
- `Polka/Polka/UI/`: `NotchView`, `NotchShape` (the panel's outline), `NotchViewModel` (`NotchState`, selection), `ShelfGridView`, `ShelfItemTile`, `ShelfItemImages` (icons, Quick Look thumbnails, the dark-on-transparent check, and site icons), `NoticeBanner`, `SettingsView` (the Settings form)
- `Polka/Polka/Storage/`: `ShelfItem`, `ShelfStore`, `ShelfPersistence`, `JSONFileShelfPersistence` (shelf.json), `ShelfLocations` (Polka's Application Support folder), `ShelfCopies` (the Copies folder, and the only code that deletes copies), `ShelfSettings` (UserDefaults: temporary lifetime, hover delay, `HoverArea`), `FileReference` (bookmarks, moved and missing files), `LinkNaming` (link titles). No AppKit or window dependencies, so it stays testable on its own.
- `Polka/PolkaTests/`: unit tests. They run inside the app, and `AppDelegate` skips the panel while they do. A test that opens a real `NotchPanel` makes `AppLaunchTests` fail, because tests run in parallel.

## Build, run, test, logs

From `Polka/`:

- Build: `xcodebuild -project Polka.xcodeproj -scheme Polka -configuration Debug build -quiet`
- Run: `pkill Polka; open ~/Library/Developer/Xcode/DerivedData/Polka-*/Build/Products/Debug/Polka.app`
- Unit tests: `xcodebuild -project Polka.xcodeproj -scheme Polka -destination 'platform=macOS,arch=arm64' test -only-testing:PolkaTests -quiet`
- Logs: `log stream --level debug --predicate 'subsystem == "com.maksimds.Polka"'`

Always build after changes to confirm it compiles. Hands-on testing (hover, drags, full-screen apps) is done by the user, who reports back.

## AppKit lessons (don't undo these)

- The panel must keep `canBecomeKey = false`. That is how it never steals focus.
- SwiftUI `.onDrop` does not work here because it tries to make the panel key. Drops go through the AppKit `DropTargetView`.
- Never show an `NSAlert` or other system dialog from the panel, because it would activate Polka and take focus. Messages go inside the panel (`NoticeBanner`).
- Opening Settings is the one place Polka activates itself (`NSApp.activate()`), because a window from an inactive app opens behind the app you're in and can't take keystrokes. Never do this from the panel.
- The Settings window handles Cmd-W itself, since an agent app's menu bar never shows.
- When Settings closes, Polka hands focus back with `NSRunningApplication.activate(from: .current)` to the last other app that was active. Otherwise Polka stays active with no window to type into.
- Any `NSWindow` that Swift keeps a reference to needs `isReleasedWhenClosed = false`, or closing it frees it twice and crashes.
- SwiftUI `Button` and tap gestures do work in the never-key panel. Only dragging needs AppKit.
- The panel is a fixed-size transparent window, and SwiftUI animates the shape inside it. `ignoresMouseEvents` is true only while the shape is notch-sized (`.collapsed` or `.draggingOut`), so clicks pass through. It also removes the window as a drop target, which is what lets a drag reach whatever is behind the panel.
- Inside drag callbacks, read the pasteboard right away but defer state changes by one run-loop tick. Changing state during the callback produces the system log "Reentrant message: kDragIPCCompleted ...".
- A file promise is the one exception: `receivePromisedFiles` is called inside `performDragOperation`, while the drag is still going. It only starts receiving; items are added when the files arrive.
- The tile's right-click menu comes from `TileDragView.menu(for:)`, because that AppKit layer covers the tile and is what receives the click.
- A tile click is a press that ends without moving 4 pt, handled in `TileDragView.mouseUp` with the modifier keys read at mouse-down. Clicks on empty grid space reach a SwiftUI tap gesture instead, because the tile's AppKit layer takes every press on a tile.
- Drags out start in the AppKit `TileDragView`. `ShelfDragSource` belongs to the controller rather than a tile, so AppKit always has a live source to report to.
- Polka must not treat its own drags as incoming: `GlobalDragMonitor` ignores them (`beginOwnDrag`, `endOwnDrag`), and `DropTargetView` refuses any drag with a `draggingSource`, which AppKit only sets for drags from the same app.
- The shelf's content is built once and stays mounted at full size in every state: hidden (opacity 0, no hit testing) and clipped to the notch unless `.expanded`. Opening only reveals it, so the first frames never wait for views, icons or thumbnails to be made, and the tile a drag out started from still exists when the drag ends. Because tiles outlive a closed panel, each tile clears its hover state when the panel closes, and the grid scrolls back to the newest items on opening.
- Do no disk work as the panel opens. `prepareToOpen()` (remove expired items, refresh file references) runs when the hover delay starts and when an incoming drag starts, not when the drop zone finally opens.
- No mouse-moved events arrive during a drag, so check where the pointer is when one ends.
- Tracking areas need `.activeAlways`, since Polka is rarely the active app.
- Find the pointer's screen with `NSMouseInRect`, not `CGRect.contains`. The notch is at a screen's top edge, which `NSMouseInRect` counts as inside, so with a display placed above the MacBook the pointer resting on the notch still belongs to the built-in screen.
- After the panel collapses, it waits for the shrink animation to finish before it moves to another screen, so the animation doesn't end on the new one.

## Working style

- One branch per milestone step unless the user asks for something else for that milestone. `main` stays buildable. Tag each finished milestone (`m2`, ...).
- Don't commit or push until the user asks. They test first, then say when.
- Propose a short plan before writing code for each step, and wait for a go-ahead on anything large.
- After each change, explain what changed and how to test it. The user is a BSIT student and UI/UX designer, comfortable with concepts but still learning Swift and AppKit, so include short explanations of non-obvious AppKit behavior.
- Writing style: professional but human, no em-dashes.

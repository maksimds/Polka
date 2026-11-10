# Polka

Personal macOS menu bar app (Swift/SwiftUI + AppKit) that turns the MacBook notch into a hover-to-open shelf for files and links. Hover the notch to see stored items, drag files or links onto it to store them, drag items out into any app. Personal use, private repo.

`PolkaPRD.md` is the source of truth for goals, scope, requirements (FR-1 to FR-15), the data model, risks, and milestones. Read it before planning feature work.

## Settled decisions

- Dev machine: macOS 15.7.4, Xcode 16.3. Code is edited in VS Code; Xcode is for project settings and debugging.
- App deployment target: macOS 14.0. Swift 5 language mode. Bundle ID `com.maksimds.Polka`, personal team signing.
- Unsandboxed agent app (`LSUIElement = YES`, no Dock icon) with a `MenuBarExtra` Quit item.
- Storage is a plain JSON file for v1, not SwiftData.
- Hybrid storage: items reference the original by default, with an optional "keep a copy" for permanent items.
- Deleting an item never deletes the original file.
- New items are permanent by default. Temporary is opt-in per item.
- Items stay on the shelf after being dragged out.
- Drag out offers copy only, so a drop into Finder can never move the original.
- Dropping something already on the shelf adds nothing and shows a message inside the panel. The message only closes with its × button. While it is up, the panel collapses after the pointer has been away for 3 seconds, and the message is still there on the next hover.
- Link items fetch a preview in v1.
- The Xcode project uses synchronized folders: new files under `Polka/Polka/` join the target automatically. Don't hand-edit `project.pbxproj` unless necessary.
- `buildServer.json` and `.vscode/settings.json` are local-only and git-ignored.

## Layout

Layers follow the PRD. Keep them separated.

- `Polka/Polka.xcodeproj`
- `Polka/Polka/PolkaApp.swift`: app entry, `MenuBarExtra`, `@NSApplicationDelegateAdaptor`
- `Polka/Polka/App/`: `AppDelegate`, `Log` (os.Logger, one category per layer)
- `Polka/Polka/Window/`: `NotchGeometry` (notch rect, top-center fallback), `NotchPanel` (borderless non-activating `NSPanel`, all Spaces, never key), `NotchPanelController` (state machine, hover, layout, screen changes)
- `Polka/Polka/Input/`: `GlobalDragMonitor` (detects a drag starting anywhere via drag pasteboard `changeCount`, global mouse monitors, and a mouse-button poll for drag end)
- `Polka/Polka/DragDrop/`: `DropTargetView` (AppKit `NSDraggingDestination` wrapping the SwiftUI content), `DropReceiver` (reads URLs from the pasteboard), `ShelfDragSource` (`NSDraggingSource` owned by the panel controller), `TileDragView` (AppKit layer on each tile that starts drags and reports hover)
- `Polka/Polka/UI/`: `NotchView`, `NotchViewModel` (`NotchState`), `ShelfGridView`, `ShelfItemTile`, `ShelfItemImages` (icons and Quick Look thumbnails), `NoticeBanner`
- `Polka/Polka/Storage/`: `ShelfItem`, `ShelfStore`, `ShelfPersistence`. No AppKit or window dependencies, so it stays testable on its own.
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
- SwiftUI `Button` and tap gestures do work in the never-key panel. Only dragging needs AppKit.
- The panel is a fixed-size transparent window, and SwiftUI animates the shape inside it. `ignoresMouseEvents` is true only while the shape is notch-sized (`.collapsed` or `.draggingOut`), so clicks pass through. It also removes the window as a drop target, which is what lets a drag reach whatever is behind the panel.
- Inside drag callbacks, read the pasteboard right away but defer state changes by one run-loop tick. Changing state during the callback produces the system log "Reentrant message: kDragIPCCompleted ...".
- Drags out start in the AppKit `TileDragView`. `ShelfDragSource` belongs to the controller rather than a tile, so AppKit always has a live source to report to.
- Polka must not treat its own drags as incoming: `GlobalDragMonitor` ignores them (`beginOwnDrag`, `endOwnDrag`), and `DropTargetView` refuses any drag with a `draggingSource`, which AppKit only sets for drags from the same app.
- During `.draggingOut` the shape shrinks but the tiles stay mounted at full size with opacity 0, so the tile a drag started from still exists when the drag ends.
- No mouse-moved events arrive during a drag, so check where the pointer is when one ends.
- Tracking areas need `.activeAlways`, since Polka is rarely the active app.

## Working style

- One branch per milestone step unless the user asks for something else for that milestone. `main` stays buildable. Tag each finished milestone (`m2`, ...).
- Don't commit or push until the user asks. They test first, then say when.
- Propose a short plan before writing code for each step, and wait for a go-ahead on anything large.
- After each change, explain what changed and how to test it. The user is a BSIT student and UI/UX designer, comfortable with concepts but still learning Swift and AppKit, so include short explanations of non-obvious AppKit behavior.
- Writing style: professional but human, no em-dashes.

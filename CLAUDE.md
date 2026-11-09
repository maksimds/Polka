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
- The Xcode project uses synchronized folders: new files under `Polka/Polka/` join the target automatically. Don't hand-edit `project.pbxproj` unless necessary.
- `buildServer.json` and `.vscode/settings.json` are local-only and git-ignored.

## Layout

Layers follow the PRD. Keep them separated.

- `Polka/Polka.xcodeproj`
- `Polka/Polka/PolkaApp.swift`: app entry, `MenuBarExtra`, `@NSApplicationDelegateAdaptor`
- `Polka/Polka/App/`: `AppDelegate`, `Log` (os.Logger, one category per layer)
- `Polka/Polka/Window/`: `NotchGeometry` (notch rect, top-center fallback), `NotchPanel` (borderless non-activating `NSPanel`, all Spaces, never key), `NotchPanelController` (state machine, hover, layout, screen changes)
- `Polka/Polka/Input/`: `GlobalDragMonitor` (detects a drag starting anywhere via drag pasteboard `changeCount`, global mouse monitors, and a mouse-button poll for drag end)
- `Polka/Polka/DragDrop/`: `DropTargetView` (AppKit `NSDraggingDestination` wrapping the SwiftUI content), `DropReceiver` (reads URLs from the pasteboard)
- `Polka/Polka/UI/`: `NotchView`, `NotchViewModel` (`NotchState`)
- `Polka/Polka/Storage/`: item model, store, persistence. No AppKit or window dependencies, so it stays testable on its own.

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
- The panel is a fixed-size transparent window, and SwiftUI animates the shape inside it. `ignoresMouseEvents` is true only while collapsed, so clicks pass through.
- Inside drag callbacks, read the pasteboard right away but defer state changes by one run-loop tick. Changing state during the callback produces the system log "Reentrant message: kDragIPCCompleted ...".

## Working style

- One branch per milestone step (for example `m2-item-model`). `main` stays buildable. Tag each finished milestone (`m2`, ...).
- Propose a short plan before writing code for each step, and wait for a go-ahead on anything large.
- After each change, explain what changed and how to test it. The user is a BSIT student and UI/UX designer, comfortable with concepts but still learning Swift and AppKit, so include short explanations of non-obvious AppKit behavior.
- Writing style: professional but human, no em-dashes.

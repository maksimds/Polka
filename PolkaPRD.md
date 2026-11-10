# Polka: Product Requirements

Nov 7, 2026 · @Deonis

Polka is a personal macOS app that turns the MacBook notch into a hover-to-open shelf for files and links, where items can be dragged in to store and dragged out to any app.

## Problem and goals

Moving files and links between apps means digging through Finder windows, browser tabs and the Desktop. Polka gives that moment one fixed place at the top of the screen, always one hover away.

| ID | Goal | Target for v1 |
| --- | --- | --- |
| G1 | Reach any stored item fast | Hover, see and grab an item in about 2 seconds |
| G2 | Drag in from anywhere | Works from Finder, browsers and other apps with no setup |
| G3 | Drag out anywhere | Items drop into any app that accepts files or links |
| G4 | Keep or expire | Each item is permanent or temporary, my choice |
| G5 | Stay out of the way | No Dock icon, no focus stealing, no accidental opens |

This is a personal tool for one user (me) on one MacBook with a notch, kept in a private GitHub repo.

## Scope

v1 is a lean shelf for files and links. Everything else waits until the core feels right.

| Bucket | Items |
| --- | --- |
| In v1 | Hover to expand, drag in, drag out, files, folders, links with their site's name and icon, temporary and permanent items, delete, menu bar item, launch at login |
| Later | Plain text and image snippets, search, tags or groups, quick look preview, pin to top, keyboard shortcut to open |
| Out of scope | Cloud sync, iPhone companion, sharing with others, AirDrop, music or calendar widgets, App Store release |

## Functional requirements

P0 means v1 does not ship without it, P1 means v1 should have it, P2 means nice to have.

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-1 | A panel sits at the notch and expands when the pointer rests on it for a short delay | P0 |
| FR-2 | The expanded panel shows stored items as a grid with thumbnail or icon, name and type | P0 |
| FR-3 | Dragging an item out of the panel drops the real file or URL into the target app | P0 |
| FR-4 | Starting a drag anywhere on screen opens the panel as a drop target before the pointer reaches it | P0 |
| FR-5 | Dropping files or folders stores them as items | P0 |
| FR-6 | Dropping a URL stores it as a link item titled with the site's name and the page's address (for example GitHub/apple/swift) and shown with the site's icon | P0 |
| FR-7 | Each item is marked temporary (with expiry) or permanent, with a default and a one-click toggle | P0 |
| FR-8 | Items can be deleted individually; deleting never removes the original file | P0 |
| FR-9 | Clicking an item opens the file or link in its default app | P1 |
| FR-10 | Multi-select and drag several items out at once | P1 |
| FR-11 | The panel collapses when the pointer leaves, and never while a drag is active over it | P0 |
| FR-12 | The app runs as a menu bar agent with no Dock icon, a settings window and launch at login | P1 |
| FR-13 | Items persist across app restarts and reboots | P0 |
| FR-14 | The panel behaves correctly on non-notch displays by showing a top-center pill | P2 |
| FR-15 | Broken references (moved or deleted originals) are shown as unavailable, not silently dropped | P1 |

## Interaction flow

&#91;embedded content: notch states · 4 states, 6 transitions\]

Hovering the notch expands the panel, and starting a drag anywhere on screen opens it as a drop target. If a drag ends somewhere else, the panel returns to collapsed.

## Technical approach

Polka is a native Swift and SwiftUI app with AppKit underneath for window and drag behavior. It runs unsandboxed, which is fine for a personal tool and avoids file access friction with drag and drop.

| Layer | Responsibility | Key APIs |
| --- | --- | --- |
| Window | Borderless, non-activating panel pinned to the notch, visible on all Spaces | `NSPanel`, `collectionBehavior`, `NSScreen.safeAreaInsets`, `auxiliaryTopLeftArea` |
| Input | Hover detection and global drag detection | `NSTrackingArea`, global `NSEvent` monitor for dragged events, `NSPasteboard(name: .drag).changeCount` |
| Drag and drop | Panel as drop target and as drag source | `NSDraggingDestination`, `NSDraggingSource`, `NSItemProvider` |
| UI | Collapsed and expanded states, item grid, animation | SwiftUI, spring animations |
| Storage | Item model, persistence, expiry sweep | JSON file, `FileManager`, security-scoped bookmarks if needed |
| App shell | Menu bar item, settings, launch at login | `MenuBarExtra`, `SMAppService`, `LSUIElement` |

Key decisions:

- Build and sign with Xcode (free Apple ID is enough for personal use). Code can be edited in any editor.
- Study NotchDrop (MIT licensed) for window level, drop handling and notch geometry before writing the equivalents.
- Keep the panel code separate from the storage code so the shelf logic can be tested without any window.
- Target macOS 14.0 (Sonoma) or later. Development runs on macOS 15.7.4 with Xcode 16.3.
- Persist items in a plain JSON file for v1, not SwiftData.

## Data and storage

Every shelf entry is one item, stored locally in the app's support folder. Nothing leaves the Mac, except that adding a link asks that website for its name and icon.

| Field | Meaning |
| --- | --- |
| `id` | Unique identifier |
| `kind` | file, folder or link |
| `title` | Display name (file name or page title) |
| `source` | Bookmark or path for references, or URL for links |
| `storageMode` | reference (points at the original) or copy (a duplicate kept by Polka) |
| `original` | For a kept copy, the file it was made from, so the item can go back to it |
| `createdAt` | When the item was added |
| `expiresAt` | Empty for permanent items, otherwise the time the item is removed |
| `sortOrder` | Position in the grid |

Copy versus reference is a hybrid. Items default to reference, so no files are duplicated and the original stays the source of truth. An item's right-click menu offers to keep a copy, so it survives if the original moves. Files that an app hands over as a promise rather than a file on disk, such as a photo from Photos, a Mail attachment or an image from a browser, are stored as copies, since there is no original to point at. Deleting an item removes the entry and any Polka copy, never the original file.

New items are permanent unless the user makes them temporary. A temporary item lasts 24 hours by default, and that lifetime is a setting, not a hard-coded value. Temporary items are swept by a check at launch and on a timer.

## Risks and open questions

The two highest risks are window behavior and drag detection, so both are tested in the first milestone before any feature work.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Panel misbehaves across Spaces, full-screen apps or multiple displays | High | Spike first, then test against full-screen apps and an external display |
| Drag start is detected late or missed | High | Global dragged-event monitor plus drag pasteboard change count, modeled on NotchDrop |
| Browsers and apps put different types on the drag pasteboard (file URL, web URL, file promise) | Medium | Handle all three types, test with Finder, Safari and Chrome |
| Panel opens by accident while working near the menu bar | Medium | Hover delay and a tuned hit area, both adjustable in settings |
| References break when originals move or are deleted | Medium | Bookmarks, an unavailable state (FR-15), and the keep-a-copy option |
| A macOS update changes window or drag behavior | Medium | Keep window and input code isolated from storage and UI |

Open questions:

- [x] Should new items default to temporary or permanent, and what is the default lifetime? Permanent by default. An item made temporary lasts 24 hours unless the setting is changed.
- [x] Should the panel follow the pointer to an external display or stay on the notch display? It follows the pointer. A screen without a notch shows the top-center pill from FR-14.
- [x] Is fetching a link's page title in v1, or is the raw URL enough at first? In v1, a link shows its site's icon and is titled with the site's name and the page's address.

## Milestones

Work runs in five phases, with the riskiest assumptions tested first. Phases are ordered by dependency, not by date.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| M0 Setup | Xcode project, agent app, menu bar item, launch at login | App launches with no Dock icon and a working quit option |
| M1 Spike | Panel at the notch, hover expand and collapse, global drag detection, accept a dropped file and URL | Works over a full-screen app and on an external display. Drags from Finder, Safari and Chrome are all detected |
| M2 Shelf core | Item model, grid UI, drag out, delete | A file goes in and out again into Finder, Mail and a browser upload field |
| M3 Links and lifecycle | Link items, temporary and permanent items, expiry sweep, broken reference state, persistence | Items survive a restart and a reboot. Expired items disappear on schedule |
| M4 Polish | Settings, hover tuning, multi-select, animations, non-notch fallback | Used as the daily shelf for a week with no blocking issues |

A dated plan can be added once there is a target start date.

## Success criteria

v1 is done when I reach for Polka before the Desktop or a scratch note, and these checks hold:

- [ ] Dragging a file from Finder to the notch stores it, and dragging it back out drops the real file
- [ ] Dragging a link from a browser stores it, and dragging it out into another app drops the URL
- [ ] The panel opens reliably over full-screen apps and never steals focus
- [ ] Accidental expansion is rare enough that I do not turn the feature off
- [ ] Temporary items expire on schedule and permanent items persist across reboots
- [ ] Deleting an item never touches the original file

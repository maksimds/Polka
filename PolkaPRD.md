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
| G5 | Stay out of the way | No focus stealing, no accidental opens |

This is a personal tool for one user (me) on one MacBook with a notch, kept in a private GitHub repo.

## Scope

v1 is a lean shelf for files and links. Everything else waits until the core feels right.

| Bucket | Items |
| --- | --- |
| In v1 | Hover to expand, drag in, drag out, files, folders, links with their site's name and icon, text, pasting from the clipboard, screenshots straight to the shelf, temporary and permanent items, delete, open, Quick Look and Get Info, renaming a tile, converting a document to PDF, menu bar item, launch at login |
| Later | Search, tags or groups, pin to top, keyboard shortcut to open |
| Out of scope | Cloud sync, iPhone companion, sharing with others, AirDrop, music or calendar widgets, App Store release |

## Functional requirements

P0 means v1 does not ship without it, P1 means v1 should have it, P2 means nice to have.

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-1 | A panel sits at the notch and expands when the pointer rests on it for a short delay | P0 |
| FR-2 | The expanded panel shows stored items as a grid with thumbnail or icon, name and type | P0 |
| FR-3 | Dragging an item out of the panel drops the real file or URL into the target app | P0 |
| FR-4 | A drag from any app opens the panel as a drop target once it has lasted half a second, or as soon as it reaches the notch. A shorter drag elsewhere never opens it | P0 |
| FR-5 | Dropping files or folders stores them as items. They can also be chosen in the standard Open dialog from the panel's + menu | P0 |
| FR-6 | Dropping a URL stores it as a link item titled with the site's name and the page's address (for example GitHub/apple/swift) and shown with the site's icon. A link can also be typed into a field the shelf turns into, from the panel's + menu | P0 |
| FR-7 | Each item is marked temporary (with expiry) or permanent, with a default and a toggle in the item's right-click menu | P0 |
| FR-8 | Items can be deleted with a tile's delete button, or from its right-click menu, which also deletes a whole selection; deleting never removes the original file | P0 |
| FR-9 | Double-clicking an item opens the file in its default app or the link in the default browser | P1 |
| FR-10 | Multi-select, by clicking or by dragging a selection rectangle over free space as on the desktop, and drag several items out at once | P1 |
| FR-11 | The panel collapses when the pointer leaves, and never while a drag is active over it | P0 |
| FR-12 | The app has a menu bar item, a Dock icon, a settings window and launch at login | P1 |
| FR-13 | Items persist across app restarts and reboots | P0 |
| FR-14 | The panel behaves correctly on non-notch displays by showing a top-center pill | P2 |
| FR-15 | Broken references (moved or deleted originals) are shown as unavailable, not silently dropped | P1 |
| FR-16 | A file's right-click menu offers Quick Look and Get Info, which work as they do in Finder | P2 |
| FR-17 | Any tile can be renamed from its right-click menu, in place as in Finder, to give it a shorter or clearer name. Only the tile's label changes, never the file's name, its path or the link's address, and clearing the name brings back the automatic one | P2 |
| FR-18 | A document's right-click menu (docx, doc, rtf, rtfd, odt, txt) converts it to PDF, or every document in the selection. The PDF is saved next to the document under a free name and added to the shelf right after it; the document is never changed | P2 |
| FR-19 | The panel's + menu has a Paste item, named after what's on the clipboard, that stores copied files, a picture, a link or plain text. Text becomes a text tile, which can also be dropped in, and drags out as text | P1 |
| FR-20 | A Settings switch saves new screenshots and screen recordings to the shelf instead of the Desktop, as temporary items that go to the Trash when they expire or are removed. Turning it off puts back where they went before | P1 |
| FR-21 | Any tile can be pinned from its right-click menu. Pinned tiles have the first row to themselves in every sort, marked with a pin, at most five of them; pinning a sixth says why it can't | P2 |
| FR-22 | A Settings slider makes the open panel see-through glass, from solid black to a blurred view of what's behind it, like Finder's sidebar. The closed notch stays solid, and so does everything with Reduce Transparency on | P2 |

## Interaction flow

&#91;embedded content: notch states · 4 states, 6 transitions\]

Hovering the notch expands the panel. A drag from any app opens it as a drop target once the drag has lasted half a second, or right away if it reaches the notch, so quick drags elsewhere don't flash the panel open. If a drag ends somewhere else, the panel returns to collapsed.

The expanded panel's + menu adds things without dragging. "Link" turns the shelf into a field for typing a link, and back into the shelf once it's added. The field takes the keyboard while it's open, without making Polka the active app. "File" opens the standard Open dialog. "Paste" stores what's on the clipboard, and says what that is ("Paste 3 Files", "Paste Image"). It's a menu item rather than Cmd-V, because the panel never takes the keyboard from the app you're in.

## Technical approach

Polka is a native Swift and SwiftUI app with AppKit underneath for window and drag behavior. It runs unsandboxed, which is fine for a personal tool and avoids file access friction with drag and drop.

| Layer | Responsibility | Key APIs |
| --- | --- | --- |
| Window | Borderless, non-activating panel pinned to the notch, visible on all Spaces | `NSPanel`, `collectionBehavior`, `NSScreen.safeAreaInsets`, `auxiliaryTopLeftArea` |
| Input | Hover detection and global drag detection | `NSTrackingArea`, global `NSEvent` monitor for dragged events, `NSPasteboard(name: .drag).changeCount` |
| Drag and drop | Panel as drop target and as drag source | `NSDraggingDestination`, `NSDraggingSource`, `NSItemProvider` |
| UI | Collapsed and expanded states, item grid, animation | SwiftUI, spring animations, Metal for the dust a removed tile turns into |
| Storage | Item model, persistence, expiry sweep | JSON file, `FileManager`, security-scoped bookmarks if needed |
| App shell | Menu bar item, Dock icon, settings, launch at login | `MenuBarExtra`, `SMAppService` |

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
| `kind` | file, folder, link or text |
| `title` | Automatic name (file name, the site's name and the page's address, or a text's first line) |
| `customName` | Empty unless the tile was renamed, otherwise the name shown instead of `title` |
| `source` | Bookmark or path for references, URL for links, or the text itself |
| `origin` | Empty, or screenshot for one saved by macOS while screenshots go to the shelf |
| `storageMode` | reference (points at the original) or copy (a duplicate kept by Polka) |
| `original` | For a kept copy, the file it was made from, so the item can go back to it |
| `createdAt` | When the item was added |
| `expiresAt` | Empty for permanent items, otherwise the time the item is removed |
| `sortOrder` | Position in the grid |
| `pinned` | Empty unless the item is pinned to the first row |

Copy versus reference is a hybrid. Items default to reference, so no files are duplicated and the original stays the source of truth. An item's right-click menu offers to keep a copy, so it survives if the original moves. Files that an app hands over as a promise rather than a file on disk, such as a photo from Photos, a Mail attachment or an image from a browser, are stored as copies, since there is no original to point at. So are pictures pasted from the clipboard, and screenshots. Deleting an item removes the entry and any Polka copy, never the original file. A screenshot's file goes to the Trash instead of being deleted, so one that turns out to be needed can still be found.

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
| Quick Look's converter, reached through Apple's `qlmanage` test tool, changes or goes away, so converted Word files lose their pictures | Low | Fall back to Apple's own reader, which keeps the text; a unit test converts a sample Word file with a picture and fails if the picture is lost |

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

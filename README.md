# Write

![Write — a translucent terminal-styled markdown editor for macOS](docs/write.png)

A markdown editor ... but with vibes

## Build & install

```
make run       # build, bundle, and launch dist/Write.app
make install   # copy to /Applications
make test      # headless editing-behavior tests
```

Requires only Xcode Command Line Tools (`swift` + `make`). The bundle picks
up `Support/AppIcon.icns` automatically, so a fresh clone builds with the
app icon in place.

## Editing

- Click anywhere to place the cursor, like Word or Pages.
- Obsidian-style live preview: markdown renders in place and syntax markers
  (`#`, `**`, backticks, link URLs) are hidden except on the paragraph the
  cursor is on, where they reappear dimmed for editing.
- Windows and tabs: ⌘N opens a window, ⌘T a tab; ⌘W or the hover × closes a
  tab, ⇧⌘W the window; ⌘⇧] / ⌘⇧[ or ⌃⇥ cycle tabs. Drag a tab out of the bar
  to detach it into its own window. Each tab keeps its own undo history and
  autosave; the session (windows, tabs, frames) restores on relaunch.
- Bullet / numbered / task lists and quotes continue on Enter; Enter on an
  empty item exits the list. Tab / Shift-Tab indent and outdent list items.
- Type `/` at the start of a line for the slash command menu.
- Typing at the end of a bold/italic/code/colored span continues the style,
  Word-style: the caret may sit past the concealed closing marker, but new
  characters land inside it. Typing a space exits the span.
- Documents autosave 0.8s after you stop typing (once a file has a path).
- Crash recovery: every edited buffer — including untitled ones — is mirrored
  to `~/Library/Application Support/Write/Recovery/` as you type. If the app
  crashes, is force-quit, or you just quit (⌘Q, which never prompts), your
  drafts reappear on the next launch. Closing a tab or window still asks
  before discarding an unsaved untitled buffer.
- `Write.app/Contents/MacOS/Write a.md b.md` opens each file in a tab.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘B / ⌘I / ⌘E | bold / italic / inline code (wraps selection or word at caret) |
| ⌘K | insert link |
| ⌘1–⌘6, ⌘0 | set / clear heading level |
| ⌘= / ⌘− | bigger / smaller text |
| ⌘N ⌘T ⌘O ⌘S ⇧⌘S | new window / new tab / open / save / save as |
| ⌘W / ⇧⌘W | close tab / close window |
| ⌘F | find |

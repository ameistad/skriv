<img src="logo.svg" alt="Skriv logo" width="80" height="80">

# Skriv

A fast, lightweight macOS scratchpad with native text editing and a focused Vim subset.
Built with Swift and AppKit, with no external dependencies.

- Opens focused, maximized notes with a configurable global shortcut.
- Centers writing in a responsive 72-character column, with word wrapping by default.
- Dark by default, with Etterglød colors and optional Neovim settings import.
- Vim motions, Visual selection, literal search, and native Find/Replace.
- UTF-8 files, native undo, and explicit save/discard controls.

## Build and run

Requires macOS 14+ and Swift 6. Building the app icon requires Xcode or Command Line Tools.

```sh
./scripts/build-app.sh release
open build/Skriv.app
```

The local build is ad-hoc signed. Save open notes and quit an older build before relaunching.

## Basics

`⌘N` creates a note, `⌘S` saves, and `⌘F` finds text.
`Esc` enters Normal mode; `i` resumes typing. The default global shortcut is `⌃⌥⌘N`.

Run tests with `swift test`.

[Usage](docs/USAGE.md) · [Performance](docs/PERFORMANCE.md) · [Distribution](docs/DISTRIBUTION.md)

## License

Code is licensed under [MIT](LICENSE). See [third-party notices](Resources/ThirdPartyNotices.txt)
for bundled artwork and theme attribution.

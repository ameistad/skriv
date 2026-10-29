<img src="logo.svg" alt="Skriv logo" width="80" height="80">

# Skriv

A fast, lightweight macOS text editor with native editing and a focused Vim subset.
Built with Swift and AppKit, with no external dependencies.

- Native document tabs, with separate windows and a remembered window size and position.
- Left-aligns writing in a responsive column capped at 72 characters, with word wrapping by default.
- Dark by default, with Etterglød colors and a simple `~/.config/skriv/config.skriv` configuration file.
- Vim motions, Visual selection, literal search, and native Find/Replace.
- UTF-8 files, native undo, and explicit save/discard controls.
- Lightweight, color-only Markdown highlighting for `.md` and `.markdown` files.

## Build and run

Requires macOS 14+ and Swift 6. Building the app icon requires Xcode or Command Line Tools.

```sh
./scripts/build-app.sh release
open build/Skriv.app
```

The local build is ad-hoc signed. Save open documents and quit an older build before relaunching.
The build script defaults to release; use `./scripts/build-app.sh debug` for an unoptimized development build.

Install the terminal launcher once (no administrator access needed):

```sh
./build/Skriv.app/Contents/Resources/bin/skriv --install
skriv README.md
skriv "notes with spaces.txt" another-file.txt
```

The installer links `skriv` into `~/.local/bin`; add that directory to your `PATH`
if needed. `skriv` alone launches or focuses the app. File arguments open existing
UTF-8 files as tabs, reusing already-open documents. See [CLI usage](docs/USAGE.md#command-line)
for installation in another directory and supported options.

## Basics

`⌘T` or `⌘N` creates a tab, `⌘W` closes it, and `⇧⌘N` creates a separate window.
`Ctrl-Tab` / `Ctrl-Shift-Tab` switch tabs in visible order. `⌘1`–`⌘9` select the corresponding
tab, with shortcut hints beside the tab titles. `⌘S` saves and `⌘F` finds text.
Documents start in Normal mode; `i` starts typing and `Esc` returns to Normal mode.
When line numbers are enabled, the active line number is bold.
In Normal mode, `:w` saves, `:q` closes, and `:wq` saves and closes (press Return to run).
`:q` protects unsaved changes; `:q!` discards them. `:x` saves only if changed, then closes.
Use an external launcher such as Alfred or Raycast to assign a global shortcut to Skriv.

Use `⌘,` to open the configuration and `⇧⌘,` to reload it after saving.
The file uses `key = value` lines; see the [configuration reference](docs/USAGE.md#configuration).

Run editor tests with `swift test` and launcher tests with `python3 scripts/test-cli.py`.

[Usage](docs/USAGE.md) · [Performance](docs/PERFORMANCE.md) · [Distribution](docs/DISTRIBUTION.md)

## License

Code is licensed under [MIT](LICENSE). See [third-party notices](Resources/ThirdPartyNotices.txt)
for bundled artwork and theme attribution.

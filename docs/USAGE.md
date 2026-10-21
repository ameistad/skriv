<img src="../logo.svg" alt="Skriv logo" width="80" height="80">

# Skriv

A fast, lightweight macOS text editor with native editing and a focused Vim subset.
Swift, AppKit, and system frameworks only; no external runtime or package dependencies.

## Run locally

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./scripts/build-app.sh release
open build/Skriv.app
```

The script creates an ad-hoc signed local app. Distribution signing and
notarization are described in [docs/DISTRIBUTION.md](DISTRIBUTION.md).
Save or discard existing documents and quit an older running build before launching
a replacement; rebuilding the executable does not update a running process.

The editable logo is [logo.svg](../logo.svg). The build script renders it into a
macOS app icon at standard and Retina sizes, with transparent Dock padding.
To regenerate just the icon, run `swift scripts/generate-icon.swift`; the icon
and PNG previews are written to `build/Skriv.icns` and `build/Skriv.iconset/`.
The source mark is from [Streamline](https://streamlinehq.com).

## Documents and invocation

- Documents remember the most recently moved, resized, or closed window's size and
  position, including across app launches. Without a saved layout, a document opens
  maximized on the display containing the pointer. Full-screen transitions preserve
  the regular window layout. Documents open focused and ready to type in **INSERT**
  mode. The mode is shown at the bottom.
- Dark appearance and the built-in Etterglød (`etterglod.nvim`) plain-text
  palette are the defaults, independently of macOS appearance.
- Writing uses a centered column approximately 72 characters wide in the current
  font, shrinking to fit smaller windows with at least 24 points of side padding.
  Built-in settings wrap at word boundaries. Wrapping changes only presentation,
  never the saved text. Configure `writing-width`, `wrap`, and `word-wrap` in
  `config.skriv`; disabling wrapping restores horizontal scrolling.
- Documents use native macOS tabs. The tab bar appears when a window has multiple
  documents and hides again when only one remains.
  `⌘T`, `⌘N`, and the tab bar's **+** create and focus an untitled tab immediately
  after the active tab. `⇧⌘N` creates a separate window.
- `Ctrl-Tab` / `Ctrl-Shift-Tab` switch tabs in visible order, wrapping at either end.
  Each document retains its text, undo, selection, scroll position, Vim mode, and
  search state. Drag tabs to reorder or detach them; **Window → Move Tab to New
  Window** and **Merge All Windows** also manage native tab groups.
- `⌘O` and Finder open UTF-8 files as tabs in the active document window, or create
  a window if none is open. Opening an already-open file selects its existing tab
  in its original window, preserving unsaved changes. `⌘S` saves; `⇧⌘S` saves under
  a new name. Unsupported encodings produce an error rather than replacing text.
- `⌘W` and a tab’s close button close that document, protecting unsaved changes with a native prompt.
  Edited documents offer **Save**, **Cancel**, and **Don’t Save** (`⌘D`). The save panel
  appears only after choosing Save; Don’t Save never deletes an existing file.
  **File → Discard Changes…** discards changes after confirmation; it never deletes
  a previously saved file. `⌘Q` prompts for unsaved documents before quitting.
- The app remains resident after all documents close. Reopening it from the Dock or
  a launcher creates a document when no windows are visible; otherwise it brings
  existing documents forward. Closing the last tab closes its window; no empty
  replacement document is created. Tabs are session-only: Skriv does not save a tab
  list or unsaved buffers for restoration after quitting.
- Global shortcuts belong to your launcher, such as Alfred or Raycast. Skriv does
  not register system-wide shortcuts. Launch-at-login is not configured.
- When line numbers are enabled, the active logical line number is **bold**.
  This applies to absolute, relative, and combined numbering; relative-only mode
  shows a bold `0`. In Vim Visual modes, emphasis follows the moving endpoint,
  including when `o` switches ends. Native selections use their starting line.


## Vim subset

`Esc` enters **NORMAL**; `i` resumes native typing. Native Command shortcuts,
clipboard operations, and marked-text input remain available. Vim commands work
on whole extended graphemes, including Norwegian letters, combining characters,
and joined emoji.

| Action | Keys |
| --- | --- |
| Character / line motion | `h j k l`, arrow keys |
| Word / whitespace-separated WORD motion | `w b e`, `W B E` |
| Line positions | `0 ^ $` |
| First / last / numbered line | `gg`, `G`, `12gg`, `12G` |
| Enter Insert mode | `i a I A` |
| Open line below / above | `o O` |
| Delete / change / yank with a motion | `d`, `c`, `y` followed by a supported motion |
| Whole lines | `dd cc yy`, `Y` |
| Delete characters / through end of line | `x X`, `D C` |
| Paste after / before | `p P` |
| Undo / redo | `u`, `Ctrl-R`; native `⌘Z` / `⇧⌘Z` |
| Counts | `3w`, `2dd`, `d2w`, `2d3w`, `3p` |
| Literal search forward / backward | `/`, `?`, then text and Return |
| Repeat search / reverse direction | `n`, `N`, with optional counts |
| Save / close / save and close | `:w`, `:q`, `:wq`, then Return |
| Save if changed and close / discard and close | `:x`, `:q!`, then Return |
| Character / whole-line Visual selection | `v`, `V`, then supported motions |
| Switch active selection endpoint | `o` in Visual mode |
| Yank / delete / change selection | `y`, `d` or `x`, `c` in Visual mode |

Yank/delete/change share the native clipboard. Linewise clipboard metadata is
preserved between Skriv documents; text copied from another app pastes characterwise.
**Edit → Shift Right / Shift Left** (`⌘]` / `⌘[`) use the configured
`indent-width`. `Tab` follows `expand-tabs` and `tab-width` using native font geometry.

Visual selections include whole graphemes and line separators. `v`/`V` switch
selection type; repeating the current type or pressing `Esc` returns to Normal.
`c` removes the selection and enters Insert mode. A mouse click or native Find
leaves Visual mode.

This is not full Vim: block Visual mode, Visual paste, search within Visual mode,
search as an operator motion, regular expressions, general Ex commands, text objects,
macros, named registers, dot-repeat, insert repetition, `>>`/`<<`, and counted undo are
not implemented. Unsupported Normal-mode keys cancel pending commands without
inserting text. Undo uses native AppKit groups, so a change operator and later
inserted text may undo separately. `G`/`gg` and line deletion use first-nonblank
positioning (Vim `startofline` behavior); vertical motions count graphemes, not
terminal display cells. Native input methods get first refusal while composing.

### Save and close commands

In Normal mode, `:` opens the command field. Return runs the command; Escape or
Cancel returns to the editor. Commands apply to the current document:

| Command | Behavior |
| --- | --- |
| `:w`, `:write` | Save using the native save flow; an untitled document opens the Save panel. |
| `:q`, `:quit` | Close if there are no unsaved changes; otherwise show a message and keep the document open. |
| `:q!`, `:quit!` | Discard unsaved changes and close. An existing file is left unchanged. |
| `:wq` | Save, then close only after a successful save. |
| `:x`, `:xit`, `:exit` | Save if changed, then close; an unchanged document closes without writing. |

Cancelled or failed saves leave the document open. Closing the last document leaves
Skriv running, like `⌘W`; `⌘Q` quits the app. Filename arguments, ranges, counts,
command chains, shell commands, and other Ex commands are not supported. Unsupported
input shows a status message without saving, closing, or editing document text.
Command entry is supported in Normal mode, outside pending operators or counts.

## Find and replace

**Edit → Find** provides the native macOS Find bar (`⌘F`), Find and Replace
(`⇧⌘F`), next/previous match (`⌘G` / `⇧⌘G`), and Use Selection for Find (`⌘E`).
Replacement edits use the document's native undo history.

In Normal mode, `/` and `?` open a compact search field. Return searches;
Escape or Cancel returns to the document without changing the search. Vim searches
are case-sensitive literal text, preserve whole graphemes, and wrap with a
status message. Empty input reuses the last query; `n` follows its original
direction and `N` reverses it. Counts such as `3/` and `2n` select later matches.
No match leaves the caret unchanged. Each document keeps its own Vim query and
direction in memory; the native Find bar uses AppKit's separate search state.

## Configuration

Skriv reads **`~/.config/skriv/config.skriv`** at startup. This is the sole
preference store. The path is fixed; Skriv does
not search XDG overrides, project directories, or Application Support for config.
No file is required: missing settings use the built-in defaults.

**Skriv → Open Configuration…** (`⌘,`) creates a commented template if needed
and opens it as a plain-text tab in Skriv. Reopening it selects its existing tab.
Existing files and comments are never
rewritten. Save with `⌘S`, then choose **Skriv → Reload Configuration** (`⇧⌘,`).
Reload reads the saved file, applies settings to existing and future documents, and
preserves document text, selections, undo history, and edited status.

The syntax is a small, non-executable `key = value` format inspired by Ghostty:

```ini
# Comments occupy their own line.
font-family = Menlo
font-size = 18
writing-width = 80
line-numbers = both
expand-tabs = true
tab-width = 4
keybind = H=h
keybind = L=l
```

- Keys are case-sensitive. Whitespace around `=` is ignored; blank lines are ignored.
- Values may be enclosed in double quotes, such as `font-family = "SF Mono"`.
  Quotes enclose literal text; there are no escape sequences, interpolation, scripts,
  sections, or include directives. Inline comments are not supported.
- Repeated scalar settings use the last value. An empty value restores the default.
- Repeated `keybind` entries add mappings; the last entry for a source key wins.
  An empty `keybind =` clears preceding mappings.
- Colors are six hexadecimal RGB digits, optionally prefixed with `#`.
- Unknown keys, malformed values, invalid UTF-8, and files larger than 64 KiB are
  errors. Parse errors identify the line. A failed reload keeps the entire last
  working configuration. Startup errors report the problem and use built-in settings.
- Removing the file and reloading restores defaults. Opening a new document does not
  read the file again. No polling, interpreter, or external process is involved.

| Key | Default | Meaning / allowed values |
| --- | --- | --- |
| `font-family` | `monospace` | Installed font family or PostScript name; unavailable fonts fall back to system monospace |
| `font-size` | `16` | Points, 6–72; fractional sizes allowed |
| `writing-width` | `72` | Centered column width in font character advances, 20–500; shrinks to fit the window |
| `wrap` | `true` | Wrap presentation; `false` enables horizontal scrolling |
| `word-wrap` | `true` | Break wrapping at word boundaries; `false` allows character boundaries |
| `line-numbers` | `none` | `none`, `absolute`, `relative`, or `both` |
| `tab-width` | `8` | Tab width, 1–9999 |
| `indent-width` | `0` | Indentation width, 0–9999; zero follows `tab-width` |
| `expand-tabs` | `false` | Insert spaces for Tab and indentation |
| `background` | `1e1e1e` | Editor background |
| `foreground` | `c5c8c6` | Editor foreground |
| `cursor-color` | `c07020` | Caret color |
| `selection-background` | `676b71` | Selected-text background |
| `selection-foreground` | Editor foreground | Selected-text foreground |
| `line-number-foreground` | System secondary label color | Gutter text |
| `line-number-background` | Editor background | Gutter background |
| `keybind` | No remaps | `source=target`; one printable non-whitespace, non-digit source key (excluding `=`) and a supported single-key Normal command |

Remaps are applied once, only in Normal mode outside an operator-pending command.
They do not affect Insert or Visual mode, native Command shortcuts, or count keys.
Targets are `h j k l w b e W B E 0 $ ^ i a I A o O x X p P u D C Y G d c y v V n N / ? :`.
Key sequences, callbacks, and plugin commands are not supported.
The `global-shortcut` setting has been removed. Delete or comment out any existing
entry, including `none` or an empty value, then save and reload. An uncommented
entry is an unknown-setting error; existing configuration files are never rewritten.

The previous Neovim import feature has been removed. Old imported JSON and
`globalShortcut.v1` UserDefaults values are ignored and left untouched; preferences
are now set explicitly in `config.skriv`. Theme attribution remains in the bundled
third-party notices. Configuration ownership is recorded in [DATA-MODEL.md](../DATA-MODEL.md).

## Implementation phases

1. **Native lifecycle — implemented:** maximized focused documents, native text and
   undo, UTF-8 save/open, explicit discard, close/quit protection, resident reopen.
2. **Vim editing — implemented for the documented subset:** independent command
   engine, grapheme-safe motions/operators/counts, native clipboard and undo.
3. **Configuration — implemented:** Skriv-owned `config.skriv`, validated file
   reloads, live presentation updates, and Normal remaps.
4. **Invocation and performance — implemented:** standard app reopening,
   pointer-display placement, disabled window animations, opt-in cold/warm
   measurements, memory/size benchmarks, and distribution instructions. External
   presentation timing, VoiceOver/multiple-display checks, and
   Developer ID signing/notarization remain release acceptance checks.
5. **Everyday editing — implemented:** native Find/Replace, per-document literal
   Vim search with counts and wrapping, and character/line Visual selection,
   motions, endpoint switching, yank/delete/change and native undo.
6. **Performance — implemented:** reusable Unicode motion and search indexes,
   fewer window-construction operations, release symbol stripping, opt-in
   opening-stage timings, and repeatable alternating-build and editing benchmarks.

## Speed and lightweight design

Fast startup and a small resource footprint guide every phase.

- Target warm input readiness below 100 ms, including p95; measure cold startup
  separately. Distinguish first-responder readiness, application drawing, and
  actual screen presentation.
- Keep idle operation free of polling, background services, network requests,
  or subprocesses. Configuration is read only at startup or explicit reload.
- Prefer system frameworks and justify any added dependency's startup, memory,
  and bundle-size costs. Retain a bundled default palette and in-memory resolved settings.
- Track release app size, memory with no windows and a representative document, and
  repeated-open memory behavior alongside launch latency.

See [docs/PERFORMANCE.md](PERFORMANCE.md) for measured baselines, exact timing
boundaries, hardware, and reproduction. Normal/Visual commands reuse one
grapheme index while the exact text is unchanged; repeated search reuses one
match index. Indexes are built on demand and discarded on native edits; entering
Insert also releases the motion index. The first command after a change still
indexes text proportional to document size, and line numbers rebuild after edits.
Large-file editing performance has not been established; the measurements below
do not guarantee responsiveness for multi-megabyte documents.

The phase 6 alternating-build check measured warm opening at **14.3 ms median /
22.4 ms p95**, versus 15.2 / 23.7 ms before. Repeated engine motions on a
1,000-line Unicode document fell from 1.575 ms to 0.004 ms median; these engine-only
timings exclude AppKit drawing. Cold-start improvement was not established.

## Engine decision

The time-boxed `libvim.swift` investigation used commit
`7780ae5f437fa4654b1aafa50e070a4d0533e627` and Swift 6.3.3. An unmodified release
test initially failed because `fixes.h` was missing from the header search path.
Adding `Sources/clibvim/include/auto` to that path made all **319 upstream tests
pass**. A targeted `x` test on `👩🏽‍💻` then left `🏽‍💻`, violating Skriv's
whole-grapheme editing requirement.

Skriv therefore implements the agreed subset in Swift. `NSTextStorage` stays the
single live text owner and AppKit owns undo and composition. This avoids a
second synchronized Vim buffer and a C runtime dependency at the cost of a
smaller command set. Skriv does not embed or launch an external editor runtime.

## Verification

```sh
swift test
# Optional developer-only comparison against a clean Neovim installation:
# This checks Vim editing behavior; Neovim is not an app or build dependency.
python3 scripts/check-vim-conformance.py
# Build release immediately before performance measurements:
./scripts/build-app.sh release
python3 scripts/benchmark.py --runs 10 --warm 20
# CPU-only Unicode editing benchmark (no windows):
python3 scripts/benchmark-editing.py --output build/benchmarks/editing.json
# Preserve a release app before changing code, then alternate it with the new build:
python3 scripts/compare-launch.py --before /path/to/previous/Skriv.app --pairs 5 --warm 20
```

Tests cover Unicode/UTF-8, command boundaries and counts, clipboard metadata,
native editing/undo/composition, presentation-only refreshes, indentation,
configuration parsing, file ownership, failed-reload preservation, rejection of
the removed global-shortcut setting, active line-number emphasis, failed saves, and
growing/clearing a numbered 1,000-line document, literal search and wrapping, and
Visual Unicode selections and line-boundary editing, exact-byte cache invalidation,
and window sizing. The earlier conformance run
reported **2,158 cases and zero differences**, including Visual edits, within
its documented scope.

Save/close command coverage adds parser rejection, prompt submit/cancel and search
switching, unsaved-change protection, asynchronous save outcomes, real UTF-8
`:w`/`:wq` saves, and forced close preserving files and other documents.
The suite now passes **78 tests**.

The earlier 2026-10-21 revision passed **69 tests**, including an Address Sanitizer run,
and built with `./scripts/build-app.sh release`. An isolated release-app smoke check
verified the document menu labels and accessibility label, UTF-8 saving, close/cancel
and discard prompts, reopening with and without visible windows, live configuration
reload, and rejection of `global-shortcut` while keeping the previous settings active.
Visual checks confirmed bold absolute line numbers, Visual endpoint reversal, and
bold `0` in relative mode. The test fixtures install Skriv's document controller
before creating documents, matching app startup and avoiding AppKit's base singleton.

The configuration UI smoke check verified Open Configuration, saving without
renaming `.skriv` to `.txt`, live reload of line numbers, restoration of defaults,
and removal of the import menus.

Earlier UI smoke checks verified focused launch, Norwegian/emoji editing,
native save, close/cancel/discard and quit prompts, mode changes, delete/undo/redo,
line-number rendering, native Find/Replace and undo, Vim Unicode
search/Return/Escape/wrap, and character/line Visual selection.
Multi-display/Spaces, VoiceOver, older supported macOS
versions, and downloaded-app Gatekeeper behavior still require manual checks.

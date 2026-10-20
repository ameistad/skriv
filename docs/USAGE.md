<img src="../logo.svg" alt="Skriv logo" width="80" height="80">

# Skriv

A small native macOS scratchpad for quick notes and a deliberate subset of Vim.
Swift, AppKit, and system frameworks only; no bundled Neovim or package dependencies.

## Run locally

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./scripts/build-app.sh release
open build/Skriv.app
```

The script creates an ad-hoc signed local app. Distribution signing and
notarization are described in [docs/DISTRIBUTION.md](DISTRIBUTION.md).
Save or discard existing notes and quit an older running build before launching
a replacement; rebuilding the executable does not update a running process.

The editable logo is [logo.svg](../logo.svg). The build script renders it into a
macOS app icon at standard and Retina sizes, with transparent Dock padding.
To regenerate just the icon, run `swift scripts/generate-icon.swift`; the icon
and PNG previews are written to `build/Skriv.icns` and `build/Skriv.iconset/`.
The source mark is from [Streamline](https://streamlinehq.com).

## Notes and invocation

- A fresh note opens maximized on the display containing the pointer, focused
  and ready to type in **INSERT** mode. The mode is shown at the bottom.
- Dark appearance and the built-in Etterglød (`etterglod.nvim`) plain-text
  palette are the defaults, independently of macOS appearance or a Neovim install.
- Writing uses a centered column approximately 72 characters wide in the current
  font, shrinking to fit smaller windows with at least 24 points of side padding.
  Built-in settings wrap at word boundaries. Wrapping changes only presentation,
  never the saved text. Imported `wrap` / `linebreak` settings are respected;
  disabling wrapping restores horizontal scrolling. Writing width is currently
  a built-in default, not a user preference.
- `⌘N` creates a note; `⌘O` opens UTF-8 text; `⌘S` saves; `⇧⌘S` saves under a
  new name. Unsupported encodings produce an error rather than replacing text.
- `⌘W` closes, protecting unsaved changes with a native prompt.
  Edited notes offer **Save**, **Cancel**, and **Don’t Save** (`⌘D`). The save panel
  appears only after choosing Save; Don’t Save never deletes an existing file.
  **File → Discard Note…** discards changes after confirmation; it never deletes
  a previously saved file. `⌘Q` prompts for unsaved notes before quitting.
- The app remains resident after all notes close. The Dock icon reopens a fresh note.
- **Control–Option–Command–N** opens a fresh note from any app while Skriv is
  running. Set or disable it in **Skriv → Global Shortcut…** (`⌘,`). Registration
  conflicts preserve the previous working shortcut and show an error. Key names
  refer to physical US keyboard positions. No Accessibility permission is needed
  for registration. Launch-at-login is not configured.

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
| Character / whole-line Visual selection | `v`, `V`, then supported motions |
| Switch active selection endpoint | `o` in Visual mode |
| Yank / delete / change selection | `y`, `d` or `x`, `c` in Visual mode |

Yank/delete/change share the native clipboard. Linewise clipboard metadata is
preserved between Skriv notes; text copied from another app pastes characterwise.
**Edit → Shift Right / Shift Left** (`⌘]` / `⌘[`) use the imported indentation
width. `Tab` follows `expandtab` and tab width using native font geometry.

Visual selections include whole graphemes and line separators. `v`/`V` switch
selection type; repeating the current type or pressing `Esc` returns to Normal.
`c` removes the selection and enters Insert mode. A mouse click or native Find
leaves Visual mode.

This is not full Vim: block Visual mode, Visual paste, search within Visual mode,
search as an operator motion, regular expressions, Ex commands, text objects,
macros, named registers, dot-repeat, insert repetition, `>>`/`<<`, and counted undo are
not implemented. Unsupported Normal-mode keys cancel pending commands without
inserting text. Undo uses native AppKit groups, so a change operator and later
inserted text may undo separately. `G`/`gg` and line deletion use first-nonblank
positioning (Vim `startofline` behavior); vertical motions count graphemes, not
terminal display cells. Native input methods get first refusal while composing.

## Find and replace

**Edit → Find** provides the native macOS Find bar (`⌘F`), Find and Replace
(`⇧⌘F`), next/previous match (`⌘G` / `⇧⌘G`), and Use Selection for Find (`⌘E`).
Replacement edits use the document's native undo history.

In Normal mode, `/` and `?` open a compact search field. Return searches;
Escape or Cancel returns to the note without changing the search. Vim searches
are case-sensitive literal text, preserve whole graphemes, and wrap with a
status message. Empty input reuses the last query; `n` follows its original
direction and `N` reverses it. Counts such as `3/` and `2n` select later matches.
No match leaves the caret unchanged. Each note keeps its own Vim query and
direction in memory; the native Find bar uses AppKit's separate search state.

## Neovim settings

Use **Skriv → Import / Refresh Neovim Settings…** to run the installed Neovim
with your current configuration and cache its resolved settings. Extraction runs
asynchronously with a 15-second timeout and bounded output. It inherits profile
environment variables such as `NVIM_APPNAME` / `NVIM_PROFILE` when present.
The import may execute the plugins and hooks in that configuration; Skriv itself
does not host them.

Applied settings:

- `Normal`, `Visual`, `Cursor`, and `LineNr` foreground/background colors where
  applicable to a plain-text editor; missing colors fall back to Etterglød.
- `number` and `relativenumber`, wrapping and word-boundary `linebreak`.
- `tabstop`, `expandtab`, and `shiftwidth` (zero uses tabstop).
- A supported installed `guifont` in `Family:hSIZE` form, with comma-separated
  fallbacks. Empty or unsupported fonts keep the native monospace default;
  unsupported fonts are reported. VimR-only font preferences are separate.
- Nonrecursive single-character Normal-mode remaps to supported single-key
  commands. Count keys, conflicting prefixes, operator-pending remaps,
  buffer-local maps, expressions, Lua callbacks, and plugin commands are reported
  as unsupported. Mappings are applied once, only in Normal mode.

**Neovim Import Report…** shows applied mappings and unsupported items.
**Use Built-in Editor Settings** removes the cache and restores the defaults.
Refresh applies to existing and future notes without changing their text or
edited status. Failed imports retain the last good settings. Opening notes
never starts Neovim; missing or corrupt caches fall back safely. The disposable
snapshot and independently owned shortcut preference are documented in
[DATA-MODEL.md](../DATA-MODEL.md).

The current local `lite` profile was verified on 2026-10-20: Etterglød colors,
absolute/relative numbers, wrapping and indentation imported successfully;
210 unsupported mappings were reported rather than approximated.

## Implementation phases

1. **Native lifecycle — implemented:** maximized focused notes, native text and
   undo, UTF-8 save/open, explicit discard, close/quit protection, resident reopen.
2. **Vim editing — implemented for the documented subset:** independent command
   engine, grapheme-safe motions/operators/counts, native clipboard and undo.
3. **Neovim settings — implemented:** explicit asynchronous import, validated
   atomic cache, live presentation updates, safe remaps and unsupported reports.
4. **Invocation and performance — implemented:** configurable global shortcut,
   pointer-display placement, disabled window animations, opt-in cold/warm
   measurements, memory/size benchmarks, and distribution instructions. External
   presentation timing, physical hotkey/VoiceOver/multiple-display checks, and
   Developer ID signing/notarization remain release acceptance checks.
5. **Everyday editing — implemented:** native Find/Replace, per-note literal
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
  or subprocesses. Neovim runs only on explicit import.
- Prefer system frameworks and justify any added dependency's startup, memory,
  and bundle-size costs. Retain a bundled default palette and cache imports.
- Track release app size, memory with no windows and a representative note, and
  repeated-open memory behavior alongside launch latency.

See [docs/PERFORMANCE.md](PERFORMANCE.md) for measured baselines, exact timing
boundaries, hardware, and reproduction. Normal/Visual commands reuse one
grapheme index while the exact text is unchanged; repeated search reuses one
match index. Indexes are built on demand and discarded on native edits; entering
Insert also releases the motion index. The first command after a change still
indexes text proportional to note size, and line numbers rebuild after edits.
This version targets scratch notes, not multi-megabyte file editing.

The phase 6 alternating-build check measured warm opening at **14.3 ms median /
22.4 ms p95**, versus 15.2 / 23.7 ms before. Repeated engine motions on a
1,000-line Unicode note fell from 1.575 ms to 0.004 ms median; these engine-only
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
smaller command set. The bundled Neovim approach used by VimR's NvimView remains
an alternative if full Vim compatibility eventually outweighs these constraints.

## Verification

```sh
swift test
# Explicitly execute the local user's Neovim configuration for integration tests:
SKRIV_TEST_REAL_NVIM=1 swift test --filter NeovimSettingsTests
# Optional clean-Neovim comparison; does not load the user's configuration:
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
cache failure/snapshot semantics, importer timeouts/output bounds, shortcut
persistence, OS registration collisions, callback dispatch, failed saves, and
growing/clearing a numbered 1,000-line note, literal search and wrapping, and
Visual Unicode selections and line-boundary editing, exact-byte cache invalidation,
and window sizing. Phase 6 verification passes **66 tests**, with two unchanged
real-Neovim integration tests opt-in (both passed during phase 5); the conformance runner
reported **2,158 cases and zero differences**, including Visual edits, within
its documented scope.

UI smoke checks verified focused launch, Norwegian/emoji editing, native save,
close/cancel/discard and quit prompts, mode changes, delete/undo/redo, explicit
import/report, line-number rendering, shortcut preferences, native Find/Replace
and undo, Vim Unicode search/Return/Escape/wrap, and character/line Visual
selection. Physical hotkey
invocation could not be verified with the app-targeted UI input tool; OS registry
and callback tests pass. Multi-display/Spaces, VoiceOver, older supported macOS
versions, and downloaded-app Gatekeeper behavior still require manual checks.

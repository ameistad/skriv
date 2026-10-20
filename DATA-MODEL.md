# Data model

## Concept: Note
- Meaning: the current plain text and save destination of one scratchpad.
- Owner: `ScratchDocument`, with its `NSTextStorage` as the live text owner.
- Source of truth: in-memory text while editing; a user-selected UTF-8 file after saving.
- Notes are independent. Closing/discarding does not delete a saved file.
- Enforced by: `ScratchDocumentTests`.
- Decided: 2026-10-20, native scratchpad foundation.

## Concept: Transient editing and search state
- Owner: each note's `VimTextView` owns its `VimEngine` and `LiteralSearch`.
- Visual anchor/caret and pending commands are UTF-16 positions into the current native text; they are not another text buffer. Native edits and mouse interaction invalidate Visual state.
- `LiteralSearch.query` and `forward` are the last submitted nonempty literal query and submitted direction. Empty submissions reuse the query; failed searches retain it; reverse repeats do not change the stored direction.
- No search history or selection is persisted. AppKit owns the native Find bar's separate search state and replacement undo.
- `VimEngine` caches one immutable grapheme/line index and `LiteralSearch` caches one query's match ranges. These are disposable derivatives of the native text, never editable buffers. Reuse requires exact UTF-8 byte equality, not Unicode canonical equivalence, because UTF-16 positions can differ. Native edits clear both; entering Insert releases the motion index. A changed query or externally changed text rebuilds its corresponding index lazily.
- Enforced by: `EverydayEditingTests` and `NativeEditorTests`.
- Decided: 2026-10-20, everyday editing.

## Concept: Skriv configuration
- Meaning: user-selected editor presentation, editing preferences, Normal-mode remaps, and the global invocation shortcut.
- Decision: replace the imported-settings snapshot and separate shortcut preferences with one user-authored file. Neovim is no longer a configuration source or runtime integration.
- Owner/source of truth: `~/.config/skriv/config.skriv`. `SkrivConfiguration` parses defaults plus explicit overrides; `ConfigurationController.current` is a disposable in-memory copy of the last successfully applied configuration.
- Format: UTF-8, at most 64 KiB, flat case-sensitive `key = value` lines. Full-line `#` comments and literal double-quoted values are supported. No executable syntax, interpolation, includes, or project lookup. Last scalar value wins; empty values reset to defaults. `keybind` accumulates one-key mappings; empty `keybind` clears them.
- Fields: `font-family` (installed family/PostScript name or `monospace`), `font-size` (6–72 points), `writing-width` (20–500 font advances), `wrap`, `word-wrap`, `expand-tabs` (Booleans), `tab-width` (1–9999), `indent-width` (0–9999; zero follows tab width), `line-numbers` (`none`, `absolute`, `relative`, `both`).
- Colors: `background`, `foreground`, `cursor-color`, `selection-background`, `selection-foreground`, `line-number-foreground`, `line-number-background` are optional 24-bit RGB values. Missing values use bundled colors, editor colors, or system secondary label color as documented in `docs/USAGE.md`. Unavailable fonts use system monospace at the configured size.
- `keybind`: nonrecursive one-key Normal-mode translations into the supported native command whitelist. Count keys, whitespace/control sources, sequences, scripts, and other modes are excluded. The engine applies each translation once outside operator-pending mode.
- `global-shortcut`: `none`, or modifiers `ctrl`, `alt`, `cmd`, `shift` plus A–Z/space; Command or Control is required. Defaults to Control–Option–Command–N. Parsed physical keycode and Carbon modifier bits are derived runtime values, not another persisted store.
- Lifecycle: load at startup and explicit reload only. Open Configuration creates a commented template only when absent, never rewrites existing content, and opens the file as a plain-text note using the `no.skriv.configuration` document type so native Save preserves the `.skriv` extension. New notes reuse current settings. No background polling or subprocesses.
- Failure semantics: validate the whole file and register the candidate shortcut before publishing settings to existing/future notes. Failed reloads preserve the previous configuration and working shortcut. Invalid startup configuration reports an error and leaves defaults active; default shortcut registration is attempted. Missing files use defaults. Reload never changes note text or edited status.
- Legacy data: the old Neovim snapshot and UserDefaults `globalShortcut.v1` value are neither read nor written, migrated, or deleted. The user explicitly chose to remove imported configuration; all new preferences belong to `config.skriv`.
- Enforced by: `ConfigurationTests`, `ConfigurationControllerTests`, `SettingsPresentationTests`, `NativeEditorTests`, and `GlobalShortcutTests` (including real OS collision preservation).
- Decided: 2026-10-20, standalone Ghostty-style configuration.

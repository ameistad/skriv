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

## Concept: Imported Neovim settings
- Meaning: resolved, supported colors, options, and safe Normal-mode remaps from the last explicit import.
- Owner: `NeovimSettingsCache` at `~/Library/Application Support/Skriv/neovim-settings-v1.json`.
- Source of truth: the user's Neovim configuration; this file is a disposable snapshot and must not be edited as a preference store. Explicit import/refresh rebuilds it; resetting removes it.
- Format: one atomic JSON envelope containing `version` (currently 1), `importedAt` (Foundation JSON date), and `settings`.
- `settings.normal`, `visual`, `cursor`, `lineNr`: resolved optional 24-bit RGB `foreground`/`background`. Missing channels use Skriv's bundled defaults.
- `number`, `relativenumber`, `wrap`, `linebreak`, `expandtab`: resolved Boolean options.
- `tabstop`: tab width, 1–9999; `shiftwidth`: indentation width, 0–9999, where zero means tabstop.
- `guifont`: resolved Neovim GUI font string; `mapleader`: resolved leader for reporting, not an additional shortcut source.
- `normalKeyMappings`: explicitly supported nonrecursive one-key Normal-mode translations. The editor applies each translation once. Mappings with prefix conflicts, callbacks, expressions, other modes or unsupported commands are excluded.
- `unsupportedMappings`, `warnings`: import report strings, not executable commands.
- Failure semantics: missing, corrupt, oversize, invalid or unknown-version caches use bundled defaults. A failed import preserves the prior cache and current settings. No configuration is resolved during note opening.
- Enforced by: `NeovimSettingsTests` round-trip/snapshot, corrupt/version/size rejection, import whitelist, timeout and bounded-output tests.
- Decided: 2026-10-20. Cache is a snapshot with an explicit rebuild path; no schema migration is needed.

## Concept: Global invocation shortcut
- Meaning: the user's enabled state and physical keyboard combination for opening a fresh note.
- Owner/source of truth: `ShortcutPreferences`, in one UserDefaults JSON data value under `globalShortcut.v1`.
- Format: `ShortcutConfiguration { enabled: Bool, keyCode: UInt32, modifiers: UInt32 }`; modifier bits use Carbon flags. Default is Control–Option–Command–N (ANSI keycode 45), enabled.
- Keyboard values are validated against known keys and require Command or Control. Invalid persisted data falls back to defaults without rewriting it.
- UI writes only after OS registration succeeds; a disabled shortcut remains a valid configuration.
- Relationship: independent of the Neovim settings cache; importing/resetting Neovim settings must not modify it.
- Enforced by: `ShortcutPreferencesTests` for validation, malformed data and persistence; `GlobalShortcutTests.collisionPreservesWorkingRegistrationAndDisableReleasesIt` verifies OS registration failure preserves the existing shortcut and disabling releases it.
- Decided: 2026-10-20, configurable global invocation.

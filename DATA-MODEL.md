# Data model

## Concept: Remembered document window frame
- Meaning: the shared size and position used when opening a document window, across closes and app launches.
- Decision: AppKit's `NSWindow Frame SkrivDocument` application UserDefaults entry owns this UI state. It is separate from user-authored editor settings in `config.skriv`; no document paths or contents are stored.
- Source of truth: the frame most recently saved by a visible, selected document window on move, resize, or close. Hidden tabs and tab-bar adjustments do not save geometry. New windows restore it using AppKit's frame APIs; absent saved state retains the maximized-on-pointer-display default. Full-screen transitions do not replace the regular frame.
- Owner: `DocumentWindowController`, using `NSWindow.saveFrame(usingName:)` and `setFrameUsingName(_:)`. All document windows share the same key rather than competing for an exclusive AppKit autosave name.
- Enforced by: `SettingsPresentationTests` (first-window fallback, close/reopen, multiple windows, and full-screen frame preservation).
- Decided: 2026-10-21, remember window size after closing.

## Concept: Document
- Meaning: the current plain text and save destination of one text document.
- Owner: `SkrivDocument`, with its `NSTextStorage` as the live text owner.
- Source of truth: in-memory text while editing; a user-selected UTF-8 file after saving.
- Documents are independent. Closing/discarding does not delete a saved file.
- Enforced by: `SkrivDocumentTests`.
- Decided: 2026-10-20, native document foundation; terminology updated 2026-10-21.

## Concept: Document tabs
- Meaning: a session-only grouping of independent documents in one visible native window.
- Owner/source of truth: AppKit's `NSWindowTabGroup.windows` owns tab membership and visible order; `selectedWindow` owns the active tab. Each tab retains its own `SkrivDocument`, window controller, text storage, undo manager, and editor.
- Tab bar visibility is derived from the native group's document count: hidden with one document, visible with two or more.
- `SkrivDocumentController` explicitly routes new documents and opened files into the active group. New Window bypasses grouping. An already-open file is selected in its original group, preserving unsaved edits.
- `TabDestination` holds an opening operation's insertion point and native group, including while an Open panel or file read is pending. It is transient routing context, not another collection of open tabs. If its original tab closes, a surviving sibling is used; if the group closes, a new window is created.
- No tab identifiers, document paths, tab order, or unsaved contents are persisted for session restoration. Closing a tab uses the existing document save/discard lifecycle; closing the last tab closes its window without quitting the app.
- Enforced by: `DocumentTabTests` and existing document/editor tests.
- Decided: 2026-10-21, native document tabs.

## Concept: Transient editing and search state
- Owner: each document's `VimTextView` owns its `VimEngine` and `LiteralSearch`.
- Visual anchor/caret and pending commands are UTF-16 positions into the current native text; they are not another text buffer. Native edits and mouse interaction invalidate Visual state.
- `LiteralSearch.query` and `forward` are the last submitted nonempty literal query and submitted direction. Empty submissions reuse the query; failed searches retain it; reverse repeats do not change the stored direction.
- The active gutter line is derived from the engine's active Visual endpoint, or the native selection start outside Visual mode. Bold emphasis and relative numbering share this position; neither persists another caret or setting. Enforced by `LineNumberRulerTests`.
- No search history or selection is persisted. AppKit owns the native Find bar's separate search state and replacement undo.
- `VimEngine` uses native UTF-16 positions throughout. On first use it scans bounded UTF-16 blocks for CR/LF/CRLF line metadata, grouped into chunks targeting 16,384 UTF-16 units and ending at complete lines. Prefix arrays contain only UTF-16 and line counts; no document-wide grapheme count is required. The engine references native storage and copies only chunks whose detailed character indexes are requested. Native character-edit notifications replace nearby metadata and discard affected cached character indexes without indexing unvisited text. Unaffected caches survive Insert mode and are discarded on storage replacement or explicit invalidation.
- The motion character cache defaults to a 4 MiB estimated byte budget with least-recently-used eviction. Accounting includes owned UTF-8 text, conservative sparse-checkpoint allocation and per-entry overhead; line metadata and native document storage are outside this cache budget. A chunk exceeding the configured budget is temporary for one command. Logical-line chunks larger than 65,536 UTF-16 units use native composed-character ranges directly, against full storage context, so ordinary navigation does not allocate a whole-line snapshot. Cache metrics are disposable diagnostics, not persisted state. Buffer metadata detaches on edits or budget changes when engines have been copied.
- Standalone immutable-string engine callers validate cache reuse with exact UTF-8 byte equality, not Unicode canonical equivalence, because UTF-16 positions can differ. Long word motions use a command-local cursor; deletions derive their resulting caret from the joined line or surviving line offsets rather than another whole-document index.
- `LiteralSearch` caches at most 4,096 ranges for one query; more frequent matches are found on demand against one Cocoa search snapshot. `VimTextView` lazily creates a contiguous UTF-8 snapshot only for search. Native character edits clear the search snapshot and matches, including edits outside `didChangeText`. Attribute edits preserve them. Replacing storage switches the notification subscription and invalidates all derivatives. Entering Insert drops the view's search-snapshot reference but preserves motion chunks. No snapshot or index is persisted.
- `LineNumberRuler` derives UTF-16 line starts through `LineStartIndex`. Storage edit ranges rescan the surrounding lines and shift the unchanged suffix in place. No text copy or persisted line map is owned by the gutter.
- Enforced by: `EverydayEditingTests`, `NativeEditorTests`, `LargeFileTests`, `IncrementalMotionTests`, and `LazyMotionTests`.
- Decided: 2026-10-20, everyday editing.

## Concept: Skriv configuration
- Meaning: user-selected editor presentation, editing preferences, and Normal-mode remaps.
- Decision: remove global shortcut ownership from Skriv; external launchers own their shortcut assignments. Editor preferences remain in one user-authored file. Neovim is not a configuration source or runtime integration.
- Owner/source of truth: `~/.config/skriv/config.skriv`. `SkrivConfiguration` parses defaults plus explicit overrides; `ConfigurationController.current` is a disposable in-memory copy of the last successfully applied configuration.
- Format: UTF-8, at most 64 KiB, flat case-sensitive `key = value` lines. Full-line `#` comments and literal double-quoted values are supported. No executable syntax, interpolation, includes, or project lookup. Last scalar value wins; empty values reset to defaults. `keybind` accumulates one-key mappings; empty `keybind` clears them.
- Fields: `font-family` (installed family/PostScript name or `monospace`), `font-size` (6–72 points), `writing-width` (20–500 font advances), `wrap`, `word-wrap`, `expand-tabs` (Booleans), `tab-width` (1–9999), `indent-width` (0–9999; zero follows tab width), `line-numbers` (`none`, `absolute`, `relative`, `both`).
- Colors: `background`, `foreground`, `cursor-color`, `selection-background`, `selection-foreground`, `line-number-foreground`, `line-number-background` are optional 24-bit RGB values. Missing values use bundled colors, editor colors, or system secondary label color as documented in `docs/USAGE.md`. Unavailable fonts use system monospace at the configured size.
- `markdown-highlighting`: Boolean, default `true`. Enables the Markdown color overlay only for `.md`/`.markdown` destinations within the native UTF-16 size limit. `config.skriv` owns the preference; filename and length determine eligibility. `MarkdownScanCache` and layout-manager colors are disposable, never saved or added to undo. No Markdown document type or parallel text model is introduced. Enforced by `MarkdownHighlighterTests` (configuration reset, reload, filename changes, byte identity, undo, composition, and size limit). Decided: 2026-10-23.
- `keybind`: nonrecursive one-key Normal-mode translations into the supported native command whitelist. Count keys, whitespace/control sources, sequences, scripts, and other modes are excluded. The engine applies each translation once outside operator-pending mode.
- Removed field: `global-shortcut` is an unknown-setting error, including `none` and empty values. Users remove or comment out old entries; no compatibility value or migration is retained.
- Lifecycle: load at startup and explicit reload only. Open Configuration creates a commented template only when absent, never rewrites existing content, and opens the file as a plain-text document using the `no.skriv.configuration` document type so native Save preserves the `.skriv` extension. New documents reuse current settings. No background polling or subprocesses.
- Failure semantics: validate the whole file before publishing settings to existing/future documents. Failed reloads preserve the previous configuration. Invalid startup configuration reports an error and leaves defaults active. Missing files use defaults. Reload never changes document text or edited status.
- Legacy data: the old Neovim snapshot and UserDefaults `globalShortcut.v1` value are neither read nor written, migrated, or deleted. The user explicitly chose to remove imported configuration; all new editor preferences belong to `config.skriv`. App-managed window geometry is separate UI state, documented above.
- Enforced by: `ConfigurationTests`, `ConfigurationControllerTests`, `SettingsPresentationTests`, and `NativeEditorTests`. Configuration regression tests reject the removed key and preserve previously applied settings.
- Decided: 2026-10-20, standalone Ghostty-style configuration; shortcut ownership removed 2026-10-21.

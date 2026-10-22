# Measuring invocation

Build optimized code, then run on a logged-in macOS desktop:

```sh
./scripts/build-app.sh release
python3 scripts/benchmark.py --runs 10 --warm 20 --require-readiness
```

This runs ten fresh processes and twenty warm document invocations per process.
Each process creates and closes only its own unmodified documents, then exits.
Avoid interacting with benchmark windows. A separately running Skriv process and its documents are unaffected.
The script requires Python 3.10+ and saves raw JSONL and a JSON summary under
`build/benchmarks/run-*`. Reports contain hardware, OS, bundle and executable
sizes, median/p95/min/max milliseconds, and resident memory in bytes.
The harness fingerprints `~/.config/skriv/config.skriv` and rejects changes
during a run; the comparison script also checks it across builds.
Always build release immediately beforehand; the script does not infer the
optimization level from a binary.
The build script now defaults to release; explicit `debug` builds remain available.
Current benchmark builds use a centered 1,000 × 700 window, bounded by the primary
display's visible frame, and neither restore nor save window preferences. This
keeps before/after geometry identical without changing the interactive app's frame.
Older builds do not implement this geometry isolation; use matching instrumentation
when comparing startup changes.

Timing boundaries:

- `coldProcess`: immediately before Python creates the process, through
  first-responder assignment or AppKit display submission. Includes subprocess
  setup, process creation, dynamic linking, and application startup; excludes
  Finder/Launch Services dispatch. The harness passes a monotonic nanosecond
  timestamp, verified to use the same macOS uptime clock as Swift DispatchTime.
  This does not force OS filesystem caches to be cold.
- `coldStartup`: the first Swift statement in `main` to first-responder
  assignment and AppKit display submission. It excludes process creation,
  dynamic linking, and OS disk-cache effects; these are fresh-process launches,
  not forced filesystem-cold launches.
- `warmInvocation`: entry into the shared new-document action to the same points.
  The harness calls that action on the main event loop. It excludes keyboard
  hardware and external launcher event delivery.
- `inputReady`: the editor has been assigned first responder.
- `displaySubmitted`: `NSWindow.displayIfNeeded()` has returned. This measures
  application drawing, **not** compositor presentation or pixels reaching the
  screen. Actual visible latency still needs Instruments/OS presentation
  tracing or external high-speed video.
- `eventLoopReady`: a main-queue callback after initial drawing observes an active
  application, a key document window, and the editor as first responder. This
  includes the remaining startup callback and activation work that `inputReady`
  can miss. It does not measure hardware input delivery or first-keystroke latency.
- `interfaceComplete`: the complete initial interface has submitted its drawing.
  This is distinct from event-loop readiness; both are needed for a usable window.
- `fullyReady`: the later of `eventLoopReady` and `interfaceComplete`, derived by
  the Python harness in summaries. Application-emitted JSONL remains unmodified.
- Memory: `mach_task_basic_info.resident_size` sampled with an empty document open,
  after all benchmark documents close, with a 1,000-line Norwegian/emoji document open, and after
  warm runs. Representative-document and final-idle samples allow one second for
  transient drawing surfaces to settle. These RSS samples are not macOS physical
  footprint or memory pressure.

The warm input target is under 100 ms, assessed against p95 as well as median.
Do not claim a visible-presentation target based on `displaySubmitted`.
Instrumentation collects all readiness timestamps before writing diagnostics, and is disabled
unless `SKRIV_METRICS_PATH` is set. Normal operation has no measurement timer,
polling loop, or subprocess. Configuration is read at startup and explicit reload;
opening additional documents uses the resolved in-memory settings.
Pending measurements belong to their opening window and are cancelled on close.
Readiness uses AppKit notifications and main-queue callbacks, without a timer or
polling in normal use. The benchmark driver waits for readiness before starting
its representative-document memory workload. `--require-readiness` verifies the
presence and ordering of the new endpoints; omit it for historical builds.
Additional `coldStartupDetail` samples break down the existing `beforeWindow`
aggregate into application/delegate initialization, launch dispatch,
configuration, AppKit launch completion, menu creation, and document/controller
construction, including stored-property initialization.

The comparison harness uses unique bundle identities, reverses order on each
pair, retains first launches in the aggregate, and reports them separately under
`firstLaunch`. `pairedChanges` reports after-minus-before cold timings and a
deterministic 5,000-resample percentile bootstrap interval for the median paired
difference. Negative deltas favor the new build. These intervals describe this
desktop workload, not all machines or filesystem-cold launches.

The measurements below predate the standalone `config.skriv` format. References
to imported settings describe those historical measurements; the import feature
has since been removed. Built-in global shortcuts have also been removed;
references to their delivery below describe the historical benchmark boundaries.
The JSONL memory stage identifiers `oneEmptyNote` and `representativeNote` remain
stable so reports can still be compared across versions.

For manual reopening measurements, launch the executable with a metrics destination,
close its unmodified document, switch to another app, and reopen Skriv from the Dock
or your launcher. With no visible windows, reopening invokes the measured action:

```sh
SKRIV_METRICS_PATH=/tmp/skriv-launch.jsonl build/Skriv.app/Contents/MacOS/Skriv
```

Use a single interactive instance when checking app reopening. Check multiple displays, menu-bar and Dock placement,
Spaces, Norwegian layouts, VoiceOver, and marked-text composition separately.
Automatic in-process timing does not verify those workflows.

Apple documents that
[`displayIfNeeded`](https://developer.apple.com/documentation/appkit/nswindow/displayifneeded())
passes drawing through the window's view hierarchy; it does not promise
physical display presentation.
Python documents that [`monotonic_ns`](https://docs.python.org/3/library/time.html#time.monotonic)
uses `mach_absolute_time` on macOS, with a clock shared across processes from
Python 3.10 onward. The harness checks the clock implementation before running.

## Baseline — 2026-10-20

Release build, Apple M3 Pro (Mac15,7), 18 GiB RAM, arm64, macOS 26.5.
Ten fresh processes with twenty warm opens each; 200 warm samples. Imported
Etterglød settings enabled absolute and relative numbers, wrapping and
word-boundary wrapping, with the configured SF Mono / Menlo fallback font list.
The cache fingerprint is saved in the report, and the harness rejects settings
changes during a run.

| Boundary | Median | p95 |
| --- | ---: | ---: |
| Process creation → input readiness | 178.691 ms | 219.075 ms |
| Process creation → display submitted | 180.285 ms | 220.630 ms |
| Swift main → input readiness | 163.102 ms | 209.394 ms |
| Swift main → display submitted | 164.709 ms | 210.949 ms |
| Warm action → input readiness | 15.812 ms | 21.960 ms |
| Warm action → display submitted | 16.800 ms | 23.221 ms |

Warm input readiness peaked at 30.596 ms, within the 100 ms target for this
shared-action benchmark. Physical hot-key delivery and actual screen
presentation are still separate manual/trace measurements. The single
post-build preflight process took 376.591 ms to input readiness; repeated
fresh-process launches benefit from OS caches and are not a boot-cold test.

| Resident memory | Median | p95 |
| --- | ---: | ---: |
| One empty document | 101.57 MiB | 101.73 MiB |
| No windows, before warm opens | 92.91 MiB | 99.86 MiB |
| 1,000-line, 75,000-byte Norwegian/emoji document | 107.66 MiB | 216.77 MiB |
| No windows, after warm opens | 109.01 MiB | 111.06 MiB |

The representative-document measurement had one transient 216.77 MiB outlier;
that process returned to 104.58 MiB when its document closed. RSS can retain or
release AppKit drawing allocations asynchronously, so these samples do not
establish a fixed memory budget.

A separate single-process 200-open soak completed with warm input median
14.549 ms / p95 18.249 ms, and final idle RSS **109.45 MiB**—comparable with
the 20-open baseline, with no sustained per-open growth observed. Its transient
representative-document RSS was 163.77 MiB.
[`Soak report`](../build/benchmarks/run-1za6avb4/summary.json).

The ad-hoc signed app bundle is **641,818 bytes** (about 627 KiB).
Raw measurements and host metadata:
[`run-0dq9r8db/summary.json`](../build/benchmarks/run-0dq9r8db/summary.json).
The local `build` directory is ignored by version control; this section records
the baseline when raw files are not present in a checkout.


## Phase 5 check — 2026-10-20

Same hardware, imported settings, and 10-process / 200-warm-open workload,
after adding native Find/Replace, literal Vim search and Visual selection.

| Boundary | Median | p95 |
| --- | ---: | ---: |
| Process creation → input readiness | 311.195 ms | 1,391.745 ms |
| Process creation → display submitted | 313.242 ms | 1,395.057 ms |
| Swift main → input readiness | 299.167 ms | 1,152.278 ms |
| Swift main → display submitted | 301.213 ms | 1,155.591 ms |
| Warm action → input readiness | 30.956 ms | 44.484 ms |
| Warm action → display submitted | 32.500 ms | 46.378 ms |

Warm input readiness peaked at 67.400 ms, still below the 100 ms target.
This run was slower than the original baseline. During investigation, several
Simulator processes and WindowServer were consuming substantial CPU, so this
is a loaded-desktop measurement and cannot establish an isolated code regression.
No unrelated user applications were stopped to improve the result.
A temporary comparison build with `usesFindBar` and incremental searching
disabled measured 32.786 ms median / 53.081 ms p95 over 100 warm opens
([comparison report](../build/benchmarks/run-w8e3uqkg/summary.json)).
Disabling native Find initialization did not improve these timings. The runs
were sequential under variable load, so they do not quantify its exact cost.
The comparison build is outside the project; the release retains Find.

Median RSS was 101.58 MiB with an empty document, 92.83 MiB before warm opens,
107.49 MiB with the representative document, and 103.73 MiB after warm opens.
The release bundle is **669,194 bytes** (about 654 KiB), up 27,376 bytes from
phase 4. There are still no package dependencies or background services.
The custom Vim search bar is allocated on first use; search history and Visual
state are in memory only.

Raw measurements:
[`run-an7zlgqs/summary.json`](../build/benchmarks/run-an7zlgqs/summary.json).

## Phase 6 — 2026-10-20

Opening now starts with the final content rectangle and defers native window
creation until the view hierarchy is ready. The app no longer creates an
oversized window and immediately resizes it. Opt-in `coldStartupPhase` and
`warmInvocationPhase` samples identify the opening stages; samples accumulate
in memory and are written only after the input/drawing timestamps are captured.
Normal use performs no timing or diagnostic I/O.

Five alternating before/after pairs, each with 20 warm opens, on the same
M3 Pro and imported settings. The comparison harness copies and signs both
builds with isolated app identities, reverses their order every pair, and
rejects changes to binaries or settings during measurement. The desktop still
had other development workloads running.

| Input readiness | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| Warm action, 100 samples per build | 15.167 / 23.692 ms | 14.285 / 22.361 ms |
| Process creation, 5 samples per build | 154.995 / 1,085.285 ms | 161.853 / 474.696 ms |
| Swift main, 5 samples per build | 147.557 / 745.676 ms | 154.782 / 174.652 ms |

Warm drawing submission changed from 16.096 / 25.047 ms to 15.515 / 23.578 ms.
The warm improvement is modest (about 6%). The small cold-start sample and
variable load do **not** establish a cold-start improvement. All optimized
warm input samples were below 31 ms. These are application timings, not
physical hot-key delivery or compositor latency.

The first comparison using the interactive app's bundle identity completed its
measurements but timed out during exit. That incomplete run is excluded.
An isolated probe and the five isolated pairs completed successfully.

Median optimized RSS was 101.42 MiB for an empty document, 92.69 MiB with no windows
before warm opens, 103.47 MiB for the representative document and 103.91 MiB after
warm opens. As before, occasional drawing allocations produced higher
transient samples. This launch workload does not exercise the new editing caches.

The shipped executable is **413,920 bytes**, about 38% smaller than the
666,384-byte instrumented pre-optimization executable. Release packaging strips
debug/local symbols from the bundled copy before signing; the unstripped
SwiftPM binary remains in `.build` for diagnostics. The full app is
**1,639,002 bytes** (1.56 MiB). Unlike the phase 5 size baseline, both phase 6
builds include the app icon; the icon accounts for most of the bundle.

### Editing CPU measurements

Normal and Visual motions now reuse one immutable grapheme index. Literal
search retains one query's match ranges and uses binary search for repeat
navigation. Exact UTF-8 comparisons prevent stale offsets when canonically
equivalent text has different UTF-16 lengths; contiguous storage uses `memcmp`
with a safe fallback. No persisted cache or dependency was added.

| Workload, median | Before | After |
| --- | ---: | ---: |
| Motion, 1,000 lines / 75 KB UTF-8 | 1.575 ms | 0.004 ms |
| Visual motion, 1,000 lines | 3.129 ms | 0.009 ms |
| Repeat search, 1,000 lines | 1.878 ms | 0.003 ms |
| Motion, 10,000 lines / 750 KB UTF-8 | 16.063 ms | 0.015 ms |
| Visual motion, 10,000 lines | 32.161 ms | 0.030 ms |
| Repeat search, 10,000 lines | 19.481 ms | 0.030 ms |

These release-mode CPU measurements exclude AppKit input delivery, text layout,
ruler drawing and display presentation. The first command still builds an
index: 3.668 ms for the smaller fixture and 20.374 ms for the larger one in the
optimized run. Editing or replacing the text invalidates caches; first-use work
remains proportional to text size. Cached arrays consume memory proportional
to characters/lines and matches, are allocated only when used, and are released
on native edits. Entering Insert also releases the motion index. There is only
one cached text version and one search query per editor.

Reproduce:

```sh
# Save a release build before changing code:
ditto build/Skriv.app build/performance-before/Skriv.app
# After changing code:
./scripts/build-app.sh release
python3 scripts/compare-launch.py --before build/performance-before/Skriv.app
python3 scripts/benchmark-editing.py --output build/benchmarks/editing.json
# Optional: benchmark VimEngine.swift and LiteralSearch.swift from a source snapshot:
python3 scripts/benchmark-editing.py --source-root /path/to/snapshot \
  --output build/benchmarks/editing-before.json
```

Raw reports:
[alternating launch comparison](../build/benchmarks/comparison-c96u1u8n/summary.json),
[editing before](../build/benchmarks/editing-before.json),
[editing after](../build/benchmarks/editing-after.json).

## Native command path — 2026-10-21

Apple M3 Pro, arm64, macOS 26.5; Swift 6 with `-O` and whole-module
optimization. The expanded benchmark covers 1,000, 10,000 and 100,000
Norwegian/emoji lines (75 KB, 750 KB and 7.5 MB UTF-8).

The engine-only benchmark missed a cost in the editor adapter: fetching and
traversing Cocoa-backed text on every command. `VimTextView` now creates one
contiguous UTF-8 snapshot lazily and shares it with the motion and search
indexes. Text-storage character-edit notifications discard these derivatives,
including changes made outside `didChangeText`. Byte comparisons recognize
shared storage without scanning it; distinct strings still require exact
encoding equality. Insert-mode pass-through keys do not create a snapshot.

The new `--native` workload uses an offscreen `VimTextView` with the app's
explicit TextKit 1 stack. Each size measures 100 alternating `h`/`l` commands
and ten first motions after actual single-character storage replacements.
Assertions check every resulting caret position. Before/after checksums and
fixture hashes match. These are sequential runs on an active desktop.

| Native command, lines | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| Cached motion, 1,000 | 3.033 / 3.170 ms | 0.015 / 0.018 ms |
| Cached motion, 10,000 | 30.731 / 31.975 ms | 0.013 / 0.016 ms |
| Cached motion, 100,000 | 311.255 / 319.527 ms | 0.013 / 0.016 ms |
| First motion after edit, 1,000 | 14.849 / 15.293 ms | 3.417 / 3.796 ms |
| First motion after edit, 10,000 | 144.679 / 175.259 ms | 32.966 / 33.706 ms |
| First motion after edit, 100,000 | 1,441.092 / 1,486.890 ms | 296.011 / 308.094 ms |

These measurements include command handling and native selection updates,
but exclude hardware input, window/ruler drawing and compositor presentation.
Post-edit timing excludes the storage replacement itself and includes the next
command's snapshot and index rebuild. The snapshot and indexes still require
memory proportional to document size. Large-file rebuilding remains a target:
the first command after editing 100,000 lines still takes about 296 ms.
Initial literal-search indexing also remains linear (about 187 ms at that size
in the engine-only fixture). No improvement is claimed for initial search.

The engine workload additionally reports repeated index builds, initial and
cached search, Visual motion, and direct bridged-string motion. The latter
bypasses the view's snapshot and intentionally exposes the conversion cost.
Reports retain raw samples, compiler flags, host details, source/fixture hashes
and six decimal places for milliseconds so short operations do not round to zero.

```sh
python3 scripts/benchmark-editing.py --output build/benchmarks/engine.json
python3 scripts/benchmark-editing.py --native --output build/benchmarks/native.json
python3 scripts/benchmark-editing.py --native --source-root /path/to/source-snapshot \
  --output build/benchmarks/native-before.json
```

Validation: all 81 tests pass, including exact Unicode encoding, direct storage
edits, storage replacement, search, insertion, undo and redo. The differential
Vim corpus passes all 2,158 cases. The release app builds successfully.

Raw reports: [native before](../build/benchmarks/native-verified-before-20261021.json),
[native after](../build/benchmarks/native-verified-after-20261021.json),
[engine before](../build/benchmarks/engine-final-before-20261021.json),
[engine after](../build/benchmarks/engine-final-after-20261021.json).

### Current release launch and memory

Ten fresh processes and 200 warm opens, using a signed copy with an isolated
bundle identity and unchanged current configuration. This establishes a current
baseline; it is not an alternating before/after launch comparison.

| Boundary | Median | p95 |
| --- | ---: | ---: |
| Process creation → input readiness | 179.416 ms | 565.404 ms |
| Swift main → input readiness | 167.452 ms | 189.393 ms |
| Warm action → input readiness | 11.687 ms | 23.260 ms |
| Warm action → display submitted | 12.561 ms | 24.991 ms |

Every warm input sample was below 39 ms, within the 100 ms target. The process
launch p95 is the slowest of only ten samples, including the first launch of the
newly signed copy; OS caches were not flushed. RSS medians were about 98 MiB
with an empty document, 153 MiB with the representative document and 109 MiB
after warm opens. These are transient process samples, not a memory budget or
a measurement of the large-file command caches.

[Launch report and raw samples](../build/benchmarks/launch-20261021-4dkfs2ph/run-jygbkh2o/summary.json).

## Startup investigation — 2026-10-21

The retained changes are release-by-default packaging and more accurate startup
diagnostics. **No release-to-release startup speedup is claimed.** The existing
window and editor initialization behavior remains in place; neither experimental
UI optimization met the measurement gate, and neither is shipped.

The app initially found in `build/Skriv.app` matched the debug executable's Mach-O
UUID and its `-Onone` build. Defaulting packaging to release prevents that mistake;
the comparisons below use release builds on both sides and do not attribute a
compiler-configuration change to a runtime optimization.

Time Profiler found AppKit launch/menu initialization, including the system's
Writing Tools framework loading, plus native window construction and display.
The more detailed control measurements put `NSApplication` initialization at
34.889 ms median, AppKit launch completion at 22.272 ms, window construction at
23.561 ms, and show/focus at 18.364 ms. Configuration loading was 0.483 ms. These
individual medians do not sum to the overall median. There was no CPU-heavy,
app-owned task on the empty-document startup path that justified adding Rust.
System Writing Tools support remains unchanged.

### Experiments and decisions

Apple M3 Pro, arm64, macOS 26.5, Swift 6.3.3. Each experiment used 30 alternating
before/after pairs, with ten warm opens per process: 30 cold and 300 warm samples
per build. Both sides used identical new instrumentation, readiness waiting,
current configuration, and isolated 1,000 × 700 window geometry. The control
retained the original UI and activation sequence. No unrelated apps were stopped.

Values below are median **paired after-minus-before differences**, in milliseconds,
with 95% percentile bootstrap intervals. Negative values favor the candidate.

| Candidate | Input-ready delta [95% interval] | Fully-ready delta [95% interval] | Decision |
| --- | ---: | ---: | --- |
| Deferred status/ruler labels, earlier activation, consolidated settings | +6.233 [2.823, 13.648] | +1.114 [-3.236, 7.246] | Reverted |
| Lightweight status drawing, batched initial presentation, lazy ruler fonts | −0.294 [−6.927, 3.139] | +0.371 [−4.398, 7.525] | Reverted |

The staged interface delayed completion until a later queue turn without improving
full readiness. The lightweight status candidate looked promising in its small
pilot, but the 30-pair comparison did not reproduce a reliable end-to-end gain.
Their supporting UI changes and experiment-specific tests were removed together.

The second comparison's control establishes this workload's instrumented baseline:

| Boundary | Median | p95 |
| --- | ---: | ---: |
| Process creation → input readiness | 121.608 ms | 136.543 ms |
| Process creation → complete-interface submission | 122.883 ms | 137.853 ms |
| Process creation → full readiness | 204.020 ms | 230.546 ms |
| Warm action → input readiness | 12.208 ms | 29.651 ms |
| Warm action → full readiness | 20.267 ms | 35.162 ms |

The readiness gap demonstrates why first-responder assignment alone is insufficient
to measure usable startup. The first newly signed control/candidate launches in
that comparison took 755.994 / 620.788 ms to full readiness. They remain included
in the aggregate and are reported separately; neither filesystem caches nor the
rest of the desktop were reset. These numbers are not directly comparable with
older full-screen-sized window workloads or compositor presentation timings.

Raw reports and their per-process samples:
[staged-interface comparison](../build/benchmarks/startup-final/comparison-vkok3zsw/summary.json),
[lightweight-status comparison](../build/benchmarks/startup-status-final/comparison-36ixur3i/summary.json).
The local build artifacts are ignored by version control; the table records the
findings for checkouts without those files.

### Retained-build validation

All 84 existing Swift tests pass. Default release packaging and code signing
succeed. A final two-pair readiness smoke check validates all four emitted
boundaries and their ordering over four processes and 40 warm opens; it is not
a performance claim. The aggregation checks cover the derived maximum, incomplete
readiness samples, and deterministic paired intervals. An isolated normal app
launch also passed focused typing, Norwegian text, emoji paste, native Find,
Normal-mode switching, undo back to an empty document, and a new focused window.
Hardware input latency, VoiceOver speech, real IME composition, and physical
screen presentation were not timed by this check.

[Retained-build smoke report](../build/benchmarks/startup-retained-smoke/comparison-gtoym08c/summary.json).

For the next startup experiment, preserve an instrumented release before changing
behavior, then compare with the same geometry and endpoints:

```sh
./scripts/build-app.sh
ditto build/Skriv.app build/startup-before/Skriv.app
# Make the candidate change, then rebuild:
./scripts/build-app.sh
python3 scripts/compare-launch.py --before build/startup-before/Skriv.app \
  --pairs 30 --warm 10 --require-readiness
```

## Large-file memory — 2026-10-21

Vim's motion index now keeps a String index and UTF-16 offset every 32 graphemes,
plus line boundaries, instead of a `Character` and integer offset for every
grapheme. Lookups scan at most one checkpoint block. Long word and whitespace
motions use a local cursor so sequential scans do not repeatedly traverse those
blocks. An ASCII fast path builds checkpoints without constructing Characters;
Swift still determines Unicode grapheme boundaries, including CRLF, combining
marks and emoji. Character deletions calculate the resulting caret from the
joined line; line deletions use surviving offsets. Neither builds another
whole-document index to predict the caret.

Literal search retains at most 4,096 match ranges (64 KiB of range payload).
Queries with more matches switch to directional searching, preserving overlapping
matches, canonical equivalence, whole-grapheme boundaries, counts and wrapping.
Large counts skip complete cycles after enumerating one cycle. A Cocoa search
snapshot is retained only for this streaming path; character edits release it.
Queries with few or no matches can still scan the whole document initially.
Repeated dense searches trade binary-search lookup for scanning to the next
match, keeping match memory bounded.

The gutter rescans edited lines and their neighbors, then shifts the unchanged
suffix of its UTF-16 line-start array in place. Same-length edits avoid even the
suffix shift. Length-changing edits still take O(number of following lines) to
adjust offsets. Initial gutter indexing remains linear. Final CR, LF, CRLF and
Unicode line separators retain the trailing empty numbered line.

The file reader, writer, native undo and TextKit stack are unchanged. A separate
Cocoa encoding experiment did not improve save performance and was removed.
These changes reduce derived editing state; they do not implement disk-backed
text storage or a fixed memory ceiling.

### Reproduce and interpret

```sh
# Before changing sources, preserve them for an identical-workload comparison:
mkdir -p build/large-file-before
cp -R Sources build/large-file-before/
python3 scripts/benchmark-large-files.py --source-root build/large-file-before \
  --runs 3 --output build/benchmarks/large-before.json
python3 scripts/benchmark-large-files.py --runs 3 \
  --output build/benchmarks/large-after.json
```

The harness compiles with `-O` and whole-module optimization. Every workload runs
in a fresh process and uses temporary UTF-8 files, a document's real text storage,
an offscreen editor and gutter. It exercises loading, first and repeated motions,
first and repeated literal search, edits, index rebuilding and saving. SHA-256
checks verify exact file contents after restoring edits. Fixtures cover 7.5 MB
and 75 MB Norwegian/emoji text, a 10 MB single ASCII line, and one million short
lines (2 MB). No user configuration, files, windows or clipboard are changed.
Reports include raw timing samples, RSS at each stage, process peak RSS, source
and fixture hashes, compiler flags and host metadata.

These are sequential desktop runs, not isolated or filesystem-cold trials.
RSS and peak RSS are not physical footprint. The fixture does not display a
window or explicitly draw the gutter, and does not measure scrolling, native
Find, hardware input or compositor presentation. Native selection changes can
still trigger layout. Edits are single-character, same-length replacements;
their timings include the gutter update, while the subsequent motion separately
measures rebuilding the invalidated command snapshot and motion index.

### Results

Apple M3 Pro, arm64, macOS 26.5; Swift 6.3.3. Three fresh processes per fixture
per build (24 processes total), using the identical fixture hash. Values below
are medians of the three process peak-RSS samples, taken after all workloads
including saving. The source hashes in the final after report match the retained
implementation. Input/output hashes match between builds.

| Fixture | Before peak RSS | After peak RSS | Reduction |
| --- | ---: | ---: | ---: |
| 7.5 MB Unicode, 100,000 lines | 279.19 MiB | 116.78 MiB | 58% |
| 75 MB Unicode, 1,000,000 lines | 2,302.80 MiB | 571.16 MiB | 75% |
| 10 MB ASCII, one line | 877.98 MiB | 444.81 MiB | 49% |
| 2 MB ASCII, 1,000,000 lines | 196.31 MiB | 114.42 MiB | 42% |

For the 75 MB Unicode fixture:

| Operation, median | Before | After |
| --- | ---: | ---: |
| First native Vim motion | 3,749.30 ms | 2,448.79 ms |
| First literal search (`blåbær`, one million matches) | 2,087.20 ms | 110.82 ms |
| Same-length storage edit with gutter attached | 249.09 ms | 0.062 ms |
| First motion after that edit | 3,381.62 ms | 2,436.68 ms |
| Cached `l` + `h` command pair | 0.0344 ms | 0.0333 ms |
| Repeat literal search | 0.000166 ms | 0.001958 ms |

First-use timings have three samples each; edits/rebuilds have nine and cached
motion/search have 300 each. Dense repeat searches are slower in absolute terms
by approximately two microseconds, in exchange for bounded match storage.
Loading/saving showed no material improvement and their implementation is
unchanged. These measurements establish lower memory use for these workloads,
not a universal maximum file size or a guarantee of responsive UI at every size.

**Remaining limits:** the snapshot and initial motion index still scale with the
whole document. A first motion after an edit to 75 MB takes roughly 2.4 seconds.
An enormous single paragraph remains costly in the native editor: the 10 MB
single-line fixture takes 3.54 seconds for its first native motion and 1.72
seconds after an edit. The corresponding engine-only initial index in a separate
release smoke measurement took about 19 ms (previously 191 ms), locating the
remaining dominant cost outside the motion index. Long word scans and edits to
such lines remain linear; visible scrolling/layout needs its own future profiling.
The editor is still an in-memory TextKit document, not a streaming file viewer.

Validation: all 102 Swift tests pass, including sparse Unicode boundaries,
overlapping/canonical searches with bounded caches and huge counts, incremental
line-index updates across replacements and CRLF joins, joined-grapheme deletion,
and exact UTF-8 round trips. The differential Vim corpus passes all 2,158 cases.
The optimized app builds and signs successfully at `build/Skriv.app`.

Raw reports: [before](../build/benchmarks/large-before.json),
[after](../build/benchmarks/large-after.json). Reports are local ignored artifacts;
the tables above preserve the results for checkouts without them.

## Incremental motion index — follow-up

The preceding 75 MB result still rebuilt the whole motion index after each edit.
This follow-up keeps the existing native text storage and incrementally updates
its derived index. The design takes two ideas from other editors:

- [VS Code's text-buffer design](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation)
  keeps text in chunks and stores metadata relative to those chunks, avoiding
  per-character metadata updates throughout the file after an insertion.
- [Xi's minimal invalidation](https://xi-editor.io/docs/rope_science_12.html)
  propagates edit deltas and preserves unaffected cached results.

Skriv uses immutable chunks targeting 16,384 UTF-16 units, extended to the next
complete CR/LF line boundary. Each owns the sparse grapheme index introduced in
the previous round. Prefix arrays of character counts, UTF-16 lengths and line
counts translate local positions to document positions. On a native character
edit, only the affected chunks and their immediate neighbors are copied and
reindexed; small prefix arrays are then refreshed. Neighbor inclusion protects
CRLF joins and grapheme changes caused by deleting separators.

This is a derived index, not a piece-table document implementation or a second
editable text owner. Prefix updates cost O(number of chunks); a balanced tree
would only be warranted if that small remaining cost becomes significant in
measurements. Motion commands no longer create a whole-document Swift snapshot.
Search still creates its own disposable snapshot when requested.

The chunk index survives Insert mode. Storage notifications update it for native
typing, direct mutations, replacement, undo and redo. Attribute-only edits leave
it intact; replacing text storage discards it and switches the observer. The
view's subsequent `didChangeText` no longer discards an already updated index.
Keeping derived chunks while typing trades some retained memory for avoiding
the expensive rebuild when returning to Normal mode. Editors that never enter
Vim mode still do not allocate the motion index.

The benchmark now measures complete edit/selection/motion cycles, in addition
to the individual storage notification and following command. It includes
single-character insertion and deletion as well as same-length replacement,
with assertions for each resulting caret. This prevents moving index work into
the edit notification from looking like an end-to-end speedup by itself.

### Follow-up results

Same Apple M3 Pro, macOS 26.5, Swift 6.3.3 and release compiler flags. Three fresh
processes per fixture per build, run sequentially on the active desktop. The
before build is the retained memory-optimized implementation from the preceding
section. Both sides use the expanded fixture; source and fixture hashes are
recorded, final-source hashes were checked, and all input/output hashes match.

For the 75 MB Unicode fixture, these are **complete cycles**, including storage
editing, index maintenance in notifications, selection placement, and the next
native `l` command:

| Cycle, median | Before | After |
| --- | ---: | ---: |
| Same-length replacement + motion | 2,431.19 ms | 3.615 ms |
| Insert one character + motion | 2,458.90 ms | 4.165 ms |
| Delete one character + motion | 2,440.69 ms | 3.918 ms |

Replacement cycles have nine samples per build; insertion and deletion have six
each. Replacement notification time rose from 0.095 ms to 1.475 ms because it now
updates the affected chunks. The subsequent motion fell from 2,430.95 ms to
2.110 ms. The complete cycle improves by about 673×, so this is an end-to-end
reduction in measured work, not just shifting the delay earlier.

Median process peak RSS for this workload is effectively unchanged:
570.67 MiB before and 570.61 MiB after. The 7.5 MB replacement cycle improved from
243.21 ms to 3.337 ms; the one-million-short-lines fixture improved from 44.98 ms
to 1.768 ms. These remain offscreen native measurements, not hardware-to-display
latency or a visible-window scrolling benchmark.

**Remaining limits:** first-time indexing still scans the document (2.119 seconds
for 75 MB in this run). Very long logical lines are intentionally kept whole to
preserve Unicode and line semantics, so a 10 MB single-line edit still reindexes
that whole chunk and incurs native layout work: 1.591 seconds for a replacement
cycle, versus 1.734 seconds before. Its first native motion takes 3.402 seconds.
Large replacements or coalesced edits spanning much of the document also rebuild
the affected extent. This change fixes repeat whole-document rebuilding for
small edits in multiline files; it does not claim to solve those distinct cases.

Validation: all **105 Swift tests** pass. Added checks compare incrementally
updated indexes with fresh indexes through Unicode replacements, chunk boundaries,
CRLF joins, large deletions, empty documents, Normal/Visual commands, registers,
Insert transitions, undo/redo and batched storage edits. The extended differential
Vim corpus passes **2,438 cases**, including long lines and chunk-boundary commands.
The release app builds and signs successfully.

```sh
# Preserve Sources before this change in build/incremental-before, then:
python3 scripts/benchmark-large-files.py --source-root build/incremental-before \
  --runs 3 --output build/benchmarks/incremental-before.json
python3 scripts/benchmark-large-files.py --runs 3 \
  --output build/benchmarks/incremental-after.json
swift test
python3 scripts/check-vim-conformance.py --large-files
./scripts/build-app.sh release
```

Raw reports: [before](../build/benchmarks/incremental-before.json),
[after](../build/benchmarks/incremental-after.json).

## Plan: reduce first-command indexing

Status: **implemented in the follow-up below**. The following records the original plan. The incremental index above still eagerly indexes
all graphemes on its first use. The 2.119-second first native command measurement
also includes native selection/layout work; it is not an isolated index timer.

1. Separate file loading, line scanning, character indexing and command execution
   in the benchmark. Add visible-window measurements alongside the existing
   offscreen measurements.
2. Compare Skriv, Neovim and available GUI editors using identical Unicode,
   many-short-lines and single-long-line files. Record opening-to-interactive
   time, first navigation and memory. Measure application startup separately;
   document wrapping, highlighting, plugins and other configuration differences.
3. Move internal Vim positions from global grapheme counts to UTF-16 offsets.
   Replace index arithmetic with explicit next/previous-grapheme and column
   operations while preserving current Unicode and Vim semantics.
4. Collect lightweight chunk/line metadata up front and build detailed character
   indexes only for chunks visited by a command. Line-number jumps, `gg` and `G`
   must not require character indexing of preceding chunks. Native text storage
   remains the authoritative document.
5. Bound character-cache memory with a byte budget and eviction. Avoid copying
   untouched text; invalidate affected cached chunks on edits without indexing
   previously untouched regions. Audit line-separator semantics before sharing
   metadata with the gutter, whose current separator rules differ from Vim's.
6. Validate uncached jumps, eviction, Unicode boundaries, CRLF joins, selections,
   undo/redo and storage replacement through Swift tests and Neovim comparisons.
   Repeat fresh-process benchmarks and record the results before shipping.

Proposed acceptance targets, not measured results: at least 5x faster first
native command on the 75 MB multiline fixture; preserve roughly 4 ms small
edit-plus-motion cycles; reduce memory after opening and limited navigation;
bound character-cache growth during traversal; and preserve correctness.
Profile enormous single-line native layout separately before selecting that
follow-up's implementation. Begin with measurement and the UTF-16 refactor,
then add lazy caching after existing behavior passes unchanged.


## Lazy character indexing — implementation

Document positions in the Vim engine now use native UTF-16 offsets rather than
whole-document grapheme ordinals. Initial construction scans UTF-16 in bounded
blocks to collect CR/LF/CRLF line and chunk metadata. A command builds a sparse
Unicode grapheme index only for the chunks it visits. `gg`, `G` and line-number
jumps no longer index the characters in preceding chunks. Native mutable text
storage remains authoritative; unvisited chunks do not own text snapshots.

A least-recently-used cache limits retained character indexes to a 4 MiB
accounting budget per engine. Accounting includes copied UTF-8 text, checkpoint
capacity allowance and per-entry overhead; it is not a bound on total process
RSS, native text storage, line metadata or temporary allocations. Oversized
logical chunks use Foundation composed-character navigation directly against
native storage, avoiding a retained whole-line copy. Small edits rescan nearby
line metadata, discard affected character entries, and preserve unaffected
entries without populating previously unused indexes. Cache changes preserve
VimEngine value semantics when an engine is copied. The gutter keeps its own
incremental index because its Foundation line-separator rules differ from Vim's.

### Measurement boundaries

The large-file runner now has three independent fresh-process profiles:

- `engine`: file loading, first engine command and an end-of-file `G` jump, with
  no text view or native layout manager. Optional diagnostics separately report
  metadata scanning, grapheme construction, indexed units and retained cache
  estimates. Diagnostic totals are sampled after both commands.
- `offscreen`: the existing native text view, gutter, search, edit and save
  workload. This keeps the previous measurement boundary for comparisons.
- `visible`: the actual production `DocumentWindowController` with default
  `EditorSettings`, including its font, wrapping, text container and view
  hierarchy. The existing launch-benchmark flag supplies stable window geometry
  and disables preference writes. It measures controller construction, first
  display and the first Vim command separately. Display includes a main-loop
  turn and drawing submission, not hardware input-to-pixel latency. A process
  deadline is recorded as a timeout rather than a successful timing sample.

All fixtures are freshly generated UTF-8 files, read from the filesystem with
warm filesystem caches. Native edit/save runs verify exact SHA-256 round trips;
completed engine and visible profiles verify command results. These are file-operation
measurements inside already initialized processes, not complete application
startup measurements. Each profile has its own memory baseline and should not
be combined with another profile to infer peak RSS.

### Comparable editor measurement

`scripts/benchmark-neovim-large-files.py` opens the exact same four fixture byte
sequences in fresh Neovim 0.12.5 processes, with no user configuration, plugins,
swap, persistent undo or highlighting; wrapping is disabled. File loading and
navigation are timed inside Neovim after startup. Peak RSS comes from macOS
`time -l`. Three runs verify expected line counts and cursor positions. The
median empty-process launch-through-exit is 11.97 ms, reported separately rather
than subtracted from file operations.

| Neovim headless, median | Load | First `l` | Peak RSS |
| --- | ---: | ---: | ---: |
| 75 MB Unicode, 1 million lines | 100.48 ms | 0.020 ms | 90.13 MiB |
| 10 MB single ASCII line | 17.49 ms | 0.238 ms | 76.67 MiB |
| 2 MB, 1 million short lines | 22.74 ms | 0.021 ms | 17.20 MiB |

These results show that multi-second character indexing is not inherent to the
fixture. They do **not** compare GUI opening-to-interactive latency: headless
Neovim performs no window layout or drawing, and its file/line model differs
from NSTextStorage. VS Code and Sublime Text are installed, but this run does
not claim GUI comparison timings because no equivalent instrumented readiness
boundary was established. The production Skriv visible profile below separately
checks whether command improvements translate into opening responsiveness.


### Repeated before/after results

Apple M3 Pro, macOS 26.5, Swift 6.3.3, release optimization and whole-module
optimization. Three fresh processes per fixture/profile/build. The before source
is commit `ce8b46a`; both builds use the identical expanded benchmark fixture.
Source and fixture hashes are recorded, and the after source hashes were checked
against the final working tree. All completed offscreen input/output hashes match.

| Workload | Pure engine first command, before → after | Native offscreen first command, before → after | Full offscreen peak RSS, before → after |
| --- | ---: | ---: | ---: |
| 7.5 MB Unicode | 192.23 → 6.66 ms | 204.33 → 15.17 ms | 115.53 → 103.52 MiB |
| 75 MB Unicode | 1,924.82 → 65.46 ms | 1,979.95 → 70.21 ms | 570.81 → 452.59 MiB |
| 10 MB single ASCII line | 58.27 → 10.80 ms | 3,152.53 → 3,042.21 ms | 445.16 → 421.09 MiB |
| 2 MB, 1 million short lines | 34.18 → 4.82 ms | 46.54 → 16.68 ms | 106.17 → 102.41 MiB |

These are medians. The 75 MB first native command improves **28.2×**, exceeding
the proposed 5× target for the existing native benchmark. The pure engine's
resident memory immediately after its first command falls from 381.48 to
263.19 MiB. Native offscreen resident memory at that point falls from 340.59 to
301.92 MiB; peak RSS across its full search/edit/save workload falls by 118.22
MiB. Retained/index-only measurements and full-workload peaks describe different
process stages; RSS also reflects allocator and OS residency decisions.

For the 75 MB engine profile, metadata scanning takes 64.55 ms and grapheme
construction takes 0.817 ms cumulatively through first command and `G`. Only
26,040 UTF-16 units are character-indexed across two chunks, retaining 55,564
accounted bytes. The cold distant jump costs 0.320 ms. The 10 MB single-line
fixture retains no character-cache entries and uses native boundary navigation;
its remaining native command cost is dominated by work outside the Vim engine.

| 75 MB complete native cycle, median | Before | After |
| --- | ---: | ---: |
| Same-length replacement + motion | 3.078 ms | 2.434 ms |
| Insert one character + motion | 3.612 ms | 2.964 ms |
| Delete one character + motion | 3.575 ms | 2.954 ms |

Replacement medians combine nine samples per build; insertion and deletion
combine six each. The previous small-edit responsiveness is preserved. The
10 MB single-line replacement cycle remains expensive: 1,455.86 → 1,404.61 ms.
Native layout remains a separate problem, despite the cheaper command engine.


### Visible opening remains a separate bottleneck

One diagnostic run per fixture/build uses the actual production controller.
These single observations are not the three-run medians above:

| Visible workload | Controller construction, before → after | First display, before → after | First Vim command, before → after |
| --- | ---: | ---: | ---: |
| 7.5 MB Unicode | 31.14 → 31.69 s | 139 → 71 ms | 201.49 → 12.24 ms |
| 75 MB Unicode | Entire process exceeded 45 s on both builds | Not reached/reported | Not reached/reported |
| 10 MB single ASCII line | 2.58 → 2.62 s | 2.86 → 2.89 s | 59.26 → 15.92 ms |
| 2 MB, 1 million short lines | 21.08 → 21.22 s | 51 → 48 ms | 38.53 → 9.85 ms |

The 75 MB after-process sample is inside `DocumentWindowController.init`, where
setting the text view's background color enters AppKit glyph generation and
layout-hole filling. This occurs before any Vim index is created. The timeout
is a whole-process deadline, not a precise controller-construction duration;
no 75 MB visible first-command measurement is claimed. Sampling that timed-out
process does not affect the completed timing rows.

Thus the lazy-indexing target is met for command work, but **large-file GUI
opening is not fixed**. Native view configuration/layout dominates the visible
opening path even for multiline files. A follow-up should profile the order of
presentation-attribute changes and layout invalidation, plus viewport-only
layout, against these production-controller measurements. This change does not
alter native layout settings or claim a visible startup speedup.

Validation: all **115 Swift tests** and **2,522 Neovim differential cases** pass.
Coverage includes lazy cold jumps, byte-budget eviction/revisits, edits in
uncached chunks, Unicode and CRLF boundaries, copied-engine isolation, native
Insert/undo/redo/storage replacement, and oversized-line composed-character
navigation against a Swift Character oracle. The release app builds and passes
strict code-signature verification. Benchmark scripts compile with Python and
`git diff --check` passes.

```sh
mkdir -p build/lazy-before
git archive ce8b46a Sources | tar -x -C build/lazy-before
python3 scripts/benchmark-large-files.py --source-root build/lazy-before \
  --profiles offscreen engine --runs 3 --output build/benchmarks/lazy-before.json
python3 scripts/benchmark-large-files.py --profiles offscreen engine \
  --diagnostics --runs 3 --output build/benchmarks/lazy-after.json
python3 scripts/benchmark-large-files.py --source-root build/lazy-before \
  --profiles visible --runs 1 --timeout 45 --output build/benchmarks/lazy-visible-before.json
python3 scripts/benchmark-large-files.py --profiles visible --runs 1 \
  --timeout 45 --output build/benchmarks/lazy-visible-after.json
python3 scripts/benchmark-neovim-large-files.py --runs 3 \
  --output build/benchmarks/lazy-neovim.json
```

Raw reports: [before](../build/benchmarks/lazy-before.json),
[after](../build/benchmarks/lazy-after.json),
[visible before](../build/benchmarks/lazy-visible-before.json),
[visible after](../build/benchmarks/lazy-visible-after.json),
[Neovim](../build/benchmarks/lazy-neovim.json),
[production visible sample](../build/benchmarks/lazy-production-visible-sample.txt).
These are local ignored artifacts; the tables preserve the measurements.

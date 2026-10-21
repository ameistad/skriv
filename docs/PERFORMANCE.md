# Measuring invocation

Build optimized code, then run on a logged-in macOS desktop:

```sh
./scripts/build-app.sh release
python3 scripts/benchmark.py --runs 10 --warm 20
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
- Memory: `mach_task_basic_info.resident_size` sampled with an empty document open,
  after all benchmark documents close, with a 1,000-line Norwegian/emoji document open, and after
  warm runs. Representative-document and final-idle samples allow one second for
  transient drawing surfaces to settle. These RSS samples are not macOS physical
  footprint or memory pressure.

The warm input target is under 100 ms, assessed against p95 as well as median.
Do not claim a visible-presentation target based on `displaySubmitted`.
Instrumentation collects timestamps before writing diagnostics, and is disabled
unless `SKRIV_METRICS_PATH` is set. Normal operation has no measurement timer,
polling loop, or subprocess. Configuration is read at startup and explicit reload;
opening additional documents uses the resolved in-memory settings.

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

#!/usr/bin/env python3
"""Fresh-process large-file CPU/RSS benchmark; see docs/PERFORMANCE.md.

Uses real UTF-8 file reads/writes and offscreen native text storage, command
handling and gutter indexing. Optional engine and visible-window profiles isolate
command indexing and include explicit visible-window layout/drawing, respectively.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

from benchmark import summarize

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profiles", nargs="+", choices=["offscreen", "engine", "visible"], default=["offscreen"])
    parser.add_argument("--shapes", nargs="+", choices=["unicode", "singleLine", "denseLines"])
    parser.add_argument("--timeout", type=float, default=300, help="Per-process limit in seconds; timeouts are reported")
    parser.add_argument("--diagnostics", action="store_true", help="Include lazy-index implementation diagnostics")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    sources = sorted((args.source_root.resolve() / "Sources/SkrivCore").glob("*.swift"))
    fixture = ROOT / "scripts/fixtures/LargeFileBenchmarkMain.swift"
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6"]
    if args.diagnostics:
        flags += ["-D", "LAZY_INDEX_DIAGNOSTICS"]
    workloads = [("unicode", 100_000), ("unicode", 1_000_000),
                 ("singleLine", 10_000_000), ("denseLines", 1_000_000)]
    if args.shapes:
        workloads = [item for item in workloads if item[0] in args.shapes]
    source_hashes = {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
    fixture_hash = hashlib.sha256(fixture.read_bytes()).hexdigest()
    results = []
    with tempfile.TemporaryDirectory(prefix="skriv-large-files-") as directory:
        work = Path(directory)
        shutil.copyfile(fixture, work / "main.swift")
        subprocess.run(["swiftc", *flags, *map(str, sources), str(work / "main.swift"),
                        "-o", str(work / "benchmark")], check=True)
        for run in range(args.runs):
            for profile, shape, repetitions in [(p, s, n) for p in args.profiles for s, n in workloads]:
                command = [str(work / "benchmark"), shape, str(repetitions), profile]
                if profile == "visible":
                    command += ["--benchmark-launch-count", "1"]
                try:
                    report = json.loads(subprocess.check_output(command, timeout=args.timeout,
                        env=dict(os.environ, SKRIV_BENCHMARK_DIRECTORY=str(work))))
                except subprocess.TimeoutExpired:
                    report = {"profile": profile, "shape": shape, "repetitions": repetitions,
                              "error": "processTimeout", "timeoutSeconds": args.timeout}
                report["run"] = run
                report["summary"] = {key: summarize(value, digits=6) for key, value in report.items()
                                     if key.endswith("Milliseconds") and isinstance(value, list)}
                results.append(report)
                print(json.dumps({key: value for key, value in report.items() if not isinstance(value, list)}), flush=True)
    metadata = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "os": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        "compilerFlags": flags,
        "sourceRoot": str(args.source_root.resolve()),
        "sourceSHA256": source_hashes,
        "fixtureSHA256": fixture_hash,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"metadata": metadata, "workloads": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()

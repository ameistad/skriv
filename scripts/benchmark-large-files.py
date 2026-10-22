#!/usr/bin/env python3
"""Fresh-process large-file CPU/RSS benchmark; see docs/PERFORMANCE.md.

Uses real UTF-8 file reads/writes and offscreen native text storage, command
handling and gutter indexing. Does not measure layout/drawing or native Find.
"""
import argparse
import datetime
import hashlib
import json
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
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    sources = sorted((args.source_root.resolve() / "Sources/SkrivCore").glob("*.swift"))
    fixture = ROOT / "scripts/fixtures/LargeFileBenchmarkMain.swift"
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6"]
    workloads = [("unicode", 100_000), ("unicode", 1_000_000),
                 ("singleLine", 10_000_000), ("denseLines", 1_000_000)]
    results = []
    with tempfile.TemporaryDirectory(prefix="skriv-large-files-") as directory:
        work = Path(directory)
        shutil.copyfile(fixture, work / "main.swift")
        subprocess.run(["swiftc", *flags, *map(str, sources), str(work / "main.swift"),
                        "-o", str(work / "benchmark")], check=True)
        for run in range(args.runs):
            for shape, repetitions in workloads:
                report = json.loads(subprocess.check_output(
                    [str(work / "benchmark"), shape, str(repetitions)], timeout=300))
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
        "sourceSHA256": {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
        "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"metadata": metadata, "workloads": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()

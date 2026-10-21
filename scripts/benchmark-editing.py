#!/usr/bin/env python3
"""Release-mode benchmarks of Unicode motions, index rebuilding and literal search.

No windows, input events, user configuration, clipboard or external packages.
--source-root can point at a source snapshot for before/after comparison.
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
    parser.add_argument("--native", action="store_true", help="Exercise offscreen AppKit command handling")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="skriv-editing-benchmark-") as directory:
        work = Path(directory)
        fixture = "NativeEditingBenchmarkMain.swift" if args.native else "EditingBenchmarkMain.swift"
        shutil.copyfile(ROOT / "scripts/fixtures" / fixture, work / "main.swift")
        core = args.source_root.resolve() / "Sources/SkrivCore"
        sources = [core / "VimEngine.swift", core / "LiteralSearch.swift"]
        if args.native:
            sources.append(core / "VimTextView.swift")
        subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-swift-version", "6",
                        *map(str, sources), str(work / "main.swift"),
                        "-o", str(work / "benchmark")], check=True)
        report = json.loads(subprocess.check_output([str(work / "benchmark")], timeout=180))
    report["metadata"] = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "workload": "offscreenAppKit" if args.native else "engine",
        "os": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        "compilerFlags": ["-O", "-whole-module-optimization", "-swift-version", "6"],
        "sourceRoot": str(args.source_root.resolve()),
        "sourceSHA256": {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
        "fixtureSHA256": hashlib.sha256((ROOT / "scripts/fixtures" / fixture).read_bytes()).hexdigest(),
    }
    for workload in report["workloads"]:
        workload["summary"] = {name: summarize(values, digits=6) for name, values in workload.items()
                               if name.endswith("Milliseconds") and isinstance(values, list)}
        print(json.dumps({k: v for k, v in workload.items() if not isinstance(v, list)}, indent=2))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

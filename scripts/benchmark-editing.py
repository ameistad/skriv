#!/usr/bin/env python3
"""Release-mode CPU benchmark of Unicode motions and repeated literal search.

No windows, input events, user configuration, clipboard or external packages.
--source-root can point at a source snapshot for before/after comparison.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from benchmark import summarize

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="skriv-editing-benchmark-") as directory:
        work = Path(directory)
        shutil.copyfile(ROOT / "scripts/fixtures/EditingBenchmarkMain.swift", work / "main.swift")
        core = args.source_root.resolve() / "Sources/SkrivCore"
        subprocess.run(["swiftc", "-O", str(core / "VimEngine.swift"),
                        str(core / "LiteralSearch.swift"), str(work / "main.swift"),
                        "-o", str(work / "benchmark")], check=True)
        report = json.loads(subprocess.check_output([str(work / "benchmark")], timeout=180))
    for workload in report["workloads"]:
        workload["summary"] = {name: summarize(workload[name]) for name in (
            "motionMilliseconds", "visualMilliseconds", "searchMilliseconds")}
        print(json.dumps({k: v for k, v in workload.items() if not isinstance(v, list)}, indent=2))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

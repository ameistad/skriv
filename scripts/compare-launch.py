#!/usr/bin/env python3
"""Alternate two release builds on the same desktop to compare note opening.

Each subprocess uses Skriv's isolated benchmark mode. No user documents are
opened or closed. Reverses run order on every pair to reduce temporal bias.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from benchmark import summarize

ROOT = Path(__file__).resolve().parent.parent


def fingerprint(app):
    return hashlib.sha256((app / "Contents/MacOS/Skriv").read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, default=ROOT / "build/Skriv.app")
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--warm", type=int, default=20)
    parser.add_argument("--output", type=Path, default=ROOT / "build/benchmarks")
    args = parser.parse_args()
    if not 1 <= args.pairs <= 50 or not 1 <= args.warm <= 1000:
        parser.error("--pairs must be 1…50 and --warm must be 1…1000")
    apps = {"before": args.before.resolve(), "after": args.after.resolve()}
    fingerprints = {name: fingerprint(app) for name, app in apps.items()}
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="comparison-", dir=args.output.resolve()))
    # Avoid sharing Launch Services identity with an interactive Skriv instance.
    # Both copies receive the same treatment before any timing begins.
    measured_apps = {}
    for name, app in apps.items():
        copied = output / f"Skriv-{name}.app"
        shutil.copytree(app, copied)
        plist = copied / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleIdentifier"] = f"no.skriv.benchmark-{name}"
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(copied)],
                       check=True, capture_output=True)
        measured_apps[name] = copied
    samples = {"before": [], "after": []}
    metadata = {}
    cache_fingerprints = set()
    for pair in range(args.pairs):
        order = ("before", "after") if pair % 2 == 0 else ("after", "before")
        for name in order:
            destination = output / f"{pair + 1}-{name}"
            run = subprocess.run([
                sys.executable, str(ROOT / "scripts/benchmark.py"),
                "--app", str(measured_apps[name]), "--runs", "1", "--warm", str(args.warm),
                "--output", str(destination),
            ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60 + args.warm)
            (output / f"{pair + 1}-{name}.log").write_text(run.stdout)
            if run.returncode:
                raise RuntimeError(f"Benchmark failed; see {output / f'{pair + 1}-{name}.log'}")
            report_path, = destination.glob("run-*/summary.json")
            metadata[name] = json.loads(report_path.read_text())
            cache_fingerprints.add(metadata[name]["settingsCacheSHA256"])
            for raw in report_path.parent.glob("process-*.jsonl"):
                samples[name].extend(json.loads(line) for line in raw.read_text().splitlines() if line)
        print(f"Pair {pair + 1}/{args.pairs} complete", flush=True)
    if len(cache_fingerprints) != 1:
        raise RuntimeError("Editor settings changed between builds; comparison is invalid.")
    if fingerprints != {name: fingerprint(app) for name, app in apps.items()}:
        raise RuntimeError("A binary changed during measurement; comparison is invalid.")
    results = {}
    for name, batch in samples.items():
        results[name] = {}
        for kind, stage in sorted({(item["kind"], item["stage"]) for item in batch}):
            field = "residentBytes" if kind == "memory" else "milliseconds"
            results[name][f"{kind}.{stage}.{field}"] = summarize(
                [item[field] for item in batch if item["kind"] == kind and item["stage"] == stage])
    summary = {"pairs": args.pairs, "warmPerProcess": args.warm,
               "binarySHA256": fingerprints, "metadata": metadata, "results": results}
    path = output / "summary.json"
    path.write_text(json.dumps(summary, indent=2) + "\n")
    for name in apps:
        print(name, json.dumps({key: value for key, value in results[name].items()
                               if key.endswith("inputReady.milliseconds")}, indent=2))
    print(f"Full report: {path}")


if __name__ == "__main__":
    main()

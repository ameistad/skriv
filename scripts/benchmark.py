#!/usr/bin/env python3
"""Repeated, opt-in Skriv launch benchmarks; uses no synthetic input or UI automation."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time


def summarize(values, digits=3):
    ordered = sorted(values)
    return {
        "samples": len(ordered),
        "median": round(statistics.median(ordered), digits),
        "p95": round(ordered[max(0, math.ceil(len(ordered) * .95) - 1)], digits),
        "min": round(ordered[0], digits),
        "max": round(ordered[-1], digits),
    }


def with_full_readiness(samples):
    """Derive the later readiness boundary without changing application-emitted JSONL."""
    result = list(samples)
    for kind in ("coldStartup", "coldProcess", "warmInvocation"):
        ready = [item["milliseconds"] for item in samples if item["kind"] == kind and item["stage"] == "eventLoopReady"]
        complete = [item["milliseconds"] for item in samples if item["kind"] == kind and item["stage"] == "interfaceComplete"]
        if ready or complete:
            for event, interface in zip(ready, complete, strict=True):
                result.append({"kind": kind, "stage": "fullyReady", "milliseconds": max(event, interface), "derived": True})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/Skriv.app"))
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--warm", type=int, default=20, help="Warm opens per fresh process")
    parser.add_argument("--output", type=Path, default=Path("build/benchmarks"))
    parser.add_argument("--require-readiness", action="store_true",
                        help="Require event-loop readiness and complete-interface samples (new builds)")
    args = parser.parse_args()
    clock = time.get_clock_info("monotonic")
    if sys.platform != "darwin" or sys.version_info < (3, 10) or clock.implementation != "mach_absolute_time()":
        parser.error("Full-process timing requires macOS and Python 3.10+ using mach_absolute_time().")
    if not 1 <= args.runs <= 100 or not 1 <= args.warm <= 1000:
        parser.error("--runs must be 1…100 and --warm must be 1…1000")
    app = args.app.resolve()
    executable = app / "Contents/MacOS/Skriv"
    if not executable.is_file():
        parser.error("Build the release bundle first: ./scripts/build-app.sh release")
    args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=args.output.resolve()))
    configuration_path = Path.home() / ".config/skriv/config.skriv"
    configuration_before = configuration_path.read_bytes() if configuration_path.is_file() else None
    samples = []
    for run in range(args.runs):
        metrics = output / f"process-{run + 1}.jsonl"
        env = dict(os.environ, SKRIV_METRICS_PATH=str(metrics))
        env["SKRIV_PROCESS_LAUNCH_UPTIME_NS"] = str(time.monotonic_ns())
        subprocess.run([str(executable), "--benchmark-launch-count", str(args.warm)],
                       env=env, check=True, timeout=30 + args.warm)
        if not metrics.exists():
            raise RuntimeError("The app did not write metrics; use the current release build.")
        batch = [json.loads(line) for line in metrics.read_text().splitlines() if line]
        for kind, expected in (("coldStartup", 1), ("coldProcess", 1), ("warmInvocation", args.warm)):
            stages = ("inputReady", "displaySubmitted")
            if args.require_readiness:
                stages += ("eventLoopReady", "interfaceComplete")
            for stage in stages:
                found = sum(item["kind"] == kind and item["stage"] == stage for item in batch)
                if found != expected:
                    raise RuntimeError(f"Run {run + 1}: expected {expected} {kind}/{stage}, got {found}")
            if args.require_readiness:
                boundaries = {stage: [item["milliseconds"] for item in batch
                                      if item["kind"] == kind and item["stage"] == stage] for stage in stages}
                for index in range(expected):
                    if not (boundaries["inputReady"][index] <= boundaries["displaySubmitted"][index]
                            <= min(boundaries["eventLoopReady"][index], boundaries["interfaceComplete"][index])):
                        raise RuntimeError(f"Run {run + 1}: invalid readiness ordering for {kind}")
        samples.extend(with_full_readiness(batch))
        print(f"Process {run + 1}/{args.runs} complete", flush=True)

    def sysctl(name):
        return subprocess.check_output(["sysctl", "-n", name], text=True).strip()

    results = {}
    for kind, stage in sorted({(sample["kind"], sample["stage"]) for sample in samples}):
        key = "residentBytes" if kind == "memory" else "milliseconds"
        results[f"{kind}.{stage}.{key}"] = summarize(
            [sample[key] for sample in samples if sample["kind"] == kind and sample["stage"] == stage])
    configuration_after = configuration_path.read_bytes() if configuration_path.is_file() else None
    if configuration_before != configuration_after:
        raise RuntimeError("Editor settings changed during the benchmark; rerun with a stable configuration.")
    report = {
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "hardware": {"model": sysctl("hw.model"), "cpu": sysctl("machdep.cpu.brand_string"),
                     "memoryBytes": int(sysctl("hw.memsize")), "architecture": platform.machine()},
        "os": platform.platform(),
        "clock": vars(clock),
        "configurationPath": str(configuration_path),
        "configurationPresent": configuration_before is not None,
        "configurationSHA256": hashlib.sha256(configuration_before).hexdigest() if configuration_before is not None else None,
        "executable": str(executable),
        "bundleBytes": sum(path.stat().st_size for path in app.rglob("*") if path.is_file()),
        "executableBytes": executable.stat().st_size,
        "runs": args.runs,
        "warmOpensPerProcess": args.warm,
        "requiresReadiness": args.require_readiness,
        "results": results,
        "limitations": [
            "Build release immediately before benchmarking; configuration is not inferred.",
            "coldProcess begins immediately before Python subprocess.run, including harness setup, process creation, and dyld; excludes Launch Services.",
            "coldStartup begins in main. Neither cold measurement forces OS filesystem caches to be cold.",
            "Warm timing invokes the shared document action, excluding hardware key delivery.",
            "Input readiness means the editor was assigned first responder, not event delivery latency.",
            "eventLoopReady requires a main-queue turn, active app, key window and editor first responder; it does not measure hardware input latency.",
            "interfaceComplete includes secondary UI and its AppKit drawing submission; full usability requires eventLoopReady as well.",
            "Display submission is AppKit draw completion, not compositor or screen presentation.",
            "Resident bytes are point-in-time RSS, not memory pressure or physical footprint.",
            "Benchmark processes use current local settings and do not alter them.",
        ],
    }
    report_path = output / "summary.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    print(f"Bundle: {report['bundleBytes']:,} bytes")
    print(f"Full report: {report_path}")


if __name__ == "__main__":
    main()

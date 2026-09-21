"""Derive the published comparison summary from a completed run directory.

The raw evidence keeps every sample and every gradient. The summary published
next to the report keeps the identities, accuracy results, environments and
resource counts, and replaces the raw sample arrays with the distribution
statistics the report quotes. Deriving it with this script instead of by hand
makes the published numbers reproducible from the retained raw files.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import tomllib

# Raw arrays that the summary replaces with derived statistics.
NUMERICAL_RAW = ("gradient", "samples_ns")
BROWSER_RAW = ("batch_samples_ms", "samples_ms")


def statistics(samples_ms: list[float]) -> dict:
    """Summarise one timing distribution, quoting the nearest-rank percentile."""
    if not samples_ms:
        raise ValueError("a timing distribution must have at least one sample")
    ordered = sorted(samples_ms)
    # Nearest rank: ceil(0.95 * n), matching the percentile the report quotes.
    rank = math.ceil(0.95 * len(ordered))
    return {"samples": len(ordered), "minimum_ms": ordered[0], "median_ms": median(ordered),
            "p95_nearest_rank_ms": ordered[rank - 1], "maximum_ms": ordered[-1]}


def median(ordered: list[float]) -> float:
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def numerical_records(directory: Path, iteration: int) -> list[dict]:
    native = tomllib.loads((directory / f"projection-diff3d-{iteration}.toml").read_text())
    node = json.loads((directory / f"projection-three-{iteration}.json").read_text())
    records = []
    for engine, report in (("diff3d", native), ("three", node)):
        for result in report["results"]:
            record = {key: value for key, value in result.items() if key not in NUMERICAL_RAW}
            record["engine"] = engine
            record["pass_number"] = iteration
            record["timing"] = statistics([sample / 1e6 for sample in result["samples_ns"]])
            records.append(record)
    return records


def browser_records(directory: Path, iteration: int) -> list[dict]:
    report = json.loads((directory / f"browser-{iteration}.json").read_text())
    records = []
    for result in report["results"]:
        record = {key: value for key, value in result.items() if key != "engines"}
        record["pass_number"] = iteration
        record["engines"] = {}
        for engine, measurement in result["engines"].items():
            entry = {key: value for key, value in measurement.items() if key not in BROWSER_RAW}
            entry["timing"] = statistics(measurement["samples_ms"])
            record["engines"][engine] = entry
        records.append(record)
    return records


def summarize(directory: Path) -> dict:
    run_bytes = (directory / "run.json").read_bytes()
    run = json.loads(run_bytes)
    if run["status"] != "passed":
        raise ValueError("refusing to summarise a run that did not pass")
    native = tomllib.loads((directory / "projection-diff3d-1.toml").read_text())
    node = json.loads((directory / "projection-three-1.json").read_text())
    browser = json.loads((directory / "browser-1.json").read_text())
    return {
        "revision": run["revision"],
        "status": run["status"],
        "raw_files_verified": len(run["files_sha256"]),
        "run_sha256": hashlib.sha256(run_bytes).hexdigest(),
        "environment": {
            "os": run["os"], "arch": run["arch"], "cpu_count": run["cpu_count"],
            "load_average_start": run["load_average_start"],
            "load_average_end": run["load_average_end"],
            "started_unix_seconds": run["started_unix_seconds"],
            "finished_unix_seconds": run["finished_unix_seconds"],
            "julia": {key: native[key] for key in
                      ("julia", "cpu", "threads", "opt_level", "diff3d_version",
                       "forwarddiff_version")},
            "node": {key: node[key] for key in
                     ("status", "three_revision", "node", "os", "arch", "cpu",
                      "fixture_sha256")},
            "browser": {"browser": browser["browser"],
                        "browser_version": browser["browser_version"],
                        "python": browser["python"]},
        },
        "numerical": [record for iteration in (1, 2)
                      for record in numerical_records(directory, iteration)],
        "browser": [record for iteration in (1, 2)
                    for record in browser_records(directory, iteration)],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="a completed comparison output directory")
    parser.add_argument("--output", type=Path, help="write the summary here instead of stdout")
    arguments = parser.parse_args()
    summary = summarize(arguments.directory)
    text = json.dumps(summary, indent=1) + "\n"
    if arguments.output:
        arguments.output.write_text(text)
        print(f"Wrote {arguments.output} for revision {summary['revision']}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

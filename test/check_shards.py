"""Require successful, exhaustive optimized test reports for one source revision."""

import argparse
from collections import defaultdict
from pathlib import Path
import tomllib


def validate_reports(reports: list[dict], *, groups: int, revision: str) -> list[tuple]:
    if not reports or groups < 1 or not revision:
        raise ValueError("reports, a positive group count, and a revision are required")
    baseline = reports[0]
    units = baseline.get("all_units")
    digest = baseline.get("suite_sha256")
    if not isinstance(units, list) or not units or not all(isinstance(x, str) for x in units):
        raise ValueError("test unit inventory is missing or invalid")
    if not isinstance(digest, str) or len(digest) != 64:
        raise ValueError("suite source digest is missing or invalid")
    by_environment = defaultdict(list)
    for report in reports:
        if report.get("status") != "passed" or report.get("revision") != revision:
            raise ValueError("a shard failed or belongs to a different revision")
        if report.get("suite_sha256") != digest or report.get("all_units") != units:
            raise ValueError("shards have different test source inventories")
        if report.get("allocation_assertions") is not True or report.get("opt_level", 0) < 1:
            raise ValueError("allocation assertions or optimization were disabled")
        if report.get("compile_enabled") not in (1, 2):
            raise ValueError("shard did not use normal compiled execution")
        if report.get("encountered_units") != len(units):
            raise ValueError("shard did not encounter the entire source inventory")
        shard, count = report.get("shard"), report.get("shards")
        if type(shard) is not int or type(count) is not int or not 1 <= shard <= count <= len(units):
            raise ValueError("invalid shard index/count")
        expected = list(range(shard, len(units) + 1, count))
        if report.get("unit_ids") != expected:
            raise ValueError("shard has missing, duplicate, or unexpected test units")
        key = tuple(report.get(field) for field in ("julia", "os", "arch"))
        if not all(isinstance(value, str) and value for value in key):
            raise ValueError("shard environment is missing")
        by_environment[key].append(report)
    if len(by_environment) != groups:
        raise ValueError(f"expected {groups} runtime/platform groups, found {len(by_environment)}")
    for environment, members in by_environment.items():
        counts = {member["shards"] for member in members}
        if len(counts) != 1:
            raise ValueError(f"inconsistent shard counts for {environment}")
        count = counts.pop()
        if sorted(member["shard"] for member in members) != list(range(1, count + 1)):
            raise ValueError(f"missing or duplicate shards for {environment}")
    return sorted(by_environment)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--groups", type=int, required=True)
    parser.add_argument("--revision", required=True)
    arguments = parser.parse_args()
    reports = []
    for path in sorted(arguments.directory.rglob("*.toml")):
        with path.open("rb") as stream:
            reports.append(tomllib.load(stream))
    environments = validate_reports(reports, groups=arguments.groups, revision=arguments.revision)
    print(f"Verified {len(reports)} optimized shards with complete test coverage:")
    for environment in environments:
        print("  " + " / ".join(environment))


if __name__ == "__main__":
    main()

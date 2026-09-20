"""Validate and measure matched standalone viewers with GPU completion per frame."""

import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import platform
import statistics
import subprocess
import sys

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "examples"))
from browser_support import BROWSERS, launch_browser


def validate_pixels(pixels, fixture, case, animation_time, subpixel_bits):
    if type(subpixel_bits) is not int or subpixel_bits < 4:
        raise AssertionError("Invalid WebGL subpixel precision")
    # Window vertices have implementation-dependent fixed-point precision.
    # One grid step in each coordinate bounds either rounding or truncation;
    # retain the separate Float32 transform allowance. ES 2.0 table 6.18 sets
    # the minimum at four bits, so a fixed 0.002-pixel band is insufficient.
    edge_tolerance = 0.002 + math.sqrt(2) * 2.0 ** -subpixel_bits
    width, height = fixture["width"], fixture["height"]
    if len(pixels) != width * height * 4:
        raise AssertionError("Unexpected pixel buffer size")
    expected = bytearray(width * height)
    boundary = set()
    phase = animation_time % 2
    shift = case["amplitude"] * min(phase, 2 - phase) if case["mode"] == "dynamic" else 0
    vertices = case["positions"]
    for index in range(case["count"]):
        cx, cy, _ = case["centers"][3 * index:3 * index + 3]
        points = [((vertices[i] + cx + 1) * width / 2,
                   (vertices[i + 1] + cy + shift + 1) * height / 2) for i in (0, 3, 6)]
        edges = list(zip(points, points[1:] + points[:1]))
        tolerances = [edge_tolerance * math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in edges]
        for y in range(max(0, math.floor(min(p[1] for p in points))), min(height, math.ceil(max(p[1] for p in points)))):
            for x in range(max(0, math.floor(min(p[0] for p in points))), min(width, math.ceil(max(p[0] for p in points)))):
                values = [(b[0] - a[0]) * (y + 0.5 - a[1]) - (b[1] - a[1]) * (x + 0.5 - a[0]) for a, b in edges]
                pixel = y * width + x
                if min(values) >= 0:
                    expected[pixel] = 1
                if all(value >= -tolerance for value, tolerance in zip(values, tolerances)) and any(
                        abs(value) <= tolerance for value, tolerance in zip(values, tolerances)):
                    boundary.add(pixel)
    foreground = [round(value * 255) for value in fixture["color"]]
    background = [round(value * 255) for value in fixture["background"]]
    failures, colored = [], 0
    for index, inside in enumerate(expected):
        actual = pixels[4 * index:4 * index + 4]
        colored += actual[:3] != background
        wanted = (foreground if inside else background) + [255]
        if index in boundary:
            valid = any(all(abs(a - b) <= 1 for a, b in zip(actual, value + [255]))
                        for value in (foreground, background))
        else:
            valid = all(abs(a - b) <= 1 for a, b in zip(actual, wanted))
        if not valid and len(failures) < 10:
            failures.append({"x": index % width, "y": index // width, "actual": actual, "expected": wanted})
    if failures or not colored:
        raise AssertionError(f"Independent triangle pixel oracle failed: {failures}, colored={colored}")
    return {"pixel_sha256": hashlib.sha256(bytes(pixels)).hexdigest(), "colored_pixels": colored,
            "edge_tie_pixels": len(boundary), "edge_tolerance_pixels": edge_tolerance}, boundary


def measure(page, html, fixture, case, instrument):
    errors, network = [], []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    page.on("request", lambda request: network.append(request.url) if request.url.startswith(("http:", "https:")) else None)
    page.add_init_script("window.__benchmarkDimensions=" + json.dumps({"width": fixture["width"], "height": fixture["height"]}) + ";\n" + instrument)
    page.goto(html.resolve().as_uri(), wait_until="load", timeout=120_000)
    page.wait_for_function("window.__benchmarkFirst || window.__benchmarkFailure", timeout=120_000)
    failure = page.evaluate("window.__benchmarkFailure")
    if failure:
        raise AssertionError(failure)
    first = page.evaluate("window.__benchmarkFirst")
    environment = page.evaluate("window.__benchmarkEnvironment()")
    if (environment["width"], environment["height"], environment["devicePixelRatio"]) != (fixture["width"], fixture["height"], 1):
        raise AssertionError(f"Incorrect rendering dimensions: {environment}")
    if environment["context"]["antialias"] or environment["context"]["alpha"]:
        raise AssertionError(f"Incorrect rendering attributes: {environment}")
    expected_calls = 1 if case["mode"] == "instanced" else case["count"]
    expected_objects = 1 if case["mode"] == "instanced" else case["count"]
    if environment["objectCount"] != expected_objects or abs(environment["animationTime"]) > 1e-9:
        raise AssertionError(f"Incorrect initial scene state: {environment}")
    first_pixels = page.evaluate("window.__benchmarkPixels()")
    first_oracle, first_boundary = validate_pixels(first_pixels, fixture, case, 0, environment["subpixelBits"])
    frames, batches = [first], []
    batch_size = fixture["frames_per_sample"]
    for index in range(fixture["warmup"] + fixture["samples"]):
        batch = page.evaluate("args => window.__benchmarkBatch(...args)", [1 + index * batch_size, batch_size])
        frames.extend(batch["frames"])
        batches.append(batch["milliseconds"])
    for frame in frames:
        if frame["calls"] != expected_calls or frame["triangles"] != case["count"]:
            raise AssertionError(f"Incorrect draw/triangle count: {frame}")
        if not math.isfinite(frame["milliseconds"]) or frame["milliseconds"] < 0:
            raise AssertionError(f"Invalid timing: {frame}")
    if frames[-1]["resources"] != first["resources"]:
        raise AssertionError("Matched fixture created or deleted GPU resources after the first frame")
    final_time = (fixture["warmup"] + fixture["samples"]) * batch_size / 60
    actual_time = page.evaluate("window.__benchmarkEnvironment().animationTime")
    if abs(actual_time - final_time) > 1e-9:
        raise AssertionError(f"Animation clock {actual_time} != {final_time}")
    final_pixels = page.evaluate("window.__benchmarkPixels()")
    final_oracle, final_boundary = validate_pixels(final_pixels, fixture, case, final_time, environment["subpixelBits"])
    if case["mode"] == "dynamic" and first_pixels == final_pixels:
        raise AssertionError("Dynamic fixture did not change the image")
    if errors or network:
        raise AssertionError(f"Viewer errors={errors}, external requests={network}")
    data = html.read_bytes()
    return {"environment": environment, "first_frame": first,
            "frames_per_sample": batch_size,
            "batch_samples_ms": batches[fixture["warmup"]:],
            "samples_ms": [elapsed / batch_size for elapsed in batches[fixture["warmup"]:]],
            "final_resources": frames[-1]["resources"], "first_pixels": first_oracle, "final_pixels": final_oracle,
            "html_bytes": len(data), "gzip_bytes": len(gzip.compress(data, mtime=0)),
            "html_sha256": hashlib.sha256(data).hexdigest()}, (first_pixels, final_pixels), (first_boundary, final_boundary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--browser", choices=BROWSERS, required=True)
    parser.add_argument("--order", choices=("diff3d-first", "three-first"), default="diff3d-first")
    parser.add_argument("--case", action="append", help="Run only this fixture ID (repeatable)")
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    cases = fixture["cases"]
    if fixture["schema"] != 1 or any(not isinstance(fixture[key], int) or fixture[key] <= 0 for key in ("width", "height", "samples", "warmup", "frames_per_sample")):
        parser.error("invalid benchmark fixture")
    if args.case:
        unknown = set(args.case) - {case["id"] for case in cases}
        if unknown:
            parser.error(f"unknown cases: {sorted(unknown)}")
        cases = [case for case in cases if case["id"] in args.case]
    if not cases:
        parser.error("empty benchmark fixture")
    instrument = (Path(__file__).parent / "browser_instrument.js").read_text()
    report = {"status": "failed", "browser": args.browser, "os": platform.platform(),
              "arch": platform.machine(), "python": sys.version, "order": args.order,
              "fixture_sha256": hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
              "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)),
              "results": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with sync_playwright() as playwright:
            browser = launch_browser(playwright, args.browser)
            try:
                report["browser_version"] = browser.version
                for case in cases:
                    records, images, boundaries = {}, {}, {}
                    order = ("diff3d", "three") if args.order == "diff3d-first" else ("three", "diff3d")
                    for engine in order:
                        page = browser.new_page(viewport={"width": 800, "height": 600}, device_scale_factor=1)
                        try:
                            records[engine], images[engine], boundaries[engine] = measure(page,
                                args.artifacts / f"{engine}-{case['id']}.html", fixture, case, instrument)
                        finally:
                            page.close()
                    differences = []
                    for field in ("renderer", "vendor"):
                        if records["diff3d"]["environment"][field] != records["three"]["environment"][field]:
                            raise AssertionError(f"{case['id']}: engines used different {field} values")
                    for stage in (0, 1):
                        allowed = boundaries["diff3d"][stage] | boundaries["three"][stage]
                        mismatches = sum(any(abs(a - b) > 1 for a, b in zip(
                            images["diff3d"][stage][i:i+4], images["three"][stage][i:i+4]))
                            for i in range(0, len(images["diff3d"][stage]), 4) if i // 4 not in allowed)
                        if mismatches:
                            raise AssertionError(f"{case['id']}: {mismatches} mismatching pixels outside edge ties")
                        differences.append(mismatches)
                    report["results"].append({"id": case["id"], "mode": case["mode"], "count": case["count"],
                        "engines": records, "pixel_mismatches_outside_edge_ties": differences})
                    print("BROWSER_COMPARISON_OK " + case["id"] + " " + json.dumps({engine:
                        statistics.median(record["samples_ms"]) for engine, record in records.items()}), flush=True)
            finally:
                browser.close()
        report["status"] = "passed"
    finally:
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

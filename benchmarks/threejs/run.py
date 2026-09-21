"""Run the pinned comparison sequentially and retain commands, logs and raw data."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import tomllib

ROOT = Path(__file__).resolve().parents[2]
BENCH = Path(__file__).resolve().parent


def portable_argument(argument: str, *, root: Path, output: Path) -> str:
    """Rewrite one command argument so a published record carries no local layout.

    Paths inside the output directory and the repository become the stable
    `<output>` and `<repo>` placeholders. Any remaining absolute path belongs to
    a tool installed elsewhere, such as the interpreter, and is reduced to its
    program name. Relative arguments and plain options are returned unchanged.
    """
    # The output directory can live inside the repository, so replace it first.
    text = argument.replace(str(output), "<output>").replace(str(root), "<repo>")
    if text == argument and Path(argument).is_absolute():
        return Path(argument).name
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--browser", choices=("chromium", "firefox", "webkit"), required=True)
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--allow-dirty", action="store_true", help="Permit a development probe; release reports require a clean checkout")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("use an empty output directory to preserve previous evidence")
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True))
    if dirty and not args.allow_dirty:
        parser.error("comparison requires a clean checkout; use --allow-dirty only for development probes")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    output.mkdir(parents=True, exist_ok=True)
    report = {"status": "failed", "revision": revision, "dirty": dirty,
              "os": platform.platform(), "arch": platform.machine(), "cpu_count": os.cpu_count(),
              "load_average_start": list(os.getloadavg()) if hasattr(os, "getloadavg") else None,
              "started_unix_seconds": time.time(), "commands": []}

    def run(name, command):
        start = time.monotonic()
        log = output / f"{name}.log"
        argv = [portable_argument(argument, root=ROOT, output=output) for argument in command]
        if any(Path(argument).is_absolute() for argument in argv):
            raise AssertionError(f"{name} would record a machine-specific path: {argv}")
        command_record = {"name": name, "argv": argv, "exit_code": None, "log": log.name}
        report["commands"].append(command_record)
        try:
            with log.open("w") as stream:
                completed = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=False)
            command_record["exit_code"] = completed.returncode
        except OSError as error:
            command_record["error"] = str(error)
            raise
        finally:
            command_record["process_elapsed_seconds"] = time.monotonic() - start
        if completed.returncode:
            raise RuntimeError(f"{name} failed with exit {completed.returncode}; see {log}")
        print(f"COMPARISON_STEP_OK {name}", flush=True)

    try:
        # Preserve the exact resolved Julia dependencies, including their tree
        # hashes, before running either implementation. Manifest.toml is ignored
        # in this library repository, so a clean Git tree alone cannot lock it.
        environment = output / "julia-environment"
        environment.mkdir()
        environment_bytes = {name: (ROOT / name).read_bytes()
                             for name in ("Project.toml", "Manifest.toml")}
        for name, contents in environment_bytes.items():
            (environment / name).write_bytes(contents)
        project = tomllib.loads(environment_bytes["Project.toml"].decode())
        manifest = tomllib.loads(environment_bytes["Manifest.toml"].decode())
        forwarddiff_version = manifest["deps"]["ForwardDiff"][0]["version"]
        run("fixtures", [sys.executable, str(BENCH / "fixtures.py"), str(output / "fixtures")])
        julia = [args.julia, "--startup-file=no", f"--project={ROOT}"]
        run("browser-build-diff3d", julia + [str(BENCH / "browser.jl"), str(output / "fixtures/browser.toml"), str(output / "html")])
        run("browser-build-three", ["node", str(BENCH / "browser_build.mjs"), str(output / "fixtures/browser.json"), str(output / "html")])
        # Reverse the engine order on the second pass. Each command runs after
        # its predecessor exits; warmups and raw samples remain in each report.
        for iteration, order in enumerate(("diff3d-first", "three-first"), 1):
            operations = [
                ("projection-diff3d", julia + [str(BENCH / "projection.jl"), str(output / "fixtures/projection.toml"), str(output / f"projection-diff3d-{iteration}.toml")]),
                ("projection-three", ["node", "--expose-gc", str(BENCH / "projection.mjs"), str(output / "fixtures/projection.json"), str(output / f"projection-three-{iteration}.json")]),
            ]
            for name, command in (operations if iteration == 1 else reversed(operations)):
                run(f"{name}-{iteration}", command)
            run(f"browser-{iteration}", [sys.executable, str(BENCH / "browser.py"),
                str(output / "fixtures/browser.json"), str(output / "html"), str(output / f"browser-{iteration}.json"),
                "--browser", args.browser, "--order", order])

        projection_fixture = json.loads((output / "fixtures/projection.json").read_text())
        browser_fixture = json.loads((output / "fixtures/browser.json").read_text())
        expected_native = {(case["count"], method) for case in projection_fixture["cases"]
                           for method in ("reverse_ad", "forward_ad", "central_difference")}
        expected_node = {(case["count"], "central_difference") for case in projection_fixture["cases"]}
        expected_browser = {case["id"] for case in browser_fixture["cases"]}
        package = json.loads((BENCH / "package.json").read_text())
        pins = {**package["dependencies"], **package["devDependencies"]}
        build = json.loads((output / "html/three-build.json").read_text())
        if any(build[name] != pins[name] for name in ("three", "esbuild")):
            raise AssertionError("Installed comparison dependencies do not match their pins")
        for iteration in (1, 2):
            native = tomllib.loads((output / f"projection-diff3d-{iteration}.toml").read_text())
            node = json.loads((output / f"projection-three-{iteration}.json").read_text())
            browser = json.loads((output / f"browser-{iteration}.json").read_text())
            if any(item["status"] != "passed" for item in (native, node, browser)):
                raise AssertionError("Incomplete comparison result")
            if native["diff3d_version"] != project["version"] or native["forwarddiff_version"] != forwarddiff_version:
                raise AssertionError("Loaded Julia packages do not match the captured environment")
            for item, expected in ((native, expected_native), (node, expected_node)):
                identities = [(record["count"], record["method"]) for record in item["results"]]
                if len(identities) != len(expected) or set(identities) != expected:
                    raise AssertionError("Incomplete projection comparison inventory")
            identities = [record["id"] for record in browser["results"]]
            if len(identities) != len(expected_browser) or set(identities) != expected_browser:
                raise AssertionError("Incomplete browser comparison inventory")
            if any(item["revision"] != revision or item["dirty"] != dirty for item in (native, browser)):
                raise AssertionError("Comparison source changed during the run")
        current_revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        current_dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True))
        if current_revision != revision or current_dirty != dirty:
            raise AssertionError("Checkout changed while collecting evidence")
        if any((ROOT / name).read_bytes() != contents for name, contents in environment_bytes.items()):
            raise AssertionError("Julia dependency environment changed while collecting evidence")
        report["status"] = "passed"
    finally:
        report["finished_unix_seconds"] = time.time()
        report["load_average_end"] = list(os.getloadavg()) if hasattr(os, "getloadavg") else None
        report["files_sha256"] = {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sorted(output.rglob("*")) if path.is_file()}
        (output / "run.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()

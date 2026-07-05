from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - depends on host Python.
    print("Python 3.11+ is required for tomllib", file=sys.stderr)
    raise SystemExit(2)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = REPO_ROOT / "examples" / "examples_registry.toml"
SMOKE_SCRIPT = "examples/browser_webgl_smoke.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate and browser-smoke examples listed in examples_registry.toml.",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help="Path to examples_registry.toml.",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="UPSTREAM_ID",
        help="Run one upstream_id. May be passed more than once.",
    )
    parser.add_argument(
        "--skip-generate",
        action="store_true",
        help="Skip Julia example generation and only smoke existing HTML.",
    )
    parser.add_argument(
        "--skip-browser",
        action="store_true",
        help="Skip browser smoke and only run Julia example generation.",
    )
    parser.add_argument(
        "--julia",
        default="julia",
        help="Julia executable to use.",
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python executable to use for browser smoke.",
    )
    parser.add_argument(
        "--shard",
        default=None,
        metavar="N/M",
        help="Run shard N of M (1-indexed), splitting the examples round-robin "
             "across M parallel runners. Without this, all examples run.",
    )
    return parser.parse_args()


def apply_shard(examples: list[dict], shard: str | None) -> list[dict]:
    if not shard:
        return examples
    try:
        n_str, m_str = shard.split("/")
        n, m = int(n_str), int(m_str)
    except ValueError:
        raise RuntimeError(f"--shard must look like N/M, got {shard!r}")
    if not (1 <= n <= m):
        raise RuntimeError(f"--shard out of range: {shard!r} (need 1 <= N <= M)")
    # Round-robin so expensive examples (text/font, csg, terrain) spread evenly
    # across shards rather than clustering in one.
    return [e for i, e in enumerate(examples) if i % m == (n - 1)]


def load_examples(registry_path: Path) -> list[dict]:
    with registry_path.open("rb") as handle:
        registry = tomllib.load(handle)
    examples = registry.get("examples")
    if not isinstance(examples, list):
        raise RuntimeError(f"{registry_path} is missing an examples array")
    return examples


def selected_examples(examples: list[dict], only: list[str]) -> list[dict]:
    runnable = [entry for entry in examples if entry.get("status") != "planned"]
    if not only:
        return runnable
    wanted = set(only)
    found = {entry.get("upstream_id") for entry in runnable}
    missing = sorted(wanted - found)
    if missing:
        raise RuntimeError("unknown or planned upstream_id(s): " + ", ".join(missing))
    return [entry for entry in runnable if entry.get("upstream_id") in wanted]


def expected_paths(entry: dict) -> tuple[Path, Path, str, str]:
    upstream_id = entry.get("upstream_id")
    local_script = entry.get("local_script")
    if not isinstance(upstream_id, str) or not isinstance(local_script, str):
        raise RuntimeError(f"malformed registry entry: {entry!r}")

    script = REPO_ROOT / local_script
    html = REPO_ROOT / "examples" / "output" / (script.stem + ".html")
    generate_command = f"julia --project=. {local_script}"
    smoke_command = f"python {SMOKE_SCRIPT} examples/output/{script.stem}.html"
    return script, html, generate_command, smoke_command


def validate_entry(entry: dict) -> tuple[Path, Path]:
    script, html, generate_command, smoke_command = expected_paths(entry)
    upstream_id = entry["upstream_id"]
    if not script.is_file():
        raise RuntimeError(f"{upstream_id}: missing local script {script}")
    verification = entry.get("verification")
    if not isinstance(verification, list):
        raise RuntimeError(f"{upstream_id}: verification must be an array")
    if generate_command not in verification:
        raise RuntimeError(f"{upstream_id}: missing verification command {generate_command!r}")
    if smoke_command not in verification:
        raise RuntimeError(f"{upstream_id}: missing verification command {smoke_command!r}")
    return script, html


def run_checked(command: list[str], *, label: str) -> None:
    print(label, " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def main() -> int:
    args = parse_args()
    if args.skip_generate and args.skip_browser:
        print("--skip-generate and --skip-browser cannot both be used", file=sys.stderr)
        return 2

    examples = selected_examples(load_examples(args.registry), args.only)
    examples = apply_shard(examples, args.shard)
    generated = 0
    smoke_paths: list[Path] = []
    for entry in examples:
        script, html = validate_entry(entry)
        if not args.skip_generate:
            run_checked([args.julia, "--project=.", str(script.relative_to(REPO_ROOT))],
                        label="REGISTRY_GENERATE")
            generated += 1
        if not args.skip_browser:
            if not html.is_file():
                raise RuntimeError(f"{entry['upstream_id']}: missing generated HTML {html}")
            smoke_paths.append(html.relative_to(REPO_ROOT))

    if smoke_paths:
        run_checked([args.python, SMOKE_SCRIPT, *(str(path) for path in smoke_paths)],
                    label="REGISTRY_SMOKE")

    print(
        f"REGISTRY_VERIFICATION_OK examples={len(examples)} generated={generated} smoked={len(smoke_paths)}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as err:
        raise SystemExit(err.returncode)
    except RuntimeError as err:
        print(f"REGISTRY_VERIFICATION_ERROR {err}", file=sys.stderr)
        raise SystemExit(1)

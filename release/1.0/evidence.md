# Diff3D 1.0 release evidence

The gate tracker is [RELEASE_PLAN.md](../../RELEASE_PLAN.md). This file records
observed results; a planned command is not a passed check.

## Starting inspection — 2026-09-20

- `git status --short`: empty; starting revision
  `87debdbe65fe768ec3f8e7ed1c3ca6d9645ff5c1`.
- `Project.toml`: package version 0.1.8; Julia compatibility starts at 1.10.
- General `D/Diff3D/Versions.toml`: registered 0.1.8 tree
  `4e89e79cf3dd264b0de5f165084b30608137e6e7`. Matching local history identifies
  `07de039d7267a594fe1049c3fde01bb4c200e5c8`, before the 23 audit commits.
- A fresh Julia 1.12.7 process loaded the current package and reported 454 public
  bindings; `diff_render` is undefined and `differentiable_render` is defined.
  Required Draco, Meshopt, and Basis glTF extension probes each raised the
  documented unsupported-extension error.
- Parsing `examples/examples_registry.toml` with Python `tomllib` counted 108
  entries, all with `status = "partial"`.
- `.github/workflows/ci.yml`, `test/runtests.jl`, `docs/make.jl`, the public
  exports, renderer entry points, and the benchmark harness were inspected for
  release ownership and verification paths.
- Available local commands: Julia 1.12.7, Node 26.5.0, Python 3.14.7. Other
  supported runtime/platform results remain to be established for this release.

No complete 1.0 gate has passed yet. The previous audit is baseline evidence only.

## R1/R5 — preserve HTML exports when serialization fails

VERIFIED on the starting implementation: `save_webgl_html` opened/truncated the
destination before scene serialization. A required `ShaderMaterial` rejection in
a later case left a partial new file and damaged an existing file. The focused
public regression (`test/web_export_atomicity.jl`) recorded 15 passes and 7
failures before the fix.

The canonical exporter now streams to a sibling temporary file, closes it, and
commits by one filesystem rename. It propagates errors, preserves existing
regular-file permissions, and replaces a destination symlink without modifying
its target. New files use owner-only read/write permissions. HTML serialization
and its streaming implementation are unchanged.

Observed validation on macOS/aarch64:

| Check | Result |
|---|---|
| `julia --startup-file=no -O0 --compile=min --project -e 'include("test/web_export_atomicity.jl"); include("test/public_contract.jl")'` | 22 export and 45 public-contract assertions passed, Julia 1.12.7 |
| Export regression under Julia 1.10.12 with a separately resolved 1.10 environment | 22 assertions passed |
| Existing two-sphere streamed-export allocation workload under normal Julia 1.12.7 compilation | 226,576 bytes; unchanged budget 350,000 bytes |
| Successful HTML compared with the existing complete-HTML writer | Byte-for-byte equal |

The first minimum-Julia attempt reused the ignored Julia 1.12 root manifest and
failed in `PrecompileTools` before loading Diff3D. Repeating with the separately
resolved Julia 1.10 environment passed. Release consumer validation must resolve
dependencies for its actual Julia version.

Local raw logs: `/tmp/diff3d-1.0-export-before.log`,
`/tmp/diff3d-1.0-public-contract-fixed.log`,
`/tmp/diff3d-1.0-export-julia110-resolved.log`, and
`/tmp/diff3d-1.0-export-allocation.log`. Full candidate and browser checks remain
required.

## R3 — complete optimized test runner

The suite was moved to `test/suite.jl`. After removing the automatic low-compile
respawn header, all moved source bodies and allocation budgets were checked by
text and normalized Julia AST comparison. Three pre-existing trailing comment
spaces were removed; executable ASTs and budgets are unchanged. The inventory contains
455 top-level test sets and 60 complete included regression files (515 units).

Observed checks:

- `julia --startup-file=no --depwarn=error --project test/test_runner.jl`:
  42 assertions passed under Julia 1.12.7. The same runner checks passed under
  Julia 1.10.12. They cover exhaustive/disjoint partitions, included files,
  shared declarations, invalid options, and failing-process report propagation.
- `python3 test/test_check_shards.py`: all 3 validator test methods passed,
  including missing/duplicate shards and 16 mutations of otherwise valid reports.
- A real `Pkg.test(test_args=ARGS)` invocation with `--shard=515/515
  --require-optimized --report=/tmp/diff3d-1.0-real-shard.toml` passed the 22 export
  assertions. Its report recorded Julia 1.12.7, macOS/aarch64, optimization level
  2, normal compilation, enabled allocation assertions, and all 515 source units
  encountered. This is one selected unit, not a full-suite pass.

Two initial runner-fixture issues were corrected: a dynamically created test
module lacked the standard `include` binding, and Julia 1.12 required latest-world
access to newly included bindings. The final minimum/current runner checks passed.
Full optimized correctness/allocation results will come from the complete CI
shard reports; they remain pending.

The first complete CI run (`35486410719`, source `357d95e`) passed seven native
shards and exposed allocation failures in WebGL case serialization, transformed
custom attributes, CSG operations, and the cold truncated-HDR test. Raw job logs
are retained under `/tmp/diff3d-1.0-ci-*.log`; these failures are being investigated,
not waived. The runner now groups results with a standard outer `Test` test set,
so later test units still execute after a failed assertion. Its updated checks
passed 44 assertions on Julia 1.10.12 and 1.12.7, including a deliberately failing
subprocess whose later unit runs while the report remains failed.

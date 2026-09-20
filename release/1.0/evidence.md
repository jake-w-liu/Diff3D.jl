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

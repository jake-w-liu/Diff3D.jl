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

No 1.0 gate has passed yet. The previous audit is baseline evidence only.

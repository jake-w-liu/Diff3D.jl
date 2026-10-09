# Diff3D 1.1 release evidence

This file records observed results for the 1.1.0 candidate. A planned command
is not a passed check. The 1.0 gate process is in `RELEASE_PLAN.md`; the same
acceptance discipline applies here.

## Post-1.0 audit recovery — 2026-10-09

The three.js r186 parity audit ran in nine `audit/*` worktrees off `main` and
stopped mid-session with four dirty trees. Verified and committed the
remaining work (`mathapi`, `renderer`, `shading`, `webexport` — including the
missing `uOpaque` entry in `test/web_uniform_writes.jl`), wrote the missing
changelog entries, and merged all eight audit branches plus the standalone
JPEG commit into `main`. The audit branches and worktrees were removed after
merge; a stale `RESTORED by geometry agent` stash duplicating committed MTL
work was dropped; scratch verification scripts and stray shard reports were
deleted.

## Suite state after merge

The first merged six-shard run reported 57 failures in 18 testsets, all traced
to expectations the audit intentionally changed (BRDF_Lambert albedo/π
normalization, `AnimationAction` loop-multiple sampling, the appended
`MeshToonMaterial.vertex_colors` field, and the `uOpaque` uniform contract).
Stale expectations were migrated; one genuinely new incompatibility — the
public-contract export inventory — was updated for the four documented API
additions (`mat4_compose`, `mat4_decompose`, `mat4_determinant`,
`quat_from_rotation_matrix`).

## Fresh audit pass — merged tree

- Read every source file the per-subsystem audit never touched:
  `src/cameras.jl`, `src/csg.jl`, `src/io.jl`, `src/losses.jl`,
  `src/shadows.jl`, `src/textures.jl`, `src/teapot_geometry.jl`,
  `src/benchmark.jl`, `src/docs.jl` — no confirmed defects.
- Verified `texture_update_matrix!` against three.js r186
  `Matrix3.setUvTransform` element-for-element: identical, including the
  center/offset terms. The glTF `KHR_texture_transform` path uses the spec's
  distinct T·R·S ordering in a manual matrix — checked against the fixture
  reference.
- `mat4_decompose` previously tested the 3×3 determinant sign; three.js
  `Matrix4.decompose` uses the full 4×4 `determinant()`. Corrected for
  projective matrices; the documented singular-matrix fallback is retained.
- Pattern scans: no `TODO`/`FIXME`/`@warn`/debug output in `src/`; every
  `catch` converts conversion failures into `ArgumentError` or predicate
  `false` — no swallowed errors.
- Documentation coverage: all 462 `names(Diff3D)` bindings carry docstrings;
  `test/public_api.txt` inventory (461 exports) matches `names(Diff3D)`
  exactly.

## Local validation results — Julia 1.13.1, Windows x86_64

- `julia --project=. -e 'using Pkg; Pkg.test(test_args=ARGS)' --
  --shard={1..6}/6 --require-optimized`: all six shards pass;
  `allocation_assertions = true`, `opt_level = 2` in each report. Shard 4
  example: 10058/10058 in 336 s.
- `julia --project=. test/test_runner.jl`: 47 pass, 1 intentionally broken
  (shard partition + include-mapping checks).
- `python test/test_check_shards.py`: 3 pass.
- `test/public_contract.jl` standalone: all six contract testsets pass.

Browser/platform matrices, the pinned three.js comparison, and the
installed-consumer checks are run by the release-validation workflow
(`.github/workflows/release-validation.yml`) on the candidate commit; per the
1.0 plan, local Playwright runs are not authoritative.

## Registration

Minor release over 1.0.0: no `BREAKING` label applies. Registration follows
`release/1.0/publishing.md`: `@JuliaRegistrator register` on the verified
candidate commit with `release/1.1/release-notes.md` under a `Release notes:`
line, then the annotated `v1.1.0` tag on the same commit.

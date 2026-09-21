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

## R1/R2 — compatibility contract and executable documentation

The intended 1.x compatibility contract now describes public API ownership,
backend boundaries, numeric/AD types, mutation, concurrency, errors, asset
extensions and deprecation. The public inventory records 453 exported names.
Undefined `diff_render` and obsolete `param_injector!` references were corrected;
the four edited source files were checked for identical executable ASTs after
removing documentation and source locations.

All 18 tutorial blocks now execute in isolated Documenter example scopes. The
first strict build failed because the inverse example imported ForwardDiff
without declaring it directly in the docs environment. The dependency and its
compatibility range were added, the tracked docs manifest was resolved, and
`DOCUMENTER_DEPLOY=false julia --startup-file=no --project=docs docs/make.jl`
completed successfully on Julia 1.12.7 with `warnonly=false`, export documentation
checks and doctests enabled. This includes the tutorial's finite-difference
gradient comparison and inverse-loss reduction checks.

Installation wording, actual I/O support, shader boundaries and inverse-example
claims were corrected. Local logs: `/tmp/diff3d-1.0-docs-first.log`,
`/tmp/diff3d-1.0-docs-resolve.log`, `/tmp/diff3d-1.0-docs-second.log`, and
`/tmp/diff3d-1.0-ast-check.log`. Versioned deployment and final-candidate docs
validation remain separate release gates.

## R3 — geometry transform allocation repair

The minimum-version shard exposed 4,160 bytes for transforming the existing
custom-attribute fixture (limit: 4,096). An allocation profile traced temporary
tuple construction to `_transform_geometry_morphs!`. Giving `ntuple` the matrix's
fixed 16-element length as `Val(16)` reduced the measured fixture to 3,424 bytes
on Julia 1.10.12 and 3,344 bytes on Julia 1.12.7, without changing the result or
the allocation limit.

The canonical optimized unit 145 passed all 31 assertions on both versions.
`transformed_morph_targets.jl`, `deformation_normals.jl`, and
`tangent_handedness.jl` then passed 827, 112, and 387 assertions respectively on
both versions. Logs: `/tmp/diff3d-1.0-transform-fixed-{110,112}.log`; profiles and
before/after measurements: `/tmp/diff3d-1.0-transform-{profile,variant}-{110,112}.log`.

## R3 — malformed-image allocation guard

The previous truncated-HDR test measured the first decoder call and `Test`
error formatting together: the same input measured 21,600,080 bytes on its
first local call, then 2,480 bytes on each repeated call. The guard now warms
rejection with a different small image, measures the first large-image rejection
through the existing allocation helper, and checks the error outside that
window. Both original 2,000,000-byte limits are unchanged.

The canonical optimized unit 162 passed all 9 assertions on Julia 1.10.12 and
1.12.7. A runtime-only mutant moved the large HDR image allocation ahead of
payload validation: the corrected test rejected it at 25,167,392 bytes (8 pass,
1 expected failure). Logs: `/tmp/diff3d-1.0-loader-bounds-fixed-{110,112}.log`,
`/tmp/diff3d-1.0-loader-bounds-mutant.log`, and
`/tmp/diff3d-1.0-hdr-allocation-112.log`. No loader behavior or test budget changed.

## R3 — test result compatibility

CI on Julia 1.13.0 exposed a `TypeError` in the runner's use of Test's internal
`anynonpass` field: it is now a `UInt8` cache rather than a Boolean. The runner
now inspects failure/error counts from `Test.get_test_counts`, including its
Julia 1.10 tuple return form. Local checks passed 47 assertions on Julia 1.10.12
and 1.12.7, plus one deliberately broken fixture assertion used to check that
expected broken tests are distinct from failures. A nested failing subprocess
also leaves its report failed and executes the later test unit.

The Julia 1.13 standard-library source was checked against tag `v1.13.0`.
After installing Julia 1.13.0 locally, the same 47 assertions and deliberately
broken fixture also passed on that runtime (`/tmp/diff3d-1.0-runner-final-113.log`). Logs:
`/tmp/diff3d-1.0-runner-final-110.log`, `/tmp/diff3d-1.0-runner-counts-112.log`,
and `/tmp/diff3d-1.0-ci-aggregated-106016474433.log`.

## R4 — platform and browser validation infrastructure

The release workflow reuses the routine CI workflow with the full matrix:
36 optimized native jobs (two Julia versions, three operating systems, six
complete shards), plus all six example groups in each of three browser engines.
The coverage job requires six complete runtime/platform groups. Playwright is
pinned to 1.63.0 and launch/environment reporting is shared across browser tests.

On macOS 26.5.1/aarch64, all 14 gallery scenes and controls passed in Chromium
153.0.8010.12 (ANGLE SwiftShader), Firefox 155.0 (reported Apple M1 or similar),
and WebKit 26.6 (reported Apple GPU). The detailed Firefox and WebKit pixel suites
then failed their physical-texture availability assertion. The runtime currently
requires 17 fragment samplers plus an optional environment cube for that path;
this is being investigated without removing the assertion.

Python compilation, CLI argument checks, Ruby YAML parsing, and the three
coverage-validator test methods passed. Full platform/browser release results
remain pending. Logs: `/tmp/diff3d-1.0-browser-{chromium,firefox,webkit}-pilot.log`
and `/tmp/diff3d-1.0-browser-{firefox,webkit}-pixels.log`.

## R3 — exact WebGL integer serialization

The shared light/transform writers now format integer IDs into the numeric
buffer they already receive. Decimal bytes remain exact for signed integer
extrema and values beyond Float64's exact range. The 28-light fixture measured
18,848 bytes on Julia 1.10.12 (previously 26,240; unchanged limit 25,000) and
16,480 on Julia 1.12.7 (previously 21,856). Complete JSON matched the previous
writers byte for byte at 0, 7, 28, and 112 lights.

The canonical optimized WebGL unit passed 1,253 assertions on both versions,
including integer extrema, empty/short buffers, and a zero-allocation reused
buffer guard. Adjacent hierarchy, instance-batch, and atomic-export tests passed
18, 36, and 22 assertions respectively on both versions. Logs:
`/tmp/diff3d-1.0-web-integer-fixed-{110,112}.log`. Two initial comparison-script
runs stopped before measurement because its definition count omitted an
overload; the corrected scripts completed all checks above.

## R3 — CSG allocation repair

BSP clipping now skips empty branches, inversion reuses each node's polygon
vector, and split fragments allocate their initial storage in one step. Plane
classification, interpolation, operation frames and epsilon rules are unchanged.
The same box union/subtraction/intersection outputs matched the previous
implementation's complete position, normal, UV and index arrays.

On Julia 1.10.12, union/subtraction/intersection measured 101,696 / 91,200 /
80,688 bytes, down from 113,472 / 108,928 / 99,856. All three original limits
(105,000 / 102,000 / 95,000) passed. Julia 1.12.7 measured 69,216 / 60,704 /
55,792 bytes, down from 73,728 / 68,512 / 64,240.

Every existing top-level unit containing CSG work passed on both versions:
2,838 assertions, including degeneracy, reflected solids, widely differing
feature scales, stable UV interpolation, and the duplicate allocation guard.
Earlier partial optimizations still exceeded the union limit and were not
treated as passing. Logs: `/tmp/diff3d-1.0-csg-buffers-{110,112}.log`; the original
allocation profile is `/tmp/diff3d-1.0-csg-profile-110.log`.

## R7 — versioned documentation and publishing procedure

Documentation pushes from `main` now target `/dev/`; version tags produce
versioned pages and the stable alias. The workflow checks out tag history and
retains the built site. The previous deployment-history deletion step and
unconfigured SSH-key input were removed. A tag/package-version guard accepted
the main branch and matching 0.1.8 tag and rejected a mismatching 999.0.0 tag:
four assertions passed locally. The first scratch check incorrectly expected a
successful Julia `if` expression to return `nothing`; its assertion was corrected
without changing the production guard. Log:
`/tmp/diff3d-1.0-docs-tag-policy-fixed.log`.

`publishing.md` records the exact-commit registration/tag/docs/release sequence;
`migration.md` describes the public contract, corrected soft-render examples,
backend boundaries, and file/workspace ownership. The docs introduction no
longer describes Julia image arrays as row-major or claims an upstream three.js
CSG algorithm. YAML parsing and `git diff --check` passed. A strict build of these
documentation changes and final candidate/tag validation remain required.

## R5 — independent installed consumer

The bootstrap installs an immutable local Git commit through `Pkg.add` into a
fresh environment with Diff3D as its only direct dependency, then starts an
isolated Julia consumer process. It verifies the resolved revision/tree and
package-store source, imports a hand-authored glTF triangle, checks CPU pixels
and a PNG round trip, and exports a standalone browser page. An identifiable
three-parameter inverse-color problem checks gradients against an algebraic
derivative and independent central differences, then recovers the parameters
with both public forward- and reverse-AD Adam paths. Documented unsupported
glTF extensions and browser shader callbacks must fail explicitly.

The first run installed `9d4085e7740996990aff944ec4a671434ea8db1c`, tree
`b011f3341c812b3485b43e3bf27d9b861f86cef3`, on Julia 1.12.7/macOS arm64.
All 39 assertions passed. Maximum gradient error was
`1.1102230246251565e-16`; both optimizers reached MSE
`1.326912711409517e-20` and recovered `[0.2, 0.4, 0.6]` within `4e-10`.
Its exported triangle passed Chromium, Firefox and WebKit: center RGBA
`[51, 102, 153, 255]`, black opaque corner, no WebGL/page errors or remote
requests. Logs: `/tmp/diff3d-1.0-consumer-first.log`,
`/tmp/diff3d-1.0-consumer-first/consumer.toml`, and
`/tmp/diff3d-1.0-consumer-browser-{chromium,firefox,webkit}.log`.

The reusable workflow repeats installation on all three release operating
systems and both Julia versions, retains manifests/evidence/outputs, then
checks the installed export in all three browsers. The Windows load-path
separator follows Julia's platform rule. YAML parsing and Python compilation
passed; the platform matrix and exact candidate installation remain required.

## R3 — mapped standard lighting with ambient occlusion

The complete minimum-Julia shard also exposed an existing 4,096-byte pooled
rendering guard. Its 32-sphere standard-material/AO fixture measured 98,528
bytes. Allocation profiling and inferred-code inspection traced per-pixel
boxing to the generic filtered direct-light iterator. Extending the existing
built-in light dispatch to the filtered view removed allocations in both mapped
standard shading functions while preserving the generic custom-light path.

The canonical optimized pooled-render unit passed all 94 assertions on Julia
1.10.12, including its original pixel and allocation checks. Additional checks
passed 22 assertions for all built-in lights, custom lights, Float64/BigFloat
results and zero-allocation reused built-in shading, followed by 9 lighting
energy assertions. The new test initially compared whole BigFloat-containing
struct identity; it now compares the three numerical channels exactly. No
pixel tolerance or allocation budget changed. The same 94 + 22 + 9 assertions
also passed on Julia 1.12.7 (`/tmp/diff3d-1.0-standard-fixed-112.log`). Logs: `/tmp/diff3d-1.0-standard-fixed-110.log`,
`/tmp/diff3d-1.0-standard-direct-final-110.log`,
`/tmp/diff3d-1.0-standard-profile-110.log` and
`/tmp/diff3d-1.0-direct-light-variants-110.log`.

## R4 — full physical materials on 16-sampler contexts

Roughness, matcap and toon-gradient textures already shared texture unit 5,
but their shader declarations consumed three sampler uniforms. Those mutually
exclusive material families now use one sampler while retaining their own
texture transforms and color controls. The full shader requires 15 2D samplers
plus its environment cube, within the 16-fragment-sampler limit reported by
the tested Firefox and WebKit contexts.

Both complete pixel suites passed: all 65 fixtures / 72 configurations on each
engine, including disabled-ANGLE-instancing fallbacks and texture-storage/dirty
refresh checks. Fixture identities were checked against the script's complete
inventory. No pixel expectation or physical-texture availability assertion was
removed. Logs: `/tmp/diff3d-1.0-browser-{firefox,webkit}-samplers.log`.
The native optimized export unit passed all 1,253 assertions on Julia 1.10.12
(`/tmp/diff3d-1.0-web-samplers-native-110.log`). Chromium also completed every
one of the 72 configurations (`/tmp/diff3d-1.0-browser-chromium-samplers.log`). This is evidence for the tested
contexts, not a claim of support for every WebGL 1 device.

## R6 — reuse linked-program shader locations

The matched browser fixture exposed repeated uniform/attribute queries in the
per-object draw path. A diagnostic runtime variant changed only those queries
to per-program caches. For 128 separate triangles in Firefox, original/cached/
cached/original median frame-call times were 119 / 24 / 30 / 99 ms, with identical
first/final pixel hashes and the independent triangle oracle passing. These
measurements ran under concurrent system load and are diagnostic evidence,
not the final three.js comparison. Logs and raw samples:
`/tmp/diff3d-1.0-location-probe-fixed.log` and
`/tmp/diff3d-1.0-location-probe/measurements.json`.

The canonical runtime now caches locations by linked program in page-owned
WeakMaps, including inactive `null` uniforms and `-1` attributes. Each link
creates a new program. Mechanically undoing the lookup rewrite and removing
the two helpers reconstructs the previous shader/draw source exactly, including
its specialization templates. The 14 affected string assertions were updated
to the equivalent helper calls.

The native optimized export unit passed 1,253 assertions on Julia 1.10.12. All
72 pixel configurations passed again in Firefox and WebKit; Chromium passed the
stacked-camera, native/fallback instance and matcap pilot. New actual-GL checks
verify two programs with the same uniform names, inactive locations, correct
uniform values, and zero shader-location queries during warmed drawing.
Logs: `/tmp/diff3d-1.0-web-locations-native-110.log`,
`/tmp/diff3d-1.0-browser-location-{firefox,webkit}.log`, and
`/tmp/diff3d-1.0-browser-location-chromium-pilot.log`.

## R3/R7 — additional remote results

[The runner-compatibility revision](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35488434799)
completed every native shard on Julia 1.13.0 successfully. Its minimum-version
failures are the WebGL integer writer, CSG and standard/AO allocation guards
repaired in later commits; the failed run is retained as evidence. This older
revision is not the final release check.

Strict versioned documentation builds passed for
[`adc9f3d`](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490654471),
[`ea75e07`](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490709153), and
[`42e394c`](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490806027).
The first full platform/consumer release run was dispatched at `bb44801` as
[run 35490876994](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490876994).
Its later Windows failures are recorded below. The final candidate must pass
its own complete validation.

## R6 — pinned comparison harness

The harness pins three.js 0.186.0 and esbuild 0.28.2. JSON/TOML fixtures contain
identical checked Float64 values. The projection objective passed independent
loss/gradient expectations at 16/64/256/1,024 parameters for Diff3D reverse AD,
ForwardDiff and central differences, and three.js central differences: 16
method/size combinations. All four 16-parameter fits recovered the known depths.
Logs/results: `/tmp/diff3d-1.0-projection-{julia,node}-final-code.{log,toml,json}`
(Julia results use TOML; Node results use JSON).

The browser comparison passed all nine matched fixtures (static/instanced/
animated, 16/128/512 triangles) against independent pixels and actual draw
counts. Both engines reported the same GPU/vendor. Initial/final pixels matched
outside the declared subpixel edge ties, and neither engine allocated/deleted
GPU resources after its first frame. The final harness records 21 batches of
eight completed frames, after five warmup batches. Report:
`/tmp/diff3d-1.0-comparison-batched-check.json`.

The sequential runner retains commands, raw samples, input/output hashes and
failures, and reverses engine order on its second pass. Its dirty-checkout,
occupied-output and missing-executable rejection paths were exercised. Workflow
YAML and Python/JavaScript syntax checks passed. Complete two-pass measurements
on a clean candidate and the comparison workflow remain required. All local
prototype timings above were collected alongside other work and must not be
published as controlled release measurements or universal performance claims.

## R7 — 1.0.0 candidate metadata

`Project.toml` and the resolved tracked docs manifest now identify version
1.0.0. The README and compatibility page describe the 1.x contract without
claiming that pending release gates have passed. `CHANGELOG.md` and the migration
guide record the supported scope and accepted fixes. The matching-version docs
guard passed all four checks again against the installed 1.0.0 package:
`/tmp/diff3d-1.0-candidate-tag-policy.log`. The local Julia 1.12.7 public-contract
and atomic-export checks passed all 45 and 22 assertions respectively:
`/tmp/diff3d-1.0-candidate-contract.log`. Exact-commit release validation remains
required.

The exported-file permission wording is now explicitly about POSIX permission
bits. Julia's actual Windows `mktemp` implementation uses `GetTempFileNameW`,
while its POSIX path uses `mkstemp`; the earlier wording exceeded the platforms
on which owner-only mode bits had been verified. This changes documentation,
not export behavior.

The standalone three.js comparison artifacts now include the installed
package's complete MIT license verbatim, both in each HTML file and as a separate
artifact. All nine files were checked against that license; their executable
script contents are unchanged. The final comparison regenerates and measures
these complete artifacts. Package resolution, YAML/syntax checks and
`git diff --check` passed. No tag, registry submission or public release has
been created.

## R4 — Windows number formatting, checkout and report paths

The first full matrix exposed three Windows defects. Both installed-consumer
jobs failed at the exporter's unqualified `snprintf` lookup on Julia 1.10 and
1.13: [minimum Julia](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490876994/job/106025464075)
and [current Julia](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490876994/job/106025464103).
The [current-Julia first shard](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490876994/job/106025464137)
also failed three multiline source assertions in a CRLF checkout and uploaded
no shard report. Raw logs are retained as
`/tmp/diff3d-1.0-release-windows-{job-id}.log`.

**VERIFIED:** Bash removes the backslashes from the workflow's unquoted Windows
report path. Quoting the argument preserves it exactly. The workflow now quotes
that path and still requires the report artifact. `*.jl text eol=lf` preserves
the source assertions and the byte-identical suite digest required across
platforms. A fresh Git checkout simulation with `core.autocrlf=true` changed all
221 Julia files to CRLF before this rule; with it all 221 matched the source
bytes. Log: `/tmp/diff3d-1.0-windows-checkout-probe.log`.

Both numeric writers now use the existing Printf dependency's buffer method,
whose implementations were inspected in Julia 1.10, 1.12 and 1.13. Integer IDs
remain integers; finite numbers retain `%.17g`; caller-owned buffers are reused.
No platform fallback or allocating string conversion is added. An independent
macOS libc differential/round-trip probe passed 101,901 checks on each of Julia
1.10.12 and 1.13.0, including exponent boundaries, generated Float64 bit patterns,
integer extrema, tiny buffers and zero warmed allocations. Logs:
`/tmp/diff3d-1.0-portable-format-probe-{110,113}.log`.

The actual optimized WebGL export unit passed all 3,242 assertions on Julia
1.10.12, with its existing scene allocation budgets unchanged and 1,989 new
finite-number checks: `/tmp/diff3d-1.0-web-portable-native-110.{log,toml}`.
Workflow YAML, quoted-argument checks, coverage-validator tests and
`git diff --check` passed. Windows execution and the final complete release
matrix are still required; these local checks do not substitute for them.

## R6 — complete runner and observable timed gradients

The clean `f0d7b21` run completed all nine sequential commands and both engine
orders. Its 40 recorded file hashes were independently recomputed; all 32
numerical records and 18 matched browser cases passed. Each browser record has
21 samples of eight completed frames, with zero pixel mismatches outside the
declared edge ties. Raw directory:
`/tmp/diff3d-1.0-candidate-comparison-f0d7b21`; driver log has the same path plus
`.log`. This shared host had 10 logical CPUs and load averages of 28.93 at the
start and 24.42 at the end; the two orders show substantial timing variation.
These results must retain that qualification.

Review then found that the numerical loops discarded timed gradients after
checking the initial invocation. Both loops now consume and validate every
timed result after stopping its clock, and record the maximum error across
samples. This makes their actual outputs observable; it is not a claim that
compiler elimination occurred in the earlier run. Fixtures, derivative methods,
sample counts and timing boundaries remain the same.

All 16 method/size combinations passed the added checks, with the same errors
as their initial oracles: `/tmp/diff3d-1.0-projection-observed.{toml,json}`.
Wrong-length, wrong-value and nonfinite oracle inputs were also rejected.
For each language, a mutant corrupting only the first timed gradient passed the
previous harness and failed the corrected one, while preserving a failed result
record: `/tmp/diff3d-1.0-gradient-observability-mutants/check.log` and its adjacent
sources/results. The complete clean two-order run must be recollected with this
stronger check before final timing claims are published.

## R1/R6 — dependency compatibility and measurement provenance

A fresh environment installed the immutable `f0d7b21` source from GitHub with
ForwardDiff 0.10.39 on Julia 1.10.12. Eight existing AD/optimizer/gradient test
units passed 550 assertions, including their enabled allocation guards and
mixed forward/reverse scalar operations. This supplements the ForwardDiff 1.x
checks; it is a focused dependency-compatibility result, not another complete
platform matrix. Source tree: `3287a43e8dbd71e684f64c619c75db79d4e68846`.
Log: `/tmp/diff3d-1.0-forwarddiff-010-remote.log`; the adjacent environment
directory retains the resolved manifest.

The comparison now captures the exact resolved Julia Project/Manifest before
running and fails if either changes. Numerical reports identify the loaded
Diff3D and ForwardDiff versions and require Diff3D to come from the recorded
checkout; both passes compare those versions with the captured files. The
native provenance probe passed, a different installed source was rejected, and
an injected launch failure retained byte-identical environment files plus a
failed run record. Evidence: `/tmp/diff3d-1.0-projection-environment.toml`,
`/tmp/diff3d-1.0-wrong-package-environment.log` and
`/tmp/diff3d-1.0-comparison-environment-failure/`. Syntax and whitespace checks
passed. The final complete run will exercise the added provenance checks on
both measured passes.

## Complete recorded comparison and final contract review

The clean two-order run at `284eadd7b899661f4f1c78a0d55d4ede45ffa75c`
completed all nine commands, all 32 numerical method/size records and all 18
paired browser cases. All 42 raw-file hashes were recomputed successfully. Each
of the 43 archive members (including the run record) was checked byte-for-byte
against its original. [The report](comparison.md) publishes both orders,
median/95th-percentile times, startup, allocations, artifact sizes, accuracy and
unfavorable cases. The raw archive and derived statistics are committed under
`release/1.0/comparison/`; they do not depend on temporary files remaining present.

The numerical maximum timed-gradient error was `3.4723482769671854e-13`, and the
16-parameter recovery error was at most `4.99853491930935e-11`. Browser output
pairs had zero mismatches outside the specified edge ties. Reverse AD had lower
median cost than the explicit three.js finite-difference baseline at 1,024
parameters; three.js had lower browser-frame medians in 17 of 18 measurements.
The report includes the larger reverse-AD allocation and first-call compilation
costs. The shared host's one-minute load average was 23.52/19.08 at start/end on
10 logical CPUs, so these timings are qualified observations. The physical host
reported Apple M5; Julia's CPU target and Firefox's renderer reported different
strings, both retained without treating them as independent hardware detection.

Final source review at that revision traced the public contracts back through
the production diff, temporary-file/rename error paths, formatter buffer bounds,
filtered lighting dispatch, CSG input/storage ownership and per-program location
caches. Comparing the moved test suite against the starting `runtests.jl`
confirmed that the low-optimization respawn was removed, the original allocation
limits were retained, and the other existing assertion changes correspond to
warmup/error-measurement handling and the changed browser location/sampler source.
The review also checked shard failure aggregation/inventory, installed-package
isolation, comparison clocks/oracles and the versioned-docs guard. No additional
confirmed production defect emerged; this review does not replace the remaining
actual platform checks. Notes: `/tmp/diff3d-1.0-final-contract-review.md`.

The later-completing old Windows 1.10 shards 2, 3 and 5 in run `35490876994`
failed on the same missing `snprintf` symbol and resulting export assertions;
the report path also lost its Windows separators. Their inspected logs are
`/tmp/diff3d-1.0-release-windows-{106025464415,106025464345,106025464326}.log`.
These are pre-repair `bb44801` results, not results for the `f0d7b21` repair.
Actual repaired Windows checks and the complete final candidate matrix remain
required. No failed run has been deleted or relabelled as passing.

## Chromium subpixel precision oracle

**VERIFIED:** comparison job
[106030312701](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35492724064/job/106030312701)
at `16f043a` failed on the `static-128` initial pixel oracle. Current local
Chromium reproduced the same failure (`/tmp/diff3d-1.0-chromium-static128-reproduction.log`).
Complete captured Diff3D/three.js RGBA buffers were byte-identical, and both
contexts reported `SUBPIXEL_BITS = 4`. An independent scanline check found 23
non-edge disagreements with ideal continuous vertices, but zero after snapping
window vertices to the 1/16-pixel grid. The first disputed pixel is 0.008944 pixels
from its ideal edge, beyond the previous fixed 0.002 tolerance. The full buffers,
reported renderer and scanline check are retained under
`/tmp/diff3d-1.0-raster-precision-probe/` and
`/tmp/diff3d-1.0-raster-precision-{probe,check}.log`.
The [committed counterexample archive](comparison/2026-09-20-chromium-subpixel.tar.gz)
also retains both complete RGBA buffers, their hashes, context metadata, fixture
and scanline-check result.

The [OpenGL ES specification, table 6.18](https://registry.khronos.org/OpenGL/specs/es/2.0/es_full_spec_2.0.pdf)
permits this four-bit minimum; section 3.5.1 defines edge coverage. The canonical
comparison oracle now records the queried precision and bounds the edge band by
one subpixel step per coordinate, plus its existing Float32 transform allowance:
`0.002 + sqrt(2) * 2^(-SUBPIXEL_BITS)`. Geometry, timings, sample counts, colors,
all pixels outside that band, resource checks and both engine paths are unchanged.
The full captured buffers now pass with a 0.090388-pixel band; 1,220 of 65,536
pixels are classified as edge ties. This repair concerns the oracle, not a
rendering defect in either engine.

Six regression tests use a fixed measured 16×16 mask. They accept the four-bit
image, reject it under the narrower eight-bit contract, and reject invalid
precision, one-pixel shifts, wrong interior/background/edge colors, alpha
corruption, empty/full images and invalid buffer size. The tests and JavaScript
syntax check passed; the comparison workflow now runs these negative checks.
The complete local Chromium replay and exact candidate CI remain required.

The full Chromium replay subsequently finished successfully in both orders:
all 18 fixture pairs passed, with `[0, 0]` initial/final cross-engine mismatches
outside edge ties. Both engines reported four subpixel bits in all cases.
Fixture hashes were checked against the frozen `284eadd` input. Raw JSON and
logs are retained in the [replay archive](comparison/2026-09-20-chromium-replay.tar.gz)
(SHA-256 `578c748953c673f59f949750f8047bcd417495e0c6c9d0e0f79776deebada84a`).
Archive members were compared byte-for-byte with the completed outputs. The
first process records a dirty `284eadd` checkout containing the oracle repair;
the second records clean `c5114d9`. Both use the same frozen exported HTML.
This is accuracy replay evidence, not a new clean candidate timing report.

## R4 — non-power-of-two browser cube maps

**VERIFIED:** WebKit registry job
[106025464089](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35490876994/job/106025464089)
failed in the glTF loader example with `INVALID_VALUE` mip uploads. The example
creates a 12×12 cube with authored mipmaps. Instrumenting actual WebKit 26.6
uploads locally reproduced twelve errors: six 6×6 faces at level one and six
3×3 faces at level two. The canonical `makeCubeTexture` uploader attempted
these uploads before checking whether the base dimensions were powers of two.
A 3×3 cube also incorrectly reported maximum LOD one, despite using base-level
sampling. Raw probe: `/tmp/diff3d-1.0-portability-webkit-before.log`.

The uploader now applies its existing power-of-two predicate before authored
mip uploads, matching the 2D texture path. NPOT faces retain their base pixels
and report maximum LOD zero; POT generated/authored mipmaps remain supported.
No input data, example sizes, browser error checks or pixel tolerances changed.
The backend restriction is documented in the compatibility contract.

A browser regression checks real upload levels, all sampled output pixels,
maximum LOD, cached object reuse and GL errors for face sizes 1, 3, 4 and 12,
with and without authored mipmaps. It fails against the pre-repair export and
passes all eight configurations in Chromium 153, Firefox 155 and WebKit 26.6
on macOS arm64. The regenerated glTF/GLB example also passed its complete
WebKit controls/render smoke test (`cases=2`). Logs:
`/tmp/diff3d-1.0-cube-{chromium,firefox,webkit}-after.log` and
`/tmp/diff3d-1.0-gltf-cube-webkit-smoke.log`.

Two other Ubuntu failures remain under investigation: Firefox cannot create a
WebGL context in the current headless launch, and WebKit's UV0 baked comparison
reports maximum channel error four against its unchanged limit of three.
Local WebKit and Chromium/Metal report 23-bit mediump precision and pass that
UV comparison; this does not establish the Linux cause. A separate diagnostic
branch/run records Linux context-creation events and compares fragment precision
without changing main's acceptance workflow. No release gate is marked complete.

## R4/R5 — actual Windows consumer after formatter repair

**VERIFIED:** the Julia 1.10 Windows installed-consumer job
[106033831389](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35494065177/job/106033831389)
passed at `f0d7b21` using Julia 1.10.12 on NT/x86_64. Its downloaded report,
manifest and Git tree agree on version 1.0.0, revision
`f0d7b21de82b6bb9c48937942bafd52fbe2a65fc` and tree
`3287a43e8dbd71e684f64c619c75db79d4e68846`. The public acceptance-script hash,
PNG hash and exported HTML byte count were independently recomputed and match
its report. Maximum gradient error was `1.1102230246251565e-16`; forward and
reverse inverse fits ended at loss `1.3269127490142768e-20`.
Artifacts: `/tmp/diff3d-1.0-consumer-windows-f0d7b21/`. Remaining native Windows
shards and the final candidate's full consumer matrix are separate gates.

The NPOT repair also passed the existing optimized WebGL-export unit on Julia
1.10.12: `julia +1.10 --project=/tmp/diff3d-deep-debug-idzwWW/julia110-env
test/runtests.jl --shard=40/516 --require-optimized` completed with all 3,242
assertions and unchanged allocation limits. The generated runtime passed
`node --check`; the modified Python harness compiled without errors.

All six installed-consumer jobs in the same `f0d7b21` run subsequently passed:
Julia 1.10.12 and 1.13.0 on Linux/x86_64, Windows/x86_64 and macOS/aarch64.
Each report was checked against its downloaded manifest, exact Git tree,
acceptance-script hash, PNG hash and HTML length. Artifacts are retained in
`/tmp/diff3d-1.0-consumer-f0d7b21-all/`. These results verify the actual Windows
formatter repair in consumer workflows; they do not close later-candidate or
browser-export validation.

The complete local WebKit browser suite then passed all 72 configurations,
including the new cube upload/sampling check and all unchanged baked-image,
instancing-fallback, resource and shader-location checks. Log:
`/tmp/diff3d-1.0-cube-webkit-fixtures.log`.

## R4 — partial power-of-two cube mip chains

**VERIFIED:** at `4ca753f`, WebKit 26.6 sampling of a valid but incomplete
authored cube chain returned `[0, 0, 0, 255]` with no GL error. The recorded
probe (`/tmp/diff3d-1.0-cube-partial-chain-before.log`, replayed in
`/tmp/diff3d-1.0-cube-partial-chain-before-replay.log`) shows a 4×4 cube missing
its 1×1 level and an 8×8 cube missing its 1×1 level both sampling black, while
the same base cubes with no authored levels sample `[31, 63, 127, 255]`.
`makeCubeTexture` accepted the validated prefix and uploaded only those levels,
leaving the texture mipmap-incomplete under `LINEAR_MIPMAP_LINEAR` minification.

The uploader now generates the physical pyramid from the base before writing the
authored levels whenever the validated prefix is shorter than
`floor(log2(width))`. Authored pixels overwrite the generated prefix and the
reported maximum LOD still stops at the last authored level, so explicit
environment LOD is unchanged. Complete chains skip generation entirely; NPOT
cubes keep their just-verified base-only behavior. No serialized data, public
API or pixel tolerance changed. The backend rule is documented in the
compatibility contract.

The browser regression now covers face sizes 1, 3, 4, 8 and 12 with empty,
complete and partial chains, checking actual upload levels, maximum LOD, cached
object reuse, GL errors, high-bias sampling of the last physical level and
bias-one sampling of a supplied level. It fails against the frozen `4ca753f`
export (`/tmp/diff3d-1.0-cube-partial-regression-before.log`: the 4×4 partial
case reported all-black supplied and physical samples) and passes all fifteen
configurations in Chromium 153, Firefox 155 and WebKit 26.6 on macOS arm64.
Logs: `/tmp/diff3d-1.0-cube-partial-{chromium,firefox,webkit}-after.log`.
The same three-browser check was rerun on 2026-09-21 from an independently
created Playwright 1.63.0 environment against the current tree and printed
`CUBE_UPLOAD_AND_SAMPLING_OK` for each browser.

## R4 — Ubuntu Firefox WebGL context and WebKit fragment precision

Both Ubuntu browser failures recorded in the `c5114d9` release-validation run
[35497954369](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35497954369)
now have measured causes. The isolated diagnostic job
[106049101765](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35499683333/job/106049101765)
ran on Ubuntu 24.04 (`Linux-6.17.0-1022-azure-x86_64-with-glibc2.39`) and its
`firefox-context.log` and `webkit-precision.log` artifacts are the evidence
below.

**VERIFIED — Firefox needs an X display.** Headless Firefox 155.0 with no
display reported `created: false` and
`WebGL creation failed: * WebglAllowWindowsNativeGl:false restricts context
creation on this system. () * Exhausted GL driver options.
(FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS)`. Forcing the native-GL preference
produced the same failure through `tryNativeGL`. With an Xvfb display the same
build created a context in both headless and headful launches, reported renderer
`llvmpipe, or similar`, and read back the expected `[64, 128, 191, 255]` pixel
with GL error zero. This is a runner environment requirement, not a defect in
the export: macOS Firefox 155 passes the same suite without a display. The Linux
browser jobs now run Firefox under `xvfb-run --auto-servernum`; Chromium and
WebKit keep their existing headless launch, which the same diagnostic shows is
sufficient for them. The effect of this workflow change must be confirmed by the
candidate Ubuntu run.

**VERIFIED — the WebKit UV0 failure is a 10-bit `mediump` fragment precision.**
On the same runner, WebKit 26.6 reported `MEDIUM_FLOAT precision 10` — the
OpenGL ES minimum — while `HIGH_FLOAT` reported 23. Against the unchanged baked
comparison limit of three, the default-precision export measured maximum channel
error four on `gltf_texture_uv0` (22 pixels over the limit) and on
`gltf_texture_uv1` (9 pixels over); `gltf_texture_mirrored` measured three. The
identical fixtures with `highp` forced measured maximum channel error **one**
with zero pixels over the limit in all three cases. Local macOS WebKit and
Firefox report 23-bit `mediump` and never reproduced the failure, which is why
the earlier local probes could not establish this cause.

The exporter now selects its fragment precision from the context instead of
hard-coding `mediump`: `FRAGMENT_PRECISION` is `precision highp float;` when
`gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT).precision` is
positive and `precision mediump float;` otherwise. All seven exported fragment
shaders — `DFSH`, `PDFSH`, `FSH`, `FSH_EMISSIVE`, `CFSH`, `PFSH` and `SFSH` —
use it, and `FSH_EMISSIVE` keeps its `#extension` directive on the first line.
No shader body, uniform, sampler budget or pixel tolerance changed.

A browser regression checks the selection against the context's reported
formats, requires each of the seven shader sources to declare exactly the
selected qualifier, and confirms the declaration takes effect by adding a
uniform `2^-11` to `1.0` in a probe shader: a 10-bit mantissa discards it, a
wider one preserves it. It fails against any export that hard-codes `mediump` on
a `highp`-capable context. Local verification on macOS arm64: Chromium 153
reported `MEDIUM_FLOAT 10 / HIGH_FLOAT 23`, Firefox 155 and WebKit 26.6 reported
23 for both, and all three selected `precision highp float;` and read the
expected centre pixel with GL error zero. The complete 72-configuration browser
suite passed on WebKit 26.6 and Firefox 155 with the new shaders. The Ubuntu
result remains required from the candidate run.

## R1/R3/R4 — pinned Julia versions and current dependencies

The validation matrices previously used the floating `"1"` alias, which resolved
to whatever the latest stable Julia was on the day a job ran, so recorded results
could not be reproduced later. The optimized test matrix, the installed-consumer
matrix, the browser fixture generator and the documentation build now name
`1.10` (the minimum in `Project.toml`) and `1.13` (the current stable release)
explicitly; the comparison workflow already pinned `1.13.0`. The resulting
runtime/platform group count is unchanged, so `test/check_shards.py --groups`
keeps its existing values. `Project.toml` still declares `julia = "1.10"`, which
admits every 1.x release from 1.10 onward.

`"1"` already resolved to Julia 1.13.0 in the runs recorded above, so this change
pins what was measured rather than adding an untested runtime. Locally, the
canonical optimized WebGL export unit passed under
`julia +1.13 --project=. -e 'using Pkg; Pkg.test(test_args=ARGS)' --
--shard=40/515 --require-optimized` on Julia 1.13.0/macOS arm64, and the browser
fixture generator produced all 65 fixtures on the same version.

Every dependency resolves to its latest registered version. Checked against the
General registry after `Pkg.Registry.update()` on 2026-09-21: ColorTypes 0.12.1,
ForwardDiff 1.4.6, JpegTurbo 0.1.6 and, for the documentation environment,
Documenter 1.19.0. The declared `[compat]` entries already admitted each of
these. One transitive package is held below its latest release:
FixedPointNumbers resolves to 0.8.6 rather than 0.9.1. **VERIFIED** as an
upstream constraint, not a Diff3D one — the General registry's `Compat.toml`
records `FixedPointNumbers = "0.8"` for ColorTypes `0.12-0`, Colors `0.13-0` and
ImageCore `0.9-0`, and `"0.8.2-0.8"` for ColorVectorSpace `0.9.3-0`.
`ForwardDiff = "0.10, 1"` deliberately keeps the validated 0.10 lower bound; it
does not prevent the latest 1.x from resolving.

The tracked `docs/Manifest.toml` was re-resolved and updated on Julia 1.13.0, so
it records `julia_version = "1.13.0"` and the pinned documentation toolchain
agrees with it. The workflow action versions were raised to their current
majors — `actions/checkout@v7`, `actions/setup-python@v7`, `actions/setup-node@v7`,
`actions/upload-artifact@v7`, `actions/download-artifact@v8`,
`julia-actions/setup-julia@v3` and `julia-actions/cache@v3` — which also clears
the Node 20 deprecation warnings the earlier runs reported. Python pins moved to
3.14 and the comparison's Node pin to 26.9.0. These workflow changes are
unverified until the candidate run executes them.

## R8 — no machine-specific paths in the published tree

A registered package ships every tracked file, so a path from the machine that
produced a file is neither reproducible nor meaningful to a consumer.

**VERIFIED:** re-resolving the documentation environment with an absolute
`Pkg.develop` path rewrote the tracked `docs/Manifest.toml` entry for Diff3D
from `path = ".."` to `path = "/Users/<account>/…/Diff3D.jl"`. Re-developing by
the repository-relative `".."` restored it, and `docs/Project.toml` now declares
`[sources] Diff3D = {path = ".."}` so the documentation environment resolves
without any absolute path. A scan of the tree at that point found the remaining
offenders only in the superseded `284eadd` comparison record and its archive:
the comparison harness recorded each command's absolute `argv`, and
`projection.jl` recorded `package_source` as `realpath(pkgdir(Diff3D))`.

`benchmarks/threejs/run.py` now records commands through `portable_argument`,
which rewrites output-directory and repository prefixes to `<output>` and
`<repo>` and reduces any other absolute path to its program name, and refuses to
record a command if any argument is still absolute. The output directory is
substituted first because it can live inside the repository.
`projection.jl` records the checkout-relative package location instead; the
existing check that Diff3D was loaded from the recorded checkout is unchanged.
`benchmarks/threejs/test_run_record.py` passed all 6 cases, covering both
output-inside-repository and output-outside-repository layouts.

`test/check_no_local_paths.py` scans every tracked file, and every member of
every tracked `.tar.gz`, for home directories and per-machine temporary roots on
Linux, macOS and Windows. Its own tests (`test/test_check_no_local_paths.py`,
7 cases) check that portable text such as `path = ".."`, `<repo>`, `<output>`,
`/usr/bin/python3` and a generic `/tmp/diff3d-comparison` example is accepted,
that binary payloads are skipped, that untracked files are ignored and that both
a tracked file and an archive member are reported with their line numbers. Run
against the tree before the comparison was regenerated, the guard reported 70
paths, all in `release/1.0/comparison/2026-09-20-284eadd-run.json` and inside
`2026-09-20-284eadd.tar.gz` (`run.json`, `projection-diff3d-1.toml`,
`projection-diff3d-2.toml`). The other two committed archives were already
clean. The guard runs as its own CI job on every push and pull request.

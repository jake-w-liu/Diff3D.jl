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
8 cases) check that portable text such as `path = ".."`, `<repo>`, `<output>`,
`/usr/bin/python3` and a generic `/tmp/diff3d-comparison` example is accepted,
that binary payloads are skipped, that untracked files are ignored, that both
a tracked file and an archive member are reported with their line numbers, and
that the `SELF` exemption covers exactly the guard and its own tests while a
third file with identical contents is still reported. Run
against the tree before the comparison was regenerated, the guard reported 70
paths, all in `release/1.0/comparison/2026-09-20-284eadd-run.json` and inside
`2026-09-20-284eadd.tar.gz` (`run.json`, `projection-diff3d-1.toml`,
`projection-diff3d-2.toml`). The other two committed archives were already
clean. The guard runs as its own CI job on every push and pull request.

## R4 — Ubuntu WebKit UV precision closed; Firefox moves to macOS

**VERIFIED:** the candidate release validation
[35559707286](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35559707286)
at `017289a` passed every Ubuntu WebKit browser job, including shard 1/6, which
runs `test/browser_rendering.py` and contains the baked `gltf_texture_uv0` and
`gltf_texture_uv1` comparisons that failed before the `highp` change with a
maximum channel error of four against their unchanged limit of three. The same
run passed all six installed-consumer jobs — Linux, macOS and Windows on Julia
1.10.12 and 1.13.0 — the Chromium and WebKit installed exports, every Chromium
example shard, and the optimized test shards on all three operating systems for
both Julia versions.

Xvfb improved Ubuntu Firefox but did not make it reliable. In the same run
`xvfb-run --auto-servernum` ran with `xvfb` installed, and four of the six
Firefox example shards passed while shards 3/6 and 6/6 failed with
`Validation browser has no WebGL 1 context` on the first page they opened; the
installed-consumer Firefox export timed out waiting for the viewer's first frame.
A passing shard reported renderer `llvmpipe, or similar`, vendor `Mesa`,
`WebGL 1.0` and 32 fragment texture units, so the display and drivers were
present when it worked.

**VERIFIED:** the isolated diagnostic run
[35560737171](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35560737171)
(branch `diagnose/firefox-gl`) created a WebGL context in all three dependency
variants — `--with-deps firefox` alone, the same plus
`libgl1 libegl1 libglx-mesa0 libgl1-mesa-dri`, and the same plus WebKit's
dependency set. Each reported `DISPLAY=:99`, renderer `llvmpipe, or similar` and
the expected `[64, 128, 191, 255]` readback with GL error zero. A missing GL
library is therefore ruled out: the release job's Firefox failures are an
unreliable context in a job that has already run the full Julia example
generation, not a dependency gap.

Firefox browser validation and the installed-consumer Firefox export now run on
`macos-latest`, where Firefox uses the host GPU and needs no display server, and
the Xvfb workaround is removed. **Corrected:** the macOS runners have no GPU, and
Firefox there renders with Apple's software OpenGL renderer; see "the macOS
Firefox blank frame" below, which also moves Firefox back to Linux. Chromium and WebKit keep their Linux headless
jobs. The complete 72-configuration local browser suite passes on macOS
Firefox 155, so the engine is fully exercised; the compatibility contract and
the publication audit now state which platform validates which engine.

## R4 — exported fragment precision on every local engine

The new `verify_fragment_precision` regression was run against the current
export on macOS arm64 in all three engines. Each selected
`precision highp float;` and passed the shader-declaration and mantissa checks:
Chromium 153 reported `MEDIUM_FLOAT 10 / HIGH_FLOAT 23`, Firefox 155 and
WebKit 26.6 reported 23 for both. Chromium's 10-bit `mediump` shows that the
previous exports lost texture-coordinate precision on SwiftShader as well as on
Ubuntu WebKit. Run against a frozen pre-change export the regression fails
immediately, because `FRAGMENT_PRECISION` is undefined there; against an export
that defined it but hard-coded a qualifier, the per-shader declaration check is
what rejects it.

The complete 72-configuration browser suite passed on all three local engines —
Chromium 153, Firefox 155 and WebKit 26.6 — with the new shaders, each process
exiting zero. A further complete WebKit run with the regression wired into the
suite also passed all 72 configurations and printed
`BROWSER_FRAGMENT_PRECISION_OK precision highp float;` with both float formats
reporting 23 bits.

## R6 — final candidate comparisons

Two matched comparison runs were completed and published, replacing the
superseded `284eadd` record:

- **Linux / Chromium**, revision `017289a`, produced by the release validation's
  comparison job on a runner whose one-minute load average was 1.63 at the start
  and 3.63 at the end on 4 CPUs. Julia 1.13.0, ForwardDiff 1.4.6, Node 26.9.0,
  Chromium 153.0.8010.12 with the ANGLE/SwiftShader software renderer.
- **macOS / Firefox**, revision `8cec4f2`, run locally from a clean checkout.
  Julia 1.13.0, ForwardDiff 1.4.6, Node 26.5.0, Firefox 155.0 on an Apple GPU,
  with load 28.75 falling to 27.08 on 10 CPUs.

Both reported `status = passed` with 42 hashed raw files, all 32 numerical
records and all 18 browser pairs. Both measured a largest timed-gradient error
of `3.4723482769671854e-13` and recovered the known depths within
`4.99853491930935e-11`; both recorded zero cross-engine pixel mismatches outside
edge ties, four subpixel bits and the same 0.090388-pixel edge band. The two
runs produced byte-identical exported artifacts, and byte-identical Diff3D
first-frame buffers for the three 16-mesh fixtures across the Apple GPU and
SwiftShader. At 1,024 parameters the three.js central-difference baseline took
12.94x and 11.66x the Diff3D reverse-AD median on Linux and 4.95x and 11.61x on
macOS; three.js had the lower browser-frame median in all 18 measurements of
both runs, and was faster than Diff3D reverse AD at 64 parameters in every pass.
Unfavourable results are published alongside the favourable ones.

**VERIFIED:** every program that produced these measurements is unchanged
between those revisions and the final candidate. `git diff --name-status 017289a
HEAD -- src/ benchmarks/` reports exactly three entries: `benchmarks/threejs/README.md`
(prose), the added `benchmarks/threejs/summarize.py`, and the extended
`benchmarks/threejs/test_run_record.py`. The first is documentation; the second
only derives statistics from files a completed run already wrote; the third is a
unit test. Since `8cec4f2` the only change under `benchmarks/` is that README.
Nothing under `src/`, and no fixture generator, driver, harness or dependency pin
that a measurement executes, differs — so both comparison records remain valid
for this candidate. The later commits change workflows, documentation, evidence
and the browser harness only.

`benchmarks/threejs/summarize.py` derives each published statistics file from the
retained raw files. **VERIFIED:** re-deriving the superseded `284eadd` summary
from its archive reproduced the committed file exactly when nanoseconds are
scaled the way the original ad-hoc derivation scaled them; the committed script
divides instead, which is correctly rounded and differs by at most 2.2e-16
relative. `benchmarks/threejs/test_run_record.py` passed all 11 cases, covering
the portable-argument rewriting and the timing statistics.

The path guard initially reported its own pattern and its test fixtures, which
contain example paths as data. Those two files are now the only exemptions,
named explicitly in `SELF` and checked by a test that a third file with the same
contents is still reported. With the superseded archive replaced, the guard
reports no machine-specific paths in the published tree, and the Linux/Chromium
comparison artifact produced by CI was independently confirmed to contain none.

## R2/R4 — complete local checks on the candidate source

The full browser suite passed all 72 configurations in each of Chromium 153,
Firefox 155 and WebKit 26.6 on macOS arm64 with the `highp` shaders and both
cube-map repairs, each process exiting zero. Those three runs predate wiring the
`verify_fragment_precision` regression into the suite; it was exercised
separately against the same exports in all three engines, and a further complete
WebKit run with it wired in passed all 72 configurations as well.

`DOCUMENTER_DEPLOY=false julia +1.13 --startup-file=no --project=docs
docs/make.jl` completed with `DOCS_EXIT=0` on Julia 1.13.0, with `warnonly=false`,
doctests enabled and no error or warning lines in its output. It regenerated the
108-case example gallery, ran all 18 executable tutorials and recorded the
automatic inventory version `1.0.0` from `Project.toml`. The candidate's
Documentation workflow run repeats this build on the pushed source.

## R4 — macOS Firefox: two wall-clock assumptions, and the sweep's scope

The candidate validation run
[35562468487](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35562468487)
moved Firefox to macOS and produced two failures, both fixed-delay assumptions
in the harness rather than rendering defects.

**VERIFIED — the registered-example shard is a host-speed problem.** In the
standalone macOS smoke run
[35562194332](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35562194332)
Firefox 155 reported its environment, selected `precision highp float;` with both
float formats at 23 bits, and passed 71 of the 72 browser configurations in
36.1 minutes. The validation's `firefox, examples 4/6` shard reported
`BROWSER_ENVIRONMENT` and `BROWSER_WEBGL_OK` for seven examples, taking between
1.5 and 6 minutes each, then exceeded the smoke harness's fixed 120-second
selector wait on the eighth — Playwright's call log shows the canvas *resolved
to visible*, so the page was alive but its main thread could not service the
poll. Measured shard durations: Linux Firefox 5.9–10.5 min, Linux WebKit
6.4–9.3 min, macOS Firefox 30.5 min for 8 of 18 examples.

The registered-example sweep is an upstream-parity smoke check over the same
exported runtime, while `test/browser_rendering.py` is what actually exercises
per-engine behaviour — shaders, textures, cube maps, samplers, resource reuse.
Firefox therefore runs the full 72-configuration contract suite on macOS, and
the 108-example sweep runs in Chromium and WebKit on Linux, where a shard takes
minutes. No engine loses contract coverage and no assertion was relaxed.

**VERIFIED — the 72nd configuration failed on an undrawn buffer.** The macOS
smoke run failed `orbit_zoom_limits at 1024x800` with centre pixel `[3, 3, 3]`
while reporting the correct fitted distance of exactly 2200. The check reset the
case and then waited a fixed 300 ms before reading pixels, so on a host where one
frame takes longer than that it sampled a buffer that had not yet been drawn; the
correct distance shows the state reset had already applied. The wait now polls
presented frames — reading after `gl.finish()` and awaiting
`requestAnimationFrame` until the fitted view appears, bounded at 120 frames —
so a slow host is tolerated while a genuinely clipped view still fails. The
thresholds (`blue[2] > 200`, `max(blue[:2]) < 20`, exact distance) are unchanged.
The repaired fixture passes locally in Chromium 153, Firefox 155 and WebKit 26.6.

**VERIFIED — the installed-consumer export hit Playwright's 30-second default.**
`consumer / Installed export (firefox)` failed with
`Page.wait_for_function: Timeout 30000ms exceeded` on macOS. That call used
Playwright's default timeout while the other harnesses set 120 seconds
explicitly; the consumer check now sets the same 120-second default. Its pixel
and error assertions are unchanged.

## R8 — independent audit of the candidate, and the corrections it forced

An eight-dimension review of `39a59cc` ran 92 agents over the exporter change,
the workflows, the browser harness, the path guard, the comparison harness, every
published claim, registry packaging and the Julia 1.13 coverage. Each candidate
finding was then put to three independent verifiers instructed to refute it; 15
of 28 survived. The corrections they forced are recorded here because several
contradict statements this file previously made.

**Corrected — the `orbit_zoom_limits` root cause was stated too early.** This
file previously recorded as VERIFIED that the failure was an undrawn buffer
caused by the fixed 300 ms wait, and that polling presented frames repaired it.
The candidate run
[35565028839](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35565028839)
refutes that: with the frame-polling fix in place the same configuration failed
with `{'pixel': [3, 3, 3], 'frames': 120, 'error': 0, 'dist': 2200}`. The
`frames: 120` field proves the bound was exhausted with the centre pixel still at
the clear colour, so the wall-clock wait was at most a contributing factor and
not the cause. The earlier claim should not have been labelled VERIFIED before a
passing run existed. What is established: `[3, 3, 3]` is exactly the scene
background `Color3(0.01, 0.01, 0.01)`, `setCase` restores the camera correctly
(`dist` exactly 2200, pitch `asin(825/2200)`), and the same fixture passes in
Chromium 153, Firefox 155 and WebKit 26.6 locally. The check now reports the
viewer's full state on failure so the cause can be measured rather than inferred.

**Corrected — cancelled runs were reported as failures.** `native-coverage` used
`if: always()`, which GitHub evaluates as true for a cancelled run as well. A
cancelled run therefore still started that job, which downloaded no shard
artifacts and exited with
`ValueError: reports, a positive group count, and a revision are required`,
turning a cancelled run into a red failure; the `if: always()` upload steps
likewise emitted `if-no-files-found` errors on cancelled jobs. All four
conditions are now `${{ !cancelled() }}`, which keeps the intended behaviour of
still running when a shard genuinely fails. This is what produced the
"3 successful, 18 cancelled" check banner on the candidate commit.

**Corrected — cross-renderer determinism is not engine-specific.** The report
said the three 16-mesh Diff3D first-frame buffers were byte-identical across the
Apple GPU and SwiftShader while "all nine three.js buffers" differed. Hashing the
committed summaries shows three.js is byte-identical on exactly the same three
fixtures, so this is a property of the small fixtures, not of either engine.

**Corrected — three quantitative slips.** The published macOS load averages were
28.72/27.06 against 28.74951171875/27.08056640625 in the committed run record;
they now read 28.75/27.08. "Both runs agree exactly on accuracy" was too strong —
the worst-case figures agree exactly, but 22 per-record losses and 6 gradient
errors differ between the runs; the wording now says so. The path guard's test
file was described as 7 cases when it has 8, and the description omitted the
`SELF` exemption test.

**Checked and dismissed.** One surviving finding claimed each comparison archive
holds 86 members, half of them macOS AppleDouble `._*` sidecars. Direct
inspection refutes it: `tar tzf` reports exactly 43 members for each of the two
comparison archives and `grep -c '\._'` reports zero. The published "43 files"
counts are correct.

## R4/R8 — the intermittent macOS Firefox orbit failure, and what it does and does not establish

Candidate `b002186` failed `platforms / Browser validation (firefox, examples 1/6)`
in Release validation
[35604405469](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35604405469)
(job 106347900109) at the restored-after-zoom orbit check. The whole 678x424 frame
read the scene background `[3, 3, 3]`, `gl.getError()` was 0, the camera state was
correct, and the 120-frame poll bound was exhausted.

**VERIFIED — the failure is intermittent at one revision, so no single green run can
validate a fix for it.** The same source `b002186` passed that job in CI run
[35595532823](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35595532823)
(job 106319335965, `BROWSER_RENDERING_OK orbit_zoom_limits instancing=True`) and
failed it in 35604405469 (job 106347900109).

**Corrected — the dead-render-loop diagnosis was never established.** This file
previously recorded that `render()` re-armed `requestAnimationFrame` only on its
success path, so one uncaught exception ended rendering and left the canvas at the
colour of the frame's opening `gl.clear()`. That defect is real and is now fixed,
but it was never shown to be this failure's cause. No browser error was captured
from any failing run, and an instrumented experiment reproduced the identical
signature with the loop *alive*: forcing `drawSceneView`'s
`vp[2]<=0||vp[3]<=0` early return returned `{'blue': 0, 'pixel': [3,3,3],
'frames': 120, 'error': 0, 'canvas': [678,424], 'contextLost': false,
'stats': '0 draw items', 'renderFrames': 200, 'rafErrors': 0,
'dist': 2241.6131964122023, 'draws': 1, 'objects': 1}` — every field matching the
recorded failure, including the orbit distance to thirteen significant figures,
with no thrown frame at all.

**VERIFIED — that early return cannot occur in this fixture.** `resize()` clamps the
drawing buffer with `Math.max(1, Math.round(r.width*dpr))` on both axes, and
`fillCameraViews` gives a single non-array camera the viewport
`[0,0,canvas.width,canvas.height]`, so `vp[2]` and `vp[3]` are at least 1. The
experiment therefore shows that this signature does not identify a mechanism; it
does not show that this mechanism occurred.

**VERIFIED — the fixture does not reproduce locally.** Sixty consecutive runs of
`test/browser_rendering.py --browser firefox --only orbit_zoom_limits` against
unmodified `b002186` on macOS 26.5 arm64 with Firefox 155 all exited 0. **Corrected:**
this was not the runner's platform class. This machine is an Apple M5 and Firefox
drew on its GPU; the runner has no GPU and Firefox drew with Apple's software
renderer. Both report the sanitised string "Apple M1, or similar". The local failure rate for this fixture
in isolation is therefore below one in sixty.

**Hypothesis (untested) — what remains.** With the degenerate-viewport return
excluded and no exception captured, a background-only frame requires one of: a frame
that threw, a frame whose visibility filter selected nothing, or a draw that
rasterised nothing. `activeDrawItemCount()` reported 1, but it re-runs the filter at
probe time instead of recording the frame, so it cannot separate them. **Decisive
test:** the orbit probe now records the viewer's own completed-frame counter, its
last frame error, whether the loop stopped, whether the context was lost, and the
`stats` text `render()` last wrote. `renderedDelta == 0` with `lastRenderError` set
is a thrown frame; `renderedDelta > 0` with `0 draw items` is a frame that drew
nothing; `renderedDelta > 0` with `1 draw items` is a draw that rasterised nothing.
The next occurrence records which, without another round trip.

**The source change.** `render()` re-arms the loop from a `finally` block, bounded by
`RENDER_FAILURE_LIMIT` consecutive failures so a viewer that fails every frame stops
rather than rethrowing and rewriting the DOM at frame rate; one successful frame
resets the count. Start-up wraps `setCase` so a throw there still starts the loop.
`__diff3dDebug` gained `renderedFrames`, `lastRenderError`, `renderStopped` and
`contextLost`.

**VERIFIED — the regression fails without the fix and passes with it.**
`verify_render_loop_recovery` injects one thrown frame through every draw entry
point, including the cached `ANGLE_instanced_arrays` object, then requires the loop
to advance at least three further frames, to report the error rather than swallow it,
and to restore the same centre block; it then injects a permanently throwing frame
and requires the loop to stop and stay stopped. Against a control viewer carrying the
same instrumentation but the previous success-path-only re-arm, it fails with
`Render loop did not survive one thrown frame: {'advanced': 0, 'stopped': False,
'lastError': 'injected render fault', 'lost': False}, errors ['injected render
fault']`. Against the candidate it prints `BROWSER_RENDER_RECOVERY_OK` in Firefox
155, Chromium 153 and WebKit 26.6, and the complete 72-configuration suite passes in
all three engines locally, each process exiting zero.

The `statsAfterFrame` probe added while diagnosing this was removed. Its comment
claimed that a change in the stats text across one frame proves the loop is alive;
`render()` writes `${drawn} draw items`, a pure function of the draw count, so on
this single-object fixture a healthy loop rewrites the identical string every frame
and the field could never discriminate anything.

## R1 — the declared ForwardDiff floor, re-checked on the candidate

`Project.toml` declares `ForwardDiff = "0.10, 1"`, and no CI job resolves the lower
bound: every matrix entry takes the 1.x release. The earlier 0.10 result in this file
was collected at `f0d7b21`, several source changes back, so it no longer covered the
candidate.

**VERIFIED — the 0.10 floor passes on the candidate source.** A separate environment
resolved `ForwardDiff v0.10.39` against the working tree (`Diff3D v1.0.0`,
Julia 1.13.0) and ran the AD, gradient and soft-differentiation units directly:

| Unit | Assertions |
|---|---|
| `forwarddiff_primal_branches` | 3 |
| `forwarddiff_validation` | 75 |
| `line_projection_gradients` | 24 |
| `mean_gradients` | 3 |
| `numerical_gradient_range` | 1 |
| `scaled_direction_gradients` | 203 |
| `triangle_gradients` | 8 |
| `soft_mixed_allocations` | 9 |
| `soft_scene_objects` | 37 |
| `soft_workspace_lifetimes` | 9 |

All ten units passed, 372 assertions in total, with their allocation guards enabled.
This is a focused dependency-compatibility result on the candidate, not a platform
matrix: the declared floor is exercised by this recorded run rather than by CI.

## R6 — both comparison passes re-run after the render-loop change

The render-loop change rewrites every exported viewer, so under this plan's rule the
published browser comparison stopped covering the candidate. Both passes were re-run
and republished.

**VERIFIED — the exported file changed and the rendered pixels did not.** The
`static-16` Diff3D first-frame buffer still hashes to
`482ffcd625d56300cc44b1ebb2e2ce3c5b8e4efcc781efc8982575172d54296b`, identical to the
superseded run, while the artifact hash moved from `70a547da...` to `6b8a2700...` and
its gzip size grew from 40,671 to 41,112 bytes. Three.js hashes to the same pixel
value on that fixture in both runs, which is why the report describes the
determinism as a property of the small fixtures rather than of either engine.

**VERIFIED — every accuracy result reproduced exactly.** Across both new runs: 32
numerical records and 18 browser pairs each, `status = passed`, 42 raw file hashes
verified, zero cross-engine pixel mismatches outside edge ties, a largest
timed-gradient absolute error of `3.47235e-13`, and all four methods recovering the
known 16-parameter depths within `4.99853e-11`. Those are the same worst cases the
superseded runs recorded. Warmed Julia allocation totals at 1,024 parameters are also
unchanged: 4,436,808 / 116,352 / 16,528 bytes on Linux and 4,481,488 / 124,528 /
16,512 on macOS.

**VERIFIED — the qualitative conclusions are unchanged.** Three.js keeps the lower
warmed frame median in all 18 measurements of each run, and Diff3D's gzip export is
smaller in all 18, with its uncompressed `dynamic-128`, `static-512` and `dynamic-512`
exports larger. Timings moved with host load, so the published ratios changed: at
1,024 parameters the three.js central-difference baseline now takes 12.6x and 12.6x
as long as Diff3D reverse AD on the Linux runner and 18.3x and 19.3x on the macOS
host, which was more heavily loaded than before (one-minute load 44.29 rising to
48.12 on 10 CPUs, against 1.26 rising to 3.99 on the Linux runner's 4). Two ordering
claims moved with the numbers and were corrected: Diff3D reverse AD now has the
lowest median at 256 parameters on both hosts rather than only on Linux, and three.js
central differences also beat Diff3D reverse AD at 16 parameters in the Linux first
pass.

**VERIFIED — the published numbers are reproducible from the committed files.**
Extracting each committed archive and re-running `benchmarks/threejs/summarize.py`
over it reproduces the committed summary byte-for-byte, and all 52 table rows in the
report are generated verbatim from those committed summaries. The superseded
`017289a` and `8cec4f2` artifacts were removed, since nothing references them.

- Linux/Chromium `3fee531`, from the `comparison / compare` job of Release validation
  [35678519977](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35678519977),
  archive SHA-256 `cacdf458e56f95dd8c7f0406482b0271412b41d8a945a6d3e77da3043c322f77`.
- macOS/Firefox `0dddaff`, run locally on a clean checkout, archive SHA-256
  `53d99d935d3c4008058d907484d66ebdb4c77751491fd6d965eb685d76af7042`.

## R4 — the instrumented failure, and what it rules out

Release validation
[35678519977](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35678519977)
on `3fee531` reproduced the failure with the new probe in place (job 106590098572,
57 of 61 jobs green at the time of reading, the sole failure being
`platforms / Browser validation (firefox, examples 1/6)`). The recorded state:

```
'stats': '1 draw items', 'renderedFrames': 278, 'renderedDelta': 120,
'renderStopped': False, 'lastRenderError': None, 'contextLost': False,
'error': 0, browser errors []
'pixel': [3,3,3], 'census': {'topColours': [['3,3,3', 287472]]},
'dist': 2200, 'atLoad': {'blue': 0, 'frames': 120, 'dist': 2200}
```

**VERIFIED — the render loop was alive and nothing threw.** `renderedDelta` is 120:
the viewer completed a frame for every one of the 120 frames the probe waited, the
failure counter never advanced, no frame error was recorded, the context was not
lost, and the page collected no errors at all. The dead-render-loop mechanism this
file previously recorded as the cause is therefore refuted for this failure, not
merely unproven. The bounded re-arm remains correct hardening for a real defect, but
it is not the fix for this.

**VERIFIED — the frame drew, and the draw rasterised nothing.** `stats` reads
`1 draw items`, so `render()` reached its end having submitted the fixture's single
object, and `draw()` issues `gl.drawElements` unconditionally. The canvas is
nevertheless the background colour over all 287,472 pixels with `gl.getError()` at 0.

**VERIFIED — the zoom sequence is not involved.** `atLoad` records the view before
any reset, and it is already blank with the fitted distance correct at exactly 2200.
This failure occurred at the first orbit check, whereas the `b002186` failure passed
that check and failed only after zooming. The common element is a blank frame from a
healthy loop, not the wheel sequence.

Seventy-one fixtures passed in the same browser process before this one, each on its
own page. **Corrected:** that does not show the driver rendered correctly; it
drops clipped triangles, and this is the only fixture whose every triangle has a
vertex behind the camera. The fixture
is the only one whose scene is 2,200 units across, with clip planes derived as
near 22 and far 143,000.

**Hypothesis (untested) — the remaining candidates.** A submitted `drawElements` that
rasterises nothing, with no GL error, is consistent with a zero or wrong element
count, an out-of-range offset, a program that is bound but not usable, a degenerate
or out-of-frustum transform, or a driver-level fault on that host. **Decisive test:**
`__diff3dDebug.frameDiagnostics()` now captures, only when a frame comes back blank,
the drawing-buffer and canvas sizes, framebuffer binding, viewport, scissor box and
enable, depth test/func/range/mask, colour mask, cull enable/mode/front face, blend,
the view and projection matrices with a finiteness check, the link status of every
program, and each object's mode, element count, index type, draw offset, instance
count, buffer presence, side, visibility and matrix finiteness. The healthy baseline
for this fixture, measured locally in Firefox 155, is `count` 6, `indexType` 5123,
`offset` 0, all four programs linked, cull disabled, `depthFunc` 513, `depthRange`
[0,1], viewport `[0,0,678,424]`, all matrices finite and `error` 0. The next
occurrence reports the same fields, and any divergence from that baseline names the
mechanism.

## R4/R8 — the macOS Firefox blank frame: Apple's software rasteriser

**VERIFIED — the macOS runners have no GPU, and Firefox renders there with Apple's
software OpenGL renderer.** On the `macos-26-arm64` runner `system_profiler
SPDisplaysDataType` prints nothing, and Firefox 155 with
`webgl.sanitize-unmasked-renderer` off reports renderer `Apple Software Renderer`,
vendor `Apple Inc.` Run [35814164935](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35814164935),
branch `diag/blank-frame-ladder`. With sanitising left on, as in every earlier run,
Firefox reports "Apple M1, or similar" there, and also on the Apple M5 used for the
local runs, so the two environments were never shown to be the same.

**VERIFIED — every triangle of this fixture needs clipping.** The plane's indices are
`[0,3,1, 0,2,3]`, and corner 3 is behind the camera in both checked views: clip
w = -398.02 at the fitted distance 2200 and -356.41 at the restored distance
2241.613 (read back from the failing runs' uniforms).

**VERIFIED — the draw is correct and the rasteriser drops it.** A diagnostic redraw
ladder replayed the real frame at each CI failure with one factor changed per rung.
It recorded nine failures, seven from twelve isolated runs of the fixture and two
from full suites. In eight, every rung rasterised nothing: the replay, the
non-instanced path, a fresh identity instance buffer, fresh vertex and index
buffers, a freshly linked copy of the mesh program, and the real vertex shader with
a flat fragment shader. Minimal instanced controls filled the canvas in all nine. In
the ninth, the fresh-buffer rung and then the replay with the original buffers drew
the whole plane after the earlier rungs had drawn nothing, so the same commands
both fail and succeed in one context. The isolated runs fail 7 of 12,
so suite order is not involved.

**VERIFIED — Apple's renderer drops these triangles without any browser.** A C program
drew the plane's clip-space corners through CGL into an offscreen framebuffer, 50
times per case:

| Case | Apple M5 (`2.1 Metal - 90.5`) | Apple Software Renderer (`2.1 APPLE-23.1.1`) |
|---|---|---|
| Triangle (0,3,1) | 106,169 px every draw | 106,170 px every draw |
| Triangle (0,2,3) | 93,567 px every draw | 0 px every draw |
| Both | 199,736 px every draw | 106,170 px every draw |
| Control, all w > 0 | 56,000 px every draw | 0 to 19,727 px |

Firefox with `webgl.forbid-hardware` on the M5 selects the same renderer and
reproduces the losses with a minimal WebGL page.

**VERIFIED — three.js loses the same scene.** Three.js 0.186.0 with the fixture's plane,
material, 45° camera and exact eye `(1654.287, 840.605, 1257.596)` draws 199,481 blue
pixels on the M5 and 85,138 on Apple's software renderer in each of ten runs. At the
fitted distance both engines draw exactly 200,332 pixels on the M5.

**VERIFIED — Mesa llvmpipe rasterises the same triangles correctly.** On
`ubuntu-latest`, Firefox 155 under Xvfb reports `llvmpipe (LLVM 20.1.2, 256 bits)` and
draws the failing plane, the fitted plane and the all-positive control at 199,479,
200,074 and 55,484 pixels — the counts Firefox gives on the M5 — in each of 10 draws
on each of five runners, and those five passed all 72 rendering configurations
(run [35825717039](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35825717039)).
The sixth runner's Firefox had no WebGL context.

**VERIFIED — a Firefox launch under Xvfb occasionally has no WebGL context, and a
relaunch recovers.** Across 323 measured launches
([35825717039](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35825717039),
[35826296834](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35826296834),
[35826621965](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35826621965)), four
instances could not create any context, reporting `Exhausted GL driver options
(FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS)`; a second context in the same instance
failed too, and each of the three relaunches that followed a failure succeeded. A
24-bit screen did not prevent it; with a fresh server per launch, 1 of 90 immediate
launches and 0 of 90 launches after a three-second wait failed, too few to separate
the two. The earlier "four of six shards" failures had the same signature — no
context on the first page opened — but recorded no reason.

**VERIFIED — the arrangement passes the full platform matrix.** CI run
[35827796217](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35827796217) on
`338771c` passed all 56 jobs. Linux Firefox (`llvmpipe (LLVM 20.1.2, 256 bits)`) passed
all 72 rendering configurations, `orbit_zoom_limits` included, and smoked all 108
registered examples across its six shards. Three of those six jobs relaunched Firefox
once, each time on the first launch in the job with the same `Exhausted GL driver
options` reason, and each relaunch created a context; over all measurements that is 7
failed launches in 333, with all six relaunches that followed a failure recovering.
**Hypothesis (untested):** the first GL use in a job is slow enough on a cold Mesa
shader cache that Firefox's start-up GL probe gives up; timing Firefox's GL start-up
with and without a warm cache would settle it.

**The change.** Every engine now validates on Linux; Firefox runs under
`xvfb-run --auto-servernum`, and the registered-example sweep runs in all three
engines. `launch_browser` asks Firefox for its unsanitised renderer, creates a WebGL
context in every new instance, and relaunches an instance that cannot, at most three
times, printing the browser's reason each time. `report_browser_environment` refuses
`Apple Software Renderer`. The viewer itself is unchanged by this: the fault was in
the rasteriser, and three.js is affected the same way.

The earlier sections of this file record the render-loop, GL-state, cache and
uniform hypotheses that were eliminated on the way. The bounded frame re-arm stays:
it fixes a real defect, but it was not this failure's cause.

## R4/R8 — chromium examples 4/6 starved by the periodic GL error drain; fixed on `3eb2300`

The robustness adoption on `0eb886c` passed 65 of 66 release-validation jobs and
19 of 20 standard-CI jobs; both runs failed only in `Browser validation
(chromium, examples 4/6)`.

**VERIFIED — the failure was main-thread starvation, not a rendering error.** The
release-validation job
([35937540492](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35937540492))
died on `Locator.focus: Timeout 120000ms exceeded` while smoking
`webgl_buffergeometry_instancing_billboards.html`; the standard-CI job
([35937519319](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35937519319))
hit the smoke's 5400 s cap with the same example still running at 42.7 min. The
identical shard passed under Firefox on Mesa llvmpipe in ~5.5 min, and all
517 optimised test units passed on every OS and Julia version.

**VERIFIED — `gl.getError()` is a full pipeline synchronisation.** The viewer
drains the GL error queue itself once per rendered-frame second
(`checkGlErrors("frame")`). Measured locally under headless Chromium/SwiftShader
via CDP on the failing example: a single `drainGlErrors()` call blocked the main
thread for **266.8 s**, waiting for the entire queued command backlog. With
frames longer than 1 s the once-per-second drain fires on every frame, so the
main thread lived inside multi-minute stalls — matching the `focus()` starvation
on CI. The same page without drains stayed responsive (~1 ms eval round-trips).

**VERIFIED — the fix restores responsiveness while preserving error pickup.**
`3eb2300` drains only after a `render()` call that returned within 250 ms — a
command queue that accepts a frame without backpressure is shallow — and backs
the next interval off by 20× the measured drain cost; explicit `drainGlErrors()`
calls are unaffected. Measured on the same heavy fixture: 0 self-drains in a
20 s window with a free main thread; on a light fixture the drain kept its ~1 s
cadence (3 self-drains in 12 s), so the harness's ≤10 s error-pickup check is
preserved.

**VERIFIED — the candidate is green end to end.** On `3eb2300`: standard CI run
[35947389004](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35947389004)
passed 20/20 jobs; release-validation run
[35947427671](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35947427671)
passed 66/66 — 36 optimised test shards (Linux/macOS/Windows × Julia 1.10/1.13),
18 browser shards (Chromium/Firefox/WebKit × 6), 6 installed-consumer jobs,
3 installed-export browser jobs, the three.js comparison, and tree hygiene; the
documentation run
[35947389008](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35947389008)
passed. In the previously failing shard, `instancing_billboards` completed in
~28.6 min (vs 42.7 min and death on the failed candidate; 14.3 min before the
robustness patch — the residual delta is the legitimate per-frame cost of the
new state machinery on a software rasteriser, not starvation), and the shard
finished ~72 min, inside the 90-min smoke cap.

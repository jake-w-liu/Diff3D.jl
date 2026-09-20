# Diff3D 1.0 release plan

This is the work tracker for the 1.0 release. A gate is complete only when its
acceptance checks have passed on the recorded source revision. Commands, raw
measurements, failures, and resulting fixes belong in `release/1.0/evidence.md`.

## Scope and baseline

The release establishes a stable Julia graphics and differentiable-rendering
API, with documented CPU, soft-rendering, and standalone WebGL-export behavior.
Existing documented functionality stays supported. Backend differences and
unsupported asset extensions must be explicit. Full three.js equivalence is not
the release contract.

The starting revision is `87debdbe65fe768ec3f8e7ed1c3ca6d9645ff5c1`. Its
[CI](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35451658109) and
[documentation](https://github.com/jake-w-liu/Diff3D.jl/actions/runs/35451658107)
passed after the preceding correctness/allocation audit. General's registered
0.1.8 uses the earlier `07de039d7267a594fe1049c3fde01bb4c200e5c8` revision.
These baseline results do not substitute for validation of the release changes.

## Gates

| ID | Work and acceptance criteria | Status | Evidence |
|---|---|---|---|
| R1 | Publish the compatibility contract: public names and documented signatures, supported backends and numeric/AD inputs, mutation and buffer ownership, concurrency, errors, extension points, and deprecation rules. Exercise the contract through public APIs. | In progress | Contract published; 453-name inventory and 45 public assertions passed locally; candidate consumer checks remain |
| R2 | Correct public documentation, examples, and installation instructions; execute consumer-facing examples; build strict docs with no stale API references. | In progress | Strict local docs build passed all 18 executable tutorials; final candidate build remains |
| R3 | Make the complete optimized test/allocation coverage reproducible without lowering budgets or dropping cases. Keep focused development checks and run the required release suite under the normal compiler. | In progress | Complete shard inventory and runner checks passed; full optimized CI remains required |
| R4 | Verify the supported Julia versions on Linux, macOS, and Windows; exercise browser export on Chromium, Firefox, and WebKit. Preserve numerical, resource-lifetime, concurrency, and example checks. Record the tested architectures and browser/GPU environments. | In progress | Full release matrix prepared; local gallery passed all three engines; sampler repair passed all Firefox/WebKit pixel cases; Chromium check is in progress |
| R5 | Add independent consumer acceptance workflows: clean package installation, asset import and render/export, and an inverse problem using public APIs. Check outputs/gradients against independent expectations and test documented unsupported-input failures. | In progress | Fresh Git installation passed 39 public assertions on Julia 1.12.7 and its export passed all three browsers; release platform/candidate checks remain |
| R6 | Run pinned, reproducible comparisons with three.js. Validate matching inputs and output accuracy before timing; publish raw timing/memory/size results, environment details, advantages, and limitations. Repair confirmed relevant bottlenecks and rerun affected comparisons. | In progress | three.js 0.186.0 and esbuild 0.28.2 pinned; matched projection-gradient prototypes pass their oracles; controlled measurements and browser comparison remain |
| R7 | Prepare versioned docs, tag/release and registry procedures, release notes, and migration guidance. Verify the workflow on a release candidate and confirm that the release source includes every accepted fix. | In progress | Versioned docs policy and publishing/migration procedures committed; tag/version guard passed; release notes and candidate/tag validation remain |
| R8 | Review the final diff and contract independently of the implementation route; pass all required gates on the exact candidate revision; produce the reviewable version/tag/registration payload and final evidence report. | Pending | — |

Work proceeds in this order: contract and docs; test/CI infrastructure; consumer
acceptance and comparisons; fixes supported by those results; candidate release
and final verification. Each coherent, verified change is committed and pushed
to `main`. A later source change invalidates affected evidence until rechecked.

## Comparison protocol

- Pin three.js and all comparison dependencies. Record the Diff3D revision,
  operating system, CPU, Julia/Node/browser versions, thread counts, actual GPU
  renderer, and whether rendering uses software or hardware.
- Compare browser rendering with the same geometry, transforms, cameras,
  materials supported by both engines, resolution, color pipeline, antialiasing,
  and synchronization policy. Validate pixels and actual scene/draw counts.
  Include static, instanced, and changing scenes at multiple sizes.
- Measure startup/first output separately from warmed frames. Keep raw samples;
  report distributions, allocation/peak memory where observable, artifact size,
  and resource reuse. Do not compare a CPU frame with an asynchronous GPU enqueue
  and label the ratio engine speed.
- Evaluate native differentiation on a matched numerical objective with accuracy
  and convergence checks. Compare Diff3D reverse/forward AD and finite differences
  with a three.js finite-difference baseline; identify the derivative method as
  part of every result. Additional custom derivative implementations must be
  identified explicitly. Different hard/soft objectives cannot support a speed
  ratio.
- Candidate advantages are Julia integration, native gradients, offline export,
  and allocation-efficient repeated numerical work. These are hypotheses until
  demonstrated. Include unfavorable results and unsupported features; no gate
  requires a predetermined winner or a universal superiority claim.

## Baseline findings to close

- The README permits public API changes and has stale registration wording.
- The public soft-render docs reference undefined `diff_render` and describe
  `param_injector!` where the implementation takes `setup_fn`.
- `Pkg.test()` respawns under `-O0 --compile=min`, disabling the monolithic
  suite's allocation guards. Optimized CI currently covers selected files.
- CI currently uses Ubuntu and Chromium; docs deploy `main` to `stable`.
- All 108 example registry entries are partial upstream matches. Browser export
  uses WebGL 1 and rejects `ShaderMaterial`; required Draco, Meshopt, and Basis
  glTF extensions are rejected. These supported-scope boundaries need one
  authoritative public description and consumer checks.

## Completion rule

Do not mark this plan or its persistent goal complete while a required gate is
pending, failed, or unverified. Do not treat a benchmark loss as a correctness
failure, or conceal one to claim an advantage. Release publication is performed
only with session authorization, after the exact candidate and its evidence are
reviewable. External registration/review delays must be reported as such.

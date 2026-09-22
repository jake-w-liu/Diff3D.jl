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
| R1 | Publish the compatibility contract: public names and documented signatures, supported backends and numeric/AD inputs, mutation and buffer ownership, concurrency, errors, extension points, and deprecation rules. Exercise the contract through public APIs. | In progress | Contract, 453-name inventory and public checks prepared; ForwardDiff 0.10.39 also passed 550 integration assertions. Final candidate consumer checks remain |
| R2 | Correct public documentation, examples, and installation instructions; execute consumer-facing examples; build strict docs with no stale API references. | In progress | Strict local docs build passed all 18 executable tutorials; final candidate build remains |
| R3 | Make the complete optimized test/allocation coverage reproducible without lowering budgets or dropping cases. Keep focused development checks and run the required release suite under the normal compiler. | In progress | Complete shard inventory and runner checks passed; full optimized CI remains required |
| R4 | Verify the supported Julia versions on Linux, macOS, and Windows; exercise browser export on Chromium, Firefox, and WebKit. Preserve numerical, resource-lifetime, concurrency, and example checks. Record the tested architectures and browser/GPU environments. | In progress | Optimized shards passed on all three operating systems for Julia 1.10 and 1.13. Cube uploads repaired for NPOT and partial mip chains. The `highp` change closed the Ubuntu WebKit UV failure, confirmed on the candidate. Xvfb raised Ubuntu Firefox to four of six shards but not to reliability, and a diagnostic ruled out missing GL libraries, so Firefox now validates on macOS, where `orbit_zoom_limits` then failed intermittently at one revision (passing and failing the same job at `b002186`). The viewer's frame loop no longer dies on a frame that raises and the retry is bounded, with a regression that fails against the previous re-arm; the intermittent failure's own mechanism is still unproven, and the probe now records the discriminating state. The final candidate matrix must confirm the arrangement on `3fee531` |
| R5 | Add independent consumer acceptance workflows: clean package installation, asset import and render/export, and an inverse problem using public APIs. Check outputs/gradients against independent expectations and test documented unsupported-input failures. | In progress | Fresh Git installation passed 39 public assertions on Julia 1.12.7 and its export passed all three browsers; release platform/candidate checks remain |
| R6 | Run pinned, reproducible comparisons with three.js. Validate matching inputs and output accuracy before timing; publish raw timing/memory/size results, environment details, advantages, and limitations. Repair confirmed relevant bottlenecks and rerun affected comparisons. | In progress | Both passes were re-run after the render-loop change and republished in [the report](release/1.0/comparison.md): Linux/Chromium at `3fee531` from CI and macOS/Firefox at `0dddaff` locally. Each passed all 32 numerical records and 18 browser pairs with zero mismatches outside edge ties, reproducing the previous worst timed-gradient error of 3.47e-13, the 5.00e-11 recovery bound and the byte-identical `static-16` pixel hash, so the change altered the exported file without altering a rendered pixel. Every published table row is derived from the committed summaries, which reproduce byte-for-byte from the committed raw archives. Awaiting the final candidate revision |
| R7 | Prepare versioned docs, tag/release and registry procedures, release notes, and migration guidance. Verify the workflow on a release candidate and confirm that the release source includes every accepted fix. | In progress | Version 1.0.0 metadata, changelog, versioned docs and publishing/migration procedures prepared; matching-version guard passed. The release notes now carry the breaking-change section that General's AutoMerge requires for a major bump, and publishing.md records that requirement. No tag or GitHub release exists yet; exact candidate/tag validation remains |
| R8 | Review the final diff and contract independently of the implementation route; pass all required gates on the exact candidate revision; produce the reviewable version/tag/registration payload and final evidence report. | In progress | Source/contract review completed. The CI guard rejecting machine-specific paths anywhere in the published tree, including inside the evidence archives, now passes on the whole tree. The dead-render-loop root cause recorded earlier is retracted as unproven and the evidence log now says so. Exact final candidate matrix, docs and release payload remain |

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
- Validation matrices used the floating `"1"` Julia alias, so a recorded result
  could not be reproduced once a newer stable Julia was released.
- Exported fragment shaders declared `mediump`, which WebGL 1 guarantees at only
  ten mantissa bits. Headless Linux Firefox cannot create a WebGL context at all,
  and remains unreliable with a display, so it is validated on macOS instead.
- Published files recorded absolute paths from the machine that produced them.
- Six example scripts wrote through `..` outside the package, which resolves into
  the depot for an installed copy; they now resolve `DIFF3D_EXAMPLE_ROOT` and fall
  back to a scratch directory when there is no development checkout.
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

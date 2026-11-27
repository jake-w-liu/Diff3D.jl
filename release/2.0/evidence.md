# Diff3D 2.0 release evidence

This file records observed results for the 2.0.0 candidate. A planned command
is not a passed check.

## How the audit was run

Every source file was audited against the three.js r186 sources in two rounds.
Round 1 split the package into 18 subsystems; round 2 took nine cross-subsystem
packages made of what round 1 could not reach from inside one file. Each
package was worked in its own git worktree and then reviewed by an independent
adversarial pass that re-derived each change from the three.js source, checked
that every new regression test fails on the old code, re-measured every
performance claim on Julia 1.10 and 1.13, and ran the full suite. Reference
values come from executing three.js itself under Node 26, and for the exported
viewer from headless Chromium, not from reading alone.

The 27 reviewed branches were merged in sequence. Integration found five
defects that no single branch could see, all fixed before release:

- `render_tiled!` called a depth helper that the rasterizer branch had renamed.
- A grazing mesh raycast at coordinates near 1e6 was lost to world-space
  rounding; mesh raycasts now intersect in object space as three.js does.
- Two branches rewrote the exported viewer's animation sampler on opposite
  sides (Julia mixer and JavaScript player); the player was reconciled with the
  stateful mixer and is differential-tested against it under Node.
- `_mat4_linear_max_scale` returned NaN for a zero-valued `Dual` under
  ForwardDiff 1.5, which changed which operand `max` returns on a tie.
- The WebGL export allocated a 64 KiB staging buffer per call, which pushed
  `save_webgl_html` past its allocation budget on Windows; the buffer is now
  reused per task with byte-identical output.

Two regression tests written by the audit were brittle and were corrected: one
compared forward- and reverse-mode gradients at an exact `min`/`max` tie, where
each mode may return a different one-sided derivative; one relied on the old
white sheen-color default.

## Local validation — macOS arm64, Apple M-series

Commit `bb4f22e` (the candidate before the staging-buffer fix):

- `julia --project=. test/runtests.jl --shard={1..6}/6 --require-optimized`:
  all six shards pass on Julia 1.13.1 and on Julia 1.10.12 with ForwardDiff
  1.5.0 — 166,847 assertions per Julia version, `allocation_assertions = true`
  in every report. The v1.1.1 baseline on the same machine was 41,218
  assertions.
- `julia --startup-file=no release/1.0/consumer_install.jl`: the package
  installed from the committed tree passes 39/39 independent consumer
  assertions.
- `julia --project=docs docs/make.jl`: the strict documentation build passes,
  including every executable tutorial and the check that all 683 exported
  names are documented.
- `python examples/verify_examples_registry.py --skip-browser`: all 108
  registered examples generate.
- All 66 pages from `test/browser_rendering.jl` load in headless Chromium
  (SwiftShader) with no console message at error level and no blank canvas;
  the extracted viewer script passes `node --check`.
- CPU against browser export, five pixels of a lit sphere at 400x400: Lambert
  and Phong identical, Standard dielectric within 2/255. A fully metallic
  sphere under ambient light differs by up to 47/255 because the CPU renderer
  keeps its own ambient model; the compatibility contract lists this.

Commit `ba22650` adds the staging-buffer fix: `test/audit3_webexport_data.jl`
passes on Julia 1.13.1 and 1.10.12, and the serialized bytes of a 14 MB scene
are identical before and after.

## Measured against v1.1.1

Minimum of two runs each on an otherwise idle machine, Julia 1.13.1, public
entry points only (`time`, then bytes allocated per call):

| Entry point | v1.1.1 | 2.0.0 |
|---|---|---|
| `reverse_gradient`, soft render 64 px, 459 parameters | 498.7 ms, 637 MB | 7.5 ms, 3.5 MB |
| `reverse_gradient`, soft render 128 px | 1326 ms, 1.54 GB | 16.9 ms, 10.8 MB |
| `ForwardDiff.gradient`, soft render 64 px | 1788 ms | 646.7 ms |
| `raycast`, sphere with 128x96 segments | 2.51 ms | 0.147 ms |
| `raycast`, 400 boxes | 0.128 ms, 256 B | 0.102 ms, 576 B |
| `load_png`, 512x512 | 10.6 ms | 1.36 ms |
| `save_webgl_html`, lit three-mesh scene | 14.9 ms | 5.3 ms |
| `mat4_multiply`, 100,000 products | 4.69 ms | 2.13 ms |
| `soft_render`, 128 px, 224 faces | 11.3 ms | 7.2 ms |
| `render!`, 512x512 flat / smooth | 11.0 / 33.3 ms | 8.4 / 28.3 ms |
| `render_pooled!`, `render_tiled!`, 512x512 | 9.9 / 9.8 ms | 8.6 / 8.5 ms |
| `loss_ssim`, 128x128 | 24.2 ms | 19.4 ms |

No measured entry point is slower. A single-hit raycast allocates 320 bytes
more because `Intersection` now carries the face, normals, UVs and barycentric
weights.

## Platform validation

Release-validation run 46035496739 on `bb4f22e` (Linux, macOS and Windows on
Julia 1.10 and 1.13; Chromium, Firefox and WebKit; installed consumers; the
pinned three.js comparison): every completed job passed except the two Windows
shard-4 jobs, which failed on the `save_webgl_html` allocation budget described
above. The validation run for the released commit is linked from the GitHub
release.

## Not verified here

- Local browser checks used headless Chromium with SwiftShader only; Firefox
  and WebKit are exercised by the release-validation workflow.
- The exported viewer's shadow and lighting changes were compared with
  three.js r186 in headless Chromium at the pixel positions the audit chose,
  not over whole images.
- One benchmark run stalled for several minutes in `save_webgl_html` while the
  machine was at a load average of 22. It did not recur in five further runs,
  loaded or idle, and its cause was not identified.

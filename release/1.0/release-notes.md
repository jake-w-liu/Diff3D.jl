# Diff3D.jl 1.0.0

Diff3D 1.0 defines a stable contract for its documented Julia graphics and
differentiation APIs. It covers supported calls and properties, backend and
numeric limits, errors, extension points, and ownership of mutable data.
Incompatible public changes require a later major release.

## Breaking changes

This release is breaking. Registered 0.1.8 made no compatibility promise; 1.0 fixes
the documented public surface for the whole 1.x series, and several corrected
behaviours change results that 0.1.8 produced.

- Corrected numerical, shading, deformation and loader behaviour changes previously
  incorrect pixels and derivatives. Recheck application image and gradient baselines
  against known expectations rather than accepting every changed result as equivalent.
- A failed WebGL export now preserves the existing destination instead of leaving a
  partial file, a successful save replaces a destination symlink rather than writing
  through it, and on POSIX systems new files are created owner read/write with
  existing regular-file permission bits preserved.
- Render caches and soft workspaces have explicit ownership rules. Copy a
  soft-workspace image that must outlive another call, and give concurrent
  independent renders separate mutable resources.
- Only exported names and documented calls, properties and behaviour are covered.
  Internal helpers, cache fields and the generated browser JavaScript are
  implementation details.
- Documentation that referred to `diff_render` or `param_injector!` was incorrect;
  `differentiable_render(params, setup_fn, width, height)` is the supported call.

The migration guide below gives the full 0.1.8 upgrade path, and the changelog lists
everything included in this release.

## Changes included

- Correct gradient propagation through zero means, planar triangle normals and
  areas, scaled vector differences, and zero line-projection parameters.
- Preserve an existing WebGL export when saving fails, and format exported
  numbers portably on Windows while preserving Float64 precision and integer IDs.
- Fit the full physical-texture browser path into the tested 16-sampler contexts
  and reuse shader locations during repeated rendering.
- Keep browser cube maps within WebGL 1 limits, completing the physical mip
  pyramid for partial authored chains, and request `highp` fragment precision
  wherever the browser reports it.
- Keep the exported viewer's frame loop alive when a frame raises, bound that
  retry, and report completed frames, the last frame error and context loss.
- Reduce allocations in affine morph transforms, CSG clipping/inversion,
  integer serialization, and standard-material lighting with ambient occlusion.
- Execute the documented tutorials and provide versioned documentation, complete
  optimized test shards, platform/browser validation and independent installed
  consumer checks.

The pinned comparison with three.js 0.186.0 publishes two matched runs — a
Linux runner with software rendering and a macOS host with a hardware GPU — with
both execution orders and raw accuracy, timing, memory and artifact-size
measurements. Both runs report zero cross-engine pixel mismatches outside edge
ties, a largest timed-gradient error of 3.47e-13, smaller compressed Diff3D
exports in every fixture, and Diff3D reverse AD ahead of the three.js
central-difference baseline by 12.6x and 12.6x at 1,024 parameters on the Linux
runner. Three.js has the lower browser-frame median in all 18 measurements of
both runs, and is faster than Diff3D reverse AD at 64 parameters in every pass.
The report qualifies each host and claims no general rendering parity or
superiority.

Julia 1.10 or later in the 1.x series is supported. Release validation runs the
minimum supported Julia 1.10 and the current stable Julia 1.13 on Linux, macOS
and Windows, with browser export checked in Chromium, Firefox and WebKit on Linux
and in Firefox and WebKit on an Apple silicon GPU. CPU rendering, soft
differentiable rendering and browser export have distinct supported scopes.
Browser export uses WebGL 1 and built-in materials; it does not export Julia
ShaderMaterial callbacks. The glTF loader rejects required Draco, Meshopt and
Basis extensions.

See the [compatibility contract](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/docs/src/compatibility.md),
[migration guide](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/release/1.0/migration.md),
and [comparison report and raw evidence](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/release/1.0/comparison.md).

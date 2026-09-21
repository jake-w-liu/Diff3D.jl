# Diff3D.jl 1.0.0

Diff3D 1.0 defines a stable contract for its documented Julia graphics and
differentiation APIs. It covers supported calls and properties, backend and
numeric limits, errors, extension points, and ownership of mutable data.
Incompatible public changes require a later major release.

- Correct gradient propagation through zero means, planar triangle normals and
  areas, scaled vector differences, and zero line-projection parameters.
- Preserve an existing WebGL export when saving fails, and format exported
  numbers portably on Windows while preserving Float64 precision and integer IDs.
- Fit the full physical-texture browser path into the tested 16-sampler contexts
  and reuse shader locations during repeated rendering.
- Keep browser cube maps within WebGL 1 limits, completing the physical mip
  pyramid for partial authored chains, and request `highp` fragment precision
  wherever the browser reports it.
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
central-difference baseline by 12.9x and 11.7x at 1,024 parameters on the Linux
runner. Three.js has the lower browser-frame median in all 18 measurements of
both runs, and is faster than Diff3D reverse AD on the smaller parameter counts.
The report qualifies each host and claims no general rendering parity or
superiority.

Julia 1.10 or later in the 1.x series is supported. Release validation runs the
minimum supported Julia 1.10 and the current stable Julia 1.13 on Linux, macOS
and Windows. CPU rendering, soft
differentiable rendering and browser export have distinct supported scopes.
Browser export uses WebGL 1 and built-in materials; it does not export Julia
ShaderMaterial callbacks. The glTF loader rejects required Draco, Meshopt and
Basis extensions.

See the [compatibility contract](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/docs/src/compatibility.md),
[migration guide](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/release/1.0/migration.md),
and [comparison report and raw evidence](https://github.com/jake-w-liu/Diff3D.jl/blob/v1.0.0/release/1.0/comparison.md).

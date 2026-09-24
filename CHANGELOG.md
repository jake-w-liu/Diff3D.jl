# Changelog

## 1.0.0

The first 1.x compatibility contract covers documented public calls, properties,
numeric and AD inputs, extension points, errors, and ownership of mutable data.
Compatible additions use minor releases; incompatible public changes require a
major release. See [compatibility](docs/src/compatibility.md) and the
[0.1.8 migration guide](release/1.0/migration.md).

This release is breaking relative to the registered 0.1.8, which carried no
compatibility promise. Corrected numerical, shading, deformation and loader
behaviour changes previously incorrect pixels and derivatives, failed WebGL
exports and destination symlinks are now handled differently, and mutable
render caches and soft workspaces have explicit ownership rules. Recheck
application baselines rather than accepting every changed result as equivalent.

Changes included in this release:

- Correct gradient propagation through zero means, planar triangle normals and
  areas, scaled vector differences, and zero line-projection parameters.
- Preserve existing WebGL exports when serialization fails. Replace destination
  symlinks without changing their targets and preserve POSIX regular-file modes.
- Format exported numbers through Julia's reusable Printf buffer on every
  platform, preserving Float64 precision and exact integer IDs on Windows.
- Share mutually exclusive material samplers so the full physical-texture path
  fits the tested 16-sampler contexts. Reuse linked-program shader locations
  during repeated browser rendering.
- Keep non-power-of-two browser cube maps at level zero, preventing invalid
  WebGL mip uploads in exported environments such as the glTF loader example.
  Complete the physical mip pyramid for a partial authored power-of-two chain so
  those environments keep sampling their authored levels.
- Request `highp` fragment precision in exported shaders wherever the browser
  reports it, so texture coordinates survive contexts that honour the 10-bit
  WebGL 1 `mediump` minimum.
- Keep the exported viewer's frame loop alive when a frame raises, and bound the
  retry so a viewer that fails every frame stops instead of rethrowing about sixty
  times a second. Report the completed-frame count, the last frame error and the
  context-loss state, so a canvas showing only its background can be told apart
  from a loop that died, a frame that drew nothing, and a draw that rasterised
  nothing without another validation round trip.
- Recover a lost WebGL context the way three.js does: prevent its default so the
  browser restores it, draw nothing while it is lost, and rebuild every buffer,
  texture and program from the scene's CPU data through the same resource path
  used at start-up.
- Link viewer programs once and enumerate their active uniforms and attributes
  into a link-time table, replacing the by-name cache that could keep a null
  location forever. Write every uniform through one typed writer: an inactive
  name stays a no-op, while a misspelt required name, a wrong component count
  and a type the call cannot write throw instead of leaving a zero matrix or a
  zero opacity behind.
- Re-declare the vertex arrays a draw uses and disable every other one before
  drawing, bind `aPosition` to attribute 0 in every program, and draw instanced
  only for objects that own instance matrices instead of routing every object
  through a shared identity buffer.
- Establish the GL state a frame depends on at the top of the frame and around
  each shadow pass, unbind the shadow framebuffer when a pass throws, and keep
  a reported error on a persistent banner instead of letting the next frame
  erase it.
- Reduce allocations in affine morph transforms, exact integer serialization,
  CSG clipping/inversion, and standard-material lighting with ambient occlusion.
- Execute all tutorials and publish versioned documentation. Main-branch docs
  use `/dev/`; version tags provide versioned pages and the stable alias.
- Add complete optimized test shards, release platform/browser matrices, fresh
  package-consumer checks, and pinned comparisons with three.js 0.186.0 on both
  a software-rendering Linux runner and a hardware-GPU macOS host.
- Validate Firefox on Linux with Mesa's llvmpipe instead of on the hosted macOS
  runners, which have no GPU and give Firefox Apple's software OpenGL renderer.
  That renderer drops triangles that need clipping, so the browser harness now
  records each engine's unsanitised renderer and refuses it.
- Reject machine-specific filesystem paths anywhere in the published package
  tree, including inside the committed release evidence archives.

Julia 1.10 or later in the 1.x series is supported. Release validation runs the
minimum supported Julia 1.10 and the current stable Julia 1.13 on Linux, macOS
and Windows, with browser export checked in Chromium, Firefox and WebKit on Linux
and in Firefox and WebKit on an Apple silicon GPU. CPU rendering, soft
differentiable rendering and WebGL export have distinct contracts. Browser
export uses WebGL 1 and built-in materials; it does not export `ShaderMaterial`
callbacks. Required Draco, Meshopt and Basis glTF extensions remain unsupported.
A matching three.js API name does not imply matching backend coverage or speed.

The [release tracker](RELEASE_PLAN.md) records the candidate's validation status;
its checks must pass before publication. The
[comparison report](release/1.0/comparison.md) includes both measurement orders,
raw data, observed advantages and unfavorable results; the
[protocol](benchmarks/threejs/README.md) describes how to reproduce it.

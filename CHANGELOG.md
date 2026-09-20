# Changelog

## 1.0.0

The first 1.x compatibility contract covers documented public calls, properties,
numeric and AD inputs, extension points, errors, and ownership of mutable data.
Compatible additions use minor releases; incompatible public changes require a
major release. See [compatibility](docs/src/compatibility.md) and the
[0.1.8 migration guide](release/1.0/migration.md).

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
- Reduce allocations in affine morph transforms, exact integer serialization,
  CSG clipping/inversion, and standard-material lighting with ambient occlusion.
- Execute all tutorials and publish versioned documentation. Main-branch docs
  use `/dev/`; version tags provide versioned pages and the stable alias.
- Add complete optimized test shards, release platform/browser matrices, fresh
  package-consumer checks, and pinned comparisons with three.js 0.186.0.

Julia 1.10 or later in the 1.x series is supported. CPU rendering, soft
differentiable rendering and WebGL export have distinct contracts. Browser
export uses WebGL 1 and built-in materials; it does not export `ShaderMaterial`
callbacks. Required Draco, Meshopt and Basis glTF extensions remain unsupported.
A matching three.js API name does not imply matching backend coverage or speed.

The [release tracker](RELEASE_PLAN.md) records the candidate's validation status;
its checks must pass before publication. The
[comparison report](release/1.0/comparison.md) includes both measurement orders,
raw data, observed advantages and unfavorable results; the
[protocol](benchmarks/threejs/README.md) describes how to reproduce it.

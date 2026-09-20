# Moving from 0.1.8 to 1.0

This guide accompanies the candidate under preparation. Use the published
release's compatibility contract and evidence when selecting a version.

- The 1.x contract covers exported names and documented calls, properties and
  behavior. Internal helpers, cache fields and generated browser JavaScript
  remain implementation details. Use the public API in application code.
- Explicit inverse-rendering setups take `params` and return vertices, faces,
  face colors, a view-projection matrix and a background color. Earlier text
  mentioning `diff_render` or `param_injector!` was incorrect documentation;
  `differentiable_render(params, setup_fn, width, height)` is the supported call.
- Check the documented backend before moving a scene between CPU, soft and
  browser rendering. Soft visibility defines a different image model. Browser
  export uses WebGL 1 and built-in materials; `ShaderMaterial` export was already
  rejected in registered 0.1.8. Its Julia callback belongs to CPU rendering.
- Failed WebGL exports now preserve the existing destination. A successful save
  replaces a symlink instead of overwriting its target. New files have owner
  read/write permissions; existing regular-file permission bits are preserved.
  Set the permissions explicitly when another local account must read a new file.
- Reuse render caches and workspaces according to their ownership rules. Copy
  soft-workspace images that must outlive another call, and give concurrent
  independent renders separate mutable resources.
- Corrected numerical, shading, deformation and loader behavior can change
  previously incorrect pixels or derivatives. Recheck application image and
  gradient baselines against known expectations rather than accepting every
  changed result as equivalent.

See [the compatibility contract](../../docs/src/compatibility.md),
[verification evidence](evidence.md), and [the release gates](../../RELEASE_PLAN.md).

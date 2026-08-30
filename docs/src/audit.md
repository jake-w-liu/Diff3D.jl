# Publication Audit

This audit page records the technical-readiness checks expected before a public
release.

## Correctness Checks

- Run `julia --project=. -e 'using Pkg; Pkg.test()'`.
- Confirm exported API documentation coverage:

  ```julia
  using Diff3D
  has_doc(mod, name) = isdefined(Base.Docs, :hasdoc) ?
      getfield(Base.Docs, :hasdoc)(mod, name) :
      haskey(Base.Docs.meta(mod), Base.Docs.Binding(mod, name))
  missing = [n for n in names(Diff3D) if
             isdefined(Diff3D, n) && !has_doc(Diff3D, n)]
  isempty(missing)
  ```

- Regenerate representative WebGL examples and run the browser smoke test:

  ```powershell
  julia --project=. examples/live_webgl_showcase.jl
  python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
  ```

- Regenerate and smoke-test every non-planned parity registry entry:

  ```powershell
  python examples/verify_examples_registry.py
  ```

## Industrial Readiness Notes

- Runtime dependencies should stay limited to packages needed by `src/`.
  Optional paper/experiment dependencies belong in example scripts or separate
  environments.
- The test suite should remain broad enough to cover math, geometry, scene graph
  transforms, materials, loaders, CPU rendering, WebGL export, differentiable
  rendering, and regression cases.
- Generated artifacts should not be required for package loading or tests.
- Browser smoke tests should fail on JavaScript console errors, missing canvas
  output, mismatched draw counts, and transparent center pixels.

## Release Blockers To Resolve Outside Code

- Keep the top-level MIT `LICENSE` file present for registry license detection.
- Keep the top-level `Manifest.toml` untracked. Diff3D is a reusable package,
  so dependency versions must resolve against the consuming Julia version.

## CI Coverage

- `.github/workflows/ci.yml` runs package tests on the minimum supported Julia
  release and the latest stable Julia release, plus the full registered-example
  browser smoke sweep through `examples/verify_examples_registry.py`.

# Publication Audit

This audit page records the technical-readiness checks expected before a public
release.

## Correctness Checks

- Run `julia --project=. -e 'using Pkg; Pkg.test()'`.
- Confirm exported API documentation coverage:

  ```julia
  using Three
  missing = [n for n in names(Three) if isdefined(Three, n) && !Docs.hasdoc(Three, n)]
  isempty(missing)
  ```

- Regenerate representative WebGL examples and run the browser smoke test:

  ```powershell
  julia --project=. examples/live_webgl_showcase.jl
  python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
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
- Decide whether this repository is a package-only artifact or a reproducible
  research artifact; that determines whether committing `Manifest.toml` is
  appropriate.
- Add CI for package tests, docs, and at least one browser smoke path.

# Diff3D and three.js comparison

This harness checks matched outputs before measuring them. Its package lock pins
three.js 0.186.0 and esbuild 0.28.2. A passing development probe is not release
evidence: the final report requires a clean, unchanged checkout and both passes.

From the repository root, install the Julia project, run `npm ci` in this
directory, and install `test/requirements-browser.txt` plus the selected
Playwright browser. Python 3.11 or newer is required. Then run:

```sh
python benchmarks/threejs/run.py /tmp/diff3d-comparison --browser firefox
```

Choose a new empty output directory. The script runs commands sequentially,
reverses engine order on its second pass, and saves fixtures, standalone HTML,
commands, logs, raw samples, content hashes, source revision and environment
metadata. `--allow-dirty` enables development probes, which must not be cited as
final release measurements. Avoid running other heavy tasks during measurement;
the report records system load, but cannot make different machine loads equal.

The run also captures the resolved Julia `Project.toml` and `Manifest.toml` in
`julia-environment/` before measurement and requires them to remain unchanged.
These files lock the exact Julia package versions and dependency tree hashes
used for that run; both numerical passes check their loaded Diff3D/ForwardDiff
versions. To reproduce a recorded run, use its Julia version in a clean checkout
of its source revision, copy these environment files to the checkout root, and
instantiate them before running the harness.

## Numerical differentiation

`fixtures.py` writes identical Float64 inputs in JSON and TOML at 16, 64, 256
and 1,024 parameters. The objective projects points through the same perspective
matrix and compares their two image coordinates to known targets. An algebraic
loss/gradient oracle is independent of both implementations. Every method must
meet the same gradient tolerance; the 16-parameter problem also requires recovery
of its known depths under the same 1,000 gradient-descent steps.

The Julia implementation uses public Diff3D matrix/vector operations and reverse
AD, ForwardDiff, or central differences. The JavaScript implementation uses
three.js Matrix4/Vector3 and explicit central differences with a reused vector.
Derivative methods are part of the comparison: this does not measure image
rendering speed or claim that a finite-difference implementation is the best
possible JavaScript derivative. A hand-derived gradient or another AD library
would be an additional baseline with a different implementation contract.

Each method records its first invocation separately, five warmups and 21 timed
gradients, plus actual objective-evaluation counts. Every timed gradient is
consumed and checked against the independent oracle after its clock stops;
reports retain the largest error across those samples. Julia reports total
allocated bytes for one warmed gradient. Node reports retained heap/ArrayBuffer deltas
after GC, result storage and an RSS snapshot. These are different memory
quantities and must not be divided into an allocation-efficiency ratio.
First-invocation time includes compilation encountered by that call; it does not
include process launch or package import. Command elapsed time includes the
entire command, including its validation and all samples.

## Browser rendering

Both viewers draw the same indexed unlit triangles, transforms, orthographic
camera, linear RGB color, black background, 256×256 buffer, device scale 1 and
disabled antialiasing. Fixtures cover 16/128/512 separate meshes, an instance
batch, and meshes animated through each engine's public keyframe/clip API.
Both artifacts contain their runtime and data and must make no remote requests.

Diff3D uses its full exported viewer, including its controls and status DOM.
The three.js artifact bundles a minimal app with esbuild. HTML/gzip sizes are
the sizes of those working artifacts, not a comparison of equally featured
editor products. The backends also differ: Diff3D uses WebGL 1 and three.js uses
WebGL 2. Actual context attributes, renderer and browser versions are recorded.
Chromium uses the shared CI launcher's SwiftShader configuration and must be
reported as software rendering. Firefox/WebKit renderer metadata must be checked
before describing a run as using hardware.

The harness drives the real frame callbacks at identical simulation times and
calls `gl.finish()` after **every** frame. It checks actual draw and triangle
counts, initial/final pixels against an independent triangle oracle and against
the other engine, animation advancement, WebGL errors and GPU-resource reuse.
The permitted edge-coverage band is `0.002 + sqrt(2) * 2^(-SUBPIXEL_BITS)` pixels.
The queried WebGL precision bounds one subpixel step in each window coordinate;
0.002 pixels additionally covers Float32 transforms. The precision and resulting
band are recorded, and color must still be foreground or background on an edge.
Channel quantization may differ by one byte. All other pixels must match their
expected foreground/background values. `test_browser_oracle.py` checks a
captured four-bit rasterization mask and rejects shifted or corrupted images.

Navigation through the first completed frame is recorded separately. Warm
measurements contain five warmup batches and 21 measured batches of eight
completed frames; each sample is the batch duration divided by eight. Batching
reduces the effect of browser clock quantization. The measurement includes the
shared callback/draw instrumentation and completion checks. It is not an
asynchronous GPU enqueue measurement or a monitor-refresh FPS estimate.

`summarize.py` derives the published statistics file from a completed output
directory: it keeps the identities, accuracy results, environments and resource
counts, and replaces each raw sample array with its sample count, minimum,
median, nearest-rank 95th percentile and maximum. It reads only the retained raw
files and measures nothing itself, so the published numbers stay checkable
against the archive.

Recorded commands use `<repo>` and `<output>` placeholders instead of absolute
paths, and the harness refuses to record a command whose arguments would still
name this machine's filesystem layout.

Publish both passes and unfavorable cases with their raw files. Ratios apply to
the measured fixture, derivative method, backend and machine; they do not
establish overall feature parity or universal superiority.

Primary references: [three.js WebGLRenderer](https://threejs.org/docs/pages/WebGLRenderer.html),
[three.js matrix projection](https://github.com/mrdoob/three.js/blob/r186/src/math/Vector3.js),
[WebGL completion](https://registry.khronos.org/webgl/specs/latest/1.0/#5.14.11),
[OpenGL ES subpixel precision (table 6.18)](https://registry.khronos.org/OpenGL/specs/es/2.0/es_full_spec_2.0.pdf),
and [Diff3D compatibility](../../docs/src/compatibility.md).

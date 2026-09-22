# Diff3D 1.0 comparison with three.js

Two matched runs measure the release candidate: a quiet Linux runner with
software rendering, and a busy macOS host with a hardware GPU. Both validate
their outputs before timing anything.

The measured advantages are native Julia differentiation and smaller compressed
standalone artifacts. At 1,024 depth parameters the three.js central-difference
baseline took 12.6x and 12.6x as long as Diff3D reverse AD by median time on the
Linux runner, and 18.3x and 19.3x on the macOS host. Three.js had the lower median
browser frame time in **all 18 measurements of both runs**. This evidence
supports a Julia numerical-workflow use case; it does not establish overall
rendering superiority or three.js parity.

**Measurement qualification:** the Linux runner had a one-minute load average of
1.26 at the start and 3.99 at the end on 4 logical CPUs, and is the more reliable
timing environment. The macOS host was shared and busy, with load 44.29 rising
to 48.12 on 10 logical CPUs; its percentiles are correspondingly wide and it is
published for its hardware renderer and for its second engine, not for precise
timing. Reversing execution order exposes substantial variation on both. Treat
the numbers as observations of these runs, not isolated-machine guarantees.

## Source and reproducibility

| | Linux / Chromium | macOS / Firefox |
|---|---|---|
| Diff3D revision | [`3fee531`](https://github.com/jake-w-liu/Diff3D.jl/tree/3fee5313ea9103da48397b9517eebdab5b070695) | [`0dddaff`](https://github.com/jake-w-liu/Diff3D.jl/tree/0dddaff19277998cb2e7202de9a9fa9971cdf54c) |
| Package version | 1.0.0 | 1.0.0 |
| Host | `Linux-6.17.0-1022-azure-x86_64`, 4 CPUs, AMD EPYC 7763 | `macOS-26.5.1-arm64`, 10 CPUs, Apple M5 |
| Julia | 1.13.0, one thread, optimization level 2, CPU target `znver3` | 1.13.0, one thread, optimization level 2, CPU target `apple-m1` |
| ForwardDiff | 1.4.6 | 1.4.6 |
| Node / three.js / esbuild | 26.9.0 / 0.186.0 / 0.28.2 | 26.5.0 / 0.186.0 / 0.28.2 |
| Browser | Chromium 153.0.8010.12, Playwright 1.63.0, Python 3.14.7 | Firefox 155.0, Playwright 1.63.0, Python 3.14.7 |
| Reported renderer | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)` — software | `Apple M1, or similar` — hardware |
| Clean checkout | yes | yes |

Both revisions contain the same measured `src/` and `benchmarks/` trees; `0dddaff`
only adds evidence prose on top of `3fee531`. Exact
resolved Julia `Project.toml` and `Manifest.toml` files are archived inside each
run and are required to stay unchanged for its duration.

- Linux/Chromium: [run record and 42 file hashes](comparison/2026-09-22-3fee531-chromium-run.json),
  [derived statistics](comparison/2026-09-22-3fee531-chromium-summary.json), and the
  [complete raw archive](comparison/2026-09-22-3fee531-chromium.tar.gz)
  (43 files; SHA-256 `cacdf458e56f95dd8c7f0406482b0271412b41d8a945a6d3e77da3043c322f77`).
- macOS/Firefox: [run record and 42 file hashes](comparison/2026-09-22-0dddaff-firefox-run.json),
  [derived statistics](comparison/2026-09-22-0dddaff-firefox-summary.json), and the
  [complete raw archive](comparison/2026-09-22-0dddaff-firefox.tar.gz)
  (43 files; SHA-256 `53d99d935d3c4008058d907484d66ebdb4c77751491fd6d965eb685d76af7042`).

Each archive holds the run record, raw samples, commands, logs, fixtures,
dependency snapshots and 18 working HTML artifacts. Recorded commands use the
`<repo>` and `<output>` placeholders so no published file carries a local
filesystem layout. The statistics files are derived from the raw files by
`benchmarks/threejs/summarize.py`; they add no measurement of their own.

Follow the [comparison protocol](../../benchmarks/threejs/README.md) with the
recorded source and environment. Run `python benchmarks/threejs/run.py OUTPUT
--browser firefox` into a new output directory; both orders must finish with
`status = passed`. The **Pinned three.js comparison** workflow reproduces the
Linux/Chromium run on every dispatch.

## Numerical objective and accuracy

Each point has one variable depth. Both implementations project identical
Float64 points through the same perspective matrix and minimize the same mean
squared coordinate error. An algebraic oracle checks the loss and complete
gradient independently of either implementation. Central differences use the
same step, `1e-5`. All initial, warmup and timed gradients are checked, with the
timed-result check outside the clock.

Both runs meet the same accuracy bounds, and their worst cases agree exactly:
the largest timed-gradient absolute error was **3.47e-13** across all 32
method/size/pass records of each run. The per-record losses and gradient errors
are not bit-identical between the two runs, as different hardware and Julia
builds reorder floating-point work. In the
16-parameter problem, which is the one that also requires recovery, all four
methods reached the known depths within **5.00e-11** after the same 1,000
gradient-descent updates, in both passes of both runs.

The three.js baseline uses its public Matrix4/Vector3 operations plus explicit
central differences. A hand-derived gradient or another JavaScript AD system
could produce different results; neither is measured here. These are numerical
projection-gradient measurements, not differentiable image-rendering timings.

Each cell is **median [95th percentile] milliseconds per gradient**, from 21
samples after five warmups. The percentile is the nearest-rank statistic
(`ceil(0.95 x 21)`, the 20th sorted sample). Pass 1 runs Julia first; pass 2 runs
Node first.

**Linux / Chromium runner:**

| Parameters | Pass | Diff3D reverse AD | Julia ForwardDiff | Julia central difference | three.js central difference |
|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 0.0196 [0.0210] | 0.0026 [0.0031] | 0.0258 [0.0281] | 0.0146 [0.0304] |
| 16 | 2 | 0.0195 [0.0211] | 0.0026 [0.0033] | 0.0257 [0.0335] | 0.0267 [0.0300] |
| 64 | 1 | 0.1062 [0.1663] | 0.0232 [0.0501] | 0.4086 [0.4308] | 0.0681 [0.1026] |
| 64 | 2 | 0.1065 [0.1752] | 0.0260 [0.0291] | 0.4078 [0.4287] | 0.0682 [0.1045] |
| 256 | 1 | 0.3223 [0.5558] | 0.4045 [0.4477] | 6.5767 [7.1286] | 1.0555 [1.0600] |
| 256 | 2 | 0.3194 [0.5727] | 0.4782 [0.5098] | 6.5384 [6.6186] | 1.0370 [1.0519] |
| 1,024 | 1 | 1.3129 [1.7114] | 6.1746 [6.2079] | 105.2757 [109.1490] | 16.4731 [16.6482] |
| 1,024 | 2 | 1.3168 [1.7646] | 7.3386 [7.3927] | 104.7046 [105.0355] | 16.6063 [16.7615] |

**macOS / Firefox host:**

| Parameters | Pass | Diff3D reverse AD | Julia ForwardDiff | Julia central difference | three.js central difference |
|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 0.0297 [0.0336] | 0.0039 [0.0060] | 0.0179 [0.0180] | 0.0189 [0.0226] |
| 16 | 2 | 0.0277 [0.0310] | 0.0039 [0.0061] | 0.0179 [0.1559] | 0.0192 [0.0398] |
| 64 | 1 | 0.1127 [1.0544] | 0.0306 [0.0435] | 0.2768 [2.3332] | 0.0576 [0.0695] |
| 64 | 2 | 0.1032 [0.1746] | 0.0311 [0.1087] | 0.2769 [0.2893] | 0.0556 [0.0690] |
| 256 | 1 | 0.4596 [0.9343] | 0.6749 [0.6992] | 10.1087 [32.4177] | 0.8355 [0.9413] |
| 256 | 2 | 0.4138 [0.7307] | 0.4723 [1.6937] | 13.5716 [27.1360] | 0.8463 [35.3906] |
| 1,024 | 1 | 2.0796 [26.1720] | 21.0330 [62.3609] | 238.8392 [274.4137] | 38.0338 [61.9902] |
| 1,024 | 2 | 2.0042 [22.4196] | 20.5839 [45.2090] | 215.1775 [242.0806] | 38.6908 [71.4512] |

At 1,024 parameters, reverse AD used one objective evaluation, ForwardDiff used
86, and each central-difference method used 2,048. The evaluated objective and
AD work differ within those calls; these counts are not engine-speed ratios.
ForwardDiff had the lowest median of the four methods at 16 and 64 parameters in
every pass of both runs; Diff3D reverse AD had the lowest median at 256 and 1,024
parameters in every pass of both runs. Three.js central differences were faster
than Julia central differences at 64, 256 and 1,024 parameters in every pass of
both runs. They were also faster than Diff3D reverse AD at 64 parameters in every
pass of both runs, at 16 parameters in both passes on the macOS host, and at 16
parameters in the first pass on the Linux runner. Diff3D's reverse-AD advantage in
this objective appears only as the parameter count grows.

Julia's compilation cost matters for short jobs. At 16 parameters, first-call
times were 0.425/0.418 seconds for reverse AD and 0.528/0.510 seconds for
ForwardDiff on the Linux runner, versus 0.605/0.585 milliseconds for the three.js
finite-difference call. The loaded macOS host needed 1.431/1.215 and 2.006/1.715
seconds for the same first calls. These clocks exclude process launch and package
import; full command elapsed times are in each run record.

Warmed Julia allocation totals at 1,024 parameters were **4,436,808 bytes** for
reverse AD, **116,352 bytes** for ForwardDiff and **16,528 bytes** for central
differences on the Linux runner (4,481,488 / 124,528 / 16,512 on macOS). Reverse
AD's time advantage here costs more allocated memory. Node records retained
heap/ArrayBuffer changes after GC and an RSS snapshot, not total allocations or
peak memory. Its 1,024-element result stores 8,192 bytes. A zero retained-heap
delta does not mean zero allocation; these memory measures do not support a
cross-language allocation ratio.

## Browser frames, startup and artifact sizes

Nine fixtures cover 16/128/512 separate static meshes, one instance batch, and
separate animated meshes. Both engines draw the same triangles, colors, camera,
256x256 buffer and animation times, with antialiasing disabled and linear RGB.
Diff3D exports WebGL 1; three.js uses WebGL 2. The protocol calls `gl.finish()`
after every frame and includes the shared instrumentation/completion checks.

All 36 paired measurements across the two runs passed the independent
initial/final pixel oracle, draw/triangle counts, animation checks, the zero
external-request check and the stable GPU-resource counts. There were **zero
cross-engine pixel mismatches outside edge ties** in every pair. Both contexts of
both runs reported four subpixel bits, giving the edge band
`0.002 + sqrt(2) * 2^-4 = 0.090388` pixels; the harness still rejects incorrect
edge colors and shifted or corrupted images. In the three 16-mesh fixtures
Diff3D's first-frame buffers were byte-identical on both the Apple GPU and
SwiftShader — `static-16` hashed to `482ffcd625d56300...` in each — so those
exports are bit-deterministic across the two renderers rather than merely within
tolerance. Three.js behaves the same way on those three fixtures, so this is a
property of the small fixtures rather than of either engine. The 128- and
512-mesh buffers of both engines differ between the renderers while staying
inside the permitted band.

The [earlier subpixel counterexample](comparison/2026-09-20-chromium-subpixel.tar.gz)
and [Chromium replay](comparison/2026-09-20-chromium-replay.tar.gz) archives
document how that edge band was derived and checked against frozen exports. See
the [protocol](../../benchmarks/threejs/README.md) and
[verification evidence](evidence.md#chromium-subpixel-precision-oracle).

Warmed cells show **median [95th percentile] milliseconds per completed frame**.
Each sample is an eight-frame batch; there are 21 samples after five warmup
batches. These are synchronized frame costs, not monitor-refresh FPS.

**Linux / Chromium runner (software rendering):**

| Fixture | Diff3D pass 1 | three.js pass 1 | Diff3D pass 2 | three.js pass 2 |
|---|---:|---:|---:|---:|
| static-16 | 4.025 [23.938] | 0.250 [0.337] | 4.050 [24.200] | 0.262 [0.337] |
| instanced-16 | 1.438 [22.562] | 0.250 [0.388] | 1.325 [22.500] | 0.238 [0.375] |
| dynamic-16 | 4.163 [21.162] | 0.238 [0.325] | 4.988 [24.925] | 0.250 [0.525] |
| static-128 | 16.787 [19.338] | 0.575 [0.938] | 17.200 [19.500] | 0.625 [0.975] |
| instanced-128 | 1.537 [29.013] | 0.300 [0.413] | 0.650 [0.787] | 0.300 [0.438] |
| dynamic-128 | 16.988 [20.250] | 0.650 [0.925] | 17.662 [20.350] | 0.600 [1.000] |
| static-512 | 54.237 [60.350] | 1.325 [4.775] | 54.600 [60.338] | 1.225 [1.625] |
| instanced-512 | 0.975 [46.200] | 0.287 [0.388] | 0.600 [1.463] | 0.312 [0.450] |
| dynamic-512 | 53.413 [58.512] | 1.375 [1.650] | 52.087 [61.088] | 1.325 [1.425] |

**macOS / Firefox host (hardware renderer, busy machine):**

| Fixture | Diff3D pass 1 | three.js pass 1 | Diff3D pass 2 | three.js pass 2 |
|---|---:|---:|---:|---:|
| static-16 | 2.500 [7.875] | 0.750 [1.000] | 2.625 [11.250] | 1.000 [1.500] |
| instanced-16 | 1.000 [1.375] | 0.625 [0.875] | 1.000 [1.875] | 0.625 [0.875] |
| dynamic-16 | 2.750 [9.875] | 0.875 [1.625] | 2.750 [12.625] | 0.750 [1.000] |
| static-128 | 26.750 [32.250] | 1.250 [1.625] | 22.125 [31.875] | 1.250 [1.750] |
| instanced-128 | 1.000 [1.250] | 0.625 [1.000] | 0.875 [1.500] | 0.750 [1.250] |
| dynamic-128 | 20.375 [28.875] | 1.375 [3.500] | 27.500 [37.625] | 1.250 [1.375] |
| static-512 | 87.375 [96.875] | 2.750 [6.250] | 104.500 [112.000] | 3.000 [3.625] |
| instanced-512 | 1.250 [1.875] | 0.625 [0.875] | 1.125 [1.500] | 0.625 [1.000] |
| dynamic-512 | 100.625 [120.000] | 3.375 [6.375] | 110.000 [119.500] | 3.250 [4.000] |

Three.js has the lower median in all nine fixtures of both passes of both runs.
The data show no browser-rendering speed advantage for Diff3D in these fixtures;
the gap is largest for the separate-mesh static and dynamic scenes, where Diff3D
issues one draw call per mesh.

Navigation-to-first-completed-frame times are **milliseconds**, measured
separately from warmed frames. They include local HTML loading and browser
initialization encountered by that page, with no network asset fetch.

**Linux / Chromium runner:**

| Fixture | Diff3D pass 1 / 2 | three.js pass 1 / 2 | Diff3D HTML / gzip kB | three.js HTML / gzip kB |
|---|---:|---:|---:|---:|
| static-16 | 455 / 517 | 66 / 86 | 212.0 / 41.1 | 553.3 / 139.1 |
| instanced-16 | 357 / 349 | 58 / 59 | 173.0 / 40.4 | 553.3 / 139.1 |
| dynamic-16 | 413 / 370 | 63 / 64 | 215.8 / 41.5 | 553.3 / 139.1 |
| static-128 | 407 / 398 | 64 / 65 | 529.2 / 46.6 | 557.2 / 139.6 |
| instanced-128 | 346 / 362 | 62 / 61 | 181.6 / 41.0 | 557.2 / 139.6 |
| dynamic-128 | 418 / 403 | 65 / 70 | 558.8 / 48.7 | 557.2 / 139.6 |
| static-512 | 507 / 499 | 70 / 75 | 1612.9 / 61.6 | 573.3 / 141.2 |
| instanced-512 | 390 / 358 | 66 / 66 | 211.5 / 42.9 | 573.3 / 141.2 |
| dynamic-512 | 499 / 472 | 85 / 80 | 1731.1 / 68.8 | 573.3 / 141.2 |

**macOS / Firefox host:**

| Fixture | Diff3D pass 1 / 2 | three.js pass 1 / 2 | Diff3D HTML / gzip kB | three.js HTML / gzip kB |
|---|---:|---:|---:|---:|
| static-16 | 821 / 824 | 321 / 633 | 212.0 / 41.1 | 553.3 / 139.1 |
| instanced-16 | 523 / 1,607 | 451 / 790 | 173.0 / 40.4 | 553.3 / 139.1 |
| dynamic-16 | 693 / 549 | 418 / 543 | 215.8 / 41.5 | 553.3 / 139.1 |
| static-128 | 818 / 750 | 419 / 337 | 529.2 / 46.6 | 557.2 / 139.6 |
| instanced-128 | 534 / 611 | 284 / 1,246 | 181.6 / 41.0 | 557.2 / 139.6 |
| dynamic-128 | 1,508 / 809 | 425 / 1,391 | 558.8 / 48.7 | 557.2 / 139.6 |
| static-512 | 1,041 / 916 | 1,253 / 392 | 1612.9 / 61.6 | 573.3 / 141.2 |
| instanced-512 | 876 / 1,462 | 365 / 431 | 211.5 / 42.9 | 573.3 / 141.2 |
| dynamic-512 | 1,385 / 894 | 494 / 520 | 1731.1 / 68.8 | 573.3 / 141.2 |

Sizes use decimal kB and are identical in both runs, as they are properties of
the artifacts rather than of the host. Diff3D's artifact is the full standalone
viewer; the three.js artifact is an esbuild bundle of the matched minimal
application. Diff3D's gzip sizes are smaller in every fixture, while its
uncompressed `dynamic-128`, `static-512` and `dynamic-512` exports are larger. This is a delivery-size
observation for these functioning artifacts, not equal-feature bundle-size
equivalence. Both implementations work offline in these checks; offline delivery
is not an exclusive Diff3D capability.

## Capability boundaries and positioning

| Need | Diff3D 1.0 evidence / scope | three.js comparison scope |
|---|---|---|
| Julia objectives and gradients | Public numerical inputs work with ForwardDiff and built-in Float64 reverse AD; projection oracles above and the [installed consumer](consumer_acceptance.jl) check known inverse solutions. | The pinned baseline is JavaScript with explicit central differences. Other derivative implementations are unmeasured. |
| Differentiable image objectives | Explicit soft-render inputs and inverse-rendering optimizers are part of the [compatibility contract](../../docs/src/compatibility.md). Scene extraction and hard visibility have documented limits. | This report does not benchmark a three.js soft-image objective. |
| Browser backend | Standalone WebGL 1 export; Julia callbacks and arbitrary ShaderMaterial export are unsupported. | [WebGLRenderer](https://threejs.org/docs/pages/WebGLRenderer.html) uses WebGL 2; [WebGPURenderer](https://threejs.org/docs/pages/WebGPURenderer.html) supports WebGPU with a WebGL 2 fallback. |
| Compressed glTF assets | Required Draco, Meshopt and Basis extensions are rejected and tested as errors. | [GLTFLoader](https://threejs.org/docs/pages/GLTFLoader.html) supports these paths when the corresponding decoder/transcoder is configured. |

Diff3D's demonstrated role is a Julia graphics and differentiation workflow with
standalone delivery. Browser frame time and compressed-asset/backend coverage
remain concrete areas where this candidate does not match three.js. Performance
on other scenes, GPUs, isolated hosts, WebGPU, JavaScript AD or full
inverse-image workloads requires new matched measurements. Release readiness also
depends on the platform, consumer and documentation gates; a benchmark win does
not replace those checks.

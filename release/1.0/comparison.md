# Diff3D 1.0 comparison with three.js

Two matched runs measure the release candidate: a quiet Linux runner with
software rendering, and a busy macOS host with a hardware GPU. Both validate
their outputs before timing anything.

The measured advantages are native Julia differentiation and smaller compressed
standalone artifacts. At 1,024 depth parameters the three.js central-difference
baseline took 12.9x and 11.7x as long as Diff3D reverse AD by median time on the
Linux runner, and 5.0x and 11.6x on the macOS host. Three.js had the lower median
browser frame time in **all 18 measurements of both runs**. This evidence
supports a Julia numerical-workflow use case; it does not establish overall
rendering superiority or three.js parity.

**Measurement qualification:** the Linux runner had a one-minute load average of
1.63 at the start and 3.63 at the end on 4 logical CPUs, and is the more reliable
timing environment. The macOS host was shared and busy, with load 28.75 falling
to 27.08 on 10 logical CPUs; its percentiles are correspondingly wide and it is
published for its hardware renderer and for its second engine, not for precise
timing. Reversing execution order exposes substantial variation on both. Treat
the numbers as observations of these runs, not isolated-machine guarantees.

## Source and reproducibility

| | Linux / Chromium | macOS / Firefox |
|---|---|---|
| Diff3D revision | [`017289a`](https://github.com/jake-w-liu/Diff3D.jl/tree/017289a7bd30d062ebcba62ed3d471911598c00b) | [`8cec4f2`](https://github.com/jake-w-liu/Diff3D.jl/tree/8cec4f2a56460c122e157d16a82527c11b2e09c3) |
| Package version | 1.0.0 | 1.0.0 |
| Host | `Linux-6.17.0-1022-azure-x86_64`, 4 CPUs, AMD EPYC 7763 | `macOS-26.5.1-arm64`, 10 CPUs, Apple M5 |
| Julia | 1.13.0, one thread, optimization level 2, CPU target `znver3` | 1.13.0, one thread, optimization level 2, CPU target `apple-m1` |
| ForwardDiff | 1.4.6 | 1.4.6 |
| Node / three.js / esbuild | 26.9.0 / 0.186.0 / 0.28.2 | 26.5.0 / 0.186.0 / 0.28.2 |
| Browser | Chromium 153.0.8010.12, Playwright 1.63.0, Python 3.14.7 | Firefox 155.0, Playwright 1.63.0, Python 3.14.7 |
| Reported renderer | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)` — software | `Apple M1, or similar` — hardware |
| Clean checkout | yes | yes |

Both revisions contain the same measured `src/` and `benchmarks/` trees; `8cec4f2`
only adds the summary derivation script and its tests on top of `017289a`. Exact
resolved Julia `Project.toml` and `Manifest.toml` files are archived inside each
run and are required to stay unchanged for its duration.

- Linux/Chromium: [run record and 42 file hashes](comparison/2026-09-21-017289a-chromium-run.json),
  [derived statistics](comparison/2026-09-21-017289a-chromium-summary.json), and the
  [complete raw archive](comparison/2026-09-21-017289a-chromium.tar.gz)
  (43 files; SHA-256 `d8eb85eee5db739ad996bdb2f5f3e884743a89b89c903af7b9be49151842899a`).
- macOS/Firefox: [run record and 42 file hashes](comparison/2026-09-21-8cec4f2-firefox-run.json),
  [derived statistics](comparison/2026-09-21-8cec4f2-firefox-summary.json), and the
  [complete raw archive](comparison/2026-09-21-8cec4f2-firefox.tar.gz)
  (43 files; SHA-256 `92b99487afdd6c18585b57b1a41b56fc558374553373c1b5a4f0a22760db62f6`).

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
| 16 | 1 | 0.0194 [0.0425] | 0.0029 [0.0036] | 0.0258 [0.0258] | 0.0211 [0.0322] |
| 16 | 2 | 0.0204 [0.0213] | 0.0026 [0.0030] | 0.0258 [0.0271] | 0.0259 [0.0300] |
| 64 | 1 | 0.0883 [0.1674] | 0.0261 [0.0481] | 0.4146 [0.4265] | 0.0681 [0.0966] |
| 64 | 2 | 0.1009 [0.1533] | 0.0263 [0.0336] | 0.4071 [0.4182] | 0.0682 [0.1074] |
| 256 | 1 | 0.3174 [0.4930] | 0.4355 [0.4458] | 6.5610 [6.6747] | 1.0464 [1.1080] |
| 256 | 2 | 0.3298 [0.4415] | 0.4348 [0.4549] | 6.5441 [6.5777] | 1.1097 [1.1197] |
| 1,024 | 1 | 1.2842 [1.7486] | 6.7634 [6.7925] | 105.0718 [106.5205] | 16.6172 [16.8560] |
| 1,024 | 2 | 1.4326 [1.6523] | 6.7582 [6.7905] | 104.7490 [106.6261] | 16.7006 [17.0063] |

**macOS / Firefox host:**

| Parameters | Pass | Diff3D reverse AD | Julia ForwardDiff | Julia central difference | three.js central difference |
|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 0.0287 [0.3074] | 0.0028 [0.0035] | 0.0183 [0.1025] | 0.0202 [0.1067] |
| 16 | 2 | 0.0303 [0.1782] | 0.0030 [0.0037] | 0.0179 [1.6670] | 0.0202 [0.0816] |
| 64 | 1 | 0.1670 [8.6544] | 0.0315 [0.0412] | 0.3304 [5.8194] | 0.0611 [3.1304] |
| 64 | 2 | 0.1394 [11.2605] | 0.0355 [0.1648] | 0.2795 [6.8110] | 0.0575 [6.4649] |
| 256 | 1 | 0.6783 [0.8812] | 0.5548 [1.9023] | 10.8354 [63.4633] | 1.0370 [6.8542] |
| 256 | 2 | 0.6146 [10.8933] | 0.4864 [1.8629] | 17.2556 [70.0534] | 6.2565 [48.5912] |
| 1,024 | 1 | 9.0138 [77.1057] | 53.5998 [111.5650] | 305.1523 [571.8335] | 44.6340 [130.4581] |
| 1,024 | 2 | 5.4748 [53.3995] | 50.7525 [107.4771] | 325.2635 [592.1810] | 63.5831 [142.6885] |

At 1,024 parameters, reverse AD used one objective evaluation, ForwardDiff used
86, and each central-difference method used 2,048. The evaluated objective and
AD work differ within those calls; these counts are not engine-speed ratios.
ForwardDiff had the lowest median of the four methods at 16 and 64 parameters in
every pass of both runs, and at 256 parameters on the macOS host; Diff3D reverse
AD had the lowest median at 256 parameters on the Linux runner and at 1,024
parameters in both runs. Three.js central differences were faster than Julia
central differences at 64, 256 and 1,024 parameters in every pass of both runs.
They were also faster than Diff3D reverse AD at 64 parameters in every pass of
both runs, and at 16 parameters on the macOS host. Diff3D's reverse-AD advantage
in this objective appears only as the parameter count grows.

Julia's compilation cost matters for short jobs. At 16 parameters, first-call
times were 0.425/0.420 seconds for reverse AD and 0.533/0.515 seconds for
ForwardDiff on the Linux runner, versus 0.615/0.608 milliseconds for the three.js
finite-difference call. The loaded macOS host needed 5.371/5.643 and 6.682/4.085
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
| static-16 | 2.888 [24.037] | 0.275 [0.338] | 3.738 [24.087] | 0.237 [0.325] |
| instanced-16 | 1.338 [21.375] | 0.250 [0.325] | 1.337 [22.487] | 0.238 [0.363] |
| dynamic-16 | 4.287 [25.375] | 0.238 [0.325] | 3.188 [25.113] | 0.250 [0.338] |
| static-128 | 16.362 [18.138] | 0.525 [1.100] | 18.463 [19.863] | 0.537 [0.900] |
| instanced-128 | 1.513 [26.975] | 0.250 [0.375] | 9.100 [28.500] | 0.288 [0.562] |
| dynamic-128 | 16.900 [23.125] | 0.638 [0.875] | 16.412 [19.825] | 0.575 [0.763] |
| static-512 | 51.200 [56.600] | 1.088 [1.325] | 53.100 [58.600] | 1.175 [1.600] |
| instanced-512 | 0.888 [43.775] | 0.250 [0.337] | 0.675 [1.188] | 0.250 [0.300] |
| dynamic-512 | 54.162 [61.763] | 1.363 [1.950] | 54.400 [61.925] | 1.263 [3.025] |

**macOS / Firefox host (hardware renderer, busy machine):**

| Fixture | Diff3D pass 1 | three.js pass 1 | Diff3D pass 2 | three.js pass 2 |
|---|---:|---:|---:|---:|
| static-16 | 25.625 [76.000] | 2.125 [8.000] | 11.875 [38.375] | 3.125 [10.375] |
| instanced-16 | 7.375 [14.625] | 2.375 [8.875] | 2.125 [6.250] | 1.875 [13.125] |
| dynamic-16 | 11.500 [36.125] | 3.250 [7.500] | 15.375 [29.500] | 3.625 [7.875] |
| static-128 | 54.875 [94.625] | 5.000 [11.625] | 65.500 [118.000] | 2.625 [15.500] |
| instanced-128 | 4.625 [44.375] | 2.125 [18.125] | 1.500 [3.875] | 1.375 [6.375] |
| dynamic-128 | 137.250 [205.375] | 11.125 [28.375] | 52.625 [88.125] | 2.250 [5.750] |
| static-512 | 227.750 [291.000] | 13.750 [31.125] | 198.250 [303.000] | 8.250 [12.125] |
| instanced-512 | 4.125 [17.000] | 1.250 [7.250] | 3.375 [22.875] | 1.625 [6.250] |
| dynamic-512 | 248.375 [427.375] | 10.125 [28.625] | 175.625 [263.375] | 9.375 [13.500] |

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
| static-16 | 467 / 478 | 89 / 79 | 211.0 / 40.7 | 553.3 / 139.1 |
| instanced-16 | 386 / 365 | 60 / 61 | 172.0 / 40.0 | 553.3 / 139.1 |
| dynamic-16 | 365 / 373 | 60 / 65 | 214.8 / 41.1 | 553.3 / 139.1 |
| static-128 | 380 / 432 | 62 / 67 | 528.2 / 46.1 | 557.2 / 139.6 |
| instanced-128 | 350 / 345 | 60 / 60 | 180.6 / 40.6 | 557.2 / 139.6 |
| dynamic-128 | 387 / 380 | 68 / 66 | 557.8 / 48.3 | 557.2 / 139.6 |
| static-512 | 461 / 488 | 68 / 73 | 1611.9 / 61.2 | 573.3 / 141.2 |
| instanced-512 | 338 / 366 | 66 / 64 | 210.5 / 42.4 | 573.3 / 141.2 |
| dynamic-512 | 472 / 469 | 82 / 79 | 1730.1 / 68.4 | 573.3 / 141.2 |

**macOS / Firefox host:**

| Fixture | Diff3D pass 1 / 2 | three.js pass 1 / 2 | Diff3D HTML / gzip kB | three.js HTML / gzip kB |
|---|---:|---:|---:|---:|
| static-16 | 2,643 / 2,194 | 1,749 / 2,118 | 211.0 / 40.7 | 553.3 / 139.1 |
| instanced-16 | 1,928 / 2,988 | 1,026 / 1,703 | 172.0 / 40.0 | 553.3 / 139.1 |
| dynamic-16 | 1,864 / 2,370 | 1,070 / 1,505 | 214.8 / 41.1 | 553.3 / 139.1 |
| static-128 | 2,353 / 2,454 | 1,542 / 1,804 | 528.2 / 46.1 | 557.2 / 139.6 |
| instanced-128 | 2,683 / 956 | 1,254 / 1,048 | 180.6 / 40.6 | 557.2 / 139.6 |
| dynamic-128 | 3,215 / 1,879 | 2,527 / 671 | 557.8 / 48.3 | 557.2 / 139.6 |
| static-512 | 3,868 / 2,616 | 1,725 / 1,008 | 1611.9 / 61.2 | 573.3 / 141.2 |
| instanced-512 | 2,216 / 2,529 | 1,203 / 931 | 210.5 / 42.4 | 573.3 / 141.2 |
| dynamic-512 | 2,169 / 1,790 | 1,174 / 1,549 | 1730.1 / 68.4 | 573.3 / 141.2 |

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

# Diff3D 1.0 comparison with three.js

The measured advantages are native Julia differentiation and smaller compressed
standalone artifacts in these fixtures. At 1,024 depth parameters, the three.js
central-difference baseline took 6.8× and 6.9× as long as Diff3D reverse AD by
median time in the two passes. Three.js had lower median browser frame times in
17 of 18 measurements. This evidence supports a Julia numerical-workflow use
case; it does not establish overall rendering superiority or three.js parity.

**Measurement qualification:** this was a shared, busy host. Its one-minute load
average was 23.52 at the start and 19.08 at the end on 10 logical CPUs. Reversing
execution order exposed substantial timing variation. Treat the numbers as
observations of this run, not isolated-machine performance guarantees. No causal
claim about the remaining browser cost is established by these measurements.

## Source and reproducibility

- Date: 2026-09-20. Clean, unchanged Diff3D source:
  [`284eadd7b899661f4f1c78a0d55d4ede45ffa75c`](https://github.com/jake-w-liu/Diff3D.jl/tree/284eadd7b899661f4f1c78a0d55d4ede45ffa75c),
  package version 1.0.0; Julia 1.12.7, one thread, optimization level 2;
  ForwardDiff 1.4.5. Exact Julia project/manifest files are archived.
- Host: Apple M5, arm64, macOS 26.5.1, 10 logical CPUs. Julia reports CPU target
  `apple-m1`; Firefox reports renderer `Apple M1, or similar`, vendor `Apple`.
  Those strings are preserved as reported and are not a separate GPU-model test.
- Three.js 0.186.0, esbuild 0.28.2, Node 26.5.0; Playwright 1.63.0,
  Firefox 155.0, Python 3.14.7. Both engines reported the same browser renderer.
- [Run record and 42 file hashes](comparison/2026-09-20-284eadd-run.json),
  [readable derived statistics](comparison/2026-09-20-284eadd-summary.json), and
  [complete raw evidence archive](comparison/2026-09-20-284eadd.tar.gz).
  The archive includes all 43 original files: run record, raw samples, commands,
  logs, fixtures, dependency snapshots and 18 working HTML artifacts.
  Archive SHA-256: `b9b61b309a756085f4753b32f9b10aa7500c19551e7cbd6e4eefb02899de6413`.

Follow the [comparison protocol](../../benchmarks/threejs/README.md) using the
recorded source and environment. Run `python benchmarks/threejs/run.py OUTPUT
--browser firefox` with a new output directory. Both orders must finish with
`status = passed`; preserve all raw files. The release CI also replays the
protocol on Linux/Chromium with software rendering. Its candidate result is a
separate gate in [the release tracker](../../RELEASE_PLAN.md).

## Numerical objective and accuracy

Each point has one variable depth. Both implementations project identical
Float64 points through the same perspective matrix and minimize the same mean
squared coordinate error. An algebraic oracle checks the loss and complete
gradient independently of either implementation. Central differences use the
same step, `1e-5`. All initial, warmup and timed gradients are checked, with the
timed-result check outside the clock. The largest timed-gradient absolute error
was **3.48e-13 or less** across all 32 method/size/pass records. All four methods
recovered the 16 known depths within **5.0e-11** after the same 1,000 updates.

The three.js baseline uses its public Matrix4/Vector3 operations plus explicit
central differences. A hand-derived gradient or another JavaScript AD system
could produce different results; neither is measured here. These are numerical
projection-gradient measurements, not differentiable image-rendering timings.

Each cell is **median [95th percentile] milliseconds per gradient**, from 21
samples after five warmups. The percentile is the nearest-rank statistic
(`ceil(0.95 × 21)`, the 20th sorted sample). Pass 1 runs Julia first; pass 2 runs
Node first. Every method and both orders are shown.

| Parameters | Pass | Diff3D reverse AD | Julia ForwardDiff | Julia central difference | three.js central difference |
|---:|---:|---:|---:|---:|---:|
| 16 | 1 | 0.1050 [0.7096] | 0.0035 [0.0654] | 0.0188 [0.0670] | 0.0695 [0.2873] |
| 16 | 2 | 0.0332 [0.2452] | 0.0039 [0.0045] | 0.0187 [0.0240] | 0.0191 [0.0248] |
| 64 | 1 | 0.1991 [1.0840] | 0.0425 [0.1914] | 0.3935 [0.5882] | 0.0587 [0.1422] |
| 64 | 2 | 0.1311 [0.2194] | 0.0516 [0.2194] | 0.3927 [1.2559] | 0.0564 [0.1186] |
| 256 | 1 | 0.8705 [3.4192] | 0.8542 [1.8762] | 8.4596 [44.8564] | 1.7337 [4.5395] |
| 256 | 2 | 1.2817 [17.4889] | 1.2451 [6.6484] | 6.1574 [11.7765] | 1.9529 [9.9497] |
| 1,024 | 1 | 4.0925 [19.5025] | 12.6187 [20.0829] | 196.2070 [348.5995] | 27.9323 [70.9915] |
| 1,024 | 2 | 3.6699 [28.0106] | 15.7728 [25.2982] | 134.1733 [207.4279] | 25.4462 [52.4534] |

At 1,024 parameters, reverse AD used one objective evaluation, ForwardDiff used
86, and each central-difference method used 2,048. The evaluated objective and
AD work differ within those calls; these counts are not engine-speed ratios.
ForwardDiff had the lowest median at 16, 64 and 256 parameters in both passes.
Three.js central differences were faster than Julia central differences at
64/256/1,024 parameters in both passes.

Julia's compilation cost matters for short jobs. At 16 parameters, first-call
times were 1.986/1.579 seconds for reverse AD and 2.054/2.001 seconds for
ForwardDiff, versus 0.939/4.327 milliseconds for the three.js finite-difference
call. These clocks exclude process launch and package import; full command
elapsed times are in the run record. First calls at larger sizes can include
further specialization and are retained in the raw data.

Warmed Julia allocation totals at 1,024 parameters were **4,481,488 bytes** for
reverse AD, **124,528 bytes** for ForwardDiff and **16,512 bytes** for central
differences in both passes. Reverse AD's time advantage here costs more allocated
memory. Node records retained heap/ArrayBuffer changes after GC and an RSS
snapshot, not total allocations or peak memory. Its 1,024-element result stores
8,192 bytes. A zero retained-heap delta does not mean zero allocation; these
memory measures do not support a cross-language allocation ratio.

## Browser frames, startup and artifact sizes

Nine fixtures cover 16/128/512 separate static meshes, one instance batch, and
separate animated meshes. Both engines draw the same triangles, colors, camera,
256×256 buffer and animation times, with antialiasing disabled and linear RGB.
Diff3D exports WebGL 1; three.js uses WebGL 2. The protocol calls `gl.finish()`
after every frame and includes the shared instrumentation/completion checks.

All 18 paired measurements passed the independent initial/final pixel oracle,
draw/triangle counts, animation checks, zero external-request check and stable
GPU-resource counts. There were **zero cross-engine pixel mismatches outside
edge ties**. The archived Firefox run permits one byte of channel quantization
and a 0.002-pixel edge tolerance; it does not require CPU/soft-render parity.

A later Chromium/SwiftShader check exposed the fixed edge tolerance as too
narrow for its reported four-bit subpixel grid: both engines produced identical
buffers, including 23 pixels that disagreed with the continuous-coordinate
oracle. All non-edge pixels matched an independent oracle after vertex snapping
to that grid. The current harness records `SUBPIXEL_BITS` and uses
`0.002 + sqrt(2) * 2^(-SUBPIXEL_BITS)` for edge coverage, while still rejecting
incorrect edge colors and shifted/corrupted images. The archived timings and
their source remain unchanged. See the [current protocol](../../benchmarks/threejs/README.md)
and [verification evidence](evidence.md#chromium-subpixel-precision-oracle).

Warmed cells show **median [95th percentile] milliseconds per completed frame**.
Each sample is an eight-frame batch; there are 21 samples after five warmup
batches. These are synchronized frame costs, not monitor-refresh FPS.

| Fixture | Diff3D pass 1 | three.js pass 1 | Diff3D pass 2 | three.js pass 2 |
|---|---:|---:|---:|---:|
| static-16 | 10.875 [30.875] | 5.000 [19.000] | 9.250 [17.250] | 2.125 [8.375] |
| instanced-16 | 5.125 [23.875] | 3.875 [10.750] | 6.500 [14.000] | 3.375 [7.625] |
| dynamic-16 | 14.500 [30.875] | 4.875 [17.250] | 10.375 [16.875] | 2.625 [18.500] |
| static-128 | 69.750 [98.875] | 4.125 [17.875] | 32.375 [58.125] | 3.500 [14.000] |
| instanced-128 | 5.625 [19.250] | 3.500 [16.625] | 2.375 [12.000] | 1.750 [4.125] |
| dynamic-128 | 67.625 [101.125] | 8.875 [17.500] | 39.625 [77.250] | 5.500 [10.250] |
| static-512 | 213.625 [274.375] | 19.375 [39.500] | 112.375 [142.125] | 9.125 [12.750] |
| instanced-512 | 6.750 [17.375] | 8.125 [14.875] | 5.125 [6.875] | 1.750 [3.250] |
| dynamic-512 | 135.625 [170.125] | 9.750 [18.625] | 134.000 [183.625] | 8.750 [18.125] |

The lone lower Diff3D median, `instanced-512` in pass 1, reverses in pass 2.
The data do not support a consistent browser-rendering speed advantage.

Navigation-to-first-completed-frame times are **milliseconds**, measured
separately from warmed frames. They include local HTML loading and browser
initialization encountered by that page, with no network asset fetch.

| Fixture | Diff3D pass 1 / 2 | three.js pass 1 / 2 | Diff3D HTML / gzip kB | three.js HTML / gzip kB |
|---|---:|---:|---:|---:|
| static-16 | 2966 / 1349 | 1238 / 1509 | 210.2 / 40.3 | 553.3 / 139.1 |
| instanced-16 | 1574 / 1408 | 1080 / 646 | 171.2 / 39.6 | 553.3 / 139.1 |
| dynamic-16 | 1725 / 1312 | 1330 / 878 | 214.0 / 40.7 | 553.3 / 139.1 |
| static-128 | 2244 / 1706 | 923 / 824 | 527.5 / 45.8 | 557.2 / 139.6 |
| instanced-128 | 2196 / 1362 | 1239 / 979 | 179.8 / 40.2 | 557.2 / 139.6 |
| dynamic-128 | 1688 / 1663 | 958 / 845 | 557.0 / 47.9 | 557.2 / 139.6 |
| static-512 | 3119 / 1880 | 1838 / 674 | 1611.1 / 60.8 | 573.3 / 141.2 |
| instanced-512 | 1754 / 1188 | 1012 / 674 | 209.7 / 42.1 | 573.3 / 141.2 |
| dynamic-512 | 1983 / 1786 | 904 / 679 | 1729.3 / 68.0 | 573.3 / 141.2 |

Sizes use decimal kB. Diff3D's artifact is the full standalone viewer; the
three.js artifact is an esbuild bundle of the matched minimal application.
Diff3D's gzip sizes are smaller in every fixture, while its uncompressed
512-mesh static/dynamic exports are larger. This is a delivery-size observation
for these functioning artifacts, not equal-feature bundle-size equivalence.
Both implementations work offline in these checks; offline delivery is not an
exclusive Diff3D capability.

## Capability boundaries and positioning

| Need | Diff3D 1.0 evidence / scope | three.js comparison scope |
|---|---|---|
| Julia objectives and gradients | Public numerical inputs work with ForwardDiff and built-in Float64 reverse AD; projection oracles above and the [installed consumer](consumer_acceptance.jl) check known inverse solutions. | The pinned baseline is JavaScript with explicit central differences. Other derivative implementations are unmeasured. |
| Differentiable image objectives | Explicit soft-render inputs and inverse-rendering optimizers are part of the [compatibility contract](../../docs/src/compatibility.md). Scene extraction and hard visibility have documented limits. | This report does not benchmark a three.js soft-image objective. |
| Browser backend | Standalone WebGL 1 export; Julia callbacks and arbitrary ShaderMaterial export are unsupported. | [WebGLRenderer](https://threejs.org/docs/pages/WebGLRenderer.html) uses WebGL 2; [WebGPURenderer](https://threejs.org/docs/pages/WebGPURenderer.html) supports WebGPU with a WebGL 2 fallback. |
| Compressed glTF assets | Required Draco, Meshopt and Basis extensions are rejected and tested as errors. | [GLTFLoader](https://threejs.org/docs/pages/GLTFLoader.html) supports these paths when the corresponding decoder/transcoder is configured. |

Diff3D's demonstrated role is a Julia graphics and differentiation workflow
with standalone delivery. Browser frame time and compressed-asset/backend
coverage remain concrete areas where this candidate does not match three.js.
Performance on other scenes, GPUs, isolated hosts, WebGPU, JavaScript AD or full
inverse-image workloads requires new matched measurements. Release readiness
also depends on the platform, consumer and documentation gates; a benchmark
win does not replace those checks.

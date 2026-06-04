# Industrial-scale benchmark: renders a 100K+ triangle scene through the hard
# CPU rasterizer and reports timing (warmup + repetitions, median/IQR/min),
# per-frame allocation, and the hardware environment. Writes a CSV record.
#
#   julia --project=Diff3D.jl Diff3D.jl/examples/scalability_bench.jl
#
# Output: logs/threejs_scalability.csv

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Diff3D
using Printf

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const LOGS = joinpath(ROOT, "logs")
isdir(LOGS) || mkpath(LOGS)

function main()
    W, H = 512, 512
    counts = [1000, 5000, 20000, 60000, 120000]          # target triangle counts
    sphere_faces = SphereGeometry(radius=0.7, width_segments=16, height_segments=8).n_faces

    println("Hardware: ", Sys.CPU_NAME, "  cores=", Sys.CPU_THREADS,
            "  julia_threads=", Threads.nthreads(),
            "  mem=", round(Sys.total_memory()/2^30, digits=1), "GB")
    println(@sprintf("%-10s %-12s %-10s %-10s %-10s %-10s", "tris", "img", "median_ms", "iqr_ms", "min_ms", "alloc_MB"))

    rows = String["target_triangles,actual_triangles,width,height,reps,median_ms,iqr_ms,min_ms,alloc_mb"]
    for tgt in counts
        n_inst = max(cld(tgt, sphere_faces), 1)
        scene = build_instanced_scene(n_inst)
        side = ceil(Int, cbrt(n_inst)); c = side * 1.0
        cam = PerspectiveCamera(fov=π/4, aspect=W/H, near=0.1, far=1000.0)
        cam.position = Vec3(c*2.5, c*2.5, c*4.0); cam.target = Vec3(c, c, c)
        br = benchmark_render(scene, cam, W, H; warmup=2, reps=7)
        @printf("%-10d %-12s %-10.2f %-10.2f %-10.2f %-10.1f\n",
                br.triangles, "$(W)x$(H)", br.median_s*1e3, br.iqr_s*1e3, br.min_s*1e3, br.alloc_bytes/1e6)
        push!(rows, @sprintf("%d,%d,%d,%d,%d,%.4f,%.4f,%.4f,%.2f",
              tgt, br.triangles, W, H, br.reps, br.median_s*1e3, br.iqr_s*1e3, br.min_s*1e3, br.alloc_bytes/1e6))
    end

    csv = joinpath(LOGS, "threejs_scalability.csv")
    open(f -> write(f, join(rows, "\n") * "\n"), csv, "w")
    println("BENCH_OK wrote ", csv)
end

main()

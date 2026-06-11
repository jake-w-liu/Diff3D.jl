# --------------------------------------------------------------------------
# Industrial-scale rendering: a large-scene builder, a triangle counter, and a
# benchmark harness with warmup, repetitions, median/IQR, and per-frame
# allocation. Designed to render 100K+ triangle scenes through the hard
# rasterizer while reusing RenderTarget/scratch buffers across frames.
# --------------------------------------------------------------------------

struct BenchResult
    triangles::Int
    width::Int
    height::Int
    reps::Int
    median_s::Float64
    iqr_s::Float64
    min_s::Float64
    alloc_bytes::Int
end

"""Total renderable triangles in a scene (hierarchically visible drawables
only), including InstancedMesh instances."""
function scene_triangle_count(scene::AbstractObject3D)
    n = 0
    for m in collect_meshes(scene)
        n += count_triangles(m.geometry)
    end
    for im in collect_instanced(scene)
        # collect_instanced traverses without pruning invisible subtrees;
        # match collect_meshes' hierarchical visibility.
        _visible_in_tree(im) || continue
        n += instanced_count(im) * count_triangles(im.geometry)
    end
    return n
end

"""
    build_instanced_scene(n_instances; segments)

A scene of `n_instances` spheres laid out on a 3-D grid via a single
`InstancedMesh` (bounded memory: one geometry, `n_instances` transforms).
"""
function build_instanced_scene(n_instances::Int; width_segments=16, height_segments=8)
    geom = SphereGeometry(radius=0.7, width_segments=width_segments, height_segments=height_segments)
    im = InstancedMesh(geom, MeshLambertMaterial(color=Color3(0.7,0.45,0.30)), n_instances)
    side = max(ceil(Int, cbrt(n_instances)), 1)
    for i in 1:n_instances
        k = i - 1
        x = k % side; y = (k ÷ side) % side; z = k ÷ (side * side)
        set_instance_matrix!(im, i, mat4_translation(x*2.0, y*2.0, z*2.0))
    end
    scene = Scene(background=Color3(0.05,0.06,0.1))
    add!(scene, im)
    add!(scene, AmbientLight(intensity=0.4))
    d = DirectionalLight(intensity=0.8, position=Vec3(1.0,1.0,1.0)); d.target = Vec3(0.0,0,0)
    add!(scene, d)
    return scene
end

"""
    benchmark_render(scene, camera, W, H; warmup=2, reps=7, shading=:flat)

Render `scene` `reps` times (after `warmup` untimed frames) into a single reused
`RenderTarget`, returning a [`BenchResult`] with median/IQR/min wall-clock time
and the first frame's allocation. Reusing the target keeps per-frame allocation
bounded (no framebuffer reallocation).
"""
function benchmark_render(scene::Scene, camera::AbstractCamera, W::Int, H::Int;
                          warmup::Int=2, reps::Int=7, shading::Symbol=:flat)
    rt = RenderTarget(W, H)
    for _ in 1:warmup
        render!(rt, scene, camera; shading=shading)
    end
    times = Float64[]
    alloc = 0
    for r in 1:reps
        res = @timed render!(rt, scene, camera; shading=shading)
        push!(times, res.time)
        r == 1 && (alloc = res.bytes)
    end
    sort!(times)
    med = times[(reps + 1) ÷ 2]
    q1 = times[clamp(round(Int, 0.25 * (reps + 1)), 1, reps)]
    q3 = times[clamp(round(Int, 0.75 * (reps + 1)), 1, reps)]
    return BenchResult(scene_triangle_count(scene), W, H, reps, med, q3 - q1, minimum(times), alloc)
end

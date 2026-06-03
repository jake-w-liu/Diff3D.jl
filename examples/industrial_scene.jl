# Industrial-scale scene: >100K triangles, multiple lights, cast shadows, and
# UV-mapped textures, rendered by the engine's z-buffer rasterizer and exported
# through its own PNG/PDF writer.
#
#   julia --project=Three.jl Three.jl/examples/industrial_scene.jl
#
# Output: paper/figs/fig_industrial_scene.{pdf,png}; prints triangle count / time.
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Three

const PROJECT_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const FIGS = joinpath(PROJECT_ROOT, "paper", "figs")
isdir(FIGS) || mkpath(FIGS)

function downsample2x(img)
    Hb, Wb, _ = size(img); H, W = Hb ÷ 2, Wb ÷ 2
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for c in 1:3, i in 1:H, j in 1:W
        i0, j0 = 2i - 1, 2j - 1
        out[i, j, c] = 0.25 * (img[i0, j0, c] + img[i0+1, j0, c] + img[i0, j0+1, c] + img[i0+1, j0+1, c])
    end
    return out
end

function build_scene()
    scene = Scene(background = Color3(0.09, 0.11, 0.15))

    # Large textured ground plane (checkerboard albedo), receives shadows.
    gtex = checker_texture(n = 24, cell = 6, a = Color3(0.55, 0.57, 0.62), b = Color3(0.30, 0.32, 0.38))
    ground = Mesh(PlaneGeometry(width = 44.0, height = 44.0, width_segments = 40, height_segments = 40),
                  MeshStandardMaterial(color = Color3(1.0, 1.0, 1.0), roughness = 0.92, map = gtex);
                  name = "ground", receive_shadow = true)
    ground.rotation = Euler(-π/2, 0.0, 0.0)
    add!(scene, ground)

    # A 5x4 grid of high-tessellation spheres; alternating textured and solid PBR.
    stex = checker_texture(n = 6, cell = 12, a = Color3(0.90, 0.55, 0.30), b = Color3(0.25, 0.45, 0.80))
    cols = [Color3(0.82, 0.30, 0.28), Color3(0.30, 0.68, 0.42),
            Color3(0.30, 0.52, 0.85), Color3(0.88, 0.78, 0.32)]
    idx = 0
    for ix in -2:2, iz in -1:2
        idx += 1
        textured = isodd(idx)
        mat = MeshStandardMaterial(color = textured ? Color3(1.0, 1.0, 1.0) : cols[(idx % 4) + 1],
                                   metalness = 0.1, roughness = 0.45,
                                   map = textured ? stex : nothing)
        s = Mesh(SphereGeometry(radius = 0.85, width_segments = 64, height_segments = 48), mat;
                 cast_shadow = true)
        s.position = Vec3(ix * 2.4, 0.85, iz * 2.4)
        add!(scene, s)
    end

    # Lighting rig: ambient fill + key (shadow caster) + cool fill + warm rim.
    add!(scene, AmbientLight(color = Color3(1.0, 1.0, 1.0), intensity = 0.22))
    key = DirectionalLight(color = Color3(1.0, 0.97, 0.90), intensity = 1.0, position = Vec3(7.0, 13.0, 6.0))
    key.target = Vec3(0.0, 0.0, 0.0); key.cast_shadow = true
    add!(scene, key)
    fill = DirectionalLight(color = Color3(0.55, 0.66, 1.0), intensity = 0.45, position = Vec3(-9.0, 6.0, -5.0))
    fill.target = Vec3(0.0, 0.0, 0.0); add!(scene, fill)
    rim = DirectionalLight(color = Color3(1.0, 0.86, 0.7), intensity = 0.35, position = Vec3(0.0, 4.0, 12.0))
    rim.target = Vec3(0.0, 0.5, 0.0); add!(scene, rim)
    return scene
end

function main()
    W, H = 760, 560; ss = 2
    scene = build_scene()
    tri = sum(count_triangles(m.geometry) for m in collect_meshes(scene))
    nlights = length(collect_lights(scene))

    cam = PerspectiveCamera(fov = π/4.4, aspect = W / H, near = 0.1, far = 200.0)
    cam.position = Vec3(9.5, 8.0, 13.0); cam.target = Vec3(0.0, 0.6, 0.5)

    rt = RenderTarget(W * ss, H * ss)
    @info "Rendering industrial scene" triangles=tri lights=nlights pixels="$(W*ss)x$(H*ss)"
    # Warm up (JIT) once, then time repeats for a true per-frame cost.
    render!(rt, scene, cam; shading = :smooth, shadows = true, shadow_resolution = 2048)
    times = Float64[]
    for _ in 1:4
        push!(times, @elapsed render!(rt, scene, cam; shading = :smooth, shadows = true, shadow_resolution = 2048))
    end
    sort!(times)
    med = 0.5 * (times[2] + times[3])
    img = downsample2x(rt.color)
    save_pdf(joinpath(FIGS, "fig_industrial_scene.pdf"), img; dpi = 200)
    save_png(joinpath(FIGS, "fig_industrial_scene.png"), img)
    println("INDUSTRIAL_OK triangles=$tri lights=$nlights shadows=true textures=true " *
            "render_px=$(W*ss)x$(H*ss) median_frame_s=$(round(med, digits=3)) " *
            "min_frame_s=$(round(times[1], digits=3)) fps=$(round(1/med, digits=2))")
end

main()

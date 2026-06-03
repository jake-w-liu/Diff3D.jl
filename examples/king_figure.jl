# Renders the paper's king figure: a single composition exercising the scene
# graph, every built-in geometry, the full material hierarchy, and multiple
# light types, then exports it through Three.jl's own PNG/PDF writer.
#
#   julia --project=Three.jl Three.jl/examples/king_figure.jl
#
# Output: paper/figs/fig_king_scene.{pdf,png}

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Three

const PROJECT_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const FIGS = joinpath(PROJECT_ROOT, "paper", "figs")
isdir(FIGS) || mkpath(FIGS)

# 2x supersampling: render large, then box-average down for clean edges since
# the hard rasterizer is point-sampled (one sample per pixel, no MSAA).
function downsample2x(img)
    Hb, Wb, _ = size(img)
    H, W = Hb ÷ 2, Wb ÷ 2
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for c in 1:3, i in 1:H, j in 1:W
        i0, j0 = 2i - 1, 2j - 1
        out[i, j, c] = 0.25 * (img[i0, j0, c] + img[i0+1, j0, c] +
                               img[i0, j0+1, c] + img[i0+1, j0+1, c])
    end
    return out
end

function build_scene()
    scene = Scene(background = Color3(0.06, 0.07, 0.10))

    # Ground plane, laid flat (PlaneGeometry normal is +Z, rotate to +Y), with a
    # checkerboard albedo texture (UV-mapped, per-pixel sampled) that also receives
    # the cast shadows.
    ground = Mesh(PlaneGeometry(width = 24.0, height = 24.0, width_segments = 24, height_segments = 24),
                  MeshStandardMaterial(color = Color3(1.0, 1.0, 1.0), metalness = 0.0, roughness = 0.92,
                                       map = checker_texture(n = 12, cell = 12,
                                             a = Color3(0.60, 0.62, 0.67),
                                             b = Color3(0.34, 0.36, 0.42)));
                  name = "ground", receive_shadow = true)
    ground.rotation = Euler(-π/2, 0.0, 0.0)
    ground.position = Vec3(0.0, 0.0, 0.0)
    add!(scene, ground)

    # Reflective sphere — PBR metal (metalness-roughness workflow).
    sphere = Mesh(SphereGeometry(radius = 1.0, width_segments = 64, height_segments = 48),
                  MeshStandardMaterial(color = Color3(0.95, 0.78, 0.22),
                                       metalness = 0.9, roughness = 0.25);
                  name = "sphere", cast_shadow = true)
    sphere.position = Vec3(-2.3, 1.0, 0.0)
    add!(scene, sphere)

    # Textured box — checkerboard albedo over a PBR base.
    box = Mesh(BoxGeometry(width = 1.5, height = 1.5, depth = 1.5),
               MeshStandardMaterial(color = Color3(1.0, 1.0, 1.0), metalness = 0.0, roughness = 0.6,
                                    map = checker_texture(n = 4, cell = 16,
                                          a = Color3(0.85, 0.30, 0.22),
                                          b = Color3(0.95, 0.82, 0.32)));
               name = "box", cast_shadow = true)
    box.position = Vec3(0.2, 0.75, -1.7)
    box.rotation = Euler(0.0, π/6, 0.0)
    add!(scene, box)

    # Glossy torus knot — Blinn-Phong specular highlight.
    knot = Mesh(TorusKnotGeometry(radius = 0.9, tube = 0.30, tubular_segments = 128, radial_segments = 16),
                MeshPhongMaterial(color = Color3(0.15, 0.55, 0.85),
                                  specular = Color3(0.9, 0.9, 0.9), shininess = 80.0);
                name = "knot", cast_shadow = true)
    knot.position = Vec3(2.4, 1.2, 0.4)
    add!(scene, knot)

    # Rougher PBR cylinder.
    cyl = Mesh(CylinderGeometry(radius_top = 0.55, radius_bottom = 0.55, height = 1.6, radial_segments = 48),
               MeshStandardMaterial(color = Color3(0.25, 0.70, 0.45),
                                    metalness = 0.1, roughness = 0.6);
               name = "cylinder", cast_shadow = true)
    cyl.position = Vec3(1.1, 0.8, 2.1)
    add!(scene, cyl)

    # Normal-mapped icosahedron — surface orientation visualised as RGB.
    ico = Mesh(IcosahedronGeometry(radius = 0.85),
               MeshNormalMaterial(); name = "icosahedron", cast_shadow = true)
    ico.position = Vec3(-1.1, 0.85, 2.3)
    ico.rotation = Euler(0.3, 0.6, 0.0)
    add!(scene, ico)

    # Lighting rig: fill ambient + key/back/rim directional lights of different hue.
    add!(scene, AmbientLight(color = Color3(1.0, 1.0, 1.0), intensity = 0.28))
    key  = DirectionalLight(color = Color3(1.0, 0.96, 0.88), intensity = 0.95, position = Vec3(5.0, 8.0, 5.0))
    key.target = Vec3(0.0, 0.5, 0.0)
    key.cast_shadow = true       # key light casts shadows onto the textured ground
    add!(scene, key)
    back = DirectionalLight(color = Color3(0.55, 0.65, 1.0), intensity = 0.55, position = Vec3(-6.0, 4.0, -4.0))
    back.target = Vec3(0.0, 0.5, 0.0)
    add!(scene, back)
    rim  = DirectionalLight(color = Color3(1.0, 0.85, 0.7), intensity = 0.40, position = Vec3(0.0, 3.0, 9.0))
    rim.target = Vec3(0.0, 0.8, 0.0)
    add!(scene, rim)

    return scene
end

function main()
    W, H = 900, 650
    ss = 2                       # supersample factor
    scene = build_scene()
    tri = sum(count_triangles(m.geometry) for m in collect_meshes(scene))

    cam = PerspectiveCamera(fov = π/4.6, aspect = W / H, near = 0.1, far = 100.0)
    cam.position = Vec3(5.0, 4.0, 7.7)
    cam.target = Vec3(0.2, 0.7, 0.2)

    rt = RenderTarget(W * ss, H * ss)
    @info "Rendering king scene" triangles=tri pixels="$(W*ss)x$(H*ss)"
    t = @elapsed render!(rt, scene, cam; shading = :smooth, shadows = true, shadow_resolution = 2048)
    img = downsample2x(rt.color)

    pdf = joinpath(FIGS, "fig_king_scene.pdf")
    png = joinpath(FIGS, "fig_king_scene.png")
    save_pdf(pdf, img; dpi = 200)
    save_png(png, img)
    @info "King figure written" pdf png render_seconds=round(t, digits=2) triangles=tri
    println("KING_OK triangles=$tri seconds=$(round(t, digits=2))")
end

main()

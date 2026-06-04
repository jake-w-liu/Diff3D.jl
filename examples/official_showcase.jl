# Diff3D.jl official-example-inspired showcase.
#
# Inspired by recurring themes in the official three.js examples:
# instancing, particles/points, sprites, shadows, bloom, outlines, SSAO,
# and depth-of-field. This script renders three PNGs with this package's
# CPU renderer and post-processing pipeline.
#
# Run:
#   julia --project=. examples/official_showcase.jl
#
# Output:
#   examples/output/showcase_instancing_bloom.png
#   examples/output/showcase_particles_sprites.png
#   examples/output/showcase_postprocessing_dof.png

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D
using Random

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function save_showcase(name::String, img)
    path = joinpath(OUT, name)
    save_png(path, img)
    println("wrote $path")
    return path
end

function render_scene(scene, camera, width::Int, height::Int; shading=:smooth, shadows=false)
    rt = RenderTarget(width, height)
    render!(rt, scene, camera; shading=shading, shadows=shadows, shadow_resolution=1024)
    return rt
end

function camera(width, height; position=Vec3(7.0, 5.0, 9.0), target=Vec3(0.0, 0.8, 0.0), fov=pi/4.3)
    cam = PerspectiveCamera(fov=fov, aspect=width/height, near=0.1, far=160.0)
    cam.position = position
    cam.target = target
    return cam
end

function instancing_bloom_demo()
    W, H = 720, 460
    scene = Scene(background=Color3(0.015, 0.018, 0.026))
    add!(scene, AmbientLight(color=Color3(0.7, 0.8, 1.0), intensity=0.22))
    key = DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.05, position=Vec3(5.0, 9.0, 7.0))
    key.target = Vec3(0.0, 0.0, 0.0)
    key.cast_shadow = true
    add!(scene, key)
    add!(scene, DirectionalLight(color=Color3(0.35, 0.56, 1.0), intensity=0.55, position=Vec3(-7.0, 4.0, -6.0)))

    ground = Mesh(PlaneGeometry(width=22.0, height=22.0, width_segments=28, height_segments=28),
                  MeshStandardMaterial(color=Color3(0.32, 0.34, 0.40), roughness=0.95);
                  receive_shadow=true)
    ground.rotation = Euler(-pi/2, 0.0, 0.0)
    add!(scene, ground)

    mat = MeshStandardMaterial(color=Color3(0.28, 0.76, 0.95), metalness=0.25, roughness=0.32)
    geo = IcosahedronGeometry(radius=0.34)
    n = 13
    inst = InstancedMesh(geo, mat, n*n; cast_shadow=true)
    k = 0
    for ix in 1:n, iz in 1:n
        x = (ix - (n + 1) / 2) * 0.82
        z = (iz - (n + 1) / 2) * 0.82
        wave = 0.58 + 0.46 * sin(0.8*x + 0.65*z)
        rot = mat4_rotation_y(0.45*x) * mat4_rotation_x(0.25*z)
        scale = mat4_scaling(0.75 + 0.25*wave, 0.75 + 0.25*wave, 0.75 + 0.25*wave)
        k += 1
        set_instance_matrix!(inst, k, mat4_translation(x, wave, z) * rot * scale)
    end
    add!(scene, inst)

    cam = camera(W, H; position=Vec3(7.5, 6.2, 8.6), target=Vec3(0.0, 0.7, 0.0), fov=pi/4.0)
    rt = render_scene(scene, cam, W, H; shading=:flat, shadows=true)

    composer = EffectComposer()
    add_pass!(composer, bloom_pass(threshold=0.42, intensity=0.95, radius=5))
    add_pass!(composer, outline_pass(rt.depth; threshold=0.04, color=Color3(0.02, 0.03, 0.04)))
    add_pass!(composer, fxaa_pass())
    img = compose(composer, rt.color)
    return save_showcase("showcase_instancing_bloom.png", img)
end

function positions_geometry(points)
    positions = Float64[]
    for p in points
        append!(positions, (p.x, p.y, p.z))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], length(points), 0)
end

function segment_geometry(segments)
    positions = Float64[]
    for (a, b) in segments
        append!(positions, (a.x, a.y, a.z, b.x, b.y, b.z))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], 2length(segments), 0)
end

function particles_sprites_demo()
    W, H = 720, 460
    Random.seed!(151)
    scene = Scene(background=Color3(0.01, 0.012, 0.025))

    pts = Vec3{Float64}[]
    for i in 1:360
        t = 0.18 * i
        r = 0.028 * i
        y = 0.014 * i - 2.5
        push!(pts, Vec3(r*cos(t), y, r*sin(t)))
    end
    cloud = PointsObject(positions_geometry(pts), PointsMaterial(color=Color3(0.62, 0.86, 1.0), size=3.0))
    add!(scene, cloud)

    sprite_mat_a = MeshBasicMaterial(color=Color3(1.0, 0.52, 0.28), side=:double)
    sprite_mat_b = MeshBasicMaterial(color=Color3(0.56, 1.0, 0.72), side=:double)
    for (i, p) in enumerate(pts[1:30:end])
        sp = Sprite(isodd(i) ? sprite_mat_a : sprite_mat_b)
        sp.position = p + Vec3(0.0, 0.16, 0.0)
        s = 0.16 + 0.035 * (i % 4)
        sp.scale = Vec3(s, s, s)
        add!(scene, sp)
    end

    cam = camera(W, H; position=Vec3(4.2, 1.7, 8.4), target=Vec3(0.2, 0.1, 0.0), fov=pi/3.2)
    rt = render_scene(scene, cam, W, H; shading=:flat)

    composer = EffectComposer()
    add_pass!(composer, bloom_pass(threshold=0.26, intensity=0.75, radius=3))
    add_pass!(composer, fxaa_pass())
    img = compose(composer, rt.color)
    return save_showcase("showcase_particles_sprites.png", img)
end

function postprocessing_dof_demo()
    W, H = 720, 460
    scene = Scene(background=Color3(0.055, 0.060, 0.075))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.22))
    key = DirectionalLight(color=Color3(1.0, 0.92, 0.78), intensity=0.95, position=Vec3(5.0, 9.0, 5.0))
    key.target = Vec3(0.0, 0.7, 0.0)
    key.cast_shadow = true
    add!(scene, key)
    add!(scene, DirectionalLight(color=Color3(0.45, 0.60, 1.0), intensity=0.6, position=Vec3(-7.0, 5.0, -3.0)))

    floor_tex = checker_texture(n=12, cell=8, a=Color3(0.55, 0.57, 0.64), b=Color3(0.26, 0.28, 0.34))
    floor = Mesh(PlaneGeometry(width=20.0, height=24.0, width_segments=24, height_segments=24),
                 MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0), roughness=0.88, map=floor_tex);
                 receive_shadow=true)
    floor.rotation = Euler(-pi/2, 0.0, 0.0)
    add!(scene, floor)

    colors = [Color3(0.95, 0.35, 0.26), Color3(0.26, 0.72, 0.96), Color3(0.95, 0.78, 0.24), Color3(0.46, 0.86, 0.48)]
    for row in 1:5, col in 1:5
        z = -5.5 + 2.0 * row
        x = -4.2 + 2.1 * col
        radius = 0.38 + 0.055 * row
        mat = MeshStandardMaterial(color=colors[mod1(row + col, length(colors))], metalness=0.15, roughness=0.42)
        obj = isodd(row + col) ?
            Mesh(SphereGeometry(radius=radius, width_segments=32, height_segments=20), mat; cast_shadow=true) :
            Mesh(TorusKnotGeometry(radius=radius, tube=0.13, tubular_segments=56, radial_segments=10), mat; cast_shadow=true)
        obj.position = Vec3(x, radius + 0.05, z)
        obj.rotation = Euler(0.2row, 0.35col, 0.1row)
        add!(scene, obj)
    end

    cam = camera(W, H; position=Vec3(4.8, 4.4, 10.0), target=Vec3(0.2, 0.55, 0.6), fov=pi/4.6)
    rt = render_scene(scene, cam, W, H; shading=:smooth, shadows=true)
    finite_depths = sort([d for d in vec(rt.depth) if isfinite(d)])
    focus = finite_depths[max(1, length(finite_depths) ÷ 2)]

    composer = EffectComposer()
    add_pass!(composer, ssao_pass(rt.depth; radius=3.2, intensity=0.55, samples=10))
    add_pass!(composer, outline_pass(rt.depth; threshold=0.035, color=Color3(0.025, 0.028, 0.035)))
    add_pass!(composer, bokeh_pass(depth=rt.depth, focus_depth=focus, aperture=18.0))
    add_pass!(composer, bloom_pass(threshold=0.55, intensity=0.35, radius=3))
    add_pass!(composer, fxaa_pass())
    img = compose(composer, rt.color)
    return save_showcase("showcase_postprocessing_dof.png", img)
end

function main()
    println("Diff3D.jl showcase inspired by official three.js examples")
    paths = String[]
    push!(paths, instancing_bloom_demo())
    push!(paths, particles_sprites_demo())
    push!(paths, postprocessing_dof_demo())
    println("SHOWCASE_OK files=$(length(paths))")
end

main()

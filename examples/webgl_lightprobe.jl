# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lightprobe

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const LIGHTPROBE_CUBE_SIZE = 32
const LIGHTPROBE_SUBJECT_RADIUS = 5.0
const LIGHTPROBE_CAMERA_POSITION = Vec3(0.0, 0.0, 30.0)
const LIGHTPROBE_POSITION = Vec3(-10.0, 0.0, 0.0)

function lightprobe_cube_face_direction(face::Int, u::Float64, v::Float64)
    dir = if face == 1       # +X
        Vec3(1.0, 2v - 1, 1 - 2u)
    elseif face == 2         # -X
        Vec3(-1.0, 2v - 1, 2u - 1)
    elseif face == 3         # +Y
        Vec3(2u - 1, 1.0, 1 - 2v)
    elseif face == 4         # -Y
        Vec3(2u - 1, -1.0, 2v - 1)
    elseif face == 5         # +Z
        Vec3(2u - 1, 2v - 1, 1.0)
    elseif face == 6         # -Z
        Vec3(1 - 2u, 2v - 1, -1.0)
    else
        throw(ArgumentError("cube face index must be in 1:6"))
    end
    normalize(dir)
end

function lightprobe_environment_color(dir::Vec3)
    up = clamp(0.5 + 0.5 * dir.y, 0.0, 1.0)
    horizon = exp(-abs(dir.y) * 4.2)
    courtyard = 0.5 + 0.5 * cos(5.0 * atan(dir.x, dir.z))
    sun_dir = normalize(Vec3(-0.42, 0.58, 0.70))
    sun = max(dot(dir, sun_dir), 0.0)^28
    sky = Color3(0.16 + 0.22 * up, 0.25 + 0.36 * up, 0.42 + 0.42 * up)
    stone = Color3(0.58 + 0.18 * courtyard, 0.49 + 0.13 * courtyard, 0.38 + 0.08 * courtyard)
    warm = Color3(1.0, 0.78, 0.48) * (0.55 * sun)
    c = sky * (0.58 + 0.18 * up) + stone * (0.24 + 0.42 * horizon) + warm
    return Color3(clamp(c.r, 0.0, 1.0), clamp(c.g, 0.0, 1.0), clamp(c.b, 0.0, 1.0))
end

function lightprobe_face_texture(face::Int; size::Int=LIGHTPROBE_CUBE_SIZE)
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = 1.0 - (y - 0.5) / size
        color = lightprobe_environment_color(lightprobe_cube_face_direction(face, u, v))
        data[y, x, 1] = color.r
        data[y, x, 2] = color.g
        data[y, x, 3] = color.b
    end
    tex = Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:linear,
                  min_filter=:linear_mipmap_linear, colorspace=:linear)
    generate_mipmaps!(tex)
    return tex
end

function lightprobe_cube_texture(; size::Int=LIGHTPROBE_CUBE_SIZE)
    CubeTexture(ntuple(face -> lightprobe_face_texture(face; size=size), 6))
end

function color_add(a::Color3, b::Color3)
    Color3(a.r + b.r, a.g + b.g, a.b + b.b)
end

function color_scale(c::Color3, s::Float64)
    Color3(c.r * s, c.g * s, c.b * s)
end

function lightprobe_coefficients(env::CubeTexture)
    dc = Color3(0.0, 0.0, 0.0)
    mx = Color3(0.0, 0.0, 0.0)
    my = Color3(0.0, 0.0, 0.0)
    mz = Color3(0.0, 0.0, 0.0)
    weight_sum = 0.0
    for face in 1:6
        tex = env.faces[face]
        height, width, _ = size(tex.data)
        for y in 1:height, x in 1:width
            u = (x - 0.5) / width
            v = 1.0 - (y - 0.5) / height
            sx = 2u - 1
            sy = 2v - 1
            weight = (1 + sx^2 + sy^2)^(-1.5)
            dir = lightprobe_cube_face_direction(face, u, v)
            sample = Color3(tex.data[y, x, 1], tex.data[y, x, 2], tex.data[y, x, 3])
            dc = color_add(dc, color_scale(sample, weight))
            mx = color_add(mx, color_scale(sample, weight * dir.x))
            my = color_add(my, color_scale(sample, weight * dir.y))
            mz = color_add(mz, color_scale(sample, weight * dir.z))
            weight_sum += weight
        end
    end
    scale = 1.0 / weight_sum
    (color_scale(dc, scale),
     color_scale(mx, 3.0 * scale),
     color_scale(my, 3.0 * scale),
     color_scale(mz, 3.0 * scale))
end

function lightprobe_helper_geometry(; radius::Float64=1.0, segments::Int=32)
    positions = Float64[]
    function add_segment(a::Vec3, b::Vec3)
        append!(positions, (a.x, a.y, a.z, b.x, b.y, b.z))
    end
    for i in 0:segments-1
        a = 2pi * i / segments
        b = 2pi * (i + 1) / segments
        add_segment(Vec3(radius * cos(a), radius * sin(a), 0.0),
                    Vec3(radius * cos(b), radius * sin(b), 0.0))
        add_segment(Vec3(radius * cos(a), 0.0, radius * sin(a)),
                    Vec3(radius * cos(b), 0.0, radius * sin(b)))
        add_segment(Vec3(0.0, radius * cos(a), radius * sin(a)),
                    Vec3(0.0, radius * cos(b), radius * sin(b)))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], length(positions) ÷ 3, 0)
end

function lightprobe_helper()
    helper = LineSegments(lightprobe_helper_geometry(radius=1.0),
                          LineBasicMaterial(color=Color3(0.94, 0.88, 0.64));
                          name="lightprobe_helper")
    helper.position = LIGHTPROBE_POSITION
    return helper
end

function build_lightprobe_case()
    env_map = lightprobe_cube_texture()
    probe = LightProbe(coeffs=lightprobe_coefficients(env_map),
                       intensity=1.0, name="lightProbe")
    probe.position = LIGHTPROBE_POSITION

    scene = Scene(background=Color3(0.05, 0.065, 0.085))
    add!(scene, probe)
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=0.6,
                                 position=Vec3(10.0, 10.0, 10.0)))

    sphere = Mesh(SphereGeometry(radius=LIGHTPROBE_SUBJECT_RADIUS,
                                 width_segments=64, height_segments=32),
                  MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                       metalness=0.0, roughness=0.0,
                                       envmap=env_map, env_map_intensity=1.0);
                  name="lightprobe_sphere", cast_shadow=true, receive_shadow=true)
    add!(scene, sphere)
    add!(scene, lightprobe_helper())

    clip = AnimationClip("lightprobe_envmap_intensity", AbstractKeyframeTrack[
        NumberKeyframeTrack(sphere, "material.envMapIntensity",
                            [0.0, 2.0, 4.0], [1.0, 0.64, 1.0])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = LIGHTPROBE_CAMERA_POSITION
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("lightprobe", "Light Probe",
                    "A generated cubemap drives LightProbe SH diffuse fill and MeshStandardMaterial reflections.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=30.0, height=0.0,
                    fov=40pi / 180, camera=camera, animations=[clip],
                    tone_mapping=:none, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lightprobe.html"), [build_lightprobe_case()])
    println("WEBGL_LIGHTPROBE_OK $html")
end

main()

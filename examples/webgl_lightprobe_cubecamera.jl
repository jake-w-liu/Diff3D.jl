# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lightprobe_cubecamera

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CUBE_CAMERA_CAPTURE_SIZE = 32
const CUBE_CAMERA_BACKDROP_SIZE = 60.0
const CUBE_CAMERA_HELPER_RADIUS = 5.0
const CUBE_CAMERA_VIEW_POSITION = Vec3(0.0, 0.0, 30.0)

function cubecamera_env_color(dir::Vec3)
    up = clamp(0.5 + 0.5 * dir.y, 0.0, 1.0)
    tower = 0.5 + 0.5 * cos(6.0 * atan(dir.x, dir.z))
    arcade = exp(-abs(dir.y) * 5.0) * (0.55 + 0.45 * tower)
    sun_dir = normalize(Vec3(-0.35, 0.55, 0.76))
    sun = max(dot(dir, sun_dir), 0.0)^36
    sky = Color3(0.14 + 0.25 * up, 0.22 + 0.38 * up, 0.40 + 0.42 * up)
    stone = Color3(0.56 + 0.16 * tower, 0.48 + 0.12 * tower, 0.36 + 0.08 * tower)
    warm = Color3(1.0, 0.80, 0.46) * (0.65 * sun)
    c = sky * (0.54 + 0.20 * up) + stone * (0.24 + 0.46 * arcade) + warm
    Color3(clamp(c.r, 0.0, 1.0), clamp(c.g, 0.0, 1.0), clamp(c.b, 0.0, 1.0))
end

function cubecamera_face_direction(camera::PerspectiveCamera, u::Float64, v::Float64)
    forward = normalize(camera.target - camera.position)
    right = normalize(cross(forward, camera.up))
    up = normalize(cross(right, forward))
    sx = 2u - 1
    sy = 2v - 1
    normalize(forward + right * sx + up * sy)
end

function cubecamera_capture_face(camera::PerspectiveCamera; size::Int=CUBE_CAMERA_CAPTURE_SIZE)
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = 1.0 - (y - 0.5) / size
        color = cubecamera_env_color(cubecamera_face_direction(camera, u, v))
        data[y, x, 1] = color.r
        data[y, x, 2] = color.g
        data[y, x, 3] = color.b
    end
    tex = Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:linear,
                  min_filter=:linear_mipmap_linear, colorspace=:linear)
    generate_mipmaps!(tex)
    return tex
end

function cubecamera_capture_texture(camera::CubeCamera; size::Int=CUBE_CAMERA_CAPTURE_SIZE)
    length(camera.cameras) == 6 ||
        throw(ArgumentError("CubeCamera capture requires exactly six face cameras"))
    CubeTexture(ntuple(face -> cubecamera_capture_face(camera.cameras[face]; size=size), 6))
end

function cubecamera_color_add(a::Color3, b::Color3)
    Color3(a.r + b.r, a.g + b.g, a.b + b.b)
end

function cubecamera_color_scale(c::Color3, s::Float64)
    Color3(c.r * s, c.g * s, c.b * s)
end

function cubecamera_lightprobe_coefficients(cube_camera::CubeCamera, env::CubeTexture)
    dc = Color3(0.0, 0.0, 0.0)
    mx = Color3(0.0, 0.0, 0.0)
    my = Color3(0.0, 0.0, 0.0)
    mz = Color3(0.0, 0.0, 0.0)
    weight_sum = 0.0
    for face in 1:6
        tex = env.faces[face]
        cam = cube_camera.cameras[face]
        height, width, _ = size(tex.data)
        for y in 1:height, x in 1:width
            u = (x - 0.5) / width
            v = 1.0 - (y - 0.5) / height
            sx = 2u - 1
            sy = 2v - 1
            weight = (1 + sx^2 + sy^2)^(-1.5)
            dir = cubecamera_face_direction(cam, u, v)
            sample = Color3(tex.data[y, x, 1], tex.data[y, x, 2], tex.data[y, x, 3])
            dc = cubecamera_color_add(dc, cubecamera_color_scale(sample, weight))
            mx = cubecamera_color_add(mx, cubecamera_color_scale(sample, weight * dir.x))
            my = cubecamera_color_add(my, cubecamera_color_scale(sample, weight * dir.y))
            mz = cubecamera_color_add(mz, cubecamera_color_scale(sample, weight * dir.z))
            weight_sum += weight
        end
    end
    scale = 1.0 / weight_sum
    (cubecamera_color_scale(dc, scale),
     cubecamera_color_scale(mx, 3.0 * scale),
     cubecamera_color_scale(my, 3.0 * scale),
     cubecamera_color_scale(mz, 3.0 * scale))
end

function cubecamera_helper_geometry(; radius::Float64=CUBE_CAMERA_HELPER_RADIUS, segments::Int=48)
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

function cubecamera_probe_helper()
    LineSegments(cubecamera_helper_geometry(radius=CUBE_CAMERA_HELPER_RADIUS),
                 LineBasicMaterial(color=Color3(0.96, 0.90, 0.64), linewidth=2.0);
                 name="cubecamera_lightprobe_helper")
end

function backdrop_plane(name::String, texture::Texture, position::Vec3, rotation::Euler)
    plane = Mesh(PlaneGeometry(width=CUBE_CAMERA_BACKDROP_SIZE,
                               height=CUBE_CAMERA_BACKDROP_SIZE),
                 MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                   map=texture, side=:double,
                                   depth_write=false);
                 name=name)
    plane.position = position
    plane.rotation = rotation
    return plane
end

function add_captured_backdrop!(scene::Scene, env::CubeTexture)
    d = CUBE_CAMERA_BACKDROP_SIZE / 2
    add!(scene, backdrop_plane("cubecamera_backdrop_px", env.faces[1],
                               Vec3(d, 0.0, 0.0), Euler(0.0, pi / 2, 0.0)))
    add!(scene, backdrop_plane("cubecamera_backdrop_nx", env.faces[2],
                               Vec3(-d, 0.0, 0.0), Euler(0.0, -pi / 2, 0.0)))
    add!(scene, backdrop_plane("cubecamera_backdrop_py", env.faces[3],
                               Vec3(0.0, d, 0.0), Euler(-pi / 2, 0.0, 0.0)))
    add!(scene, backdrop_plane("cubecamera_backdrop_ny", env.faces[4],
                               Vec3(0.0, -d, 0.0), Euler(pi / 2, 0.0, 0.0)))
    add!(scene, backdrop_plane("cubecamera_backdrop_pz", env.faces[5],
                               Vec3(0.0, 0.0, d), Euler(0.0, 0.0, 0.0)))
    add!(scene, backdrop_plane("cubecamera_backdrop_nz", env.faces[6],
                               Vec3(0.0, 0.0, -d), Euler(0.0, pi, 0.0)))
end

function build_lightprobe_cubecamera_case()
    cube_camera = CubeCamera(near=1.0, far=1000.0, position=Vec3(0.0, 0.0, 0.0))
    env_map = cubecamera_capture_texture(cube_camera)
    probe = LightProbe(coeffs=cubecamera_lightprobe_coefficients(cube_camera, env_map),
                       intensity=1.0, name="cubeCameraLightProbe")

    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, probe)
    add_captured_backdrop!(scene, env_map)

    response = Mesh(SphereGeometry(radius=1.5, width_segments=48, height_segments=24),
                    MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                         metalness=0.0, roughness=0.45);
                    name="cubecamera_probe_response")
    add!(scene, response)
    add!(scene, cubecamera_probe_helper())

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = CUBE_CAMERA_VIEW_POSITION
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("lightprobe-cubecamera", "Light Probe CubeCamera",
                    "A CubeCamera face rig captures a deterministic cubemap used to derive LightProbe diffuse fill.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=30.0, height=0.0,
                    fov=40pi / 180, camera=camera,
                    tone_mapping=:none, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lightprobe_cubecamera.html"),
                           [build_lightprobe_cubecamera_case()])
    println("WEBGL_LIGHTPROBE_CUBECAMERA_OK $html")
end

main()

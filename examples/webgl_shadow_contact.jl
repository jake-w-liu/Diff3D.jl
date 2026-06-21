# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadow_contact

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CONTACT_SHADOW_PLANE_WIDTH = 2.5
const CONTACT_SHADOW_PLANE_HEIGHT = 2.5
const CONTACT_SHADOW_CAMERA_HEIGHT = 0.3
const CONTACT_SHADOW_GROUP_Y = -0.3
const CONTACT_SHADOW_BLUR = 3.5
const CONTACT_SHADOW_DARKNESS = 1.0
const CONTACT_SHADOW_OPACITY = 1.0
const CONTACT_SHADOW_FRAME_RATE = 60.0
const CONTACT_SHADOW_DURATION = 10pi / 3
const CONTACT_SHADOW_KEYFRAME_COUNT = 73
const CONTACT_SHADOW_CAMERA_POSITION = Vec3(0.5, 1.0, 2.0)
const CONTACT_SHADOW_TARGET = Vec3(0.0, 0.0, 0.0)

function contact_shadow_key_times()
    collect(range(0.0, stop=CONTACT_SHADOW_DURATION,
                  length=CONTACT_SHADOW_KEYFRAME_COUNT))
end

function contact_shadow_mesh_position(index::Integer, total::Integer=3)
    1 <= index <= total || throw(ArgumentError("index must be in 1:$total"))
    angle = (index - 1) / total * 2pi
    Vec3(cos(angle) / 2.0, 0.1, sin(angle) / 2.0)
end

function contact_shadow_alpha_texture(; size::Int=128)
    size > 0 || throw(ArgumentError("contact shadow texture size must be positive"))
    centers = (
        (contact_shadow_mesh_position(1), 0.20, 0.20, 0.90),
        (contact_shadow_mesh_position(2), 0.18, 0.18, 0.72),
        (contact_shadow_mesh_position(3), 0.34, 0.24, 0.82),
    )
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        plane_x = (u - 0.5) * CONTACT_SHADOW_PLANE_WIDTH
        plane_z = (v - 0.5) * CONTACT_SHADOW_PLANE_HEIGHT
        alpha = 0.0
        for (center, sx, sz, strength) in centers
            dx = (plane_x - center.x) / sx
            dz = (plane_z - center.z) / sz
            core = exp(-0.5 * (dx * dx + dz * dz))
            blur = exp(-0.5 * (dx * dx + dz * dz) / CONTACT_SHADOW_BLUR)
            alpha += strength * (0.72 * core + 0.28 * blur)
        end
        alpha = clamp(alpha * CONTACT_SHADOW_DARKNESS, 0.0, 1.0)
        data[y, x, 1] = alpha
        data[y, x, 2] = alpha
        data[y, x, 3] = alpha
    end
    Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:linear,
            min_filter=:linear, mag_filter=:linear, colorspace=:linear)
end

function contact_shadow_plane(name::String, material::MeshBasicMaterial,
                              y_offset::Real)
    plane = Mesh(PlaneGeometry(width=CONTACT_SHADOW_PLANE_WIDTH,
                               height=CONTACT_SHADOW_PLANE_HEIGHT),
                 material; name=name)
    plane.rotation = Euler(-pi / 2, 0.0, 0.0)
    plane.position = Vec3(0.0, CONTACT_SHADOW_GROUP_Y + Float64(y_offset), 0.0)
    return plane
end

function contact_shadow_rotation_values(times::Vector{Float64}, per_frame::Real)
    rate = Float64(per_frame) * CONTACT_SHADOW_FRAME_RATE
    [rate * t for t in times]
end

function contact_shadow_meshes()
    geometries = (
        BoxGeometry(width=0.4, height=0.4, depth=0.4),
        IcosahedronGeometry(radius=0.3),
        TorusKnotGeometry(radius=0.4, tube=0.05, tubular_segments=256,
                          radial_segments=24, p_val=1, q_val=3),
    )
    names = ("contact_shadow_box", "contact_shadow_icosahedron",
             "contact_shadow_torus_knot")
    material = MeshNormalMaterial()
    meshes = Mesh[]
    for i in eachindex(geometries)
        mesh = Mesh(geometries[i], material; name=names[i], cast_shadow=true)
        mesh.position = contact_shadow_mesh_position(i, length(geometries))
        push!(meshes, mesh)
    end
    return meshes
end

function contact_shadow_camera_helper()
    shadow_camera = OrthographicCamera(left=-CONTACT_SHADOW_PLANE_WIDTH / 2,
                                       right=CONTACT_SHADOW_PLANE_WIDTH / 2,
                                       top=CONTACT_SHADOW_PLANE_HEIGHT / 2,
                                       bottom=-CONTACT_SHADOW_PLANE_HEIGHT / 2,
                                       near=0.0,
                                       far=CONTACT_SHADOW_CAMERA_HEIGHT,
                                       name="contact_shadow_depth_camera")
    shadow_camera.position = Vec3(0.0, CONTACT_SHADOW_GROUP_Y, 0.0)
    shadow_camera.rotation = Euler(pi / 2, 0.0, 0.0)
    helper = CameraHelper(shadow_camera; color=Color3(0.0, 0.4, 1.0))
    helper.visible = false
    helper.name = "contact_shadow_camera_helper"
    return helper
end

function build_shadow_contact_case()
    scene = Scene(background=Color3(1.0, 1.0, 1.0))

    meshes = contact_shadow_meshes()
    for mesh in meshes
        add!(scene, mesh)
    end

    fill_plane = contact_shadow_plane(
        "contact_shadow_fill_plane",
        MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                          opacity=1.0,
                          transparent=true,
                          side=:double,
                          depth_write=false),
        -0.004,
    )
    shadow_plane = contact_shadow_plane(
        "contact_shadow_render_target_plane",
        MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                          opacity=CONTACT_SHADOW_OPACITY,
                          transparent=true,
                          side=:double,
                          alpha_map=contact_shadow_alpha_texture(),
                          depth_write=false),
        0.004,
    )
    shadow_plane.scale = Vec3(1.0, -1.0, 1.0)

    blur_plane = contact_shadow_plane(
        "contact_shadow_blur_plane",
        MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                          opacity=0.0,
                          transparent=true,
                          side=:double,
                          depth_write=false),
        0.0,
    )
    blur_plane.visible = false

    add!(scene, fill_plane)
    add!(scene, shadow_plane)
    add!(scene, blur_plane)
    add!(scene, contact_shadow_camera_helper())

    times = contact_shadow_key_times()
    tracks = AbstractKeyframeTrack[]
    for mesh in meshes
        push!(tracks, NumberKeyframeTrack(mesh, "rotation.x", copy(times),
                                          contact_shadow_rotation_values(times, 0.01)))
        push!(tracks, NumberKeyframeTrack(mesh, "rotation.y", copy(times),
                                          contact_shadow_rotation_values(times, 0.02)))
    end
    clip = AnimationClip("contact_shadow_mesh_rotation",
                         CONTACT_SHADOW_DURATION, tracks; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=0.1, far=100.0)
    camera.position = CONTACT_SHADOW_CAMERA_POSITION
    camera.target = CONTACT_SHADOW_TARGET

    WebGLExportCase("shadow-contact", "Contact Shadows",
                    "Contact-shadow scene with generated blurred alpha-map shadow plane.",
                    scene; camera=camera, target=CONTACT_SHADOW_TARGET,
                    radius=2.3, height=0.75, fov=50pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadow_contact.html"),
                           [build_shadow_contact_case()])
    println("WEBGL_SHADOW_CONTACT_OK $html")
end

main()

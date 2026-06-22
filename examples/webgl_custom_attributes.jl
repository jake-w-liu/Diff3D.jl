# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_custom_attributes

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CUSTOM_ATTRIBUTES_RADIUS = 50.0
const CUSTOM_ATTRIBUTES_SEGMENTS = 128
const CUSTOM_ATTRIBUTES_RINGS = 64
const CUSTOM_ATTRIBUTES_AMPLITUDE = 1.0
const CUSTOM_ATTRIBUTES_CAMERA_POSITION = Vec3(0.0, 0.0, 300.0)
const CUSTOM_ATTRIBUTES_TARGET = Vec3(0.0, 0.0, 0.0)

custom_attributes_fract(x::Float64) = x - floor(x)

function custom_attributes_hash_noise(index::Int, salt::Float64)
    custom_attributes_fract(sin((index + 1) * 12.9898 + salt * 78.233) * 43758.5453123)
end

function custom_attributes_displacement(index::Int)
    sin(0.1 * (index - 1)) + 5.0 * custom_attributes_hash_noise(index, 0.41)
end

function custom_attributes_water_texture(; n::Int=64)
    data = zeros(Float64, n, n, 3)
    for y in 1:n, x in 1:n
        u = (x - 1) / n
        v = (y - 1) / n
        wave = 0.5 + 0.5sin(10pi * u + 6pi * v)
        ripple = 0.5 + 0.5sin(18pi * (u - v))
        data[y, x, 1] = 0.18 + 0.26wave
        data[y, x, 2] = 0.32 + 0.42ripple
        data[y, x, 3] = 0.52 + 0.36(0.65wave + 0.35ripple)
    end
    Texture(data; wrap_s=:repeat, wrap_t=:repeat, filter=:linear,
            min_filter=:linear_mipmap_linear, colorspace=:srgb)
end

function custom_attributes_deformed_sphere_geometry()
    geo = SphereGeometry(radius=CUSTOM_ATTRIBUTES_RADIUS,
                         width_segments=CUSTOM_ATTRIBUTES_SEGMENTS,
                         height_segments=CUSTOM_ATTRIBUTES_RINGS)
    displacements = Vector{Float64}(undef, geo.n_vertices)
    for i in 1:geo.n_vertices
        displacement = custom_attributes_displacement(i)
        displacements[i] = displacement
        base = 3i - 2
        geo.positions[base] += CUSTOM_ATTRIBUTES_AMPLITUDE *
                               geo.normals[base] * displacement
        geo.positions[base + 1] += CUSTOM_ATTRIBUTES_AMPLITUDE *
                                   geo.normals[base + 1] * displacement
        geo.positions[base + 2] += CUSTOM_ATTRIBUTES_AMPLITUDE *
                                   geo.normals[base + 2] * displacement
    end
    set_attribute!(geo, :displacement, displacements, 1)
    compute_vertex_normals!(geo)
    return geo
end

function build_custom_attributes_case()
    scene = Scene(background=Color3(5 / 255, 5 / 255, 5 / 255))

    material = MeshPhongMaterial(color=Color3(1.0, 34 / 255, 0.0),
                                 shininess=35.0,
                                 map=custom_attributes_water_texture())
    sphere = Mesh(custom_attributes_deformed_sphere_geometry(), material;
                  name="custom_attributes_displaced_sphere")
    add!(scene, sphere)

    clip = AnimationClip("custom_attributes_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(sphere, :rotation, [0.0, 6.0, 12.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, pi),
                                 quat_from_euler(0.0, 2pi, 2pi)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=30pi / 180, aspect=16 / 9,
                               near=1.0, far=10000.0)
    camera.position = CUSTOM_ATTRIBUTES_CAMERA_POSITION
    camera.target = CUSTOM_ATTRIBUTES_TARGET

    WebGLExportCase("custom-attributes", "Custom Attributes",
                    "Displaced sphere snapshot preserving the upstream displacement attribute.",
                    scene; camera=camera,
                    target=CUSTOM_ATTRIBUTES_TARGET,
                    radius=300.0,
                    height=0.0,
                    fov=30pi / 180,
                    animations=[clip],
                    tone_mapping=:none,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_custom_attributes.html"),
                           [build_custom_attributes_case()];
                           title="Diff3D.jl webgl_custom_attributes")
    vertices = (CUSTOM_ATTRIBUTES_SEGMENTS + 1) * (CUSTOM_ATTRIBUTES_RINGS + 1)
    println("WEBGL_CUSTOM_ATTRIBUTES_OK $html vertices=$vertices")
end

main()

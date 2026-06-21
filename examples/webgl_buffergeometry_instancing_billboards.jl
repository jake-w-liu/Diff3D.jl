# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_buffergeometry_instancing_billboards

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const BILLBOARD_INSTANCE_COUNT = 75_000
const BILLBOARD_WORLD_SCALE = 500.0
const BILLBOARD_BASE_RADIUS = 1.0
const BILLBOARD_SEGMENTS = 6

billboard_fract(x::Float64) = x - floor(x)

function billboard_hash_noise(index::Int, salt::Float64)
    billboard_fract(sin((index + 1) * 25.271 + salt * 39.731) * 41293.517)
end

function billboard_translate(index::Int)
    Vec3(2.0 * billboard_hash_noise(index, 0.11) - 1.0,
         2.0 * billboard_hash_noise(index, 0.37) - 1.0,
         2.0 * billboard_hash_noise(index, 0.73) - 1.0)
end

function billboard_wave(t::Vec3{Float64}; time::Float64=0.0)
    sin((t.x + time) * 2.1) +
    sin((t.y + time) * 3.2) +
    sin((t.z + time) * 4.3)
end

function billboard_shader_scale(t::Vec3{Float64}; time::Float64=0.0)
    billboard_wave(t; time=time) * 10.0 + 10.0
end

function billboard_hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    h = billboard_fract(h)
    if s == 0.0
        return Color3(l, l, l)
    end

    q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
    p = 2.0 * l - q

    function hue_to_rgb(t)
        t = billboard_fract(t)
        t < 1 / 6 && return p + (q - p) * 6.0 * t
        t < 1 / 2 && return q
        t < 2 / 3 && return p + (q - p) * (2 / 3 - t) * 6.0
        return p
    end

    Color3(hue_to_rgb(h + 1 / 3), hue_to_rgb(h), hue_to_rgb(h - 1 / 3))
end

function billboard_instance_color(t::Vec3{Float64})
    billboard_hsl_to_rgb(billboard_wave(t) / 5.0, 1.0, 0.5)
end

function build_billboard_instanced_mesh()
    inst = InstancedMesh(CircleGeometry(radius=BILLBOARD_BASE_RADIUS,
                                        segments=BILLBOARD_SEGMENTS),
                         MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                           side=:double),
                         BILLBOARD_INSTANCE_COUNT;
                         name="buffergeometry_instancing_billboards")

    for i in 1:BILLBOARD_INSTANCE_COUNT
        t = billboard_translate(i - 1)
        scale = billboard_shader_scale(t)
        set_instance_matrix!(inst, i,
                             mat4_translation(BILLBOARD_WORLD_SCALE * t.x,
                                              BILLBOARD_WORLD_SCALE * t.y,
                                              BILLBOARD_WORLD_SCALE * t.z) *
                             mat4_scaling(scale, scale, scale))
        set_instance_color!(inst, i, billboard_instance_color(t))
    end

    return inst
end

function build_instancing_billboards_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    mesh = build_billboard_instanced_mesh()
    add!(scene, mesh)

    clip = AnimationClip("buffergeometry_instancing_billboards_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(mesh, :rotation, [0.0, 6.0, 12.0],
                                [Quaternion(),
                                 quat_from_euler(0.6, 1.2, 0.0),
                                 quat_from_euler(1.2, 2.4, 0.0)])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=1.0, far=5000.0)
    camera.position = Vec3(0.0, 0.0, 1400.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("buffergeometry-instancing-billboards",
                    "BufferGeometry Instancing Billboards",
                    "Instanced circle billboards with deterministic translate snapshots and HSL colors.",
                    scene; camera=camera, target=camera.target, radius=1400.0,
                    height=0.0, fov=50pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_buffergeometry_instancing_billboards.html"),
                           [build_instancing_billboards_case()])
    println("WEBGL_BUFFERGEOMETRY_INSTANCING_BILLBOARDS_OK $html")
end

main()

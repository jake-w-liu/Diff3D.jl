# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_camera_array

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function build_array_camera(; amount::Int=4, tile::Int=180)
    amount >= 2 || throw(ArgumentError("amount must be at least 2"))
    cameras = PerspectiveCamera[]
    viewports = NTuple{4,Int}[]
    aspect = 1.0
    for y in 0:(amount - 1), x in 0:(amount - 1)
        cam = PerspectiveCamera(fov=40pi / 180, aspect=aspect, near=0.1, far=20.0;
                                name="array_subcamera_$(x)_$(y)")
        u = amount == 1 ? 0.0 : x / (amount - 1)
        v = amount == 1 ? 0.0 : y / (amount - 1)
        cam.position = Vec3((u - 0.5) * 2.4, (0.5 - v) * 2.4, 3.0)
        cam.target = Vec3(0.0, 0.0, 0.0)
        push!(cameras, cam)
        push!(viewports, (x * tile, (amount - 1 - y) * tile, tile, tile))
    end
    return ArrayCamera(cameras, viewports)
end

function build_scene()
    scene = Scene(background=Color3(0.035, 0.04, 0.065))
    add!(scene, AmbientLight(color=Color3(0.62, 0.66, 0.76), intensity=0.65))

    key = DirectionalLight(color=Color3(1.0, 0.96, 0.88), intensity=1.5)
    key.position = Vec3(3.5, 4.0, 3.0)
    key.target = Vec3(0.0, 0.0, 0.0)
    key.cast_shadow = true
    add!(scene, key)

    floor = Mesh(PlaneGeometry(width=12.0, height=12.0),
                 MeshPhongMaterial(color=Color3(0.05, 0.05, 0.20),
                                   shininess=18.0);
                 name="array_camera_background_plane")
    floor.position = Vec3(0.0, 0.0, -0.72)
    floor.rotation = Euler(0.0, 0.0, 0.0)
    floor.receive_shadow = true
    add!(scene, floor)

    cylinder = Mesh(CylinderGeometry(radius_top=0.5, radius_bottom=0.5,
                                     height=1.15, radial_segments=32),
                    MeshPhongMaterial(color=Color3(1.0, 0.06, 0.035),
                                      specular=Color3(0.7, 0.7, 0.75),
                                      shininess=55.0);
                    name="array_camera_red_cylinder")
    cylinder.cast_shadow = true
    cylinder.receive_shadow = true
    add!(scene, cylinder)

    axis = LineSegments(BufferGeometry(Float64[
        -1.4, 0.0, 0.0,  1.4, 0.0, 0.0,
         0.0,-1.4, 0.0,  0.0, 1.4, 0.0,
         0.0, 0.0,-1.4,  0.0, 0.0, 1.4,
    ], Float64[], Float64[], Int[], 6, 0),
                        LineBasicMaterial(color=Color3(0.75, 0.82, 1.0),
                                          opacity=0.38, depth_write=false);
                        name="array_camera_reference_axes")
    add!(scene, axis)

    clip = AnimationClip("array_camera_cylinder_spin", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(cylinder, :rotation, [0.0, 3.0, 6.0],
                                [quat_from_euler(0.35, 0.0, 0.0),
                                 quat_from_euler(0.35, pi, 0.8pi),
                                 quat_from_euler(0.35, 2pi, 1.6pi)])
    ]; loop=:repeat)

    return scene, cylinder, clip
end

function build_case()
    scene, _, clip = build_scene()
    camera = build_array_camera()
    WebGLExportCase("camera-array", "ArrayCamera",
                    "Grid of perspective sub-cameras rendered with browser scissor viewports.",
                    scene; camera=camera, target=Vec3(0.0, 0.0, 0.0), radius=4.0,
                    height=0.0, fov=40pi / 180, animations=[clip],
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_camera_array.html"), [build_case()])
    println("WEBGL_CAMERA_ARRAY_OK $html")
end

main()

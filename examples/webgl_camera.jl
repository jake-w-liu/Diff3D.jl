# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_camera

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function deterministic_points_geometry(; n::Int=4200)
    n > 1 || throw(ArgumentError("point count must be greater than one"))
    positions = Float64[]

    spread(i::Int, salt::Int) = begin
        raw = mod(1_103_515_245 * (i + 1 + 97salt) + 12_345, 1_000_003)
        20.0 * (raw / 1_000_002 - 0.5)
    end

    for i in 0:(n - 1)
        push!(positions, spread(i, 11), spread(i, 37), spread(i, 73))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], n, 0)
end

function build_camera_scene()
    scene = Scene(background=Color3(0.012, 0.014, 0.020))
    add!(scene, AmbientLight(color=Color3(0.45, 0.48, 0.58), intensity=0.65))
    add!(scene, GridHelper(18.0, 18; color=Color3(0.12, 0.14, 0.18)))

    points = PointsObject(deterministic_points_geometry(),
                          PointsMaterial(color=Color3(0.48, 0.50, 0.56), size=2.2);
                          name="camera_reference_points")
    add!(scene, points)

    main_mesh = Mesh(SphereGeometry(radius=1.0, width_segments=16, height_segments=8),
                     MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), wireframe=true);
                     name="camera_target_orbit")
    add!(scene, main_mesh)

    child_mesh = Mesh(SphereGeometry(radius=0.5, width_segments=16, height_segments=8),
                      MeshBasicMaterial(color=Color3(0.1, 0.95, 0.35), wireframe=true);
                      name="camera_target_child")
    child_mesh.position = Vec3(0.0, 1.5, 0.0)
    add!(main_mesh, child_mesh)

    camera_rig = Group(name="camera_rig")
    add!(scene, camera_rig)
    rig_marker = Mesh(SphereGeometry(radius=0.12, width_segments=12, height_segments=6),
                      MeshBasicMaterial(color=Color3(0.18, 0.35, 1.0), wireframe=true);
                      name="camera_rig_marker")
    rig_marker.position = Vec3(0.0, 0.0, 1.5)
    add!(camera_rig, rig_marker)

    perspective_cam = PerspectiveCamera(fov=50pi / 180, aspect=1.0,
                                        near=0.2, far=30.0,
                                        name="camera_perspective")
    perspective_cam.position = Vec3(0.0, 2.8, 12.0)
    perspective_cam.target = Vec3(0.0, 0.0, 0.0)

    ortho_extent = 6.2
    ortho_cam = OrthographicCamera(left=-ortho_extent, right=ortho_extent,
                                   bottom=-ortho_extent, top=ortho_extent,
                                   near=0.2, far=30.0,
                                   name="camera_orthographic")
    ortho_cam.position = Vec3(0.0, 2.8, 12.0)
    ortho_cam.target = Vec3(0.0, 0.0, 0.0)

    add!(scene, CameraHelper(perspective_cam; color=Color3(1.0, 0.78, 0.2)))
    add!(scene, CameraHelper(ortho_cam; color=Color3(0.2, 0.78, 1.0)))

    times = [0.0, 2.0, 4.0, 6.0, 8.0]
    clip = AnimationClip("camera_scene_motion", AbstractKeyframeTrack[
        KeyframeTrack(main_mesh, :position, times,
                      [Vec3(7.0, 0.0, 0.0),
                       Vec3(0.0, 7.0, 7.0),
                       Vec3(-7.0, 0.0, 0.0),
                       Vec3(0.0, -7.0, -7.0),
                       Vec3(7.0, 0.0, 0.0)]),
        KeyframeTrack(child_mesh, :position, times,
                      [Vec3(0.7, 1.5, 0.0),
                       Vec3(0.0, 1.5, 0.7),
                       Vec3(-0.7, 1.5, 0.0),
                       Vec3(0.0, 1.5, -0.7),
                       Vec3(0.7, 1.5, 0.0)]),
        QuaternionKeyframeTrack(camera_rig, :rotation, times,
                                [Quaternion(),
                                 quat_from_euler(0.0, 0.5pi, 0.0),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 1.5pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    return scene, perspective_cam, ortho_cam, clip
end

function build_cases()
    perspective_scene, perspective_cam, _, perspective_clip = build_camera_scene()
    ortho_scene, _, ortho_cam, ortho_clip = build_camera_scene()

    return [
        WebGLExportCase("camera-perspective", "Camera Perspective",
                        "PerspectiveCamera, CameraHelper, point-cloud background, and keyframed target motion from the Diff3D.jl camera example port.",
                        perspective_scene; camera=perspective_cam,
                        target=perspective_cam.target, radius=12.3, height=2.8,
                        fov=50pi / 180, animations=[perspective_clip],
                        output_color_space=:srgb),
        WebGLExportCase("camera-orthographic", "Camera Orthographic",
                        "OrthographicCamera and matching CameraHelper coverage for the Diff3D.jl camera example port.",
                        ortho_scene; camera=ortho_cam,
                        target=ortho_cam.target, radius=12.3, height=2.8,
                        animations=[ortho_clip],
                        output_color_space=:srgb),
    ]
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_camera.html"), build_cases())
    println("WEBGL_CAMERA_OK $html")
end

main()

# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_trackball

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INSTANCE_COUNT = 500
const FRUSTUM_SIZE = 400.0
const ASPECT = 16 / 9

fract(x) = x - floor(x)

function configure_trackball_controls(camera::PerspectiveCamera)
    controls = TrackballControls(camera)
    trackball_save_state!(controls)
    trackball_rotate!(controls, 0.0, 0.0)
    trackball_zoom!(controls, 1.0)
    trackball_pan!(controls, 0.0, 0.0)
    trackball_reset!(controls)
    return controls
end

function build_trackball_cones(name::String)
    geometry = ConeGeometry(radius=10.0, height=30.0,
                            radial_segments=4, height_segments=1)
    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 shininess=18.0)
    inst = InstancedMesh(geometry, material, INSTANCE_COUNT; name=name)

    for i in 1:INSTANCE_COUNT
        x = 1000.0 * (fract(i * 0.7548776662466927) - 0.5)
        y = 1000.0 * (fract(i * 0.5698402909980532 + 0.17) - 0.5)
        z = 1000.0 * (fract(i * 0.4385513373931324 + 0.31) - 0.5)
        set_instance_matrix!(inst, i, mat4_translation(x, y, z))
    end

    return inst
end

function build_trackball_scene(name::String)
    scene = Scene(background=Color3(0.8, 0.8, 0.8),
                  fog=FogExp2(color=Color3(0.8, 0.8, 0.8), density=0.002))
    add!(scene, build_trackball_cones(name))

    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                                 position=Vec3(1.0, 1.0, 1.0)))
    add!(scene, DirectionalLight(color=Color3(0.0, 0.133, 0.533), intensity=3.0,
                                 position=Vec3(-1.0, -1.0, -1.0)))
    add!(scene, AmbientLight(color=Color3(0.333, 0.333, 0.333), intensity=1.0))

    return scene
end

function perspective_case()
    camera = PerspectiveCamera(fov=60pi / 180, aspect=ASPECT, near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 0.0, 500.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    configure_trackball_controls(camera)

    WebGLExportCase("misc-controls-trackball-perspective", "Trackball Controls - Perspective",
                    "Perspective camera over a deterministic instanced cone field.",
                    build_trackball_scene("trackball_cones_perspective");
                    camera=camera, target=camera.target, radius=500.0,
                    height=0.0, fov=60pi / 180, tone_mapping=:linear,
                    output_color_space=:srgb)
end

function orthographic_case()
    camera = OrthographicCamera(left=-FRUSTUM_SIZE * ASPECT / 2,
                                right=FRUSTUM_SIZE * ASPECT / 2,
                                top=FRUSTUM_SIZE / 2,
                                bottom=-FRUSTUM_SIZE / 2,
                                near=1.0, far=1000.0,
                                name="trackball_orthographic_camera")
    camera.position = Vec3(0.0, 0.0, 500.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("misc-controls-trackball-orthographic", "Trackball Controls - Orthographic",
                    "Orthographic camera counterpart to the upstream GUI switch.",
                    build_trackball_scene("trackball_cones_orthographic");
                    camera=camera, target=camera.target, radius=500.0,
                    height=0.0, fov=60pi / 180, tone_mapping=:linear,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_trackball.html"),
                           [perspective_case(), orthographic_case()];
                           title="Diff3D.jl misc_controls_trackball")
    println("MISC_CONTROLS_TRACKBALL_OK $html")
end

main()

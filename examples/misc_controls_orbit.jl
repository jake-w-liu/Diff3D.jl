# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_orbit

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INSTANCE_COUNT = 500

fract(x) = x - floor(x)

function configure_orbit_controls(camera::PerspectiveCamera)
    controls = OrbitControls(camera;
                              enable_damping=true,
                              damping_factor=0.05,
                              min_distance=100.0,
                              max_distance=500.0,
                              max_polar_angle=pi / 2)
    orbit_save_state!(controls)
    orbit_update!(controls)
    return controls
end

function build_cone_field()
    geometry = ConeGeometry(radius=10.0, height=30.0,
                            radial_segments=4, height_segments=1)
    material = MeshPhongMaterial(color=Color3(1.0, 1.0, 1.0),
                                 shininess=18.0)
    inst = InstancedMesh(geometry, material, INSTANCE_COUNT;
                         name="orbit_controls_cones")

    for i in 1:INSTANCE_COUNT
        x = 1600.0 * (fract(i * 0.7548776662466927) - 0.5)
        z = 1600.0 * (fract(i * 0.5698402909980532 + 0.17) - 0.5)
        set_instance_matrix!(inst, i, mat4_translation(x, 0.0, z))
    end

    return inst
end

function build_orbit_controls_case()
    scene = Scene(background=Color3(0.8, 0.8, 0.8),
                  fog=FogExp2(color=Color3(0.8, 0.8, 0.8), density=0.002))
    add!(scene, build_cone_field())

    dir1 = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                            position=Vec3(1.0, 1.0, 1.0))
    dir2 = DirectionalLight(color=Color3(0.0, 0.133, 0.533), intensity=3.0,
                            position=Vec3(-1.0, -1.0, -1.0))
    add!(scene, dir1)
    add!(scene, dir2)
    add!(scene, AmbientLight(color=Color3(0.333, 0.333, 0.333), intensity=1.0))

    camera = PerspectiveCamera(fov=60pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(400.0, 200.0, 0.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    configure_orbit_controls(camera)

    WebGLExportCase("misc-controls-orbit", "Orbit Controls",
                    "Instanced cone field with OrbitControls-style camera settings.",
                    scene; camera=camera, target=camera.target,
                    radius=500.0, height=200.0, fov=60pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_orbit.html"),
                           [build_orbit_controls_case()];
                           title="Diff3D.jl misc_controls_orbit")
    println("MISC_CONTROLS_ORBIT_OK $html")
end

main()

# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_map

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INSTANCE_COUNT = 500

fract(x) = x - floor(x)

function configure_map_controls(camera::PerspectiveCamera)
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

function build_building_field()
    geometry = BoxGeometry(width=1.0, height=1.0, depth=1.0)
    material = MeshPhongMaterial(color=Color3(238 / 255, 238 / 255, 238 / 255),
                                 shininess=18.0)
    inst = InstancedMesh(geometry, material, INSTANCE_COUNT;
                         name="map_controls_buildings")

    for i in 1:INSTANCE_COUNT
        x = 1600.0 * (fract(i * 0.7548776662466927) - 0.5)
        z = 1600.0 * (fract(i * 0.5698402909980532 + 0.17) - 0.5)
        h = 10.0 + 80.0 * fract(i * 0.4385513373931324 + 0.31)
        transform = mat4_translation(x, h / 2, z) * mat4_scaling(20.0, h, 20.0)
        set_instance_matrix!(inst, i, transform)
    end

    return inst
end

function build_map_controls_case()
    scene = Scene(background=Color3(0.8, 0.8, 0.8),
                  fog=FogExp2(color=Color3(0.8, 0.8, 0.8), density=0.002))
    add!(scene, build_building_field())

    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                                 position=Vec3(1.0, 1.0, 1.0)))
    add!(scene, DirectionalLight(color=Color3(0.0, 0.133, 0.533), intensity=3.0,
                                 position=Vec3(-1.0, -1.0, -1.0)))
    add!(scene, AmbientLight(color=Color3(0.333, 0.333, 0.333), intensity=1.0))

    camera = PerspectiveCamera(fov=60pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 200.0, -200.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    configure_map_controls(camera)

    WebGLExportCase("misc-controls-map", "Map Controls",
                    "Deterministic building field with map-style orbit constraints.",
                    scene; camera=camera, target=camera.target,
                    radius=sqrt(200.0^2 + 200.0^2), height=200.0,
                    fov=60pi / 180, tone_mapping=:linear,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_map.html"),
                           [build_map_controls_case()];
                           title="Diff3D.jl misc_controls_map")
    println("MISC_CONTROLS_MAP_OK $html")
end

main()

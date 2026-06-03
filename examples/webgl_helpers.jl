# Standalone Three.jl port for:
#   https://threejs.org/examples/#webgl_helpers

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function build_case()
    scene = Scene(background=Color3(0.018, 0.021, 0.028))
    add!(scene, AmbientLight(color=Color3(0.22, 0.24, 0.28), intensity=0.65))

    dir = DirectionalLight(color=Color3(1.0, 0.92, 0.78), intensity=1.1,
                           position=Vec3(3.0, 4.5, 2.5))
    dir.target = Vec3(0.0, 0.0, 0.0)
    add!(scene, dir)

    point = PointLight(color=Color3(0.35, 0.75, 1.0), intensity=12.0,
                       distance=7.0, position=Vec3(-2.8, 1.8, -1.8))
    add!(scene, point)

    spot = SpotLight(color=Color3(1.0, 0.48, 0.28), intensity=6.0, distance=8.0,
                     angle=pi/5, penumbra=0.35, position=Vec3(2.4, 3.8, -2.2))
    spot.target = Vec3(0.0, 0.3, 0.0)
    add!(scene, spot)

    hemi = HemisphereLight(color=Color3(0.55, 0.68, 1.0),
                           ground_color=Color3(0.32, 0.22, 0.12),
                           intensity=0.55)
    hemi.position = Vec3(0.0, 2.8, 0.0)
    add!(scene, hemi)

    add!(scene, GridHelper(8.0, 16; color=Color3(0.22, 0.24, 0.28)))
    add!(scene, PolarGridHelper(3.8, 16, 6; color=Color3(0.30, 0.33, 0.40)))
    add!(scene, AxesHelper(2.2))
    add!(scene, DirectionalLightHelper(dir; color=Color3(1.0, 0.92, 0.35)))
    add!(scene, PointLightHelper(point, 0.38; color=Color3(0.40, 0.80, 1.0)))
    add!(scene, SpotLightHelper(spot; color=Color3(1.0, 0.50, 0.28), segments=24))
    add!(scene, HemisphereLightHelper(hemi, 0.55))
    add!(scene, PlaneHelper(Plane(Vec3(0.0, 1.0, 0.0), 0.0), 1.6;
                            color=Color3(0.9, 0.82, 0.32)))

    mesh = Mesh(TorusKnotGeometry(radius=0.72, tube=0.16, tubular_segments=56,
                                  radial_segments=10),
                MeshStandardMaterial(color=Color3(0.36, 0.68, 0.95),
                                     metalness=0.2, roughness=0.35);
                name="helper_target_mesh")
    mesh.position = Vec3(0.0, 0.85, 0.0)
    add!(scene, mesh)
    box = BoxHelper(mesh; color=Color3(1.0, 0.84, 0.25))
    box.position = mesh.position
    add!(scene, box)

    cam = PerspectiveCamera(fov=pi/5, aspect=1.0, near=0.2, far=12.0)
    cam.position = Vec3(-2.4, 2.1, 3.2)
    cam.target = Vec3(0.0, 0.6, 0.0)
    add!(scene, CameraHelper(cam; color=Color3(0.95, 0.95, 1.0)))

    WebGLExportCase("helpers", "Helpers",
                    "Three.jl helper objects exported as interactive line geometry.",
                    scene; target=Vec3(0.0, 0.8, 0.0), radius=7.4, height=3.4,
                    fov=pi/4.3)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_helpers.html"), [build_case()])
    println("WEBGL_HELPERS_OK $html")
end

main()

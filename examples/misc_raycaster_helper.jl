# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_raycaster_helper

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SNAPSHOT_TIME = 0.0
const CAPSULE_X = (-2.0, 0.0, 2.0)

function ray_segment_geometry(raycaster::Raycaster)
    origin = raycaster.ray.origin
    endpoint = origin + raycaster.ray.direction * raycaster.far
    return BufferGeometry(Float64[
        origin.x, origin.y, origin.z,
        endpoint.x, endpoint.y, endpoint.z,
    ], Float64[], Float64[], Int[], 2, 0)
end

function add_capsules!(scene::Scene)
    geometry = CapsuleGeometry(radius=0.5, length=0.5,
                               cap_segments=4, radial_segments=32)
    material = MeshNormalMaterial(side=:double)
    rotation_z = sin(SNAPSHOT_TIME * 0.5) * pi

    for (i, x) in enumerate(CAPSULE_X)
        capsule = Mesh(geometry, material;
                       name="raycaster_capsule_$(i)")
        capsule.position = Vec3(x, sin(SNAPSHOT_TIME * 0.5 + x), 0.0)
        capsule.rotation = Euler(0.0, 0.0, rotation_z)
        add!(scene, capsule)
    end

    return scene
end

function add_ray_helper!(scene::Scene, raycaster::Raycaster, hits)
    ray = LineSegments(ray_segment_geometry(raycaster),
                       LineBasicMaterial(color=Color3(0.20, 0.65, 1.0),
                                         linewidth=2.0);
                       name="raycaster_helper_ray")
    add!(scene, ray)

    marker_geometry = SphereGeometry(radius=0.12, width_segments=16, height_segments=8)
    marker_material = MeshBasicMaterial(color=Color3(1.0, 0.85, 0.10))

    for (i, hit) in enumerate(hits)
        marker = Mesh(marker_geometry, marker_material;
                      name="raycaster_helper_hit_$(i)")
        marker.position = hit.point
        add!(scene, marker)
    end

    return scene
end

function build_raycaster_helper_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add_capsules!(scene)

    raycaster = Raycaster(Vec3(-4.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0);
                          near=1.0, far=8.0)
    hits = raycast(raycaster, scene; recursive=true)
    add_ray_helper!(scene, raycaster, hits)

    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = Vec3(0.0, 0.0, 10.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    WebGLExportCase("misc-raycaster-helper", "Raycaster Helper",
                    "CPU Raycaster snapshot over animated-capsule positions with visible hit markers.",
                    scene; camera=camera, target=camera.target,
                    radius=10.0, height=0.0, fov=70pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_raycaster_helper.html"),
                           [build_raycaster_helper_case()];
                           title="Diff3D.jl misc_raycaster_helper")
    println("MISC_RAYCASTER_HELPER_OK $html")
end

main()

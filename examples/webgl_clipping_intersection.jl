# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_clipping_intersection

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CLIP_INTERSECTION_PLANE_CONSTANT = 0.0
const CLIP_INTERSECTION_SPHERE_COUNT = 15
const CLIP_INTERSECTION_CAMERA_POSITION = Vec3(-1.5, 2.5, 3.0)
const CLIP_INTERSECTION_TARGET = Vec3(0.0, 0.0, 0.0)

const CLIP_INTERSECTION_PLANES = Plane{Float64}[
    Plane(Vec3(1.0, 0.0, 0.0), CLIP_INTERSECTION_PLANE_CONSTANT),
    Plane(Vec3(0.0, -1.0, 0.0), CLIP_INTERSECTION_PLANE_CONSTANT),
    Plane(Vec3(0.0, 0.0, -1.0), CLIP_INTERSECTION_PLANE_CONSTANT),
]

function clip_intersection_color(index::Integer)
    r = 0.25 + 0.60 * (0.5 + 0.5sin(1.83 * index))
    g = 0.25 + 0.60 * (0.5 + 0.5sin(2.27 * index + 1.2))
    b = 0.25 + 0.60 * (0.5 + 0.5sin(2.91 * index + 2.1))
    Color3(r, g, b)
end

function clip_intersection_sphere_radius(index::Integer)
    1 <= index <= CLIP_INTERSECTION_SPHERE_COUNT ||
        throw(ArgumentError("sphere index must be in 1:$CLIP_INTERSECTION_SPHERE_COUNT"))
    (2index - 1) / 30
end

function clip_intersection_spheres()
    group = Group(name="clip_intersection_spheres")
    for index in 1:CLIP_INTERSECTION_SPHERE_COUNT
        material = MeshPhongMaterial(color=clip_intersection_color(index),
                                     side=:double,
                                     clipping_planes=CLIP_INTERSECTION_PLANES)
        sphere = Mesh(SphereGeometry(radius=clip_intersection_sphere_radius(index),
                                     width_segments=48, height_segments=24),
                      material;
                      name="clip_intersection_sphere_$index")
        add!(group, sphere)
    end
    return group
end

function clip_intersection_helpers()
    helpers = Group(name="clip_intersection_plane_helpers")
    colors = (Color3(1.0, 0.0, 0.0),
              Color3(0.0, 1.0, 0.0),
              Color3(0.0, 0.0, 1.0))
    for (index, plane) in enumerate(CLIP_INTERSECTION_PLANES)
        helper = PlaneHelper(plane, 2.0; color=colors[index])
        helper.name = "clip_intersection_plane_helper_$index"
        add!(helpers, helper)
    end
    helpers.visible = false
    return helpers
end

function build_clipping_intersection_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    light = HemisphereLight(color=Color3(1.0, 1.0, 1.0),
                            ground_color=Color3(8 / 255, 8 / 255, 8 / 255),
                            intensity=4.5,
                            name="clip_intersection_hemisphere")
    light.position = Vec3(-1.25, 1.0, 1.25)
    add!(scene, light)

    add!(scene, clip_intersection_spheres())
    add!(scene, clip_intersection_helpers())

    camera = PerspectiveCamera(fov=40pi / 180, aspect=16 / 9,
                               near=1.0, far=200.0)
    camera.position = CLIP_INTERSECTION_CAMERA_POSITION
    camera.target = CLIP_INTERSECTION_TARGET

    WebGLExportCase("clipping-intersection", "Clipping Intersection",
                    "Nested clipped spheres using Diff3D.jl local material clipping planes.",
                    scene; camera=camera,
                    target=CLIP_INTERSECTION_TARGET,
                    radius=4.2,
                    height=0.0,
                    fov=40pi / 180,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_clipping_intersection.html"),
                           [build_clipping_intersection_case()])
    println("WEBGL_CLIPPING_INTERSECTION_OK $html")
end

main()

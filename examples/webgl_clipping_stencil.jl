# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_clipping_stencil

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CLIPPING_STENCIL_CAMERA_POSITION = Vec3(2.0, 2.0, 2.0)
const CLIPPING_STENCIL_TARGET = Vec3(0.0, 0.0, 0.0)
const CLIPPING_STENCIL_PLANES = Plane{Float64}[
    Plane(Vec3(-1.0, 0.0, 0.0), 0.0),
    Plane(Vec3(0.0, -1.0, 0.0), 0.0),
    Plane(Vec3(0.0, 0.0, -1.0), 0.0),
]

function clipping_stencil_cap_rotation(index::Integer)
    index == 1 && return Euler(0.0, -pi / 2, 0.0)
    index == 2 && return Euler(pi / 2, 0.0, 0.0)
    index == 3 && return Euler(0.0, 0.0, 0.0)
    throw(ArgumentError("cap plane index must be in 1:3"))
end

function clipping_stencil_helpers()
    helpers = Group(name="clipping_stencil_plane_helpers")
    for (index, plane) in enumerate(CLIPPING_STENCIL_PLANES)
        helper = PlaneHelper(plane, 2.0; color=Color3(1.0, 1.0, 1.0))
        helper.name = "clipping_stencil_plane_helper_$index"
        add!(helpers, helper)
    end
    helpers.visible = false
    return helpers
end

function clipping_stencil_cap_planes()
    group = Group(name="clipping_stencil_cap_planes")
    for (index, plane) in enumerate(CLIPPING_STENCIL_PLANES)
        material = MeshStandardMaterial(color=Color3(233 / 255, 30 / 255, 99 / 255),
                                        metalness=0.1,
                                        roughness=0.75,
                                        side=:double,
                                        clipping_planes=[p for p in CLIPPING_STENCIL_PLANES
                                                         if p !== plane])
        cap = Mesh(PlaneGeometry(width=4.0, height=4.0),
                   material;
                   name="clipping_stencil_cap_plane_$index")
        cap.position = plane.normal * (-plane.constant)
        cap.rotation = clipping_stencil_cap_rotation(index)
        add!(group, cap)
    end
    return group
end

function clipping_stencil_object()
    object = Group(name="clipping_stencil_object")
    material = MeshStandardMaterial(color=Color3(255 / 255, 193 / 255, 7 / 255),
                                    metalness=0.1,
                                    roughness=0.75,
                                    clipping_planes=CLIPPING_STENCIL_PLANES)
    torus = Mesh(TorusKnotGeometry(radius=0.4, tube=0.15,
                                   tubular_segments=220, radial_segments=60),
                 material;
                 name="clipping_stencil_torus_knot",
                 cast_shadow=true)
    add!(object, torus)
    return object
end

function clipping_stencil_animation(object::Group)
    AnimationClip("clipping_stencil_rotation", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(object, :rotation, [0.0, 5.0, 10.0],
                                [Quaternion(),
                                 quat_from_euler(2.5, 1.0, 0.0),
                                 quat_from_euler(5.0, 2.0, 0.0)])
    ]; loop=:repeat)
end

function build_clipping_stencil_case()
    scene = Scene(background=Color3(38 / 255, 50 / 255, 56 / 255))

    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.5,
                             name="clipping_stencil_ambient"))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                                 position=Vec3(5.0, 10.0, 7.5),
                                 cast_shadow=true,
                                 name="clipping_stencil_directional"))
    add!(scene, clipping_stencil_helpers())
    add!(scene, clipping_stencil_cap_planes())

    object = clipping_stencil_object()
    add!(scene, object)

    ground = Mesh(PlaneGeometry(width=9.0, height=9.0),
                  MeshBasicMaterial(color=Color3(0.0, 0.0, 0.0),
                                    opacity=0.25,
                                    transparent=true,
                                    side=:double);
                  name="clipping_stencil_shadow_ground",
                  receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    ground.position = Vec3(0.0, -1.0, 0.0)
    add!(scene, ground)

    camera = PerspectiveCamera(fov=36pi / 180, aspect=16 / 9,
                               near=1.0, far=100.0)
    camera.position = CLIPPING_STENCIL_CAMERA_POSITION
    camera.target = CLIPPING_STENCIL_TARGET

    WebGLExportCase("clipping-stencil", "Clipping Stencil",
                    "Solid-looking clipped torus with static cap-plane approximation.",
                    scene; camera=camera,
                    target=CLIPPING_STENCIL_TARGET,
                    radius=4.2,
                    height=0.0,
                    fov=36pi / 180,
                    animations=[clipping_stencil_animation(object)],
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_clipping_stencil.html"),
                           [build_clipping_stencil_case()];
                           title="Diff3D.jl webgl_clipping_stencil")
    println("WEBGL_CLIPPING_STENCIL_OK $html")
end

main()

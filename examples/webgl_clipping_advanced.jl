# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_clipping_advanced

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CLIPPING_ADVANCED_CAMERA_POSITION = Vec3(0.0, 1.5, 3.0)
const CLIPPING_ADVANCED_TARGET = Vec3(0.0, 1.0, 0.0)
const CLIPPING_ADVANCED_BOX_COUNT = 5 * 5 * 5
const CLIPPING_ADVANCED_BOX_SIZE = 0.18
const CLIPPING_ADVANCED_INITIAL_BOUNCY_SCALE = 1.2
const CLIPPING_ADVANCED_OBJECT_POSITION = Vec3(0.0, 1.0, 0.0)

const CLIPPING_ADVANCED_VERTICES = Vec3{Float64}[
    Vec3(1.0, 0.0, sqrt(0.5)),
    Vec3(-1.0, 0.0, sqrt(0.5)),
    Vec3(0.0, 1.0, -sqrt(0.5)),
    Vec3(0.0, -1.0, -sqrt(0.5)),
]

const CLIPPING_ADVANCED_INDICES = (
    (1, 2, 3),
    (1, 3, 4),
    (1, 4, 2),
    (2, 4, 3),
)

function clipping_advanced_plane_from_points(a::Vec3, b::Vec3, c::Vec3)
    normal = normalize(cross(c - b, a - b))
    norm(normal) > 0 || throw(ArgumentError("plane points must be non-collinear"))
    Plane(normal, -dot(normal, a))
end

function clipping_advanced_planes_from_mesh(vertices, indices)
    [clipping_advanced_plane_from_points(vertices[i], vertices[j], vertices[k])
     for (i, j, k) in indices]
end

function clipping_advanced_cylindrical_planes(n::Integer, inner_radius::Real)
    n > 0 || throw(ArgumentError("cylindrical plane count must be positive"))
    [Plane(Vec3(cos(2pi * (i - 1) / n), 0.0, sin(2pi * (i - 1) / n)),
           Float64(inner_radius)) for i in 1:n]
end

function clipping_advanced_transform_plane(plane::Plane, matrix::Mat4)
    normal = normalize(mat4_transform_direction(matrix, plane.normal))
    point = mat4_transform_point(matrix, plane.normal * (-plane.constant))
    Plane(normal, -dot(normal, point))
end

function clipping_advanced_initial_transform()
    mat4_translation(CLIPPING_ADVANCED_OBJECT_POSITION.x,
                     CLIPPING_ADVANCED_OBJECT_POSITION.y,
                     CLIPPING_ADVANCED_OBJECT_POSITION.z) *
    mat4_scaling(CLIPPING_ADVANCED_INITIAL_BOUNCY_SCALE,
                 CLIPPING_ADVANCED_INITIAL_BOUNCY_SCALE,
                 CLIPPING_ADVANCED_INITIAL_BOUNCY_SCALE)
end

const CLIPPING_ADVANCED_LOCAL_PLANES =
    [clipping_advanced_transform_plane(plane, clipping_advanced_initial_transform())
     for plane in clipping_advanced_planes_from_mesh(CLIPPING_ADVANCED_VERTICES,
                                                     CLIPPING_ADVANCED_INDICES)]

const CLIPPING_ADVANCED_GLOBAL_PLANES = clipping_advanced_cylindrical_planes(5, 2.5)

function clipping_advanced_instanced_boxes()
    material = MeshPhongMaterial(color=Color3(238 / 255, 10 / 255, 16 / 255),
                                 shininess=100.0,
                                 side=:double,
                                 clipping_planes=CLIPPING_ADVANCED_LOCAL_PLANES)
    boxes = InstancedMesh(BoxGeometry(width=CLIPPING_ADVANCED_BOX_SIZE,
                                      height=CLIPPING_ADVANCED_BOX_SIZE,
                                      depth=CLIPPING_ADVANCED_BOX_SIZE),
                          material,
                          CLIPPING_ADVANCED_BOX_COUNT;
                          name="clipping_advanced_instanced_boxes",
                          cast_shadow=true)
    boxes.position = CLIPPING_ADVANCED_OBJECT_POSITION

    slot = 1
    for z in -2:2, y in -2:2, x in -2:2
        set_instance_matrix!(boxes, slot, mat4_translation(x / 5, y / 5, z / 5))
        slot += 1
    end
    slot == CLIPPING_ADVANCED_BOX_COUNT + 1 ||
        throw(AssertionError("unexpected clipping advanced instance count"))
    return boxes
end

function clipping_advanced_volume_helpers()
    group = Group(name="clipping_advanced_volume_helpers")
    colors = (Color3(0.75, 0.25, 0.25),
              Color3(0.25, 0.75, 0.25),
              Color3(0.25, 0.40, 0.85),
              Color3(0.80, 0.70, 0.25))
    for (index, plane) in enumerate(CLIPPING_ADVANCED_LOCAL_PLANES)
        helper = PlaneHelper(plane, 3.0; color=colors[index])
        helper.name = "clipping_advanced_volume_plane_$index"
        add!(group, helper)
    end
    group.visible = false
    return group
end

function build_clipping_advanced_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                             name="clipping_advanced_ambient"))
    add!(scene, SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=60.0,
                          position=Vec3(2.0, 3.0, 3.0),
                          angle=pi / 5, penumbra=0.2,
                          cast_shadow=true,
                          name="clipping_advanced_spot"))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=1.5,
                                 position=Vec3(0.0, 2.0, 0.0),
                                 cast_shadow=true,
                                 name="clipping_advanced_directional"))

    add!(scene, clipping_advanced_instanced_boxes())
    add!(scene, clipping_advanced_volume_helpers())

    ground = Mesh(PlaneGeometry(width=9.0, height=9.0),
                  MeshPhongMaterial(color=Color3(160 / 255, 173 / 255, 175 / 255),
                                    shininess=10.0,
                                    side=:double);
                  name="clipping_advanced_ground",
                  receive_shadow=true)
    ground.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, ground)

    camera = PerspectiveCamera(fov=36pi / 180, aspect=16 / 9,
                               near=0.25, far=16.0)
    camera.position = CLIPPING_ADVANCED_CAMERA_POSITION
    camera.target = CLIPPING_ADVANCED_TARGET

    WebGLExportCase("clipping-advanced", "Clipping Advanced",
                    "Initial-frame tetrahedral material clipping over the upstream instanced box lattice.",
                    scene; camera=camera,
                    target=CLIPPING_ADVANCED_TARGET,
                    radius=4.2,
                    height=1.0,
                    fov=36pi / 180,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_clipping_advanced.html"),
                           [build_clipping_advanced_case()];
                           title="Diff3D.jl webgl_clipping_advanced")
    println("WEBGL_CLIPPING_ADVANCED_OK $html")
end

main()

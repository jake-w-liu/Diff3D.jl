# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_controls_transform

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const ASPECT = 16 / 9
const FRUSTUM_SIZE = 5.0
const TRANSLATE_DELTA = Vec3(1.16, 0.48, -0.42)
const ROTATE_DELTA = Vec3(0.0, 0.0, 0.49)
const SCALE_DELTA = Vec3(1.0, 1.45, 0.72)

function crate_texture(; n::Int=32)
    data = zeros(Float64, n, n, 4)

    for y in 1:n, x in 1:n
        border = x <= 3 || y <= 3 || x >= n - 2 || y >= n - 2
        diagonal = abs(x - y) <= 1 || abs(x + y - n - 1) <= 1
        groove = x % 8 == 0 || y % 8 == 0
        shade = border || diagonal ? 0.92 : groove ? 0.58 : 0.72
        data[y, x, 1] = shade
        data[y, x, 2] = 0.47 * shade
        data[y, x, 3] = 0.18 * shade
        data[y, x, 4] = 1.0
    end

    Texture(data; filter=:nearest, min_filter=:nearest, mag_filter=:nearest,
            colorspace=:srgb)
end

function transform_material(texture::Texture, color::Color3)
    MeshLambertMaterial(color=color, map=texture)
end

function apply_transform_snapshots!(camera::PerspectiveCamera, translate_cube::Mesh,
                                    rotate_cube::Mesh, scale_cube::Mesh)
    controls = TransformControls(camera; mode=:translate, space=:world,
                                 axis=:XYZ)

    transform_attach!(controls, translate_cube)
    transform_set_translation_snap!(controls, 0.25)
    transform_apply!(controls, TRANSLATE_DELTA)

    transform_attach!(controls, rotate_cube)
    transform_set_mode!(controls, :rotate)
    transform_set_axis!(controls, :Z)
    transform_set_rotation_snap!(controls, pi / 12)
    transform_apply!(controls, ROTATE_DELTA)

    transform_attach!(controls, scale_cube)
    transform_set_mode!(controls, :scale)
    transform_set_axis!(controls, :YZ)
    transform_set_scale_snap!(controls, 0.25)
    transform_apply!(controls, SCALE_DELTA)

    transform_set_enabled!(controls, false)
    return controls
end

function build_transform_scene(camera::PerspectiveCamera)
    scene = Scene(background=Color3(0.94, 0.94, 0.94))
    add!(scene, GridHelper(5.0, 10; color=Color3(0.533, 0.533, 0.533)))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=4.0,
                                 position=Vec3(1.0, 1.0, 1.0)))

    texture = crate_texture()
    geometry = BoxGeometry()
    translate_cube = Mesh(geometry,
                          transform_material(texture, Color3(1.0, 0.74, 0.45));
                          name="transform_translate_cube")
    rotate_cube = Mesh(geometry,
                       transform_material(texture, Color3(0.55, 0.78, 1.0));
                       name="transform_rotate_cube")
    scale_cube = Mesh(geometry,
                      transform_material(texture, Color3(0.62, 0.92, 0.58));
                      name="transform_scale_cube")

    translate_cube.position = Vec3(-2.0, 0.5, 0.0)
    rotate_cube.position = Vec3(0.0, 0.5, 0.0)
    scale_cube.position = Vec3(2.0, 0.5, 0.0)

    apply_transform_snapshots!(camera, translate_cube, rotate_cube, scale_cube)

    add!(scene, translate_cube)
    add!(scene, rotate_cube)
    add!(scene, scale_cube)
    return scene
end

function perspective_camera()
    camera = PerspectiveCamera(fov=50pi / 180, aspect=ASPECT,
                               near=0.1, far=100.0)
    camera.position = Vec3(5.0, 2.5, 5.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    orbit_update!(OrbitControls(camera))
    return camera
end

function orthographic_camera()
    camera = OrthographicCamera(left=-FRUSTUM_SIZE * ASPECT,
                                right=FRUSTUM_SIZE * ASPECT,
                                top=FRUSTUM_SIZE,
                                bottom=-FRUSTUM_SIZE,
                                near=0.1, far=100.0,
                                name="transform_orthographic_camera")
    camera.position = Vec3(5.0, 2.5, 5.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    return camera
end

function perspective_case()
    camera = perspective_camera()
    WebGLExportCase("misc-controls-transform-perspective",
                    "Transform Controls - Perspective",
                    "Snapped translate, rotate, and scale snapshots on textured cubes.",
                    build_transform_scene(camera);
                    camera=camera, target=camera.target,
                    radius=7.5, height=1.5, fov=50pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function orthographic_case()
    transform_camera = perspective_camera()
    camera = orthographic_camera()
    WebGLExportCase("misc-controls-transform-orthographic",
                    "Transform Controls - Orthographic",
                    "Orthographic camera counterpart to the upstream camera toggle.",
                    build_transform_scene(transform_camera);
                    camera=camera, target=camera.target,
                    radius=7.5, height=1.5, fov=50pi / 180,
                    tone_mapping=:linear, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_controls_transform.html"),
                           [perspective_case(), orthographic_case()];
                           title="Diff3D.jl misc_controls_transform")
    println("MISC_CONTROLS_TRANSFORM_OK $html")
end

main()

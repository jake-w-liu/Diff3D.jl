# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_csm

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const CSM_BACKGROUND = Color3(69 / 255, 78 / 255, 97 / 255)
const CSM_FLOOR_COLOR = Color3(37 / 255, 42 / 255, 52 / 255)
const CSM_MATERIAL_1_COLOR = Color3(8 / 255, 217 / 255, 214 / 255)
const CSM_MATERIAL_2_COLOR = Color3(1.0, 46 / 255, 99 / 255)
const CSM_FILL_LIGHT_COLOR = Color3(0.0, 0.0, 32 / 255)
const CSM_CAMERA_POSITION = Vec3(60.0, 60.0, 0.0)
const CSM_TARGET = Vec3(-100.0, 10.0, 0.0)
const CSM_CUBE_COLUMNS = 40
const CSM_CUBE_ROWS = 2
const CSM_CUBE_COUNT = CSM_CUBE_COLUMNS * CSM_CUBE_ROWS
const CSM_CASCADES = 4
const CSM_MAX_FAR = 1000.0
const CSM_MODE = "practical"
const CSM_SHADOW_MAP_SIZE = 1024
const CSM_LIGHT_X = -1.0
const CSM_LIGHT_Y = -1.0
const CSM_LIGHT_Z = -1.0
const CSM_LIGHT_MARGIN = 100.0
const CSM_LIGHT_NEAR = 1.0
const CSM_LIGHT_FAR = 5000.0

csm_fract(x::Float64) = x - floor(x)

function csm_light_direction()
    len = sqrt(CSM_LIGHT_X^2 + CSM_LIGHT_Y^2 + CSM_LIGHT_Z^2)
    len > 0.0 || error("CSM light direction vector must be nonzero")
    Vec3(CSM_LIGHT_X / len, CSM_LIGHT_Y / len, CSM_LIGHT_Z / len)
end

function csm_light_position(; distance::Real=200.0)
    dir = csm_light_direction()
    Vec3(-dir.x * Float64(distance),
         -dir.y * Float64(distance),
         -dir.z * Float64(distance))
end

function csm_cube_scale_y(column::Integer, row::Integer)
    1 <= column <= CSM_CUBE_COLUMNS ||
        throw(ArgumentError("cube column must be in 1:$CSM_CUBE_COLUMNS"))
    1 <= row <= CSM_CUBE_ROWS ||
        throw(ArgumentError("cube row must be in 1:$CSM_CUBE_ROWS"))
    6.0 + 2.0 * csm_fract(sin(17.731 * column + 29.417 * row) * 91.113)
end

function csm_cube_position(column::Integer, row::Integer)
    1 <= column <= CSM_CUBE_COLUMNS ||
        throw(ArgumentError("cube column must be in 1:$CSM_CUBE_COLUMNS"))
    1 <= row <= CSM_CUBE_ROWS ||
        throw(ArgumentError("cube row must be in 1:$CSM_CUBE_ROWS"))
    z = row == 1 ? 30.0 : -30.0
    Vec3(-(column - 1) * 25.0, 20.0, z)
end

function csm_floor()
    floor = Mesh(PlaneGeometry(width=10000.0, height=10000.0,
                               width_segments=8, height_segments=8),
                 MeshPhongMaterial(color=CSM_FLOOR_COLOR);
                 name="csm_floor", cast_shadow=true, receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    return floor
end

function csm_cubes()
    geometry = BoxGeometry(width=10.0, height=10.0, depth=10.0)
    material1 = MeshPhongMaterial(color=CSM_MATERIAL_1_COLOR)
    material2 = MeshPhongMaterial(color=CSM_MATERIAL_2_COLOR)
    group = Group(name="csm_cube_rows")

    for column in 1:CSM_CUBE_COLUMNS
        for row in 1:CSM_CUBE_ROWS
            use_first = isodd(column - 1) ? row == 2 : row == 1
            material = use_first ? material1 : material2
            cube = Mesh(geometry, material;
                        name="csm_cube_$(row)_$(lpad(string(column), 2, '0'))",
                        cast_shadow=true, receive_shadow=true)
            cube.position = csm_cube_position(column, row)
            cube.scale = Vec3(1.0, csm_cube_scale_y(column, row), 1.0)
            add!(group, cube)
        end
    end

    return group
end

function build_shadowmap_csm_case()
    scene = Scene(background=CSM_BACKGROUND)

    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0),
                             intensity=1.5, name="csm_ambient"))

    add!(scene, DirectionalLight(color=CSM_FILL_LIGHT_COLOR,
                                 intensity=1.5,
                                 position=csm_light_position(),
                                 name="csm_fill_directional"))

    shadow_light = DirectionalLight(color=Color3(1.0, 1.0, 1.0),
                                    intensity=3.0,
                                    position=csm_light_position(),
                                    cast_shadow=true,
                                    shadow_pcf_radius=1,
                                    name="csm_dynamic_shadow_directional")
    shadow_light.target = Vec3(0.0, 0.0, 0.0)
    add!(scene, shadow_light)

    add!(scene, csm_floor())
    add!(scene, csm_cubes())

    camera = PerspectiveCamera(fov=70pi / 180, aspect=16 / 9,
                               near=0.1, far=5000.0)
    camera.position = CSM_CAMERA_POSITION
    camera.target = CSM_TARGET

    WebGLExportCase("shadowmap-csm", "Shadowmap CSM",
                    "Cascaded-shadow-map scene layout with a supported dynamic directional shadow fallback.",
                    scene; camera=camera, target=CSM_TARGET,
                    radius=120.0, height=20.0, fov=70pi / 180,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_csm.html"),
                           [build_shadowmap_csm_case()])
    println("WEBGL_SHADOWMAP_CSM_OK $html")
end

main()

# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_interactive_buffergeometry

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const INTERACTIVE_TRIANGLES = 5_000
const INTERACTIVE_VERTEX_COUNT = 3 * INTERACTIVE_TRIANGLES
const INTERACTIVE_SPREAD = 800.0
const INTERACTIVE_TRIANGLE_SIZE = 120.0

interactive_fract(x::Float64) = x - floor(x)

function interactive_hash_noise(index::Int, salt::Float64)
    interactive_fract(sin((index + 1) * 19.743 + salt * 104.729) * 37231.619)
end

function interactive_offset(index::Int, salt::Float64, width::Float64)
    (interactive_hash_noise(index, salt) - 0.5) * width
end

function append_interactive_vertex!(positions::Vector{Float64}, x::Float64, y::Float64, z::Float64)
    push!(positions, x, y, z)
end

function push_normal3!(normals::Vector{Float64}, n::Vec3{Float64})
    for _ in 1:3
        push!(normals, n.x, n.y, n.z)
    end
end

function push_color3!(colors::Vector{Float64}, c::Color3{Float64})
    for _ in 1:3
        push!(colors, c.r, c.g, c.b)
    end
end

function interactive_face_normal(a::Vec3{Float64}, b::Vec3{Float64}, c::Vec3{Float64})
    n = cross(c - b, a - b)
    len = norm(n)
    len > 1e-12 ? n / len : Vec3(0.0, 0.0, 1.0)
end

function interactive_triangle_cloud_geometry()
    positions = Vector{Float64}(undef, 0)
    normals = Vector{Float64}(undef, 0)
    colors = Vector{Float64}(undef, 0)
    sizehint!(positions, 3 * INTERACTIVE_VERTEX_COUNT)
    sizehint!(normals, 3 * INTERACTIVE_VERTEX_COUNT)
    sizehint!(colors, 3 * INTERACTIVE_VERTEX_COUNT)

    half_spread = INTERACTIVE_SPREAD / 2
    for triangle_id in 0:(INTERACTIVE_TRIANGLES - 1)
        x = interactive_hash_noise(triangle_id, 0.10) * INTERACTIVE_SPREAD - half_spread
        y = interactive_hash_noise(triangle_id, 0.20) * INTERACTIVE_SPREAD - half_spread
        z = interactive_hash_noise(triangle_id, 0.30) * INTERACTIVE_SPREAD - half_spread

        ax = x + interactive_offset(3triangle_id + 1, 0.11, INTERACTIVE_TRIANGLE_SIZE)
        ay = y + interactive_offset(3triangle_id + 1, 0.12, INTERACTIVE_TRIANGLE_SIZE)
        az = z + interactive_offset(3triangle_id + 1, 0.13, INTERACTIVE_TRIANGLE_SIZE)
        bx = x + interactive_offset(3triangle_id + 2, 0.21, INTERACTIVE_TRIANGLE_SIZE)
        by = y + interactive_offset(3triangle_id + 2, 0.22, INTERACTIVE_TRIANGLE_SIZE)
        bz = z + interactive_offset(3triangle_id + 2, 0.23, INTERACTIVE_TRIANGLE_SIZE)
        cx = x + interactive_offset(3triangle_id + 3, 0.31, INTERACTIVE_TRIANGLE_SIZE)
        cy = y + interactive_offset(3triangle_id + 3, 0.32, INTERACTIVE_TRIANGLE_SIZE)
        cz = z + interactive_offset(3triangle_id + 3, 0.33, INTERACTIVE_TRIANGLE_SIZE)

        a = Vec3(ax, ay, az)
        b = Vec3(bx, by, bz)
        c = Vec3(cx, cy, cz)
        n = interactive_face_normal(a, b, c)
        color = Color3(x / INTERACTIVE_SPREAD + 0.5,
                       y / INTERACTIVE_SPREAD + 0.5,
                       z / INTERACTIVE_SPREAD + 0.5)

        append_interactive_vertex!(positions, ax, ay, az)
        append_interactive_vertex!(positions, bx, by, bz)
        append_interactive_vertex!(positions, cx, cy, cz)
        push_normal3!(normals, n)
        push_color3!(colors, color)
    end

    indices = collect(1:INTERACTIVE_VERTEX_COUNT)
    geo = BufferGeometry(positions, normals, Float64[], indices,
                         INTERACTIVE_VERTEX_COUNT, INTERACTIVE_TRIANGLES)
    set_attribute!(geo, :color, colors, 3)
    geo
end

function selected_face_outline_geometry(mesh::Mesh, hit::Intersection)
    geo = mesh.geometry
    i1, i2, i3 = get_face(geo, hit.face_index)
    a = get_vertex(geo, i1)
    b = get_vertex(geo, i2)
    c = get_vertex(geo, i3)
    BufferGeometry(Float64[
        a.x, a.y, a.z,
        b.x, b.y, b.z,
        c.x, c.y, c.z,
        a.x, a.y, a.z,
    ], Float64[], Float64[], Int[], 4, 0)
end

function build_interactive_buffergeometry_case()
    scene = Scene(background=Color3(0.0196, 0.0196, 0.0196),
                  fog=Fog(color=Color3(0.0196, 0.0196, 0.0196), near=2000.0, far=3500.0))
    add!(scene, AmbientLight(color=Color3(0.2667, 0.2667, 0.2667), intensity=3.0))

    light1 = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=1.5)
    light1.position = Vec3(1.0, 1.0, 1.0)
    add!(scene, light1)
    light2 = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=4.5)
    light2.position = Vec3(0.0, -1.0, 0.0)
    add!(scene, light2)

    mesh = Mesh(interactive_triangle_cloud_geometry(),
                MeshPhongMaterial(color=Color3(0.6667, 0.6667, 0.6667),
                                  specular=Color3(1.0, 1.0, 1.0),
                                  shininess=250.0,
                                  side=:double,
                                  vertex_colors=true);
                name="interactive_buffergeometry_triangle_cloud")
    add!(scene, mesh)

    camera = PerspectiveCamera(fov=27pi / 180, aspect=16 / 9, near=1.0, far=3500.0)
    camera.position = Vec3(0.0, 0.0, 2750.0)
    camera.target = Vec3(0.0, 0.0, 0.0)

    raycaster = Raycaster(camera.position, camera.target - camera.position; near=1.0, far=3500.0)
    hits = raycast(raycaster, mesh; recursive=false)
    isempty(hits) && error("interactive buffergeometry snapshot ray did not hit the triangle cloud")
    outline = LineObject(selected_face_outline_geometry(mesh, first(hits)),
                         LineBasicMaterial(color=Color3(1.0, 1.0, 1.0),
                                           linewidth=2.0);
                         name="interactive_buffergeometry_selected_face")
    add!(scene, outline)

    clip = AnimationClip("interactive_buffergeometry_rotation",
        AbstractKeyframeTrack[
            QuaternionKeyframeTrack(mesh, :rotation, [0.0, 12.0],
                [Quaternion(), quat_from_euler(1.8, 3.0, 0.0)]),
        ]; loop=:repeat)

    WebGLExportCase("interactive-buffergeometry", "Interactive BufferGeometry",
                    "5000 colored triangles with a CPU Raycaster-selected face outline snapshot.",
                    scene; camera=camera, target=camera.target,
                    radius=2750.0, height=0.0, fov=27pi / 180,
                    animations=[clip],
                    tone_mapping=:none, output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_interactive_buffergeometry.html"),
                           [build_interactive_buffergeometry_case()];
                           title="Diff3D.jl webgl_interactive_buffergeometry")
    println("WEBGL_INTERACTIVE_BUFFERGEOMETRY_OK $html triangles=$INTERACTIVE_TRIANGLES")
end

main()

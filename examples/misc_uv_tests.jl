# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#misc_uv_tests

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function lathe_points()
    [Vec2(sin(i * 0.2) * 15.0 + 50.0, (i - 5) * 2.0) for i in 0:9]
end

function uv_point(geo::BufferGeometry, vertex_index::Int)
    offset = 2vertex_index - 1
    offset + 1 <= length(geo.uvs) ||
        throw(ArgumentError("geometry does not contain a UV coordinate for vertex $vertex_index"))
    return geo.uvs[offset], geo.uvs[offset + 1]
end

function add_uv_segment!(positions::Vector{Float64}, geo::BufferGeometry,
                         a::Int, b::Int; z::Float64=0.0)
    au, av = uv_point(geo, a)
    bu, bv = uv_point(geo, b)
    append!(positions, (au, av, z, bu, bv, z))
    return positions
end

function uv_edges_geometry(geo::BufferGeometry)
    positions = Float64[]

    for fi in 1:geo.n_faces
        a, b, c = get_face(geo, fi)
        add_uv_segment!(positions, geo, a, b)
        add_uv_segment!(positions, geo, b, c)
        add_uv_segment!(positions, geo, c, a)
    end

    return BufferGeometry(positions, Float64[], Float64[], Int[],
                          length(positions) ÷ 3, 0)
end

function uv_reference_grid_geometry()
    positions = Float64[]

    function segment!(a, b, c, d)
        append!(positions, (a, b, -0.001, c, d, -0.001))
    end

    segment!(0.0, 0.0, 1.0, 0.0)
    segment!(1.0, 0.0, 1.0, 1.0)
    segment!(1.0, 1.0, 0.0, 1.0)
    segment!(0.0, 1.0, 0.0, 0.0)

    for t in (0.25, 0.5, 0.75)
        segment!(t, 0.0, t, 1.0)
        segment!(0.0, t, 1.0, t)
    end

    return BufferGeometry(positions, Float64[], Float64[], Int[],
                          length(positions) ÷ 3, 0)
end

const UV_CASES = [
    ("misc-uv-tests-plane", "new THREE.PlaneGeometry( 100, 100, 4, 4 )",
     () -> PlaneGeometry(width=100.0, height=100.0,
                         width_segments=4, height_segments=4)),
    ("misc-uv-tests-sphere", "new THREE.SphereGeometry( 75, 12, 6 )",
     () -> SphereGeometry(radius=75.0, width_segments=12, height_segments=6)),
    ("misc-uv-tests-icosahedron", "new THREE.IcosahedronGeometry( 30, 1 )",
     () -> IcosahedronGeometry(radius=30.0, detail=1)),
    ("misc-uv-tests-octahedron", "new THREE.OctahedronGeometry( 30, 2 )",
     () -> OctahedronGeometry(radius=30.0, detail=2)),
    ("misc-uv-tests-cylinder", "new THREE.CylinderGeometry( 25, 75, 100, 10, 5 )",
     () -> CylinderGeometry(radius_top=25.0, radius_bottom=75.0,
                            height=100.0, radial_segments=10, height_segments=5)),
    ("misc-uv-tests-box", "new THREE.BoxGeometry( 100, 100, 100, 4, 4, 4 )",
     () -> BoxGeometry(width=100.0, height=100.0, depth=100.0,
                       width_segments=4, height_segments=4, depth_segments=4)),
    ("misc-uv-tests-lathe", "new THREE.LatheGeometry( points, 8 )",
     () -> LatheGeometry(lathe_points(); segments=8)),
    ("misc-uv-tests-torus", "new THREE.TorusGeometry( 50, 20, 8, 8 )",
     () -> TorusGeometry(radius=50.0, tube=20.0,
                         radial_segments=8, tubular_segments=8)),
    ("misc-uv-tests-torusknot", "new THREE.TorusKnotGeometry( 50, 10, 12, 6 )",
     () -> TorusKnotGeometry(radius=50.0, tube=10.0,
                             tubular_segments=12, radial_segments=6)),
]

function build_uv_case(id::String, title::String, geometry::BufferGeometry)
    scene = Scene(background=Color3(1.0, 1.0, 1.0))

    add!(scene, LineSegments(uv_reference_grid_geometry(),
                             LineBasicMaterial(color=Color3(0.78, 0.78, 0.78),
                                               depth_test=false);
                             name="$(id)_unit_grid"))
    add!(scene, LineSegments(uv_edges_geometry(geometry),
                             LineBasicMaterial(color=Color3(0.04, 0.12, 0.26),
                                               depth_test=false);
                             name="$(id)_uv_edges"))

    camera = OrthographicCamera(left=-0.08, right=1.08, top=1.08, bottom=-0.08,
                                near=0.1, far=10.0, name="$(id)_camera")
    camera.position = Vec3(0.5, 0.5, 2.0)
    camera.target = Vec3(0.5, 0.5, 0.0)

    WebGLExportCase(id, title, "UV triangle-edge projection generated from BufferGeometry.uvs.",
                    scene; camera=camera, target=camera.target, radius=1.2,
                    height=0.0, fov=45pi / 180, tone_mapping=:linear,
                    output_color_space=:srgb)
end

function build_uv_cases()
    [build_uv_case(id, title, builder()) for (id, title, builder) in UV_CASES]
end

function main()
    html = save_webgl_html(joinpath(OUT, "misc_uv_tests.html"),
                           build_uv_cases();
                           title="Diff3D.jl misc_uv_tests")
    println("MISC_UV_TESTS_OK $html")
end

main()

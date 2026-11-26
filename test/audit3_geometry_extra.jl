using Test, Diff3D

# Regression tests for the geometry-extra audit (src/geometries_extra.jl and
# src/csg.jl). Expected values come from three.js r186 run under node, or from
# the derivation cited next to each expectation.

function _audit3_segments(geometry)
    p = geometry.positions
    segments = NTuple{2,NTuple{3,Float64}}[]
    for i in 1:6:length(p)
        a = (p[i], p[i + 1], p[i + 2])
        b = (p[i + 3], p[i + 4], p[i + 5])
        push!(segments, a <= b ? (a, b) : (b, a))
    end
    return sort!(segments)
end

function _audit3_winding_matches_normals(geometry)
    for face in 1:geometry.n_faces
        i1, i2, i3 = geometry.indices[3face - 2], geometry.indices[3face - 1],
                     geometry.indices[3face]
        a = get_vertex(geometry, i1)
        b = get_vertex(geometry, i2)
        c = get_vertex(geometry, i3)
        winding = cross(b - a, c - a)
        for index in (i1, i2, i3)
            stored = Vec3(geometry.normals[3index - 2], geometry.normals[3index - 1],
                          geometry.normals[3index])
            dot(winding, stored) > 0 || return false
        end
    end
    return true
end

@testset "edges_geometry skips triangles with welded corners" begin
    # Unit quad split along its diagonal plus a zero-area triangle (1, 3, 3)
    # lying on that diagonal. three.js EdgesGeometry.js:96-100 skips triangles
    # whose corner hashes coincide, so node prints only the four boundary
    # edges: [0,0,0,1,0,0, 1,0,0,1,1,0, 1,1,0,0,1,0, 0,1,0,0,0,0].
    quad = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0],
                          Float64[], Float64[], [1, 2, 3, 1, 3, 4, 1, 3, 3], 4, 3)
    edges = edges_geometry(quad; threshold_angle=deg2rad(20))
    @test _audit3_segments(edges) == [
        ((0.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
        ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0)),
        ((0.0, 1.0, 0.0), (1.0, 1.0, 0.0)),
        ((1.0, 0.0, 0.0), (1.0, 1.0, 0.0)),
    ]

    # A lone triangle with two coincident corners contributes nothing; the
    # well-formed triangle keeps its three boundary edges (node prints 3).
    lone = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                           1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                          Float64[], Float64[], collect(1:6), 6, 2)
    @test edges_geometry(lone; threshold_angle=deg2rad(20)).n_vertices == 6
end

@testset "edges_geometry keeps edges at exactly the threshold" begin
    # three.js EdgesGeometry.js:120 emits an edge when
    # dot(n1, n2) <= cos(threshold). With a zero threshold every shared edge of
    # coplanar faces qualifies: node prints 18 segments for BoxGeometry(1,1,1)
    # with thresholdAngle 0 (12 cube edges + 6 face diagonals) and 12 at 90°.
    @test edges_geometry(BoxGeometry(); threshold_angle=0.0).n_vertices ÷ 2 == 18
    @test edges_geometry(BoxGeometry(); threshold_angle=π / 2).n_vertices ÷ 2 == 12
    @test edges_geometry(BoxGeometry()).n_vertices ÷ 2 == 12
end

@testset "ExtrudeGeometry wall normals follow the winding for negative depth" begin
    # three.js ExtrudeGeometry.js calls computeVertexNormals, so every stored
    # normal agrees with its triangle's winding. With depth = -1 node prints
    # the y = 0 wall of the unit square with normal (0, 1, 0).
    square = [Vec2(0.0, 0.0), Vec2(1.0, 0.0), Vec2(1.0, 1.0), Vec2(0.0, 1.0)]
    for depth in (-1.0, 1.0), steps in (1, 3)
        geometry = ExtrudeGeometry(square; depth=depth, steps=steps)
        @test _audit3_winding_matches_normals(geometry)
    end
    geometry = ExtrudeGeometry(square; depth=-1.0)
    for i in 1:geometry.n_vertices
        y = geometry.positions[3i - 1]
        n = geometry.normals[3i - 2:3i]
        abs(n[3]) == 1.0 && continue
        if y == 0.0 && n[1] == 0.0
            @test n == [0.0, 1.0, 0.0]
        end
    end
end

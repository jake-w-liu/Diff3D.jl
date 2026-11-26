using Test, Diff3D

# Index buffers below were printed by three.js r186 (`Array.from(geometry.index.array)`)
# and are zero-based; `.+ 1` converts them to Diff3D's one-based faces.
_audit3_indices(geo) = geo.indices[1:3geo.n_faces]

@testset "audit3 primitive triangulation matches three.js" begin
    # PlaneGeometry.js:85-95 emits (a, b, d), (b, c, d): each cell is split along
    # its (ix, iy+1)-(ix+1, iy) diagonal. The previous (a, d, b), (a, c, d)
    # split used the other diagonal, which changes a displaced plane's surface.
    # new THREE.PlaneGeometry(1, 1, 2, 1).index
    @test _audit3_indices(PlaneGeometry(width=1, height=1, width_segments=2,
                                        height_segments=1)) ==
          [0, 3, 1, 3, 4, 1, 1, 4, 2, 4, 5, 2] .+ 1

    # RingGeometry.js:108-124, new THREE.RingGeometry(0.5, 1, 3, 2).index
    @test _audit3_indices(RingGeometry(inner_radius=0.5, outer_radius=1.0,
                                       theta_segments=3, phi_segments=2)) ==
          [0, 4, 1, 4, 5, 1, 1, 5, 2, 5, 6, 2, 2, 6, 3, 6, 7, 3,
           4, 8, 5, 8, 9, 5, 5, 9, 6, 9, 10, 6, 6, 10, 7, 10, 11, 7] .+ 1

    # CylinderGeometry.js:156-178 (columns outermost, (a, b, d), (b, c, d)),
    # new THREE.CylinderGeometry(1, 1, 1, 3, 2).index[0:36]
    cyl = CylinderGeometry(radius_top=1.0, radius_bottom=1.0, height=1.0,
                           radial_segments=3, height_segments=2)
    @test _audit3_indices(cyl)[1:36] ==
          [0, 4, 1, 4, 5, 1, 4, 8, 5, 8, 9, 5, 1, 5, 2, 5, 6, 2,
           5, 9, 6, 9, 10, 6, 2, 6, 3, 6, 7, 3, 6, 10, 7, 10, 11, 7] .+ 1
    # CylinderGeometry.js:272-287 caps: (i, i + 1, c) on top and (i + 1, i, c)
    # at the bottom. Diff3D shares one center per cap (documented in
    # compatibility.md), so the top center is vertex 12 and its ring 13:16.
    @test _audit3_indices(cyl)[37:54] ==
          [13, 14, 12, 14, 15, 12, 15, 16, 12,
           19, 18, 17, 20, 19, 17, 21, 20, 17] .+ 1

    # new THREE.ConeGeometry(1, 1, 3, 2, true).index: the apex row keeps only
    # (b, c, d) (CylinderGeometry.js:169-176).
    @test _audit3_indices(ConeGeometry(radius=1.0, height=1.0, radial_segments=3,
                                       height_segments=2, open_ended=true)) ==
          [4, 5, 1, 4, 8, 5, 8, 9, 5, 5, 6, 2, 5, 9, 6, 9, 10, 6,
           6, 7, 3, 6, 10, 7, 10, 11, 7] .+ 1

    # SphereGeometry.js:134-140, new THREE.SphereGeometry(1, 3, 3).index
    @test _audit3_indices(SphereGeometry(radius=1.0, width_segments=3,
                                         height_segments=3)) ==
          [0, 4, 5, 1, 5, 6, 2, 6, 7, 5, 4, 9, 4, 8, 9, 6, 5, 10, 5, 9, 10,
           7, 6, 11, 6, 10, 11, 9, 8, 13, 10, 9, 14, 11, 10, 15] .+ 1

    # TorusGeometry.js:113-121, new THREE.TorusGeometry(1, 0.4, 2, 3).index
    @test _audit3_indices(TorusGeometry(radius=1.0, tube=0.4, radial_segments=2,
                                        tubular_segments=3)) ==
          [4, 0, 5, 0, 1, 5, 5, 1, 6, 1, 2, 6, 6, 2, 7, 2, 3, 7,
           8, 4, 9, 4, 5, 9, 9, 5, 10, 5, 6, 10, 10, 6, 11, 6, 7, 11] .+ 1

    # CircleGeometry.js:101-103, new THREE.CircleGeometry(1, 3).index
    @test _audit3_indices(CircleGeometry(radius=1.0, segments=3)) ==
          [1, 2, 0, 2, 3, 0, 3, 4, 0] .+ 1
end

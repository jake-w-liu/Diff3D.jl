using Test, Diff3D

# Round-2 render-parity regressions. Oracle numbers come from three.js r186
# (0.186.0) executed under Node; each expectation cites the three.js source.

# Tetrahedron with explicit positions and index, shared verbatim with the
# three.js oracle scripts so face indices compare one to one.
function _rp_tetra()
    positions = [0.0, 0.0, 1.0, 1.0, 0.0, -0.5, -0.6, 0.8, -0.5, -0.6, -0.8, -0.5]
    indices = [1, 2, 3, 1, 3, 4, 1, 4, 2, 2, 4, 3]
    return BufferGeometry(positions, Float64[], Float64[], indices, 4, 4)
end

_rp_close(a::Vec3, b::Vec3; rtol) =
    isapprox(a.x, b.x; rtol=rtol) && isapprox(a.y, b.y; rtol=rtol) &&
    isapprox(a.z, b.z; rtol=rtol)

# Exact (256-bit) ray/triangle distance for face `face` of `mesh` under its
# world matrix: the analytic truth the Float64 raycasts are measured against.
function _rp_exact_distance(world::Mat4, geo::BufferGeometry, face::Int,
                            origin::Vec3, direction::Vec3)
    setprecision(BigFloat, 256) do
        e = BigFloat.(collect(world.e))
        transform(p) = (x = BigFloat(p.x); y = BigFloat(p.y); z = BigFloat(p.z);
                        [e[1] * x + e[5] * y + e[9] * z + e[13],
                         e[2] * x + e[6] * y + e[10] * z + e[14],
                         e[3] * x + e[7] * y + e[11] * z + e[15]])
        i1, i2, i3 = Diff3D.get_face(geo, face)
        a = transform(Diff3D.get_vertex(geo, i1))
        b = transform(Diff3D.get_vertex(geo, i2))
        c = transform(Diff3D.get_vertex(geo, i3))
        o = BigFloat[origin.x, origin.y, origin.z]
        d = BigFloat[direction.x, direction.y, direction.z]
        cross3(u, v) = [u[2] * v[3] - u[3] * v[2], u[3] * v[1] - u[1] * v[3],
                        u[1] * v[2] - u[2] * v[1]]
        e1 = b - a; e2 = c - a
        p = cross3(d, e2)
        q = cross3(o - a, e1)
        t = sum(e2 .* q) / sum(e1 .* p)
        return Float64(t * sqrt(sum(d .* d)))
    end
end

# Mesh at a 1e6 translation with negative non-uniform scale and a rotation,
# posed exactly like the three.js oracle object.
function _rp_far_mesh(side::Symbol=:double)
    mesh = Mesh(_rp_tetra(), MeshBasicMaterial(side=side))
    mesh.position = Vec3(1.0e6, -2.0e6, 3.0e6)
    mesh.scale = Vec3(-1.5, 0.75, 2.0)
    mesh.rotation = Euler(0.3, -0.7, 1.1)
    return mesh
end

const _RP_FAR_ORIGIN = Vec3(1000002.0, -2000001.0, 3000006.0)
const _RP_FAR_DIRECTION = Vec3(-0.2822162605150792, 0.18814417367671948,
                               -0.9407208683835974)

@testset "render-parity: mesh raycasts intersect in object space" begin
    # three.js Mesh.raycast (src/objects/Mesh.js) maps the ray through
    # matrixWorld⁻¹, intersects local triangles with Ray.intersectTriangle and
    # measures the distance of the world-space hit point.
    mesh = _rp_far_mesh()
    world = compute_world_matrix(mesh)
    # The pose matches the oracle's matrixWorld (Object3D.updateMatrix).
    oracle_world = (-0.5203941744823484, -1.1475713675632286, -0.8137996433483468, 0.0,
                    -0.5112247399450671, 0.45225329907016054, -0.3108314957468989, 0.0,
                    -1.288435374475382, -0.45205264249924604, 1.4613632998710249, 0.0,
                    1.0e6, -2.0e6, 3.0e6, 1.0)
    @test all(isapprox.(world.e, oracle_world; atol=1e-15))
    rc = Raycaster(_RP_FAR_ORIGIN, _RP_FAR_DIRECTION)
    hits = raycast(rc, mesh)
    # Oracle: faceIndex 2 at 5.897266418978597 and faceIndex 0 at 6.83967100295149.
    @test [h.face_index for h in hits] == [3, 1]
    @test isapprox(hits[1].distance, 5.897266418978597; rtol=1e-8)
    @test isapprox(hits[2].distance, 6.83967100295149; rtol=1e-8)
    @test _rp_close(hits[1].point, Vec3(1000000.3356955242, -1999999.8904636826,
                                        3000000.452318413); rtol=1e-12)
    # Subtracting the translation before the inverse linear map and measuring
    # the world step M·(ld t) keeps the distance within a few ulps of the exact
    # value, independent of the 1e6 translation.
    for h in hits
        exact = _rp_exact_distance(world, mesh.geometry, h.face_index,
                                   rc.ray.origin, rc.ray.direction)
        @test abs(h.distance - exact) <= 1e-14 * exact
    end
    # Instances take the same path (three.js InstancedMesh.raycast composes
    # matrixWorld · instanceMatrix and reuses Mesh.raycast); oracle instanceId 1.
    instanced = InstancedMesh(_rp_tetra(), MeshBasicMaterial(side=:double),
                              [mat4_translation(50.0, 0.0, 0.0), world])
    instance_hits = raycast(rc, instanced)
    @test [(h.face_index, h.instance_id) for h in instance_hits] == [(3, 2), (1, 2)]
    @test isapprox(instance_hits[1].distance, 5.8972664037123; rtol=1e-8)
    @test isapprox(instance_hits[2].distance, 6.839671018327301; rtol=1e-8)
end

@testset "render-parity: grazing corner and shared-edge rays are watertight" begin
    # mathapi_audit.jl:145 — the direction (0.6, 0, -0.8) passes 3e-16 inside
    # the corner in local space. three.js r186 Ray.intersectTriangle (watertight,
    # inclusive edges) with this exact direction reports faceIndex 8 at 5 and
    # faceIndex 0 at 5.000000000000001 for the box at (1e6, -2e6, 3).
    corner = Mesh(BoxGeometry(), MeshBasicMaterial(side=:double))
    corner.position = Vec3(1.0e6, -2.0e6, 3.0)
    corner_point = Vec3(1.0e6 + 0.5, -2.0e6 + 0.5, 3.5)
    graze = Raycaster(corner_point + Vec3(-3.0, 0.0, 4.0), Vec3(3.0, 0.0, -4.0))
    hits = raycast(graze, corner)
    @test [h.distance for h in hits] == [5.0, 5.000000000000001]
    @test hits[1].point == Vec3(1000000.5, -1999999.5, 3.5)
    # A ray down the shared diagonal of PlaneGeometry's two triangles hits;
    # the oracle reports faceIndex 1 at distance 3 (Ray.intersectTriangle
    # accepts the zero edge function of the shared edge).
    plane = Mesh(PlaneGeometry(width=2.0, height=2.0), MeshBasicMaterial(side=:double))
    diagonal = raycast(Raycaster(Vec3(0.3, -0.3, 3.0), Vec3(0.0, 0.0, -1.0)), plane)
    @test !isempty(diagonal)
    @test all(h -> h.distance == 3.0 && h.point == Vec3(0.3, -0.3, 0.0), diagonal)
end

@testset "render-parity: raycast acceptance follows three.js Ray.intersectTriangle" begin
    # A ray starting on the surface is a hit at distance 0: intersectTriangle
    # rejects only t < 0 (oracle: faceIndex 1, distance 0).
    plane = Mesh(PlaneGeometry(width=2.0, height=2.0), MeshBasicMaterial(side=:double))
    on_surface = raycast(Raycaster(Vec3(0.25, 0.1, 0.0), Vec3(0.0, 0.0, -1.0)), plane)
    @test !isempty(on_surface) && on_surface[1].distance == 0.0
    @test on_surface[1].point == Vec3(0.25, 0.1, 0.0)
    # Side culling happens in local space, so a mirrored mesh culls by its
    # authored winding (oracle: front side faceIndex 1 at 4.125, back side
    # faceIndex 3 at 5.5).
    front = Mesh(_rp_tetra(), MeshBasicMaterial(side=:front)); front.scale = Vec3(-1.0, 1.0, 1.0)
    back = Mesh(_rp_tetra(), MeshBasicMaterial(side=:back)); back.scale = Vec3(-1.0, 1.0, 1.0)
    ray = Raycaster(Vec3(0.05, 0.02, 5.0), Vec3(0.0, 0.0, -1.0))
    front_hits = raycast(ray, front)
    back_hits = raycast(ray, back)
    @test [(h.face_index, h.distance) for h in front_hits] == [(2, 4.125)]
    @test front_hits[1].point == Vec3(0.05, 0.02, 0.875)
    @test [(h.face_index, h.distance) for h in back_hits] == [(4, 5.5)]
    # A singular world matrix inverts to zero in three.js (Matrix4.invert), so
    # the local ray has no direction and nothing is hit (oracle: []).
    flat = Mesh(_rp_tetra(), MeshBasicMaterial(side=:double)); flat.scale = Vec3(1.0, 0.0, 1.0)
    @test isempty(raycast(Raycaster(Vec3(0.05, 5.0, 0.02), Vec3(0.0, -1.0, 0.0)), flat))
end

@testset "render-parity: tiny-scale meshes stay pickable" begin
    # A unit box scaled by 1e-200 seen from z = 1e-199: the ray meets the front
    # face z = 0.5e-200 at the analytic distance 1e-199 - 0.5e-200. (three.js
    # itself misses here only because Sphere.applyMatrix4 squares the radius
    # into underflow; no absolute ray-parameter cutoff is involved.)
    box = Mesh(BoxGeometry(), MeshBasicMaterial())
    box.scale = Vec3(1.0e-200, 1.0e-200, 1.0e-200)
    hits = raycast(Raycaster(Vec3(0.0, 0.0, 1.0e-199), Vec3(0.0, 0.0, -1.0)), box)
    @test length(hits) == 2
    @test isapprox(hits[1].distance, 0.95e-199; rtol=1e-14)
    @test _rp_close(hits[1].point, Vec3(0.0, 0.0, 0.5e-200); rtol=1e-14)
    @test _rp_close(hits[1].face_normal, Vec3(0.0, 0.0, 1.0); rtol=1e-14)
end

@testset "render-parity: mirrored SkinnedMesh keeps its front faces" begin
    # three.js sets frontFaceCW from object.matrixWorld.determinant() < 0 for
    # every mesh, skinned ones included (WebGLRenderer.js renderBufferDirect →
    # WebGLState.setMaterial(material, frontFaceCW)), so a skin under a
    # mirroring parent renders exactly like the same mirrored plain mesh.
    camera = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=100.0)
    camera.position = Vec3(0.0, 0.0, 4.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    for mirror in (Vec3(-1.0, 1.0, 1.0), Vec3(-1.0, -1.0, 1.0))
        geometry = BoxGeometry()
        n = geometry.n_vertices
        bone = Bone()
        skin = SkinnedMesh(geometry, MeshNormalMaterial(), Skeleton([bone], [Mat4()]),
                           fill((1, 1, 1, 1), n), fill((1.0, 0.0, 0.0, 0.0), n))
        holder = Group(); holder.scale = mirror; holder.rotation = Euler(0.4, 0.7, 0.0)
        add!(holder, skin); add!(holder, bone)
        skinned_scene = Scene(); add!(skinned_scene, holder)
        plain_holder = Group(); plain_holder.scale = mirror
        plain_holder.rotation = Euler(0.4, 0.7, 0.0)
        add!(plain_holder, Mesh(BoxGeometry(), MeshNormalMaterial()))
        plain_scene = Scene(); add!(plain_scene, plain_holder)
        renders = ((t, s) -> render!(t, s, camera),
                   (t, s) -> render!(t, s, camera; cache=RenderCache()),
                   (t, s) -> render_msaa!(t, s, camera),
                   (t, s) -> render_pooled!(t, s, camera, RenderCache()),
                   (t, s) -> render_tiled!(t, s, camera; tiles=1, cache=[RenderCache()]))
        for draw in renders
            skinned_target = RenderTarget(24, 24)
            plain_target = RenderTarget(24, 24)
            draw(skinned_target, skinned_scene)
            draw(plain_target, plain_scene)
            @test count(>(0.05), plain_target.color) > 100
            @test skinned_target.color == plain_target.color
        end
        # The proxy's reflected storage is internal: the source geometry and the
        # world-space pose stay untouched.
        @test geometry.positions == BoxGeometry().positions
    end
end

# Orthographic camera far down +z: the view direction at the sampled pixel is
# within 1e-4 of the plane normal, so N·V = 1 to ~1e-9.
function _rp_far_ortho_camera()
    camera = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=1.0, far=2000.0)
    camera.position = Vec3(0.0, 0.0, 1000.0)
    return camera
end

@testset "render-parity: emission sits under the clearcoat layer" begin
    # meshphysical.glsl.js: outgoingLight = totalDiffuse + totalSpecular +
    # totalEmissiveRadiance, then outgoingLight · (1 - clearcoat · Fcc) with
    # Fcc = F_Schlick(0.04, 1, N·V) (bsdfs.glsl.js: f0 (1 - w) + f90 w,
    # w = exp2((-5.55473 N·V - 6.98316) N·V)). Head-on with no lights the pixel
    # is emissive · (1 - clearcoat · Fcc(1)).
    emissive = Color3(0.5, 0.25, 0.125)
    white = Texture(fill(1.0, 4, 4, 3))
    for clearcoat in (0.0, 1.0, 0.5), emissive_map in (nothing, white),
        shading in (:flat, :smooth)
        material = MeshPhysicalMaterial(color=Color3(0.0, 0.0, 0.0), clearcoat=clearcoat,
                                        emissive=emissive, emissive_map=emissive_map)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(PlaneGeometry(width=1.0, height=1.0), material))
        target = RenderTarget(16, 16)
        render!(target, scene, _rp_far_ortho_camera(); shading=shading)
        w = exp2(-5.55473 - 6.98316)
        layer = 1 - clearcoat * (0.04 * (1 - w) + w)
        @test target.color[8, 8, :] ≈ [0.5, 0.25, 0.125] .* layer atol=1e-9
    end
end

# A constant tangent-space normal map tilting the normal by (nx, ny).
function _rp_tilt_map(nx, ny)
    data = zeros(4, 4, 3)
    data[:, :, 1] .= nx / 2 + 0.5
    data[:, :, 2] .= ny / 2 + 0.5
    data[:, :, 3] .= sqrt(1 - nx^2 - ny^2) / 2 + 0.5
    return Texture(data)
end

@testset "render-parity: clearcoat lobe uses clearcoatNormal" begin
    # clearcoat_normal_fragment_begin.glsl.js: clearcoatNormal = nonPerturbedNormal,
    # replaced by the clearcoatNormalMap normal (clearcoat_normal_fragment_maps);
    # RE_Direct_Physical evaluates BRDF_GGX_Clearcoat and the layering Fcc on it.
    # A black base with zero specular intensity isolates the clearcoat lobe, so
    # the base normalMap must not change the image while the clearcoat normal
    # map must.
    camera = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=100.0)
    camera.position = Vec3(0.2, -0.1, 3.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    light = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0)
    light.position = Vec3(0.3, 0.2, 1.0)
    base_map = _rp_tilt_map(0.4, 0.1)
    coat_map = _rp_tilt_map(0.3, -0.2)
    function coat_image(normal_map, clearcoat_normal_map, shading)
        material = MeshPhysicalMaterial(color=Color3(0.0, 0.0, 0.0), roughness=0.5,
                                        clearcoat=1.0, clearcoat_roughness=0.3,
                                        specular_intensity=0.0, normal_map=normal_map,
                                        clearcoat_normal_map=clearcoat_normal_map)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(PlaneGeometry(width=1.0, height=1.0), material))
        add!(scene, light)
        target = RenderTarget(16, 16)
        render!(target, scene, camera; shading=shading)
        return target.color
    end
    for shading in (:flat, :smooth)
        plain = coat_image(nothing, nothing, shading)
        @test maximum(plain) > 0.01
        @test coat_image(base_map, nothing, shading) == plain
        coated = coat_image(nothing, coat_map, shading)
        @test maximum(abs.(coated .- plain)) > 0.005
        @test coat_image(base_map, coat_map, shading) == coated
    end
end

@testset "render-parity: coplanar surfaces resolve like LessEqual depth" begin
    # three.js Material.depthFunc defaults to LessEqualDepth (Material.js:211)
    # for every material, so of two surfaces at an identical depth the one
    # drawn later stays visible. Two identical coplanar planes: painterSortStable
    # (WebGLRenderLists.js:1-29) draws the one-material-each meshes in creation
    # order, so the second (green) wins; with sortObjects = false the scene
    # order gives the same answer.
    camera = PerspectiveCamera()
    camera.position = Vec3(0.3, 0.2, 4.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    geometry = PlaneGeometry(width=3.0, height=3.0)
    scene = Scene()
    for color in (Color3(1.0, 0.0, 0.0), Color3(0.0, 1.0, 0.0))
        plane = Mesh(geometry, MeshBasicMaterial(color=color))
        plane.rotation = Euler(-0.7, 0.4, 0.0)
        add!(scene, plane)
    end
    draws = ((t, s) -> render!(t, s, camera),
             (t, s) -> render!(t, s, camera; sort_objects=false),
             (t, s) -> render!(t, s, camera; shading=:smooth, cache=RenderCache()),
             (t, s) -> render_msaa!(t, s, camera),
             (t, s) -> render_pooled!(t, s, camera, RenderCache()),
             (t, s) -> render_tiled!(t, s, camera; tiles=2, cache=[RenderCache(), RenderCache()]))
    for draw in draws, T in (Float64, Float32)
        target = RenderTarget(48, 48; T=T)
        draw(target, scene)
        @test count(>(0.5), target.color[:, :, 2]) > 1000
        @test count(>(0.1), target.color[:, :, 1]) == 0
    end
end

@testset "render-parity: lines, points and sprites share the mesh depth test" begin
    # Lines, points and sprites are depth-tested like meshes in three.js: the
    # fragment depth quantized to the depth-buffer format, compared with
    # LessEqual (Material.js:211). Under an orthographic camera a plane facing
    # it has one depth everywhere, and a line, a point and a sprite lying in
    # it and drawn after it quantize to that same Float32 depth, so they stay
    # fully visible at every depth. (Float64 targets are not asserted: the
    # line and triangle depth interpolations round differently there, as the
    # GPU paths do, so coplanar primitives may z-fight.)
    camera = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=0.1, far=10.0)
    camera.position = Vec3(0.0, 0.0, 5.0)
    function primitive_counts(depth, with_plane)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        if with_plane
            plane = Mesh(PlaneGeometry(width=2.0, height=2.0),
                         MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0)))
            plane.position = Vec3(0.0, 0.0, depth)
            add!(scene, plane)
        end
        segment = BufferGeometry([-0.8, 0.1, depth, 0.8, 0.1, depth],
                                 Float64[], Float64[], Int[], 2, 0)
        add!(scene, LineSegments(segment, LineBasicMaterial(color=Color3(0.0, 1.0, 0.0))))
        point = BufferGeometry([0.3, -0.4, depth], Float64[], Float64[], Int[], 1, 0)
        add!(scene, PointsObject(point, PointsMaterial(color=Color3(0.0, 0.0, 1.0),
                                                        size=3.0)))
        sprite = Sprite(SpriteMaterial(color=Color3(1.0, 1.0, 1.0)))
        sprite.position = Vec3(-0.5, -0.5, depth)
        sprite.scale = Vec3(0.25, 0.25, 1.0)
        add!(scene, sprite)
        target = RenderTarget(32, 32; T=Float32)
        render!(target, scene, camera)
        white = count(i -> target.color[i[1], i[2], 1] > 0.5 &&
                           target.color[i[1], i[2], 3] > 0.5, CartesianIndices((32, 32)))
        return (count(>(0.5), target.color[:, :, 2]) - white,
                count(>(0.5), target.color[:, :, 3]) - white, white)
    end
    for depth in (0.0, -0.37, -1.1, -2.3, 0.9, 1.7)
        alone = primitive_counts(depth, false)
        @test all(>(0), alone)
        @test primitive_counts(depth, true) == alone
    end
end

@testset "render-parity: line raycasts report three.js draw indices" begin
    # Vertices on the x axis at x = 0, 1, 2, 3; a ray down -z at x = xr passes
    # 0.05 from the axis (threshold 0.1). Expected entries are three.js
    # `index + 1` (Line.js raycast/checkIntersection: `index: i`, the draw
    # entry, and `end - 1` for a LineLoop's closing segment, tested for any
    # non-empty range); every hit is at distance 5 on the segment.
    positions = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 2.0, 0.0, 0.0, 3.0, 0.0, 0.0]
    function line_geometry(indices, range)
        geometry = BufferGeometry(copy(positions), Float64[], Float64[],
                                  indices === nothing ? Int[] : indices, 4, 0)
        range === nothing || set_draw_range!(geometry, range...)
        return geometry
    end
    material = LineBasicMaterial()
    # (constructor, 1-based indices, 1-based draw range, ray x, oracle indices + 1)
    cases = ((LineObject, [4, 3, 2, 1], nothing, 2.5, [1]),
             (LineSegments, [4, 3, 2, 1], nothing, 0.5, [3]),
             (LineLoop, [2, 4, 3], nothing, 1.5, [1, 3]),
             (LineObject, nothing, (2, 2), 1.5, [2]),
             (LineObject, nothing, (2, 2), 0.5, Int[]),
             (LineObject, [4, 3, 2, 1], (2, 2), 1.5, [2]),
             (LineSegments, nothing, (2, 3), 1.5, [2]),
             (LineSegments, nothing, (2, 3), 2.5, Int[]),
             (LineLoop, nothing, (1, 2), 0.5, [1, 2]),
             (LineLoop, nothing, (3, 1), 2.0, [3]),
             (LineLoop, nothing, (2, 3), 2.0, [2, 3, 4]),
             (LineLoop, nothing, (2, 3), 1.5, [2, 4]),
             (LineLoop, [1, 4, 2, 3], (2, 3), 2.0, [2, 3, 4]))
    for (constructor, indices, range, x, expected) in cases
        line = constructor(line_geometry(indices, range), material)
        rc = Raycaster(Vec3(x, 0.05, 5.0), Vec3(0.0, 0.0, -1.0); line_threshold=0.1)
        hits = raycast(rc, line)
        @test sort([h.face_index for h in hits]) == expected
        @test all(h -> h.distance == 5.0 && h.point.z == 0.0 && h.point.y == 0.0, hits)
    end
    # Points report the vertex index (Points.js testPoint `index: a`).
    points = PointsObject(line_geometry([4, 2], nothing), PointsMaterial())
    rc = Raycaster(Vec3(1.0, 0.05, 5.0), Vec3(0.0, 0.0, -1.0); point_threshold=0.1)
    @test [h.face_index for h in raycast(rc, points)] == [2]
end

@testset "render-parity: orthographic picking starts in the camera plane" begin
    # three.js Raycaster.setFromCamera (src/core/Raycaster.js:129) unprojects
    # NDC z = projectionMatrix.elements[14] (the camera plane), so a surface
    # between the camera and its near plane is picked and distances start at
    # the camera. Oracle: three.js r186, same camera, NDC (0.25, -0.4), a
    # double-sided plane 0.2 in front of the camera (near = 0.5).
    camera = OrthographicCamera(left=-2.0, right=2.0, top=1.0, bottom=-1.0,
                                near=0.5, far=100.0)
    camera.position = Vec3(1.0, 2.0, 5.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    rc = Raycaster(Vec3(), Vec3(0.0, 0.0, -1.0))
    set_from_camera!(rc, camera, 0.25, -0.4)
    @test _rp_close(rc.ray.origin,
                    Vec3(1.5189349328070374, 1.627620265499495, 5.045164907238795); rtol=1e-14)
    @test _rp_close(rc.ray.direction,
                    Vec3(-0.18257418583505536, -0.3651483716701107, -0.9128709291752769); rtol=1e-14)
    forward = normalize(camera.target - camera.position)
    plane = Mesh(PlaneGeometry(width=10.0, height=10.0), MeshBasicMaterial(side=:double))
    plane.position = camera.position + forward * 0.2
    plane.rotation = euler_from_quaternion(Quaternion(-0.18490565855618127, 0.09682165484160256,
                                                      0.01830926837078661, 0.9778037815836903))
    hits = raycast(rc, plane)
    @test length(hits) == 1
    @test isapprox(hits[1].distance, 0.20000000000000026; rtol=1e-12)
    @test _rp_close(hits[1].point,
                    Vec3(1.4824200956400264, 1.5545905911654725, 4.862590721403739); rtol=1e-12)
end

@testset "render-parity: oblique emission layering ignores the base normalMap" begin
    # meshphysical.glsl.js computes Fcc from dot(geometryClearcoatNormal, V),
    # and clearcoatNormal is nonPerturbedNormal unless a clearcoatNormalMap is
    # set (clearcoat_normal_fragment_begin.glsl.js), so a base normalMap must
    # not move the layering of the emission. With no lights and a black base
    # the pixel is emissive · (1 - clearcoat · Fcc(N·V)) at an oblique N·V.
    angle = 1.0
    camera = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=1.0, far=2.0e5)
    # Far away, so the view direction of every fragment and face centre is
    # within 1e-5 rad of the camera axis.
    camera.position = Vec3(1.0e5 * sin(angle), 0.0, 1.0e5 * cos(angle))
    camera.target = Vec3(0.0, 0.0, 0.0)
    nv = cos(angle)
    w = exp2((-5.55473 * nv - 6.98316) * nv)
    for normal_map in (nothing, _rp_tilt_map(0.4, 0.1)), shading in (:flat, :smooth),
        clearcoat in (1.0, 0.5)
        material = MeshPhysicalMaterial(color=Color3(0.0, 0.0, 0.0), clearcoat=clearcoat,
                                        emissive=Color3(0.5, 0.25, 0.125),
                                        normal_map=normal_map)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(PlaneGeometry(width=1.5, height=1.5), material))
        target = RenderTarget(16, 16)
        render!(target, scene, camera; shading=shading)
        layer = 1 - clearcoat * (0.04 * (1 - w) + w)
        @test target.color[8, 8, :] ≈ [0.5, 0.25, 0.125] .* layer atol=1e-6
    end
end

@testset "render-parity: WebGL export depth-tests with LessEqual" begin
    # The CPU renderers' LessEqual depth test is three.js's per-material
    # default (Material.js:211, set per draw by WebGLState.setMaterial); the
    # standalone WebGL viewer uses the same function rather than GL's LESS.
    scene = Scene()
    add!(scene, Mesh(PlaneGeometry(), MeshBasicMaterial()))
    path = tempname() * ".html"
    try
        save_webgl_html(path, [WebGLExportCase("plane", "Plane", "", scene)];
                        chrome=false)
        html = read(path, String)
        @test occursin("gl.depthFunc(gl.LEQUAL)", html)
        @test !occursin("gl.depthFunc(gl.LESS)", html)
    finally
        rm(path; force=true)
    end
end

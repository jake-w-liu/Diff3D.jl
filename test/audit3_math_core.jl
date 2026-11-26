using Test, Diff3D

# Regression tests for the audit-3 math-core pass. Expected values are taken
# from three.js r186 (0.186.0) executed under node, or derived analytically as
# noted next to each expectation.

_audit3_quat_vector(q::Quaternion) = (q.x, q.y, q.z, q.w)
_audit3_vec_vector(v::Vec3) = (v.x, v.y, v.z)

@testset "audit3 math-core: mat4_decompose ignores the projective bottom row" begin
    # three.js Matrix4.decompose (src/math/Matrix4.js:1079) uses
    # determinantAffine(), the upper-left 3x3 determinant, for both the
    # singular test and the sign of the x scale.
    base = (1.7201786764100944, 0.8129782701723722, 0.616483295354832, 0.0,
            -1.409606840848546, 2.5996023039544527, 0.5050509038777022, 0.0,
            -0.7946773231802449, -1.1585179105020622, 3.745173454336797, 0.0,
            1.0, 2.0, 3.0, 1.0)
    # node: new Matrix4().fromArray(m).decompose(p, q, s) for both matrices
    # returns p=(1,2,3), q=(0.11964726626912242, -0.13243054739079688,
    # 0.22894864274603222, 0.9569374069273545), s=(2,3,4).
    expected_q = (0.11964726626912242, -0.13243054739079688,
                  0.22894864274603222, 0.9569374069273545)
    negative_w = Mat4(Base.setindex(base, -1.0, 16))
    projective = Mat4(Base.setindex(Base.setindex(base, 0.5, 4), 0.0, 16))
    for m in (negative_w, projective)
        p, q, s = mat4_decompose(m)
        @test _audit3_vec_vector(p) == (1.0, 2.0, 3.0)
        @test all(isapprox.(_audit3_quat_vector(q), expected_q; atol=4eps()))
        @test all(isapprox.(_audit3_vec_vector(s), (2.0, 3.0, 4.0); atol=8eps()))
    end
    # A zero bottom-right entry alone does not make the affine part singular.
    _, _, s = mat4_decompose(Mat4(Base.setindex(base, 0.0, 16)))
    @test all(isapprox.(_audit3_vec_vector(s), (2.0, 3.0, 4.0); atol=8eps()))
end

@testset "audit3 math-core: look-at perturbs only exactly parallel up vectors" begin
    # three.js Matrix4.lookAt (src/math/Matrix4.js:500) perturbs z only when
    # up × z has zero length. node: camera.position=(1e-7,4,0);
    # camera.lookAt(0,0,0); camera.matrixWorldInverse.elements[0,4,8] is the
    # world right axis (0, 0, -1).
    view = mat4_look_at(Vec3(1.0e-7, 4.0, 0.0), Vec3(0.0, 0.0, 0.0),
                        Vec3(0.0, 1.0, 0.0))
    @test all(isapprox.((view.e[1], view.e[5], view.e[9]), (0.0, 0.0, -1.0);
                        atol=1e-12))
    @test all(isapprox.((view.e[2], view.e[6], view.e[10]),
                        (-0.9999999999999996, 2.5000000014596673e-8, 0.0);
                        atol=1e-12))

    # OrbitControls clamps the polar angle to 1e-6 (three.js Spherical.makeSafe),
    # so the camera keeps its azimuth at the pole. node: Object3D at
    # setFromSphericalCoords(5, 1e-6, 0.3) looking at the origin gives the right
    # axis (cos 0.3, 0, -sin 0.3) = (0.955336489125606, 2.5e-17, -0.29552020666133955).
    camera = PerspectiveCamera()
    controls = OrbitControls(camera, Vec3(0.0, 0.0, 0.0))
    orbit_set!(controls; azimuth=0.3, polar=0.0, radius=5.0)
    orbit_view = view_matrix(camera)
    @test all(isapprox.((orbit_view.e[1], orbit_view.e[5], orbit_view.e[9]),
                        (0.955336489125606, 2.5279274794330966e-17,
                         -0.29552020666133955); atol=1e-12))

    # Exactly parallel inputs keep three.js's 1e-4 perturbation of z.
    # node: lookAt from (0,5,0) with up (0,1,0) -> elements[5,6,9,10] =
    # (9.999999949994454e-5, 0.999999995, -0.999999995, 9.999999949994454e-5);
    # from (0,0,5) with up (0,0,1) -> elements[1,2,9,10] =
    # (-0.999999995, 9.99999995e-5, 9.99999995e-5, 0.999999995).
    top = mat4_look_at(Vec3(0.0, 5.0, 0.0), Vec3(0.0, 0.0, 0.0),
                       Vec3(0.0, 1.0, 0.0))
    @test all(isapprox.((top.e[6], top.e[7], top.e[10], top.e[11]),
                        (9.999999949994454e-5, 0.999999995, -0.999999995,
                         9.999999949994454e-5); atol=1e-12))
    z_up = mat4_look_at(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, 0.0),
                        Vec3(0.0, 0.0, 1.0))
    @test all(isapprox.((z_up.e[2], z_up.e[3], z_up.e[10], z_up.e[11]),
                        (-0.999999995, 9.99999995e-5, 9.99999995e-5,
                         0.999999995); atol=1e-12))
end

@testset "audit3 math-core: look-at and normalize keep a concrete element type" begin
    # The exactly-parallel perturbation and the degenerate defaults must return
    # the same element type as the ordinary branch.
    for T in (Float32, Float64, BigFloat)
        origin = Vec3(zero(T), zero(T), zero(T))
        y_up = Vec3(zero(T), one(T), zero(T))
        top = @inferred mat4_look_at(Vec3(zero(T), T(5), zero(T)), origin, y_up)
        @test top isa Mat4{T}
        # Same perturbation as three.js (src/math/Matrix4.js:510): z.z += 1e-4.
        @test isapprox(top.e[7], one(T); rtol=1e-6)
        @test isapprox(top.e[11], T(1e-4); rtol=1e-6)
        @test (@inferred mat4_look_at(origin, origin, y_up)) isa Mat4{T}
        @test _audit3_vec_vector(@inferred normalize(origin)) == (zero(T), zero(T), zero(T))
    end
    # Integer input promotes to Float64 on every branch.
    @test (@inferred normalize(Vec3(0, 0, 0))) === Vec3(0.0, 0.0, 0.0)
    @test (@inferred normalize(Vec3(0, 3, 4))) === Vec3(0.0, 0.6, 0.8)
    @test (@inferred mat4_look_at(Vec3(0, 0, 5), Vec3(0, 0, 0), Vec3(0, 1, 0))) ==
          mat4_look_at(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    @test (@inferred mat4_look_at(Vec3(1, 2, 3), Vec3(1, 2, 3), Vec3(0, 1, 0))) ==
          mat4_look_at(Vec3(1.0, 2.0, 3.0), Vec3(1.0, 2.0, 3.0), Vec3(0.0, 1.0, 0.0))
end

function _audit3_view_allocations(camera)
    view_matrix(camera)
    return @allocated view_matrix(camera)
end

@testset "audit3 math-core: parented camera views do not allocate" begin
    for Camera in (PerspectiveCamera, OrthographicCamera),
        rotation_driven in (false, true), ignore_parent_scale in (false, true),
        Parent in (Group, Object3D, Bone)
        root = Group()
        root.rotation = Euler(0.3, -0.2, 0.1)
        parent = Parent()
        parent.position = Vec3(1.0, -2.0, 0.5)
        parent.rotation = Euler(0.1, 0.2, 0.3, :ZYX)
        parent.scale = Vec3(2.0, 0.5, -1.5)
        add!(root, parent)
        camera = Camera(; rotation_driven)
        camera.ignore_parent_scale = ignore_parent_scale
        camera.rotation = Euler(-0.4, 0.25, 0.05)
        add!(parent, camera)
        view = view_matrix(camera)
        @test view isa Mat4{Float64} && all(isfinite, view.e)
        if Base.JLOptions().opt_level > 0
            # Ancestor world matrices and rotations dispatch statically.
            @test _audit3_view_allocations(camera) == 0
        end
    end
end

@testset "audit3 math-core: math value types promote mixed numeric arguments" begin
    # three.js Cylindrical.setFromCartesianCoords (src/math/Cylindrical.js:91-97):
    # radius = sqrt(x*x + z*z), theta = atan2(x, z), y = y; node prints
    # (3.1622776601683795, 0.3217505543966422, 2) for (1, 2, 3).
    cylindrical = @inferred cartesian_to_cylindrical(Vec3(1, 2, 3))
    @test cylindrical isa Cylindrical{Float64}
    @test (cylindrical.radius, cylindrical.theta, cylindrical.y) ==
          (3.1622776601683795, 0.3217505543966422, 2.0)
    @test (@inferred Cylindrical(1.0, 0.5, 2)) === Cylindrical(1.0, 0.5, 2.0)
    @test (@inferred Spherical(1, 0.5, 0.25)) === Spherical(1.0, 0.5, 0.25)
    @test (@inferred Plane(Vec3(0.0, 1.0, 0.0), 2)) ===
          Plane(Vec3(0.0, 1.0, 0.0), 2.0)
    @test (@inferred BoundingSphere(Vec3(0.0, 0.0, 0.0), 1)) ===
          BoundingSphere(Vec3(0.0, 0.0, 0.0), 1.0)
    @test (@inferred Box3(Vec3(0, 0, 0), Vec3(1.0, 1.0, 1.0))) ===
          Box3(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 1.0, 1.0))
    @test (@inferred Triangle(Vec3(0, 0, 0), Vec3(1.0, 0.0, 0.0), Vec3(0, 1, 0))) ===
          Triangle(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    @test (@inferred Line3(Vec3(0, 0, 0), Vec3(1.0, 0.0, 0.0))) ===
          Line3(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0))
    # Same-type construction keeps its element type.
    @test Box3(Vec3(0, 0, 0), Vec3(1, 1, 1)) isa Box3{Int}
    @test Plane(Vec3(0f0, 1f0, 0f0), 2f0) isa Plane{Float32}
end

@testset "audit3 math-core: degenerate branches keep the general result type" begin
    # Float32 rotations stay Float32 (1/2 and 1/4 are exact in every format).
    rotation32 = quat_to_mat4(Quaternion(0.1f0, 0.2f0, 0.3f0, 0.9f0))
    @test (@inferred quat_from_rotation_matrix(rotation32)) isa Quaternion{Float32}
    position32, quaternion32, scale32 = @inferred mat4_decompose(rotation32)
    @test quaternion32 isa Quaternion{Float32} && scale32 isa Vec3{Float32}
    singular32 = Mat4(ntuple(i -> i in (6, 11, 16) ? 1f0 : 0f0, 16))
    @test (@inferred mat4_decompose(singular32))[2] ===
          Quaternion(0f0, 0f0, 0f0, 1f0)
    # Integer inputs return the floating type on singular and endpoint branches.
    @test (@inferred mat4_decompose(Mat4{Int}()))[2] === Quaternion(0.0, 0.0, 0.0, 1.0)
    @test (@inferred mat4_inverse(Mat4(ntuple(_ -> 0, 16)))) ===
          Mat4(ntuple(_ -> 0.0, 16))
    @test (@inferred quat_normalize(Quaternion(0, 0, 0, 0))) ===
          Quaternion(0.0, 0.0, 0.0, 1.0)
    @test (@inferred lerp(Vec3(1, 2, 3), Vec3(4, 5, 6), 0.0)) === Vec3(1.0, 2.0, 3.0)
    @test (@inferred lerp(Vec3(1, 2, 3), Vec3(4, 5, 6), 1.0)) === Vec3(4.0, 5.0, 6.0)
    segment = Line3(Vec3(0, 0, 0), Vec3(2, 0, 0))
    @test (@inferred line3_closest_point(segment, Vec3(-1, 1, 0))) === Vec3(0.0, 0.0, 0.0)
    @test (@inferred line3_closest_point_parameter(Line3(Vec3(1, 1, 1), Vec3(1, 1, 1)),
                                                   Vec3(0, 0, 0))) === 0.0
    triangle = Triangle(Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 2, 0))
    @test (@inferred triangle_normal(triangle)) === Vec3(0.0, 0.0, 1.0)
    @test (@inferred triangle_area(triangle)) === 2.0
    @test (@inferred triangle_centroid(Triangle(Vec3(0, 0, 0), Vec3(0, 0, 0),
                                               Vec3(0, 0, 0)))) === Vec3(0.0, 0.0, 0.0)
    @test (@inferred triangle_barycentric(triangle, Vec3(1, 1, 0))) ===
          Vec3(0.0, 0.5, 0.5)
end

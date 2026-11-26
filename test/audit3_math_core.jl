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

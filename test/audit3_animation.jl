using Test, Diff3D

# Oracle numbers below come from three.js r186 (0.186.0) evaluated in node with
# Float64Array buffers; file:line references are to that source tree.

_audit3_q(q::Quaternion) = [q.x, q.y, q.z, q.w]

@testset "audit3 animation: smooth interpolation matches three.js CubicInterpolant" begin
    # Non-uniform keys: three.js CubicInterpolant.intervalChanged_/interpolate_
    # (src/math/interpolants/CubicInterpolant.js:38-160) with the default
    # ZeroCurvatureEnding. Expected values printed by node for
    # new CubicInterpolant(times, values, 1).evaluate(t).
    times = [0.0, 0.3, 1.0, 2.5, 2.7]
    values = [0.0, 1.0, -2.0, 4.0, 3.5]
    queries = [-0.5, 0.0, 0.1, 0.3, 0.65, 1.0, 1.7, 2.5, 2.6, 2.7, 3.0]
    expected = [0.0, 0.0, 0.417989417989418, 1.0, -0.529166666666667, -2.0,
                0.541333333333333, 4.0, 3.83125, 3.5, 3.5]
    for (t, e) in zip(queries, expected)
        @test interpolate_catmull_rom(times, values, t) ≈ e atol=1e-14
    end

    # The :cubic keyframe tracks are three.js InterpolateSmooth tracks
    # (KeyframeTrack.InterpolantFactoryMethodSmooth, KeyframeTrack.js:180).
    obj = Group()
    number = NumberKeyframeTrack(obj, "position[y]", times, values; interpolation=:cubic)
    vector = KeyframeTrack(obj, :position, times,
                           [Vec3(v, -v, 2v) for v in values]; interpolation=:cubic)
    for (t, e) in zip(queries, expected)
        @test sample_track(number, t) ≈ e atol=1e-14
        sample = sample_track(vector, t)
        @test sample.x ≈ e atol=1e-14
        @test sample.y ≈ -e atol=1e-14
        @test sample.z ≈ 2e atol=1e-14
    end
    mixer = AnimationMixer(AnimationClip("smooth", AbstractKeyframeTrack[number]; loop=:once))
    mixer_set_time!(mixer, 0.1)
    @test obj.position.y ≈ 0.417989417989418 atol=1e-14

    # Evenly spaced keys keep the uniform Catmull-Rom curve: interior tangents
    # (v[k+1] - v[k-1]) / 2 = 2 and 4 around [1, 2] for keys 0, 1, 4, 9, and
    # the Hermite midpoint is (1 + 4) / 2 + (2 - 4) / 8 = 2.25.
    @test interpolate_catmull_rom([0.0, 1.0, 2.0, 3.0], [0.0, 1.0, 4.0, 9.0], 1.5) ≈ 2.25 atol=1e-14
    @test interpolate_catmull_rom(Float32[0, 1, 2, 3], Float32[0, 1, 4, 9], 1.5f0) isa Float32
end

@testset "audit3 animation: quaternion slerp returns the key itself on an interior key" begin
    # three.js Interpolant.evaluate selects the interval starting at an exact
    # key, and QuaternionLinearInterpolant.interpolate_ (QuaternionLinearInterpolant.js:24)
    # calls Quaternion.slerpFlat with alpha 0, which yields that key. The
    # previous key lies in the opposite hemisphere here (dot = -0.8).
    obj = Group()
    keys = [Quaternion(0.0, 0.0, 0.0, 1.0), Quaternion(0.0, 0.6, 0.0, -0.8),
            Quaternion(0.28, 0.0, 0.96, 0.0)]
    track = QuaternionKeyframeTrack(obj, :quaternion, [0.0, 1.0, 2.0], keys)
    @test _audit3_q(sample_track(track, 1.0)) == [0.0, 0.6, 0.0, -0.8]
    @test _audit3_q(sample_track(track, 0.5)) ≈ [0.0, -0.31622776601683794, 0.0, 0.9486832980505139] atol=1e-15
    @test _audit3_q(sample_track(track, 1.25)) ≈
          [0.10715136106222514, 0.5543277195067721, 0.3673760950704862, -0.7391036260090295] atol=1e-15
    step = QuaternionKeyframeTrack(obj, :quaternion, [0.0, 1.0, 2.0], keys; interpolation=:step)
    @test _audit3_q(sample_track(step, 1.0)) == [0.0, 0.6, 0.0, -0.8]
end

@testset "audit3 animation: glTF cubic quaternion normalizes on the first key" begin
    # GLTFLoader.js:2136-2215: copySampleValue_ (raw key) is used only outside
    # the keyed range; at t == times[1] Interpolant.evaluate interpolates with
    # p = 0 and GLTFCubicSplineQuaternionInterpolant normalizes the result.
    obj = Group()
    zero = Quaternion(0.0, 0.0, 0.0, 0.0)
    track = CubicSplineQuaternionKeyframeTrack(
        obj, :quaternion, [0.0, 1.0],
        [Quaternion(0.0, 0.0, 0.0, 2.0), Quaternion(0.0, 0.0, 1.2, 1.6)],
        [zero, zero], [zero, zero])
    @test _audit3_q(sample_track(track, -1.0)) == [0.0, 0.0, 0.0, 2.0]
    @test _audit3_q(sample_track(track, 0.0)) == [0.0, 0.0, 0.0, 1.0]
    @test _audit3_q(sample_track(track, 0.5)) ≈ [0.0, 0.0, 0.31622776601683794, 0.9486832980505139] atol=1e-15
    @test _audit3_q(sample_track(track, 1.0)) == [0.0, 0.0, 1.2, 1.6]
    @test _audit3_q(sample_track(track, 2.0)) == [0.0, 0.0, 1.2, 1.6]
end

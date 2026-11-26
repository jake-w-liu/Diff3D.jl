using Test, Diff3D

# Oracle numbers below come from three.js r186 run in node with the mapping
#   orbit_rotate!(oc, a, p) -> controls._rotateLeft(-a); controls._rotateUp(-p)
#   orbit_zoom!(oc, f)      -> controls._dollyIn(f)
#   orbit_pan!(oc, dx, dy)  -> controls._panLeft(-dx, camera.matrix);
#                              controls._panUp(dy, camera.matrix)
#   orbit_update!(oc)       -> controls.update()
# and an `update()` after every non-damped interaction, as the public
# OrbitControls.rotateLeft/pan/dollyIn methods do.

_a3_vec(v) = [v.x, v.y, v.z]

function _a3_orbit(position, target, up; kwargs...)
    camera = PerspectiveCamera()
    camera.up = up
    camera.position = position
    camera.target = target
    return OrbitControls(camera, target; kwargs...)
end

@testset "audit3 OrbitControls orbits about camera.up" begin
    # OrbitControls.js:406-407 builds _quat = setFromUnitVectors(object.up, +y)
    # and update() (703-704, 794-795) works in that y-up frame.
    oc = _a3_orbit(Vec3(4.0, 1.0, 2.0), Vec3(0.5, -0.5, 0.25), Vec3(0.0, 0.0, 1.0))
    orbit_rotate!(oc, 0.7, -0.4)
    @test _a3_vec(oc.camera.position) ≈
        [1.7694434297399428, 2.024625972578706, 3.3447176086472097] atol=1e-12
    orbit_pan!(oc, 0.3, -0.2)
    @test _a3_vec(oc.target) ≈
        [0.2983233015761451, -0.2332800631370774, 0.11514087130382258] atol=1e-12
    @test _a3_vec(oc.camera.position) ≈
        [1.567766731316088, 2.2913459094416275, 3.2098584799510315] atol=1e-12
    orbit_zoom!(oc, 0.8)
    @test _a3_vec(oc.camera.position) ≈
        [1.3138780453680985, 1.7864207149258857, 2.5909149582215893] atol=1e-12
    # Polar angle is measured from camera.up: the z-up camera at height 1.5
    # above a target at distance sqrt(13.0625) has phi = acos(1.75/r) before
    # any motion (Spherical.setFromVector3 on the rotated offset).
    fresh = _a3_orbit(Vec3(4.0, 1.0, 2.0), Vec3(0.5, -0.5, 0.25), Vec3(0.0, 0.0, 1.0))
    offset = Vec3(3.5, 1.5, 1.75)
    @test Diff3D._orbit_spherical(fresh).phi ≈ acos(1.75 / sqrt(sum(abs2, _a3_vec(offset)))) atol=1e-14

    # Tilted up vector with MapControls-style panning (screenSpacePanning=false).
    mc = _a3_orbit(Vec3(1.0, 2.0, 3.0), Vec3(0.0, 0.0, 0.0), Vec3(0.6, 0.0, 0.8);
                   screen_space_panning=false)
    orbit_rotate!(mc, -0.5, 0.3)
    @test _a3_vec(mc.camera.position) ≈
        [1.411011940768335, 3.020760889223763, 1.698248790120343] atol=1e-12
    orbit_pan!(mc, 0.25, 0.5)
    @test _a3_vec(mc.target) ≈
        [-0.21440561889368945, -0.4905835660638225, 0.16080421417026705] atol=1e-12
    @test _a3_vec(mc.camera.position) ≈
        [1.1966063218746452, 2.5301773231599394, 1.8590530042906088] atol=1e-12
end

@testset "audit3 OrbitControls update and pan re-apply the limits" begin
    limits = (; min_distance=1.0, max_distance=4.0,
              min_polar_angle=pi / 3, max_polar_angle=1.5,
              min_azimuth_angle=0.5, max_azimuth_angle=1.0)
    # The camera starts outside every limit; three.js update()
    # (OrbitControls.js:729-786) clamps theta, phi and radius.
    oc = _a3_orbit(Vec3(0.0, 0.0, 10.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                   limits...)
    orbit_update!(oc)
    @test _a3_vec(oc.camera.position) ≈
        [1.9128982848305642, 0.2829488066708116, 3.5015368232671564] atol=1e-12
    # A pan runs update() too (OrbitControls.pan -> update).
    panned = _a3_orbit(Vec3(0.0, 0.0, 10.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                       limits...)
    orbit_pan!(panned, 1.0, 0.5)
    @test _a3_vec(panned.target) ≈ [1.0, 0.5, 0.0] atol=1e-12
    @test _a3_vec(panned.camera.position) ≈
        [2.9128982848305642, 0.7829488066708117, 3.5015368232671564] atol=1e-12
    # Tightening a limit at runtime takes effect on the next update.
    runtime = _a3_orbit(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    runtime.max_distance = 2.0
    orbit_update!(runtime)
    @test _a3_vec(runtime.camera.position) ≈ [0.0, 0.0, 2.0] atol=1e-12
    # A camera already inside every limit is not touched by an update.
    inside = _a3_orbit(Vec3(0.3, 0.4, 2.5), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    before = inside.camera.position
    orbit_update!(inside)
    @test inside.camera.position === before
end

@testset "audit3 damped OrbitControls update is a single three.js pass" begin
    # Azimuth window straddling ±pi: min 3.0, max 3.3832 (normalized to -2.9).
    # three.js clamps theta once per update (OrbitControls.js:715-748), so an
    # unnormalized theta below -pi survives that frame; the target then moves
    # by dampingFactor * panOffset and the radius is clamped to maxDistance.
    oc = _a3_orbit(Vec3(-0.7056000402993361, 0.0, -4.949962483002227),
                   Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                   enable_damping=true, damping_factor=0.25,
                   min_azimuth_angle=3.0, max_azimuth_angle=3.383185307179586,
                   max_distance=4.0)
    orbit_rotate!(oc, -1.2, 0.1)
    orbit_pan!(oc, 0.5, 0.25)
    expected = (
        ([0.5070365426499461, -0.03748958365884872, -3.931044793203298],
         [-0.12374906207505568, 0.0625, 0.01764000100748341]),
        ([0.3473790347404757, -0.06556917851964081, -3.925310774069305],
         [-0.21656085863134747, 0.109375, 0.030870001763095966]),
        ([0.2773672622841349, -0.08658995428508728, -3.9125616525938582],
         [-0.2861697060485663, 0.14453125, 0.040792502329805386]),
    )
    for (position, target) in expected
        orbit_update!(oc)
        @test _a3_vec(oc.camera.position) ≈ position atol=1e-12
        @test _a3_vec(oc.target) ≈ target atol=1e-12
    end
end

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

# three.js helpers store positions in Float32BufferAttributes, so the oracle
# values below are float32; Diff3D's Float64 positions must round to them.
_a3_f32(v) = Float32.(v)

@testset "audit3 PolarGridHelper matches three.js placement" begin
    # PolarGridHelper.js: spokes only when sectors > 1, at v = i/sectors*2pi
    # with point (sin v, 0, cos v)*radius; rings r = radius - radius/rings*i
    # from the outside in, chords between j/divisions*2pi and (j+1)/...
    pg = PolarGridHelper(3.0, 3, 2; circle_segments=5)
    @test _a3_f32(pg.geometry.positions) == Float32[
        0, 0, 0, 0, 0, 3, 0, 0, 0, 2.598076105117798, 0, -1.5, 0, 0, 0,
        -2.598076105117798, 0, -1.5, 0, 0, 3, 2.8531694412231445, 0,
        0.9270510077476501, 2.8531694412231445, 0, 0.9270510077476501,
        1.7633557319641113, 0, -2.427051067352295, 1.7633557319641113, 0,
        -2.427051067352295, -1.7633557319641113, 0, -2.427051067352295,
        -1.7633557319641113, 0, -2.427051067352295, -2.8531694412231445, 0,
        0.9270510077476501, -2.8531694412231445, 0, 0.9270510077476501,
        -7.347880586115415e-16, 0, 3, 0, 0, 1.5, 1.4265847206115723, 0,
        0.4635255038738251, 1.4265847206115723, 0, 0.4635255038738251,
        0.8816778659820557, 0, -1.2135255336761475, 0.8816778659820557, 0,
        -1.2135255336761475, -0.8816778659820557, 0, -1.2135255336761475,
        -0.8816778659820557, 0, -1.2135255336761475, -1.4265847206115723, 0,
        0.4635255038738251, -1.4265847206115723, 0, 0.4635255038738251,
        -3.6739402930577075e-16, 0, 1.5]
    # A single sector draws no spoke: 1 ring x 7 chords = 14 vertices.
    @test PolarGridHelper(2.5, 1, 1; circle_segments=7).geometry.n_vertices == 14
end

@testset "audit3 GridHelper and AxesHelper match three.js buffers" begin
    # GridHelper.js: per k (k += step from -size/2), push the x-parallel line
    # (-h,0,k)-(h,0,k) and then the z-parallel line (k,0,-h)-(k,0,h).
    grid = GridHelper(5.0, 3)
    @test _a3_f32(grid.geometry.positions) == Float32[
        -2.5, 0, -2.5, 2.5, 0, -2.5, -2.5, 0, -2.5, -2.5, 0, 2.5,
        -2.5, 0, -0.8333333134651184, 2.5, 0, -0.8333333134651184,
        -0.8333333134651184, 0, -2.5, -0.8333333134651184, 0, 2.5,
        -2.5, 0, 0.8333333134651184, 2.5, 0, 0.8333333134651184,
        0.8333333134651184, 0, -2.5, 0.8333333134651184, 0, 2.5,
        -2.5, 0, 2.5, 2.5, 0, 2.5, 2.5, 0, -2.5, 2.5, 0, 2.5]
    # AxesHelper.js colors: each axis tip is a lighter tint of its colour.
    axes = AxesHelper(2.0)
    @test get_attribute(axes.geometry, :color).data ==
        [1, 0, 0, 1, 0.6, 0, 0, 1, 0, 0.6, 1, 0, 0, 0, 1, 0, 0.6, 1]
end

# TrackballControls oracle: three.js r186 with staticMoving=true, zoomSpeed=1,
# trackball_rotate!(dx, dy) -> _moveCurr - _movePrev = (dx, dy); _rotateCamera(),
# trackball_zoom!(f) -> _zoomEnd.y - _zoomStart.y = f - 1; _zoomCamera(),
# each followed by the update() tail: position = target + eye,
# _checkDistances(), lookAt(target).
function _a3_trackball(; kwargs...)
    camera = PerspectiveCamera()
    camera.position = Vec3(1.0, 2.0, 5.0)
    camera.target = Vec3(0.5, 0.0, -1.0)
    return TrackballControls(camera; kwargs...)
end

@testset "audit3 TrackballControls ignores non-positive zoom factors" begin
    # TrackballControls.js:632 scales the eye only when `factor > 0`.
    tc = _a3_trackball()
    trackball_zoom!(tc, -1.0)
    @test tc.camera.position == Vec3(1.0, 2.0, 5.0)
    trackball_zoom!(tc, 0.0)
    @test tc.camera.position == Vec3(1.0, 2.0, 5.0)
    @test view_matrix(tc.camera) == view_matrix(_a3_trackball().camera)
    trackball_zoom!(tc, 0.5)
    @test _a3_vec(tc.camera.position) ≈ [0.75, 1.0, 2.0] atol=1e-14
end

@testset "audit3 TrackballControls min/max distance" begin
    tc = _a3_trackball(min_distance=2.0, max_distance=4.0)
    @test tc.min_distance == 2.0 && tc.max_distance == 4.0
    # _checkDistances (TrackballControls.js:738-756) after each operation.
    trackball_rotate!(tc, 0.3, -0.2)
    @test _a3_vec(tc.camera.position) ≈
        [-0.4132015055232565, 1.8959168074889639, 2.401699938176633] atol=1e-12
    @test _a3_vec(tc.camera.up) ≈
        [-0.08299098377028535, 0.97705648722633, -0.1961456534868535] atol=1e-12
    trackball_zoom!(tc, 0.1)
    @test _a3_vec(tc.camera.position) ≈
        [0.043399247238371685, 0.947958403744482, 0.7008499690883168] atol=1e-12
    trackball_zoom!(tc, -1.0)
    trackball_zoom!(tc, 0.0)
    @test _a3_vec(tc.camera.position) ≈
        [0.043399247238371685, 0.947958403744482, 0.7008499690883168] atol=1e-12
    trackball_zoom!(tc, 3.0)
    @test _a3_vec(tc.camera.position) ≈
        [-0.41320150552325663, 1.8959168074889639, 2.401699938176633] atol=1e-12
    # A pan keeps the eye but applies a limit tightened at runtime.
    tc.max_distance = 3.0
    trackball_pan!(tc, 0.0, 0.0)
    @test sqrt(sum(abs2, _a3_vec(tc.camera.position - tc.target))) ≈ 3.0 atol=1e-12
    # Defaults keep three.js minDistance = 0, maxDistance = Infinity.
    @test _a3_trackball().min_distance == 0.0
    @test _a3_trackball().max_distance == Inf
    @test_throws ArgumentError _a3_trackball(min_distance=3.0, max_distance=2.0)
    @test_throws ArgumentError _a3_trackball(min_distance=NaN)
end

@testset "audit3 OrbitControls drives an OrthographicCamera" begin
    # three.js update() for orthographic cameras (OrbitControls.js:778-779,
    # 892-895): the radius is only clamped and zoom = clamp(zoom / scale,
    # minZoom, maxZoom); reset() restores zoom0 and runs update().
    camera = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=0.1, far=100.0)
    camera.position = Vec3(1.0, 2.0, 3.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    oc = OrbitControls(camera; min_zoom=0.5, max_zoom=3.0, max_distance=3.0)
    @test oc.camera === camera
    orbit_save_state!(oc)
    orbit_zoom!(oc, 0.5)
    @test camera.zoom == 2.0
    @test _a3_vec(camera.position) ≈
        [0.8017837257372733, 1.6035674514745464, 2.4053511772118195] atol=1e-12
    orbit_zoom!(oc, 0.25)
    @test camera.zoom == 3.0
    orbit_rotate!(oc, 0.4, 0.1)
    @test _a3_vec(camera.position) ≈
        [1.7725818314839605, 1.342432382991987, 2.0139088727614816] atol=1e-12
    orbit_pan!(oc, 0.2, 0.3)
    @test _a3_vec(oc.target) ≈
        [0.06143558546651249, 0.268288562877631, -0.23290967319422845] atol=1e-12
    @test _a3_vec(camera.position) ≈
        [1.8340174169504726, 1.610720945869618, 1.7809991995672527] atol=1e-12
    orbit_zoom!(oc, 4.0)
    @test camera.zoom == 0.75
    @test _a3_vec(camera.position) ≈
        [1.8340174169504724, 1.6107209458696183, 1.7809991995672523] atol=1e-12
    orbit_reset!(oc)
    @test camera.zoom == 1.0
    @test _a3_vec(camera.position) ≈
        [0.8017837257372733, 1.6035674514745464, 2.4053511772118195] atol=1e-12

    # MapControls accepts an orthographic camera too; damped dolly eases zoom.
    map_camera = OrthographicCamera()
    map_camera.position = Vec3(0.0, 5.0, 5.0)
    map_camera.target = Vec3(0.0, 0.0, 0.0)
    mc = MapControls(map_camera; enable_damping=true, damping_factor=0.5)
    orbit_zoom!(mc, 0.5)
    for _ in 1:200
        orbit_update!(mc)
    end
    # orbit_update! zeroes residual log-zoom velocities below 1e-9, so the
    # converged zoom is within ~2e-9 of 1/0.5.
    @test map_camera.zoom ≈ 2.0 atol=1e-8
    @test _a3_vec(map_camera.position) ≈ [0.0, 5.0, 5.0] atol=1e-12

    # A zoom that cannot stay positive and finite is rejected, not applied.
    @test_throws ArgumentError orbit_zoom!(OrbitControls(OrthographicCamera()), -1.0)
    @test_throws ArgumentError OrbitControls(OrthographicCamera(); min_zoom=2.0, max_zoom=1.0)
    @test_throws ArgumentError OrbitControls(OrthographicCamera(); min_zoom=-1.0)
    @test_throws ArgumentError OrbitControls(PerspectiveCamera(); max_zoom=NaN)
end

function _a3_orbit_step!(oc)
    orbit_rotate!(oc, 0.01, 0.01)
    orbit_zoom!(oc, 1.001)
    orbit_pan!(oc, 0.01, 0.01)
    orbit_update!(oc)
    return oc
end

function _a3_orbit_step_bytes(oc)
    _a3_orbit_step!(oc)
    return @allocated _a3_orbit_step!(oc)
end

@testset "audit3 OrbitControls steps do not allocate" begin
    # Allocation counts are only meaningful for optimized code.
    if Base.JLOptions().opt_level > 0
        for camera in (PerspectiveCamera(), OrthographicCamera()),
            up in (Vec3(0.0, 1.0, 0.0), Vec3(0.0, 0.0, 1.0)), damping in (false, true)
            camera.up = up
            camera.position = Vec3(1.0, 2.0, 3.0)
            camera.target = Vec3(0.0, 0.0, 0.0)
            oc = OrbitControls(camera; enable_damping=damping, max_distance=10.0)
            @test _a3_orbit_step_bytes(oc) == 0
        end
    end
end

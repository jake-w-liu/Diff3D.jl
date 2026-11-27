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

    # The same window for a z-up camera (three.js r186 oracle): the single
    # damped pass works in the camera.up frame.
    zup = _a3_orbit(Vec3(1.0, -4.5, 0.8), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0);
                    enable_damping=true, damping_factor=0.25,
                    min_azimuth_angle=3.0, max_azimuth_angle=3.383185307179586,
                    max_distance=4.0)
    orbit_rotate!(zup, -1.2, 0.1)
    orbit_pan!(zup, 0.5, 0.25)
    expected_zup = (
        ([-0.8269943565916407, 3.8795888930543234, 0.6468031213060019],
         [0.11970509308626495, 0.03754860969261319, 0.06157956316311799]),
        ([0.14365998807617059, 4.032398310114113, 0.6186963176755715],
         [0.20948391290096366, 0.06571006696207309, 0.10776423553545648]),
        ([0.87916487107352, 4.0149436299808015, 0.5974969090364495],
         [0.2768180277619877, 0.08683115991416801, 0.14240273981471036]),
    )
    for (position, target) in expected_zup
        orbit_update!(zup)
        @test _a3_vec(zup.camera.position) ≈ position atol=1e-12
        @test _a3_vec(zup.target) ≈ target atol=1e-12
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

    # Every three.js update() re-clamps an orthographic zoom to
    # [minZoom, maxZoom] (OrbitControls.js:892-895 with _scale = 1), so a zoom
    # outside the limits moves inside on update, pan, rotate and reset.
    # Oracle: three.js r186.
    wide = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                              near=0.1, far=100.0)
    wide.position = Vec3(1.0, 2.0, 3.0)
    wide.target = Vec3(0.0, 0.0, 0.0)
    wide.zoom = 5.0
    wc = OrbitControls(wide; min_zoom=0.5, max_zoom=3.0)
    @test wc.zoom0 == 5.0
    orbit_update!(wc)
    @test wide.zoom == 3.0
    @test _a3_vec(wide.position) ≈ [1.0, 2.0, 3.0] atol=1e-14
    wide.zoom = 4.0
    orbit_pan!(wc, 0.2, 0.1)
    @test wide.zoom == 3.0
    @test _a3_vec(wide.position) ≈
        [1.172833574515533, 2.0845154254728517, 2.886045191512921] atol=1e-12
    wide.zoom = 4.0
    orbit_rotate!(wc, 0.3, 0.1)
    @test wide.zoom == 3.0
    @test _a3_vec(wide.position) ≈
        [2.121826615753194, 1.758822772828356, 2.6059939101101195] atol=1e-12
    orbit_reset!(wc)
    @test wide.zoom == 3.0
    @test _a3_vec(wide.position) ≈ [1.0, 2.0, 3.0] atol=1e-12
    narrow = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=0.1, far=100.0)
    narrow.position = Vec3(1.0, 2.0, 3.0)
    narrow.target = Vec3(0.0, 0.0, 0.0)
    narrow.zoom = 0.2
    nc = OrbitControls(narrow; min_zoom=0.5, max_zoom=3.0)
    orbit_rotate!(nc, 0.3, 0.1)
    @test narrow.zoom == 0.5
    @test _a3_vec(narrow.position) ≈
        [1.9489930412376613, 1.6743073473555043, 2.7199487185971987] atol=1e-12
    # A perspective camera's zoom is not an orbit limit.
    persp = PerspectiveCamera()
    persp.zoom = 5.0
    orbit_update!(OrbitControls(persp; max_zoom=3.0))
    @test persp.zoom == 5.0

    # A zoom that cannot stay positive and finite is rejected, not applied.
    @test_throws ArgumentError orbit_zoom!(OrbitControls(OrthographicCamera()), -1.0)
    @test_throws ArgumentError OrbitControls(OrthographicCamera(); min_zoom=2.0, max_zoom=1.0)
    @test_throws ArgumentError OrbitControls(OrthographicCamera(); min_zoom=-1.0)
    @test_throws ArgumentError OrbitControls(PerspectiveCamera(); max_zoom=NaN)
end

@testset "audit3 OrbitControls auto-rotation" begin
    # OrbitControls.js update(): when autoRotate, _rotateLeft of
    # _getAutoRotationAngle(deltaTime) = 2pi/60*speed*deltaTime, or
    # 2pi/60/60*speed per frame without deltaTime.
    oc = _a3_orbit(Vec3(0.0, 1.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                   auto_rotate=true, auto_rotate_speed=3.0)
    @test oc.auto_rotate && oc.auto_rotate_speed == 3.0
    orbit_update!(oc)
    @test _a3_vec(oc.camera.position) ≈
        [-0.026179819157097894, 0.9999999999999997, 4.999931461237133] atol=1e-12
    orbit_update!(oc, 0.5)
    @test _a3_vec(oc.camera.position) ≈
        [-0.8080191055168056, 0.9999999999999997, 4.934278582034035] atol=1e-12
    # Interactions do not auto-rotate (three.js only auto-rotates in state NONE).
    before = oc.camera.position
    orbit_pan!(oc, 0.0, 0.0)
    @test oc.camera.position == before

    # Damped: the turn is queued into the azimuth velocity, z-up camera.
    damped = _a3_orbit(Vec3(0.0, 1.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0);
                       auto_rotate=true, auto_rotate_speed=-2.0,
                       enable_damping=true, damping_factor=0.1)
    for (dt, position) in (
            (0.25, [-0.005235963831419596, 0.9999862922474314, 4.9999999999999964]),
            (0.25, [-0.015183781002100182, 0.9998847197524761, 4.999999999999994]),
            (nothing, [-0.0244845223667391, 0.9997002091449616, 4.999999999999992]))
        dt === nothing ? orbit_update!(damped) : orbit_update!(damped, dt)
        @test _a3_vec(damped.camera.position) ≈ position atol=1e-12
    end
    # three.js reset() ends with update(), which auto-rotates one frame
    # (OrbitControls.js:621-633). Oracle: three.js r186 with the residual
    # deltas cleared first, as orbit_reset! documents.
    reset_plain = _a3_orbit(Vec3(0.0, 1.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                            auto_rotate=true, auto_rotate_speed=3.0)
    orbit_rotate!(reset_plain, 0.4, 0.1)
    orbit_reset!(reset_plain)
    @test _a3_vec(reset_plain.camera.position) ≈
        [-0.026179819157097894, 0.9999999999999997, 4.999931461237133] atol=1e-12
    reset_damped = _a3_orbit(Vec3(0.0, 1.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0);
                             auto_rotate=true, auto_rotate_speed=3.0,
                             enable_damping=true, damping_factor=0.1)
    orbit_rotate!(reset_damped, 0.4, 0.1)
    orbit_update!(reset_damped)
    @test _a3_vec(reset_damped.camera.position) ≈
        [-0.041437450035998566, 1.0491311601521787, 4.989750168749156] atol=1e-12
    orbit_reset!(reset_damped)
    @test _a3_vec(reset_damped.camera.position) ≈
        [0.0005235987516737948, 0.9999998629221682, 4.9999999999999964] atol=1e-12
    orbit_update!(reset_damped)
    @test _a3_vec(reset_damped.camera.position) ≈
        [0.0015184358657381013, 0.9999988471756005, 4.999999999999995] atol=1e-12
    # Without auto-rotation a reset restores the saved pose exactly.
    reset_still = _a3_orbit(Vec3(0.0, 1.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    orbit_rotate!(reset_still, 0.4, 0.1)
    orbit_reset!(reset_still)
    @test reset_still.camera.position == Vec3(0.0, 1.0, 5.0)

    # Defaults match three.js (autoRotate false, autoRotateSpeed 2).
    plain = OrbitControls(PerspectiveCamera())
    @test !plain.auto_rotate && plain.auto_rotate_speed == 2.0
    @test_throws ArgumentError OrbitControls(PerspectiveCamera(); auto_rotate_speed=Inf)
    @test_throws ArgumentError orbit_update!(oc, NaN)
    # The frame delta is validated even when auto-rotation is off.
    still = OrbitControls(PerspectiveCamera())
    @test_throws ArgumentError orbit_update!(still, Inf)
    @test_throws ArgumentError orbit_update!(still, "0.1")
    @test orbit_update!(still, 1 // 60) === still
end

@testset "audit3 OrbitControls target radius about the cursor" begin
    # OrbitControls.js:768-771: target.sub(cursor).clampLength(minTargetRadius,
    # maxTargetRadius).add(cursor) on every update, before placing the camera.
    oc = _a3_orbit(Vec3(0.0, 2.0, 6.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0);
                   cursor=Vec3(1.0, 0.0, 0.0), min_target_radius=0.2,
                   max_target_radius=0.5)
    @test oc.cursor == Vec3(1.0, 0.0, 0.0)
    orbit_update!(oc)
    @test _a3_vec(oc.target) ≈ [0.5, 0.0, 0.0] atol=1e-14
    @test _a3_vec(oc.camera.position) ≈ [0.5, 2.0, 6.0] atol=1e-14
    orbit_pan!(oc, 1.3, 0.0)
    @test _a3_vec(oc.target) ≈ [1.5, 0.0, 0.0] atol=1e-12
    @test _a3_vec(oc.camera.position) ≈ [1.5, 2.0, 6.0] atol=1e-12
    orbit_pan!(oc, -0.5, 0.1)
    @test _a3_vec(oc.target) ≈
        [1.0, 0.18973665961010278, -0.0632455532033676] atol=1e-12
    @test _a3_vec(oc.camera.position) ≈
        [1.0, 2.189736659610103, 5.936754446796632] atol=1e-12
    orbit_rotate!(oc, 0.3, 0.1)
    @test _a3_vec(oc.camera.position) ≈
        [2.823268603149492, 1.580744490285185, 5.830886173842602] atol=1e-12
    plain = OrbitControls(PerspectiveCamera())
    @test plain.cursor == Vec3(0.0, 0.0, 0.0)
    @test plain.min_target_radius == 0.0 && plain.max_target_radius == Inf
    @test_throws ArgumentError OrbitControls(PerspectiveCamera(); min_target_radius=2.0,
                                             max_target_radius=1.0)
    @test_throws ArgumentError OrbitControls(PerspectiveCamera(); cursor=Vec3(NaN, 0.0, 0.0))
end

function _a3_orbit_step!(oc)
    orbit_rotate!(oc, 0.01, 0.01)
    orbit_zoom!(oc, 1.001)
    orbit_pan!(oc, 0.01, 0.01)
    orbit_update!(oc)
    orbit_update!(oc, 1 / 60)
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
            up in (Vec3(0.0, 1.0, 0.0), Vec3(0.0, 0.0, 1.0)), damping in (false, true),
            auto_rotate in (false, true)
            camera.up = up
            camera.position = Vec3(1.0, 2.0, 3.0)
            camera.target = Vec3(0.0, 0.0, 0.0)
            oc = OrbitControls(camera; enable_damping=damping, max_distance=10.0,
                               auto_rotate=auto_rotate)
            @test _a3_orbit_step_bytes(oc) == 0
        end
    end
end

@testset "audit3 DragControls and TransformControls accept orthographic cameras" begin
    # three.js DragControls/TransformControls take any camera; picking goes
    # through Raycaster.setFromCamera, which casts parallel rays for an
    # orthographic camera: NDC x = 0.9 maps to world x = 0.9 * right = 1.8.
    camera = OrthographicCamera(left=-2.0, right=2.0, top=2.0, bottom=-2.0,
                                near=0.1, far=100.0)
    camera.position = Vec3(0.0, 0.0, 5.0)
    camera.target = Vec3(0.0, 0.0, 0.0)
    box = Mesh(BoxGeometry(width=0.2, height=0.2, depth=0.2), MeshBasicMaterial())
    box.position = Vec3(1.8, 0.0, 0.0)
    dc = DragControls([box], camera)
    @test dc.camera === camera
    drag_pick_start!(dc, 0.9, 0.0)
    @test dc.selected === box
    drag_pick_start!(dc, 0.5, 0.0)
    @test dc.selected === nothing
    tc = TransformControls(camera; mode=:translate)
    transform_attach!(tc, box)
    transform_apply!(tc, Vec3(0.5, 0.0, 0.0))
    @test box.position == Vec3(2.3, 0.0, 0.0)
    @test TransformControls(camera, box, :rotate, :local).camera === camera
end

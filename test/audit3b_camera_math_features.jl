using Test, Diff3D, ForwardDiff

# Round-2 regression tests for the camera-math-features package. Expected
# values come from three.js r186 (0.186.0) executed under node, or from the
# derivation noted next to each expectation.

_b3_close(a, b; atol=4e-16) = all(isapprox.(a, b; atol=atol, rtol=0))
_b3_mat(m::Mat4) = m.e

@testset "audit3b: interpolate_linear endpoints keep the interior type" begin
    # Clamped endpoints must return the same type as an interior evaluation;
    # integer and Float32 samples promote with the Float64 query weight.
    times = [0.0, 1.0, 2.0]
    for values in ([1, 3, 7], Float32[1, 3, 7])
        for t in (-1.0, 0.0, 0.5, 2.0, 3.0)
            result = @inferred interpolate_linear(times, values, t)
            @test result isa Float64
        end
        @test interpolate_linear(times, values, -1.0) === 1.0
        @test interpolate_linear(times, values, 3.0) === 7.0
        @test interpolate_linear(times, values, 1.5) === 5.0
    end
    vectors = [Vec3(1, 2, 3), Vec3(3, 4, 5)]
    @test (@inferred interpolate_linear([0.0, 1.0], vectors, -2.0)) ===
          Vec3(1.0, 2.0, 3.0)
    @test (@inferred interpolate_linear([0.0, 1.0], vectors, 0.5)) ===
          Vec3(2.0, 3.0, 4.0)
    @test (@inferred interpolate_linear([0, 1], [1, 3], 2)) === 3.0
    # A ForwardDiff query time clamped at an endpoint has zero derivative and
    # keeps the Dual type of interior evaluations.
    derivative(t) = ForwardDiff.derivative(x -> interpolate_linear(times, [1.0, 3.0, 7.0], x), t)
    @test derivative(-1.0) == 0.0
    @test derivative(0.5) == 2.0
    @test derivative(5.0) == 0.0
end

# node: new PerspectiveCamera(50, 1.6, 0.25, 300) with the zoom, filmOffset
# and setViewOffset(...) below, then updateProjectionMatrix();
# camera.projectionMatrix.elements (src/cameras/PerspectiveCamera.js:366-393,
# src/math/Matrix4.js:1140-1184). Only elements 0, 5, 8, 9 vary; 10 and 14 are
# -1.0016680567139282 and -0.5004170141784821, element 11 is -1.
const _B3_PERSPECTIVE_ORACLE = [
    # (zoom, view, film_offset) => (e0, e5, e8, e9)
    (1.0, nothing, 7.5) => (1.340316825318474, 2.1445069205095586, 0.2872107482825302, 0.0),
    (1.0, (1920, 1080, 480, 270, 640, 360), 0.0) =>
        (3.618855428359881, 6.433520761528676, -0.5000000000000001, 0.5),
    (1.0, (1920, 1080, 480, 270, 640, 360), 7.5) =>
        (3.618855428359881, 6.433520761528676, 0.2754690203628315, 0.5),
    (1.0, (800, 600, -100, 50, 300, 200), 0.0) =>
        (4.289013841019117, 6.433520761528676, -2.3333333333333335, 1.5000000000000002),
    (1.0, (800, 600, -100, 50, 300, 200), 7.5) =>
        (4.289013841019117, 6.433520761528676, -1.414258938829237, 1.5000000000000002),
    (2.5, nothing, 7.5) => (3.350792063296185, 5.361267301273896, 0.7180268707063252, 0.0),
    (2.5, (1920, 1080, 480, 270, 640, 360), 0.0) =>
        (9.047138570899701, 16.08380190382169, -0.5000000000000001, 0.5000000000000001),
    (2.5, (1920, 1080, 480, 270, 640, 360), 7.5) =>
        (9.047138570899701, 16.08380190382169, 1.4386725509070786, 0.5000000000000001),
    (2.5, (800, 600, -100, 50, 300, 200), 0.0) =>
        (10.722534602547794, 16.08380190382169, -2.333333333333334, 1.5000000000000002),
    (2.5, (800, 600, -100, 50, 300, 200), 7.5) =>
        (10.722534602547794, 16.08380190382169, -0.03564734707309216, 1.5000000000000002),
]

@testset "audit3b: PerspectiveCamera view offset and film offset match three.js" begin
    for ((zoom, view, film), (e0, e5, e8, e9)) in _B3_PERSPECTIVE_ORACLE
        camera = PerspectiveCamera(fov=50 * (π / 180), aspect=1.6, near=0.25,
                                   far=300.0, zoom=zoom, film_offset=film)
        view === nothing || Diff3D.set_view_offset!(camera, view...)
        m = @inferred projection_matrix(camera)
        @test m isa Mat4{Float64}
        @test _b3_close((m.e[1], m.e[6], m.e[9], m.e[10]), (e0, e5, e8, e9); atol=2e-15)
        @test _b3_close((m.e[11], m.e[12], m.e[15]),
                        (-1.0016680567139282, -1.0, -0.5004170141784821); atol=1e-15)
        @test count(iszero, m.e) == (iszero(e9) ? 10 : 9)
        # setViewOffset sets aspect = fullWidth / fullHeight.
        view === nothing || @test camera.aspect == view[1] / view[2]
    end
    # Portrait film width is filmGauge·min(aspect, 1): node with
    # PerspectiveCamera(70, 0.5, 1, 100), filmGauge=24, filmOffset=-3.
    portrait = PerspectiveCamera(fov=70 * (π / 180), aspect=0.5, near=1.0,
                                 far=100.0, film_gauge=24, film_offset=-3)
    m = projection_matrix(portrait)
    @test _b3_close((m.e[1], m.e[6], m.e[9]),
                    (2.8562960134842292, 1.4281480067421146, -0.7140740033710573);
                    atol=2e-15)
    # clearViewOffset keeps the window but disables it.
    camera = PerspectiveCamera(fov=0.8, aspect=1.6)
    plain = projection_matrix(camera)
    Diff3D.set_view_offset!(camera, 1600, 1000, 10, 20, 300, 200)
    @test projection_matrix(camera).e != plain.e
    Diff3D.clear_view_offset!(camera)
    @test camera.view isa Diff3D.CameraView && !camera.view.enabled
    @test camera.view.offset_y == 20.0
    @test projection_matrix(camera).e == plain.e
    # An infinite far plane keeps its limiting depth terms with offsets.
    infinite = PerspectiveCamera(fov=0.8, far=Inf, film_offset=2.0)
    Diff3D.set_view_offset!(infinite, 4, 4, 1, 1, 2, 2)
    @test all(isfinite, projection_matrix(infinite).e)
    @test projection_matrix(infinite).e[11] == -1.0
    # Invalid windows and film properties are rejected.
    @test_throws ArgumentError Diff3D.set_view_offset!(PerspectiveCamera(), 0, 1, 0, 0, 1, 1)
    @test_throws ArgumentError Diff3D.set_view_offset!(PerspectiveCamera(), 1, 1, NaN, 0, 1, 1)
    @test_throws ArgumentError Diff3D.set_view_offset!(OrthographicCamera(), 1, 1, 0, 0, -1, 1)
    @test_throws ArgumentError PerspectiveCamera(film_gauge=0)
    @test_throws ArgumentError PerspectiveCamera(film_offset=Inf)
    @test_throws ArgumentError PerspectiveCamera(focus=-1)
    bad = PerspectiveCamera(film_offset=1.0)
    bad.film_gauge = NaN
    @test_throws ArgumentError projection_matrix(bad)
    # Earlier positional layouts keep working with three.js defaults.
    legacy = PerspectiveCamera(Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
                               nothing, Diff3D.AbstractObject3D[], true, "c", 1,
                               0.8, 1.5, 0.1, 100.0, 2.0, Vec3(), Vec3(0.0, 1.0, 0.0))
    @test (legacy.focus, legacy.film_gauge, legacy.film_offset, legacy.view) ===
          (10.0, 35.0, 0.0, nothing)
    legacy17 = PerspectiveCamera(Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
                                 nothing, Diff3D.AbstractObject3D[], true, "c", 1,
                                 0.8, 1.5, 0.1, 100.0, 2.0, Vec3(), Vec3(0.0, 1.0, 0.0),
                                 false, true)
    @test legacy17.rotation_driven && legacy17.view === nothing
    ortho19 = OrthographicCamera(Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
                                 nothing, Diff3D.AbstractObject3D[], true, "o", 2,
                                 -1.0, 1.0, -1.0, 1.0, 0.1, 10.0, 1.0, Vec3(),
                                 Vec3(0.0, 1.0, 0.0), false, false)
    @test ortho19.view === nothing
end

@testset "audit3b: PerspectiveCamera film and focal-length helpers match three.js" begin
    # node: c = new PerspectiveCamera(50, 1.6, 0.25, 300); c.zoom = 2.5;
    # getFocalLength() = 23.455544443073297, getEffectiveFOV() =
    # 21.13114477157443 deg, getFilmWidth() = 35, getFilmHeight() = 21.875;
    # setFocalLength(85) gives fov 14.664654349387739 deg
    # (src/cameras/PerspectiveCamera.js:160-232).
    camera = PerspectiveCamera(fov=50 * (π / 180), aspect=1.6, near=0.25,
                               far=300.0, zoom=2.5)
    @test isapprox(Diff3D.get_focal_length(camera), 23.455544443073297; rtol=4eps())
    @test isapprox(Diff3D.get_effective_fov(camera), 21.13114477157443 * (π / 180);
                   rtol=4eps())
    @test Diff3D.get_film_width(camera) == 35.0
    @test Diff3D.get_film_height(camera) == 21.875
    Diff3D.set_focal_length!(camera, 85)
    @test isapprox(camera.fov, 14.664654349387739 * (π / 180); rtol=4eps())
    # Portrait aspect 0.75: getFilmWidth() = 26.25, getFilmHeight() = 35.
    portrait = PerspectiveCamera(aspect=0.75)
    @test (Diff3D.get_film_width(portrait), Diff3D.get_film_height(portrait)) ==
          (26.25, 35.0)
    @test_throws ArgumentError Diff3D.set_focal_length!(camera, 0.0)
    # node: zoom 2.5, filmOffset 7.5, setViewOffset(1920,1080,480,270,640,360);
    # getViewBounds(10) = (0.48487435830603665, -0.31087177210333233) to
    # (2.6955180710408455, 0.9326153163099974); getViewSize(10) =
    # (2.210643712734809, 1.2434870884133298) (src/cameras/PerspectiveCamera.js:243-271).
    offset = PerspectiveCamera(fov=50 * (π / 180), aspect=1.6, near=0.25,
                               far=300.0, zoom=2.5, film_offset=7.5)
    Diff3D.set_view_offset!(offset, 1920, 1080, 480, 270, 640, 360)
    low, high = Diff3D.get_view_bounds(offset, 10)
    @test _b3_close((low.x, low.y, high.x, high.y),
                    (0.48487435830603665, -0.31087177210333233,
                     2.6955180710408455, 0.9326153163099974); atol=4e-15)
    size = Diff3D.get_view_size(offset, 10)
    @test _b3_close((size.x, size.y), (2.210643712734809, 1.2434870884133298); atol=4e-15)
end

@testset "audit3b: OrthographicCamera view offset matches three.js" begin
    # node: new OrthographicCamera(-4, 6, 3, -2, 0.5, 50), zoom and
    # setViewOffset(1920,1080,480,270,640,360) (src/cameras/OrthographicCamera.js:195-223).
    oracle = [
        (1.0, false) => (0.2, 0.4, -0.2, -0.2),
        (1.0, true) => (0.6000000000000001, 1.2000000000000002, -0.09999999999999992, -1.1),
        (3.0, false) => (0.5999999999999999, 1.1999999999999997, -0.5999999999999999, -0.5999999999999999),
        (3.0, true) => (1.7999999999999998, 3.5999999999999996, -1.2999999999999998, -2.3000000000000007),
    ]
    for ((zoom, offset), (e0, e5, e12, e13)) in oracle
        camera = OrthographicCamera(left=-4, right=6, top=3, bottom=-2,
                                    near=0.5, far=50, zoom=zoom)
        offset && Diff3D.set_view_offset!(camera, 1920, 1080, 480, 270, 640, 360)
        m = @inferred projection_matrix(camera)
        @test _b3_close((m.e[1], m.e[6], m.e[13], m.e[14]), (e0, e5, e12, e13); atol=1e-15)
        @test _b3_close((m.e[11], m.e[15], m.e[16]),
                        (-0.04040404040404041, -1.02020202020202, 1.0); atol=1e-16)
    end
    camera = OrthographicCamera()
    plain = projection_matrix(camera)
    Diff3D.set_view_offset!(camera, 2, 2, 1, 0, 1, 1)
    @test projection_matrix(camera).e != plain.e
    Diff3D.clear_view_offset!(camera)
    @test projection_matrix(camera).e == plain.e
end

function _b3_view_offset_scene()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    for (center, color) in ((Vec3(-0.37, 0.21, 0.0), Color3(1.0, 0.2, 0.1)),
                            (Vec3(0.43, -0.29, -0.5), Color3(0.1, 0.9, 0.3)))
        mesh = Mesh(PlaneGeometry(width=0.83, height=0.71),
                    MeshBasicMaterial(color=color))
        mesh.position = center
        mesh.rotation = Euler(0.1, 0.2, 0.3)
        add!(scene, mesh)
    end
    return scene
end

@testset "audit3b: renderers and raycasting honour view and film offsets" begin
    scene = _b3_view_offset_scene()
    full = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0)
    full.position = Vec3(0.0, 0.0, 3.0)
    full_target = RenderTarget(16, 16)
    render!(full_target, scene, full)
    soft_full = soft_render_scene(scene, full, 16, 16)
    # Each 8×8 tile of the 16×16 view renders the matching quadrant.
    for (x, y) in ((0, 0), (8, 0), (0, 8), (8, 8))
        tile = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0)
        tile.position = full.position
        Diff3D.set_view_offset!(tile, 16, 16, x, y, 8, 8)
        target = RenderTarget(8, 8)
        render!(target, scene, tile)
        @test isapprox(target.color, full_target.color[y+1:y+8, x+1:x+8, :]; atol=1e-12)
        soft_tile = soft_render_scene(scene, tile, 8, 8)
        @test isapprox(soft_tile, soft_full[y+1:y+8, x+1:x+8, :]; atol=1e-9)
    end
    @test any(>(0.5), full_target.color)
    # A film offset of filmWidth·tan(fov/2)/2 shifts the near-plane window by
    # near·skew/filmWidth = width/4, like setViewOffset(16,16,4,0,16,16).
    film = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0)
    film.position = full.position
    film.film_offset = Diff3D.get_film_width(film) * tan(0.45) / 2
    shifted = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0)
    Diff3D.set_view_offset!(shifted, 16, 16, 4, 0, 16, 16)
    @test isapprox(collect(projection_matrix(film).e),
                   collect(projection_matrix(shifted).e); atol=1e-15)
    # Raycasting through the tile center equals the full-view ray through the
    # same pixel.
    tile = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0)
    tile.position = full.position
    Diff3D.set_view_offset!(tile, 16, 16, 8, 0, 8, 8)
    rc = Raycaster(Vec3(), Vec3(0.0, 0.0, -1.0))
    set_from_camera!(rc, tile, 0.0, 0.0)
    tile_direction = rc.ray.direction
    set_from_camera!(rc, full, 0.5, 0.5)
    @test _b3_close((tile_direction.x, tile_direction.y, tile_direction.z),
                    (rc.ray.direction.x, rc.ray.direction.y, rc.ray.direction.z);
                    atol=1e-14)
    # The browser viewer cannot represent off-axis projections; export
    # rejects them instead of silently dropping the offset.
    @test_throws ArgumentError WebGLExportCase("a", "A", "", Scene(); camera=tile)
    @test_throws ArgumentError WebGLExportCase("a", "A", "", Scene(); camera=film)
    ortho = OrthographicCamera()
    Diff3D.set_view_offset!(ortho, 2, 2, 0, 0, 1, 1)
    @test_throws ArgumentError WebGLExportCase("a", "A", "", Scene(); camera=ortho)
    Diff3D.clear_view_offset!(ortho)
    @test WebGLExportCase("a", "A", "", Scene(); camera=ortho) isa WebGLExportCase
end

# node: c = new PerspectiveCamera(60, 1.5, 0.2, 80); c.focus, c.zoom,
# optional c.setViewOffset(1920,1080,480,270,640,360); c.position.set(1,2,5);
# c.lookAt(0,0,0); s = new StereoCamera(); s.eyeSep = sep; s.update(c);
# s.cameraL/R.projectionMatrix.elements[0, 5, 8, 9] and matrixWorld
# translations (src/cameras/StereoCamera.js:95-167).
const _B3_STEREO_ORACLE = [
    (10.0, 0.064, 1.0, false) => ((1.1547005383792517, 1.7320508075688774, 0.0036950417228136146, 0.0),
        (0.9686214183778905, 2.0, 5.006275716324422), (1.0313785816221095, 2.0, 4.993724283675578)),
    (2.5, 0.5, 2.0, false) => ((2.3094010767585034, 3.464101615137755, 0.23094010767585035, 0.0),
        (0.75485483107727, 2.0, 5.049029033784546), (1.24514516892273, 2.0, 4.950970966215454)),
    (4.0, 0.3, 1.5, true) => ((1.4614178688862405, 7.794228634059949, 0.054803170083234064, 0.5000000000000001),
        (0.852912898646362, 2.0, 5.029417420270728), (1.147087101353638, 2.0, 4.970582579729272)),
]

_b3_ndc(eye, point) = begin
    clip = mat4_transform_vec4(projection_matrix(eye) * view_matrix(eye),
                               Vec4(point.x, point.y, point.z, 1.0))
    (clip.x / clip.w, clip.y / clip.w)
end

@testset "audit3b: StereoCamera builds three.js off-axis eye frusta" begin
    for ((focus, sep, zoom, offset), (left_m, left_p, right_p)) in _B3_STEREO_ORACLE
        camera = PerspectiveCamera(fov=60 * (π / 180), aspect=1.5, near=0.2,
                                   far=80.0, zoom=zoom, focus=focus)
        offset && Diff3D.set_view_offset!(camera, 1920, 1080, 480, 270, 640, 360)
        camera.position = Vec3(1.0, 2.0, 5.0)
        camera.target = Vec3(0.0, 0.0, 0.0)
        stereo = StereoCamera(eye_sep=sep)
        stereo_update!(stereo, camera)
        l = projection_matrix(stereo.cameraL).e
        r = projection_matrix(stereo.cameraR).e
        @test _b3_close((l[1], l[6], l[9], l[10]), left_m; atol=2e-15)
        # The right eye mirrors the horizontal shift (element 8).
        @test _b3_close((r[1], r[6], r[9], r[10]),
                        (left_m[1], left_m[2], -left_m[3], left_m[4]); atol=2e-15)
        @test _b3_close((l[11], l[15]), (-1.005012531328321, -0.4010025062656642); atol=4e-16)
        for (eye, expected) in ((stereo.cameraL, left_p), (stereo.cameraR, right_p))
            p = eye.position
            @test _b3_close((p.x, p.y, p.z), expected; atol=2e-15)
            # Parallel view axes: the eye keeps the base view direction.
            d = normalize(eye.target - eye.position)
            base = normalize(camera.target - camera.position)
            @test _b3_close((d.x, d.y, d.z), (base.x, base.y, base.z); atol=1e-15)
        end
    end
    # Zero separation reduces to the base projection.
    camera = PerspectiveCamera(fov=0.9, aspect=1.3, zoom=1.7)
    stereo = StereoCamera(eye_sep=0.0)
    stereo_update!(stereo, camera)
    @test projection_matrix(stereo.cameraL).e == projection_matrix(camera).e
    @test projection_matrix(stereo.cameraR).e == projection_matrix(camera).e
    # Zero parallax at the focal plane: a point on the base axis at the focus
    # distance projects to the image center in both eyes; a farther point has
    # uncrossed disparity.
    camera = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=20.0, focus=3.0)
    camera.position = Vec3(0.0, 0.0, 3.0)
    stereo = StereoCamera(eye_sep=0.2)
    stereo_update!(stereo, camera)
    @test _b3_close(_b3_ndc(stereo.cameraL, Vec3(0.0, 0.0, 0.0)), (0.0, 0.0); atol=1e-15)
    @test _b3_close(_b3_ndc(stereo.cameraR, Vec3(0.0, 0.0, 0.0)), (0.0, 0.0); atol=1e-15)
    @test _b3_ndc(stereo.cameraL, Vec3(0.0, 0.0, -3.0))[1] <
          _b3_ndc(stereo.cameraR, Vec3(0.0, 0.0, -3.0))[1]
    bad = PerspectiveCamera(focus=1.0)
    bad.focus = 0.0
    @test_throws ArgumentError stereo_update!(StereoCamera(), bad)
    if Base.JLOptions().opt_level > 0
        stereo_update!(stereo, camera)
        @test (@allocated stereo_update!(stereo, camera)) == 0
    end
end

# node: cube = new CubeCamera(0.5, 200, new WebGLCubeRenderTarget(8));
# cube.position.set(1,2,3); cube.coordinateSystem = WebGLCoordinateSystem;
# cube.updateCoordinateSystem(); cube.updateMatrixWorld(true); for each child
# c: projectionMatrix × matrixWorldInverse elements (src/cameras/CubeCamera.js:83-151).
# three.js uses fov = -90; the products agree with Diff3D's positive-fov,
# negated-up face cameras.
const _B3_CUBE_ORACLE = [
    (0.0, 0.0, 1.005012531328321, 1.0, 0.0, -1.0000000000000002, 0.0, 0.0,
     -1.0000000000000002, 0.0, 0.0, 0.0, 3.000000000000001, 2.0000000000000004,
     -2.0075187969924806, -0.9999999999999993),
    (0.0, 0.0, -1.005012531328321, -1.0, 0.0, -1.0000000000000002, 0.0, 0.0,
     1.0000000000000002, 0.0, 0.0, 0.0, -3.000000000000001, 2.0000000000000004,
     0.0025062656641612335, 1.0000000000000007),
    (1.0000000000000002, 0.0, 0.0, 0.0, 0.0, 0.0, 1.005012531328321, 1.0,
     0.0, 1.0000000000000002, 0.0, 0.0, -1.0000000000000002, -3.0000000000000013,
     -3.0125313283208013, -1.9999999999999993),
    (1.0000000000000002, 0.0, 0.0, 0.0, 0.0, 0.0, -1.005012531328321, -1.0,
     0.0, -1.0000000000000002, 0.0, 0.0, -1.0000000000000002, 3.0,
     1.0075187969924824, 2.000000000000001),
    (1.0000000000000002, 0.0, 0.0, 0.0, 0.0, -1.0000000000000002, 0.0, 0.0,
     0.0, 0.0, 1.005012531328321, 1.0, -1.0000000000000002, 2.0000000000000004,
     -4.017543859649123, -3.0),
    (-1.0000000000000002, 0.0, 0.0, 0.0, 0.0, -1.0000000000000002, 0.0, 0.0,
     0.0, 0.0, -1.005012531328321, -1.0, 1.0000000000000002, 2.0000000000000004,
     2.0125313283208026, 3.0),
]

function _b3_facing_quad!(scene, center::Vec3, color::Color3, size::Float64)
    mesh = Mesh(PlaneGeometry(width=size, height=size),
                MeshBasicMaterial(color=color, side=:double))
    mesh.position = center
    mesh.rotation = euler_from_quaternion(
        quat_from_unit_vectors(Vec3(0.0, 0.0, 1.0), normalize(-center)))
    add!(scene, mesh)
    return mesh
end

@testset "audit3b: CubeCamera faces match three.js and the cube-texture layout" begin
    cube = CubeCamera(near=0.5, far=200.0, position=Vec3(1.0, 2.0, 3.0))
    for (camera, expected) in zip(cube.cameras, _B3_CUBE_ORACLE)
        @test _b3_close((projection_matrix(camera) * view_matrix(camera)).e,
                        expected; atol=4e-15)
    end
    # Capture a scene whose six walls and six off-centre markers have
    # distinct colours. With rows reversed into WebGL order, sampling the
    # cube along any direction returns what is seen in that direction (the
    # three.js render-target cube texture contract), so neither face axis
    # is mirrored.
    axes = (Vec3(1.0, 0.0, 0.0), Vec3(-1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0),
            Vec3(0.0, -1.0, 0.0), Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, -1.0))
    walls = (Color3(1.0, 0.0, 0.0), Color3(0.0, 1.0, 1.0), Color3(0.0, 1.0, 0.0),
             Color3(1.0, 0.0, 1.0), Color3(0.0, 0.0, 1.0), Color3(1.0, 1.0, 0.0))
    markers = (Color3(1.0, 1.0, 1.0), Color3(0.5, 0.5, 0.5), Color3(1.0, 0.5, 0.0),
               Color3(0.0, 0.5, 1.0), Color3(0.5, 0.0, 1.0), Color3(0.5, 1.0, 0.0))
    scene = Scene()
    offsets = Vec3[]
    for (axis, wall, marker) in zip(axes, walls, markers)
        _b3_facing_quad!(scene, 5.0 * axis, wall, 10.0)
        # The other two axes in cyclic order, shifted by different amounts.
        u = Vec3(axis.y, axis.z, axis.x)
        v = Vec3(axis.z, axis.x, axis.y)
        offset = 2.75 * u + 1.25 * v
        push!(offsets, offset)
        _b3_facing_quad!(scene, 4.95 * axis + offset, marker, 1.2)
    end
    origin_cube = CubeCamera(near=0.1, far=100.0)
    faces = map(origin_cube.cameras) do camera
        target = RenderTarget(32, 32)
        render!(target, scene, camera)
        Texture(reverse(target.color; dims=1); wrap_s=:clamp, wrap_t=:clamp,
                filter=:nearest, colorspace=:linear)
    end
    environment = CubeTexture(Tuple(faces))
    for (axis, wall, marker, offset) in zip(axes, walls, markers, offsets)
        @test sample_cube(environment, axis) == wall
        @test sample_cube(environment, 4.95 * axis + offset) == marker
        u = Vec3(axis.y, axis.z, axis.x)
        v = Vec3(axis.z, axis.x, axis.y)
        @test sample_cube(environment, 4.95 * axis - 2.75 * u + 1.25 * v) == wall
        @test sample_cube(environment, 4.95 * axis + 2.75 * u - 1.25 * v) == wall
    end
end

# node rig: parent = Group with position (1,-2,0.5), rotation (0.3,-0.4,0.2,'XYZ'),
# scale (2,0.5,1.5); child = Object3D with position (0.5,1,-1), rotation
# (-0.2,0.7,0.1,'YXZ'), scale (1.2,0.8,1.1); parent.add(child);
# parent.updateMatrixWorld(true). Each expectation below applies one
# three.js call to a fresh rig (src/core/Object3D.js).
function _b3_rig()
    parent = Group()
    parent.position = Vec3(1.0, -2.0, 0.5)
    parent.rotation = Euler(0.3, -0.4, 0.2, :XYZ)
    parent.scale = Vec3(2.0, 0.5, 1.5)
    child = Object3D()
    child.position = Vec3(0.5, 1.0, -1.0)
    child.rotation = Euler(-0.2, 0.7, 0.1, :YXZ)
    child.scale = Vec3(1.2, 0.8, 1.1)
    add!(parent, child)
    return parent, child
end

_b3_euler(e::Euler) = (e.x, e.y, e.z)
_b3_vec(v::Vec3) = (v.x, v.y, v.z)

@testset "audit3b: Object3D rotate, translate and lookAt match three.js" begin
    # child.rotateOnAxis(new Vector3(0.6,0,0.8), 0.9) (Object3D.js:452-464).
    _, c = _b3_rig()
    @test Diff3D.rotate_on_axis!(c, Vec3(0.6, 0.0, 0.8), 0.9) === c
    @test _b3_close(_b3_euler(c.rotation),
                    (0.27230140869143943, 0.9386072633068203, 0.8464441350479441); atol=2e-15)
    @test c.rotation.order == :YXZ
    # child.rotateOnWorldAxis(new Vector3(0,0.6,0.8), -0.5) (Object3D.js:466-482).
    _, c = _b3_rig()
    Diff3D.rotate_on_world_axis!(c, Vec3(0.0, 0.6, 0.8), -0.5)
    @test _b3_close(_b3_euler(c.rotation),
                    (0.015008165482921016, 0.4276173052819045, -0.23761712002643362); atol=2e-15)
    # rotateX(0.3); rotateY(-1.1); rotateZ(2.0) (Object3D.js:484-516).
    _, c = _b3_rig()
    Diff3D.rotate_x!(c, 0.3); Diff3D.rotate_y!(c, -1.1); Diff3D.rotate_z!(c, 2.0)
    @test _b3_close(_b3_euler(c.rotation),
                    (0.13221131292760066, -0.37810251164834063, 1.9563035026406066); atol=4e-15)
    # translateOnAxis((0,0.6,0.8), 2.5); translateX(0.3); translateY(-0.7);
    # translateZ(1.1) (Object3D.js:518-566).
    _, c = _b3_rig()
    Diff3D.translate_on_axis!(c, Vec3(0.0, 0.6, 0.8), 2.5)
    Diff3D.translate_x!(c, 0.3); Diff3D.translate_y!(c, -0.7); Diff3D.translate_z!(c, 1.1)
    @test _b3_close(_b3_vec(c.position),
                    (2.5187764848680425, 2.425364205728319, 1.0573960205007469); atol=4e-15)
    # child.lookAt(3,4,-5) with a rotated, scaled parent (Object3D.js:609-643).
    _, c = _b3_rig()
    Diff3D.look_at!(c, Vec3(3.0, 4.0, -5.0))
    @test _b3_close(_b3_euler(c.rotation),
                    (-0.564375449333802, -2.959204431168959, 0.1833341232107495); atol=4e-15)
    # The world +z axis now points at the target.
    direction = Diff3D.get_world_direction(c)
    expected = normalize(Vec3(3.0, 4.0, -5.0) - Diff3D.get_world_position(c))
    # (A non-uniformly scaled parent shears the world basis, so compare loosely.)
    @test dot(direction, expected) > 0.9
    # cam = new PerspectiveCamera(); cam.position.set(0.5,1,-1); parent.add(cam);
    # cam.lookAt(3,4,-5): rotation (0.5719613004512871, 0.1538573050742357,
    # -0.281669594726074).
    p, _ = _b3_rig()
    camera = PerspectiveCamera()
    camera.position = Vec3(0.5, 1.0, -1.0)
    add!(p, camera)
    @test Diff3D.look_at!(camera, Vec3(3.0, 4.0, -5.0)) === camera
    @test _b3_close(_b3_euler(camera.rotation),
                    (0.5719613004512871, 0.1538573050742357, -0.281669594726074); atol=4e-15)
    # The target-aimed view looks at the world target too.
    world_position = Diff3D._camera_world_position(camera)
    @test _b3_close(_b3_vec(Diff3D.get_world_direction(camera)),
                    _b3_vec(normalize(Vec3(3.0, 4.0, -5.0) - world_position)); atol=1e-14)
    # Target-aimed cameras reject rotation updates that their view ignores.
    @test_throws ArgumentError Diff3D.rotate_x!(PerspectiveCamera(), 0.1)
    driven = PerspectiveCamera(rotation_driven=true)
    Diff3D.rotate_y!(driven, π / 2)
    @test _b3_close(_b3_vec(Diff3D.get_world_direction(driven)), (-1.0, 0.0, 0.0); atol=1e-15)
    # Translating a target-aimed camera moves along its view axes and keeps
    # its aim: translateZ(-2) moves forward.
    aimed = PerspectiveCamera()
    aimed.position = Vec3(0.0, 0.0, 5.0)
    Diff3D.translate_z!(aimed, -2.0)
    Diff3D.translate_x!(aimed, 1.0)
    @test _b3_close(_b3_vec(aimed.position), (1.0, 0.0, 3.0); atol=1e-15)
    @test _b3_close(_b3_vec(aimed.target), (1.0, 0.0, -2.0); atol=1e-15)
    @test_throws ArgumentError Diff3D.rotate_on_axis!(Object3D(), Vec3(NaN, 0.0, 0.0), 1.0)
    @test_throws ArgumentError Diff3D.translate_x!(Object3D(), Inf)
end

@testset "audit3b: Object3D world queries and attach match three.js" begin
    _, c = _b3_rig()
    # child.localToWorld / worldToLocal of (0.3,-0.4,2), getWorldPosition,
    # getWorldQuaternion, getWorldScale, getWorldDirection (Object3D.js:568-607,
    # 1107-1175).
    @test _b3_close(_b3_vec(Diff3D.local_to_world(c, Vec3(0.3, -0.4, 2.0))),
                    (4.650882998934757, -1.2810309882085085, 3.089380511089116); atol=8e-15)
    @test _b3_close(_b3_vec(Diff3D.world_to_local(c, Vec3(0.3, -0.4, 2.0))),
                    (-0.9985803885541287, 3.5424140192045774, 1.49320645374909); atol=8e-15)
    @test _b3_close(_b3_vec(Diff3D.get_world_position(c)),
                    (2.395335324188442, -1.0351245538111036, -0.2887044480752682); atol=4e-15)
    q = Diff3D.get_world_quaternion(c)
    @test _b3_close((q.x, q.y, q.z, q.w),
                    (-0.05623949599288058, 0.13900225665739435, 0.22821900161706882,
                     0.949023139049116); atol=4e-15)
    @test _b3_close(_b3_vec(Diff3D.get_world_scale(c)),
                    (2.1501856536772337, 0.5188925230963557, 1.8630875980547872); atol=4e-15)
    @test _b3_close(_b3_vec(Diff3D.get_world_direction(c)),
                    (0.40375795465626624, -0.06703041616805701, 0.9124069472335936); atol=4e-15)
    # p.scale.set(1.5,1.5,1.5); other = Group at (-3,1,2), rotation
    # (0.1,0.2,-0.3), scale 0.7; other.attach(child) (Object3D.js:874-908).
    # three.js documents attach for uniformly scaled ancestors only.
    p, c = _b3_rig()
    p.scale = Vec3(1.5, 1.5, 1.5)
    other = Group()
    other.position = Vec3(-3.0, 1.0, 2.0)
    other.rotation = Euler(0.1, 0.2, -0.3)
    other.scale = Vec3(0.7, 0.7, 0.7)
    world_before = compute_world_matrix(c)
    @test Diff3D.attach!(other, c) === other
    @test get_parent(c) === other && c in get_children(other) && !(c in get_children(p))
    @test _b3_close(_b3_vec(c.position),
                    (7.780036580046055, 0.4518126884044902, -1.4669382268488709); atol=1e-14)
    @test _b3_close(_b3_euler(c.rotation),
                    (-0.13990365450192, 0.0049287595842766345, 0.6149576006039283); atol=4e-15)
    @test c.rotation.order == :YXZ
    @test _b3_close(_b3_vec(c.scale),
                    (2.5714285714285725, 1.7142857142857146, 2.357142857142858); atol=1e-14)
    @test isapprox(collect(compute_world_matrix(c).e), collect(world_before.e); atol=1e-14)
    # A target-aimed camera keeps its world view when attached elsewhere.
    p, _ = _b3_rig()
    p.scale = Vec3(2.0, 2.0, 2.0)
    camera = PerspectiveCamera()
    camera.position = Vec3(0.5, 1.0, -1.0)
    camera.target = Vec3(0.0, 2.0, 0.0)
    add!(p, camera)
    view_before = view_matrix(camera)
    Diff3D.attach!(other, camera)
    @test isapprox(collect(view_matrix(camera).e), collect(view_before.e); atol=1e-13)
    @test_throws ArgumentError Diff3D.attach!(c, other)
    singular = Group()
    singular.scale = Vec3(0.0, 1.0, 1.0)
    @test_throws ArgumentError Diff3D.attach!(singular, Object3D())
end

@testset "audit3b: Object3D traversal, lookup and removal match three.js" begin
    root = Group(name="root")
    a = Group(name="a")
    b = Object3D(name="b")
    hidden = Group(name="hidden")
    hidden.visible = false
    leaf = Object3D(name="leaf")
    twin = Object3D(name="b")
    add!(root, a); add!(a, b); add!(root, hidden); add!(hidden, leaf); add!(root, twin)
    visited = String[]
    Diff3D.traverse_visible(root, node -> push!(visited, node.name))
    # traverseVisible skips invisible subtrees (Object3D.js:1265-1279).
    @test visited == ["root", "a", "b", "b"]
    ancestors = String[]
    Diff3D.traverse_ancestors(leaf, node -> push!(ancestors, node.name))
    # traverseAncestors visits parents only (Object3D.js:1281-1295).
    @test ancestors == ["hidden", "root"]
    # getObjectByName returns the first pre-order match (Object3D.js:1035-1071).
    @test Diff3D.get_object_by_name(root, "b") === b
    @test Diff3D.get_object_by_name(root, "missing") === nothing
    @test Diff3D.get_object_by_id(root, leaf.id) === leaf
    @test Diff3D.get_object_by_property(root, :visible, false) === hidden
    @test Diff3D.get_object_by_property(root, :no_such_field, 1) === nothing
    # removeFromParent / clear (Object3D.js:747-779).
    @test Diff3D.remove_from_parent!(twin) === twin && get_parent(twin) === nothing
    @test !(twin in get_children(root))
    @test Diff3D.remove_from_parent!(twin) === twin
    @test Diff3D.clear_children!(root) === root
    @test isempty(get_children(root)) && get_parent(a) === nothing &&
          get_parent(hidden) === nothing
end

# Oracle values below come from node running three.js r186 on the same inputs
# (src/math/Vector3.js, Matrix4.js, Sphere.js, Box3.js, Plane.js, Ray.js,
# Triangle.js, MathUtils.js); the three.js method is named by each check.
_b3_v(v) = (v.x, v.y, v.z)
_b3_allocations(f::F) where {F} = (f(); @allocated f())

@testset "audit3b: Vector3 and Matrix4 additions match three.js" begin
    a = Vec3(1.5, -2.0, 0.75); b = Vec3(-0.5, 3.0, 2.25); n = Vec3(0.6, 0.0, 0.8)
    @test Diff3D.vec3_distance_squared(a, b) == 31.25              # distanceToSquared
    @test Diff3D.vec3_manhattan_distance(a, b) == 8.5              # manhattanDistanceTo
    @test isapprox(Diff3D.vec3_angle_to(a, b), 2.1091101750488965; atol=4e-16)  # angleTo
    @test Diff3D.vec3_angle_to(a, Vec3()) == 1.5707963267948966
    @test _b3_close(_b3_v(Diff3D.vec3_project_on_vector(a, b)),     # projectOnVector
                    (0.17685589519650655, -1.0611353711790392, -0.7958515283842794))
    @test _b3_close(_b3_v(Diff3D.vec3_project_on_plane(a, n)),      # projectOnPlane
                    (0.6000000000000001, -2.0, -0.4500000000000002))
    @test _b3_close(_b3_v(Diff3D.vec3_reflect(a, n)),               # reflect
                    (-0.2999999999999998, -2.0, -1.6500000000000004))
    @test _b3_close(_b3_v(Diff3D.vec3_clamp_length(a, 0.5, 1.25)),  # clampLength
                    (0.7183697139158635, -0.9578262852211514, 0.35918485695793173))
    @test _b3_close(_b3_v(Diff3D.vec3_clamp_length(Vec3(0.1, 0.2, 0.1), 1, 2)),
                    (0.40824829046386296, 0.8164965809277259, 0.40824829046386296))
    @test Diff3D.vec3_clamp_length(Vec3(), 1.0, 2.0) == Vec3()
    @test _b3_close(_b3_v(Diff3D.vec3_apply_axis_angle(a, n, 1.1)), # applyAxisAngle
                    (2.598089448953643, -0.2387867228050778, -0.0735670867152321); atol=1e-15)
    @test _b3_close(_b3_v(Diff3D.vec3_apply_euler(a, Euler(0.3, -0.7, 1.2, :ZXY))),  # applyEuler
                    (2.445624195739401, -0.23828493859032893, 0.8801378194663654); atol=1e-15)
    @test Diff3D.vec3_clamp(a, Vec3(-1.0, -1.0, -1.0), Vec3(1.0, 1.0, 0.5)) == Vec3(1.0, -1.0, 0.5)
    @test Diff3D.vec3_min(a, b) == Vec3(-0.5, -2.0, 0.75)
    @test Diff3D.vec3_max(a, b) == Vec3(1.5, 3.0, 2.25)
    # m = compose((1,2,3), quaternion of Euler(0.3,-0.4,0.5), (2,0.5,1.5)).
    m = mat4_compose(Vec3(1.0, 2.0, 3.0), quat_from_euler(0.3, -0.4, 0.5), Vec3(2.0, 0.5, 1.5))
    @test isapprox(Diff3D.mat4_max_scale_on_axis(m), 1.9999999999999998; atol=4e-16)  # getMaxScaleOnAxis
    @test _b3_close(_b3_v(Diff3D.mat4_get_scale(m)), (1.9999999999999998, 0.49999999999999994, 1.5))
    @test Diff3D.mat4_get_position(m) == Vec3(1.0, 2.0, 3.0)
    @test Diff3D.mat4_get_column(m, 4) == Vec4(1.0, 2.0, 3.0, 1.0)
    @test_throws ArgumentError Diff3D.mat4_get_column(m, 5)
    @test _b3_close(Diff3D.mat4_make_rotation_axis(n, 0.9).e,         # makeRotationAxis
                    (0.7578303796932252, 0.6266615277019868, 0.18162721523008107, 0.0,
                     -0.6266615277019868, 0.6216099682706644, 0.46999614577649, 0.0,
                     0.18162721523008107, -0.46999614577649, 0.8637795885774392, 0.0,
                     0.0, 0.0, 0.0, 1.0))
    @test Diff3D.mat4_make_shear(0.1, 0.2, 0.3, 0.4, 0.5, 0.6).e ==  # makeShear
          (1.0, 0.1, 0.2, 0.0, 0.3, 1.0, 0.4, 0.0, 0.5, 0.6, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)
    @test _b3_close(Diff3D.mat4_extract_rotation(m).e,                # extractRotation
                    (0.8083070667743454, 0.35701964169862993, 0.4681630712092062, 0.0,
                     -0.44158016313715576, 0.893559408727084, 0.08098482943778701, 0.0,
                     -0.38941834230865036, -0.27219213529543135, 0.8799231762812572, 0.0,
                     0.0, 0.0, 0.0, 1.0); atol=2e-16)
    x, y, z = Diff3D.mat4_extract_basis(m)                           # extractBasis/makeBasis
    @test Diff3D.mat4_make_basis(x, y, z).e == Diff3D.mat4_set_position(m, Vec3()).e
    @test Diff3D.mat4_set_position(m, Vec3(4, 5, 6)).e[13:15] == (4.0, 5.0, 6.0)
end

@testset "audit3b: Sphere, Box3 and Plane additions match three.js" begin
    s = BoundingSphere(Vec3(1.0, 2.0, 3.0), 2.5)
    @test Diff3D.sphere_contains_point(s, Vec3(2.0, 3.0, 4.0))       # containsPoint
    @test !Diff3D.sphere_contains_point(s, Vec3(4.0, 2.0, 3.0))
    @test Diff3D.sphere_distance_to_point(s, Vec3(5.0, 2.0, 3.0)) == 1.5
    @test _b3_close(_b3_v(Diff3D.sphere_clamp_point(s, Vec3(5.0, 6.0, 3.0))),  # clampPoint
                    (2.767766952966369, 3.767766952966369, 3.0))
    @test Diff3D.sphere_clamp_point(s, Vec3(1.5, 2.0, 3.0)) == Vec3(1.5, 2.0, 3.0)
    m = mat4_compose(Vec3(1.0, 2.0, 3.0), quat_from_euler(0.3, -0.4, 0.5), Vec3(2.0, 0.5, 1.5))
    t = Diff3D.sphere_apply_matrix4(s, m)                             # applyMatrix4
    @test _b3_close((_b3_v(t.center)..., t.radius),
                    (0.4226514300226081, 2.382734083294902, 7.976965265121857, 4.999999999999999); atol=2e-15)
    t = Diff3D.sphere_expand_by_point(s, Vec3(6.0, 2.0, 3.0))       # expandByPoint
    @test (_b3_v(t.center)..., t.radius) == (2.25, 2.0, 3.0, 3.75)
    t = Diff3D.sphere_union(s, BoundingSphere(Vec3(-2.0, 0.0, 1.0), 1.5))  # union
    @test _b3_close((_b3_v(t.center)..., t.radius),
                    (-0.1361965624455006, 1.242535625036333, 2.242535625036333, 4.061552812808831); atol=2e-15)
    empty = BoundingSphere(Vec3(), -1.0)
    @test Diff3D.sphere_union(empty, s) === s && Diff3D.sphere_union(s, empty) === s
    @test Diff3D.sphere_expand_by_point(empty, Vec3(1.0, 1.0, 1.0)) == BoundingSphere(Vec3(1.0, 1.0, 1.0), 0.0)
    @test Diff3D.sphere_intersects_plane(s, Plane(Vec3(0.0, 1.0, 0.0), -4.0))    # intersectsPlane
    @test !Diff3D.sphere_intersects_plane(s, Plane(Vec3(0.0, 1.0, 0.0), -5.0))
    @test Diff3D.sphere_intersects_sphere(s, BoundingSphere(Vec3(4.0, 2.0, 3.0), 0.5))
    @test !Diff3D.sphere_intersects_sphere(s, BoundingSphere(Vec3(4.0, 2.0, 3.0), 0.4))
    bb = Diff3D.sphere_bounding_box(s)                                # getBoundingBox
    @test bb.min == Vec3(-1.5, -0.5, 0.5) && bb.max == Vec3(3.5, 4.5, 5.5)
    @test box3_is_empty(Diff3D.sphere_bounding_box(empty))

    box = Box3(Vec3(-1.0, -2.0, -3.0), Vec3(2.0, 1.0, 0.5))
    @test Diff3D.box3_clamp_point(box, Vec3(3.0, -5.0, 0.0)) == Vec3(2.0, -2.0, 0.0)  # clampPoint
    @test Diff3D.box3_distance_to_point(box, Vec3(3.0, -5.0, 0.0)) == 3.1622776601683795
    bs = Diff3D.box3_bounding_sphere(box)                             # getBoundingSphere
    @test (_b3_v(bs.center)..., bs.radius) == (0.5, -0.5, -1.25, 2.75)
    @test Diff3D.box3_bounding_sphere(Box3()).radius == -1.0
    @test Diff3D.box3_intersects_sphere(box, BoundingSphere(Vec3(3.0, 2.0, 1.0), 1.5))
    @test !Diff3D.box3_intersects_sphere(box, BoundingSphere(Vec3(3.0, 2.0, 1.0), 1.0))
    @test Diff3D.sphere_intersects_box(BoundingSphere(Vec3(3.0, 2.0, 1.0), 1.5), box)
    @test Diff3D.box3_intersects_plane(box, Plane(Vec3(0.6, 0.0, 0.8), -1.5))  # intersectsPlane
    @test !Diff3D.box3_intersects_plane(box, Plane(Vec3(0.6, 0.0, 0.8), -2.5))
    @test Diff3D.plane_intersects_box(Plane(Vec3(0.6, 0.0, 0.8), -1.5), box)

    pl = Diff3D.plane_from_coplanar_points(Vec3(1.0, 0.0, 0.0), Vec3(0.0, 2.0, 0.0), Vec3(0.0, 0.0, 3.0))
    @test _b3_close((_b3_v(pl.normal)..., pl.constant),                # setFromCoplanarPoints
                    (0.8571428571428571, 0.42857142857142855, 0.2857142857142857, -0.8571428571428571))
    @test _b3_close(_b3_v(Diff3D.plane_project_point(pl, Vec3(2.0, 2.0, 2.0))),  # projectPoint
                    (0.040816326530612734, 1.0204081632653064, 1.3469387755102042); atol=1e-15)
    @test _b3_close(_b3_v(Diff3D.plane_coplanar_point(pl)),           # coplanarPoint
                    (0.7346938775510203, 0.36734693877551017, 0.24489795918367344))
    segment = Line3(Vec3(0.0, 0.0, 0.0), Vec3(2.0, 2.0, 2.0))
    @test _b3_close(_b3_v(Diff3D.plane_intersect_line(pl, segment)),  # intersectLine
                    (0.5454545454545455, 0.5454545454545455, 0.5454545454545455))
    @test Diff3D.plane_intersect_line(pl, Line3(Vec3(), Vec3(0.1, 0.1, 0.1))) === nothing
    @test Diff3D.plane_intersect_line(pl, Line3(Vec3(), Vec3(0.1, 0.1, 0.1)); clamp_to_line=false) isa Vec3
    @test Diff3D.plane_intersects_line(pl, segment)                   # intersectsLine
    @test !Diff3D.plane_intersects_line(pl, Line3(Vec3(), Vec3(0.1, 0.1, 0.1)))
    t = Diff3D.plane_apply_matrix4(pl, m)                             # applyMatrix4
    @test _b3_close((_b3_v(t.normal)..., t.constant),
                    (-0.10874947667359885, 0.8874268979816132, 0.44793643752428747,
                     -3.8871799537539324); atol=2e-15)
    t = Diff3D.plane_normalize(Plane(Vec3(0.0, 3.0, 4.0), 10.0))      # normalize
    @test _b3_close((_b3_v(t.normal)..., t.constant), (0.0, 0.6000000000000001, 0.8, 2.0))
    @test Diff3D.plane_intersects_sphere(Plane(Vec3(0.0, 1.0, 0.0), -4.0), s)
    @test Diff3D.plane_from_normal_and_coplanar_point(Vec3(0.0, 1.0, 0.0), Vec3(3.0, 2.0, 1.0)) ==
          Plane(Vec3(0.0, 1.0, 0.0), -2.0)
end

@testset "audit3b: Ray and Triangle additions match three.js" begin
    direction = normalize(Vec3(1.0, 0.1, -0.05))
    ray = Ray(Vec3(-4.0, 0.5, 0.25), direction)
    @test _b3_close(_b3_v(Diff3D.ray_at(ray, 2.5)),                    # at
                    (-1.5154800250002336, 0.7484519974999766, 0.12577400125001167))
    @test _b3_close(_b3_v(Diff3D.ray_closest_point_to_point(ray, Vec3(1.0, 2.0, 3.0))),
                    (0.950617283950618, 0.9950617283950618, 0.0024691358024690746); atol=1e-15)
    @test Diff3D.ray_closest_point_to_point(ray, Vec3(-9.0, 0.0, 0.0)) == ray.origin
    @test isapprox(Diff3D.ray_distance_sq_to_point(ray, Vec3(1.0, 2.0, 3.0)),
                   9.997530864197532; atol=4e-15)                      # distanceSqToPoint
    @test isapprox(Diff3D.ray_distance_to_point(ray, Vec3(1.0, 2.0, 3.0)),
                   sqrt(9.997530864197532); atol=4e-15)
    for (v0, v1, expected) in (
            (Vec3(0.0, -1.0, 1.0), Vec3(1.0, 2.0, -1.0),            # distanceSqToSegment
             (0.07388456815390754, 0.5988538681948432, 0.9598853868194843, 0.020057306590257812,
              0.6027425296766271, 0.8082275890298813, -0.2054850593532542)),
            (Vec3(-6.0, 3.0, 0.0), Vec3(-5.0, 4.0, 1.0),
             (10.3125, -4.0, 0.5, 0.25, -6.0, 3.0, 0.0)))
        d, on_ray, on_segment = Diff3D.ray_distance_sq_to_segment(ray, v0, v1)
        @test _b3_close((d, _b3_v(on_ray)..., _b3_v(on_segment)...), expected; atol=2e-15)
    end
    @test _b3_close(_b3_v(Diff3D.ray_intersect_sphere(ray, BoundingSphere(Vec3(1.0, 1.0, 0.0), 1.2))),
                    (-0.192569587999889, 0.8807430412000111, 0.05962847939999444); atol=2e-15)
    @test Diff3D.ray_intersect_sphere(Ray(Vec3(1.0, 1.0, 0.0), Vec3(0.0, 1.0, 0.0)),
                                      BoundingSphere(Vec3(1.0, 1.0, 0.0), 1.2)) == Vec3(1.0, 2.2, 0.0)
    @test Diff3D.ray_intersect_sphere(ray, BoundingSphere(Vec3(1.0, 5.0, 0.0), 1.2)) === nothing
    @test Diff3D.ray_intersect_sphere(ray, BoundingSphere(Vec3(), -1.0)) === nothing
    @test Diff3D.ray_intersects_sphere(ray, BoundingSphere(Vec3(1.0, 1.0, 0.0), 1.2))
    box = Box3(Vec3(-1.0, -2.0, -3.0), Vec3(2.0, 1.0, 0.5))
    @test _b3_close(_b3_v(Diff3D.ray_intersect_box(ray, box)),         # intersectBox
                    (-1.0, 0.8, 0.09999999999999998); atol=2e-16)
    @test Diff3D.ray_intersect_box(Ray(Vec3(-4.0, 5.0, 0.0), Vec3(1.0, 0.0, 0.0)), box) === nothing
    @test Diff3D.ray_intersects_box(ray, box)
    pl = Diff3D.plane_from_coplanar_points(Vec3(1.0, 0.0, 0.0), Vec3(0.0, 2.0, 0.0), Vec3(0.0, 0.0, 3.0))
    @test isapprox(Diff3D.ray_distance_to_plane(ray, pl), 4.544267180080217; atol=4e-15)
    @test _b3_close(_b3_v(Diff3D.ray_intersect_plane(ray, pl)),        # intersectPlane
                    (0.5161290322580641, 0.9516129032258065, 0.02419354838709678); atol=2e-15)
    @test Diff3D.ray_intersects_plane(ray, pl)
    @test Diff3D.ray_intersect_plane(Ray(Vec3(), Vec3(1.0, 0.0, 0.0)), Plane(Vec3(0.0, 1.0, 0.0), 1.0)) === nothing
    @test Diff3D.ray_distance_to_plane(Ray(Vec3(), Vec3(1.0, 0.0, 0.0)), Plane(Vec3(0.0, 1.0, 0.0), 0.0)) == 0.0
    m = mat4_compose(Vec3(1.0, 2.0, 3.0), quat_from_euler(0.3, -0.4, 0.5), Vec3(2.0, 0.5, 1.5))
    t = Diff3D.ray_apply_matrix4(ray, m)                               # applyMatrix4
    @test _b3_close((_b3_v(t.origin)..., _b3_v(t.direction)...),
                    (-5.722883453344794, -0.7348393321430549, -0.3950871712087305,
                     0.8110474483388243, 0.38917078092610624, 0.43674722645535674); atol=4e-15)

    tri = Triangle(Vec3(0.0, 0.0, 0.0), Vec3(2.0, 0.0, 0.0), Vec3(0.0, 3.0, 1.0))
    for (point, expected) in zip(                                       # closestPointToPoint
            (Vec3(1.0, 1.0, 2.0), Vec3(-1.0, -1.0, 0.0), Vec3(3.0, -1.0, 0.0),
             Vec3(2.0, 3.0, 0.0), Vec3(-1.0, 1.0, 0.5)),
            ((1.0, 1.5, 0.5), (0.0, 0.0, 0.0), (2.0, 0.0, 0.0),
             (0.7142857142857142, 1.9285714285714288, 0.6428571428571429),
             (0.0, 1.0499999999999998, 0.35)))
        @test _b3_close(_b3_v(Diff3D.triangle_closest_point_to_point(tri, point)), expected; atol=2e-16)
    end
    tp = Diff3D.triangle_plane(tri)                                     # getPlane
    @test _b3_close((_b3_v(tp.normal)..., tp.constant),
                    (0.0, -0.31622776601683794, 0.9486832980505138, 0.0))
    @test !Diff3D.triangle_is_front_facing(tri, Vec3(0.0, 0.0, 1.0))    # isFrontFacing
    @test Diff3D.triangle_is_front_facing(tri, Vec3(0.0, 0.0, -1.0))
end

@testset "audit3b: MathUtils and projection helpers match three.js" begin
    @test isapprox(Diff3D.map_linear(0.3, -1, 2, 10, 20), 14.333333333333332; atol=2e-15)
    @test Diff3D.inverse_lerp(2, 6, 3.5) == 0.375
    @test Diff3D.inverse_lerp(2, 2, 3) == 0
    @test isapprox(Diff3D.damp(1, 5, 2.5, 0.1), 1.8847968677143805; atol=4e-16)
    @test isapprox(Diff3D.pingpong(2.7, 1), 0.7000000000000002; atol=4e-16)
    @test isapprox(Diff3D.pingpong(-0.3, 2), 0.2999999999999998; atol=4e-16)
    @test isapprox(Diff3D.smoothstep(0.3, 0, 2), 0.06075; atol=2e-17)
    @test Diff3D.smoothstep(-1, 0, 2) == 0 && Diff3D.smoothstep(5, 0, 2) == 1
    @test isapprox(Diff3D.smootherstep(0.3, 0, 2), 0.026611875; atol=2e-17)
    @test (@inferred Diff3D.smoothstep(0.3, 0.0, 2.0)) isa Float64
    @test (@inferred Diff3D.smoothstep(-1.0, 0.0, 2.0)) isa Float64
    # node: camera = new PerspectiveCamera(50, 1.6, 0.25, 300) at (1,2,5)
    # looking at the origin; (0.5,-0.3,0.7).project(camera) and
    # (0.2,-0.4,0.3).unproject(camera).
    camera = PerspectiveCamera(fov=50 * (π / 180), aspect=1.6, near=0.25, far=300.0)
    camera.position = Vec3(1.0, 2.0, 5.0)
    @test _b3_close(_b3_v(Diff3D.vec3_project(Vec3(0.5, -0.3, 0.7), camera)),
                    (0.09742542102431778, -0.24981368656516142, 0.8986268210654555); atol=1e-14)
    @test _b3_close(_b3_v(Diff3D.vec3_unproject(Vec3(0.2, -0.4, 0.3), camera)),
                    (0.9836707980158728, 1.615743330362947, 4.3757167918529785); atol=1e-13)
end

@testset "audit3b: math additions are generic, type stable and allocation free" begin
    a32 = Vec3(1.5f0, -2.0f0, 0.75f0); b32 = Vec3(-0.5f0, 3.0f0, 2.25f0)
    @test (@inferred Diff3D.vec3_angle_to(a32, b32)) isa Float32
    @test (@inferred Diff3D.vec3_angle_to(a32, Vec3(0f0, 0f0, 0f0))) isa Float32
    @test (@inferred Diff3D.vec3_project_on_vector(a32, b32)) isa Vec3{Float32}
    @test (@inferred Diff3D.vec3_project_on_vector(a32, Vec3(0f0, 0f0, 0f0))) isa Vec3{Float32}
    @test (@inferred Diff3D.vec3_clamp_length(a32, 0.5f0, 1.0f0)) isa Vec3{Float32}
    ray32 = Ray(Vec3(-4f0, 0.5f0, 0.25f0), normalize(Vec3(1f0, 0.1f0, -0.05f0)))
    @test (@inferred Diff3D.ray_distance_sq_to_segment(ray32, a32, b32))[1] isa Float32
    box32 = Box3(Vec3(-1f0, -2f0, -3f0), Vec3(2f0, 1f0, 0.5f0))
    @test (@inferred Diff3D.box3_bounding_sphere(box32)) isa BoundingSphere{Float32}
    tri32 = Triangle(Vec3(0f0, 0f0, 0f0), Vec3(2f0, 0f0, 0f0), Vec3(0f0, 3f0, 1f0))
    @test (@inferred Diff3D.triangle_closest_point_to_point(tri32, a32)) isa Vec3{Float32}
    # ForwardDiff: derivative of the ray-to-point distance along the point's x
    # equals the x component of the unit offset (analytic).
    ray = Ray(Vec3(-4.0, 0.5, 0.25), normalize(Vec3(1.0, 0.1, -0.05)))
    g = ForwardDiff.derivative(x -> Diff3D.ray_distance_to_point(ray, Vec3(x, 2.0, 3.0)), 1.0)
    closest = Diff3D.ray_closest_point_to_point(ray, Vec3(1.0, 2.0, 3.0))
    @test isapprox(g, normalize(Vec3(1.0, 2.0, 3.0) - closest).x; atol=1e-14)
    # A zero-valued Dual with nonzero partials still takes the zero-vector
    # branch through its primal value.
    zero_dual = ForwardDiff.Dual(0.0, 1.0)
    @test Diff3D.vec3_angle_to(Vec3(zero_dual, zero_dual, zero_dual), Vec3(1.0, 0.0, 0.0)) ≈ π / 2
    @test ForwardDiff.derivative(t -> Diff3D.smoothstep(t, 0.0, 2.0), 0.5) ≈ 6 * 0.25 * 0.75 / 2
    if Base.JLOptions().opt_level > 0
        # `let` makes the closures capture typed locals; the helper is a
        # function barrier so only the call under test is measured.
        let ray = ray, s = BoundingSphere(Vec3(1.0, 2.0, 3.0), 2.5),
            m = mat4_compose(Vec3(1.0, 2.0, 3.0), quat_from_euler(0.3, -0.4, 0.5), Vec3(2.0, 0.5, 1.5))
            checks = (() -> Diff3D.ray_intersect_box(ray, Box3(Vec3(-1.0, -2.0, -3.0), Vec3(2.0, 1.0, 0.5))),
                      () -> Diff3D.ray_distance_sq_to_segment(ray, Vec3(0.0, -1.0, 1.0), Vec3(1.0, 2.0, -1.0)),
                      () -> Diff3D.sphere_union(s, BoundingSphere(Vec3(-2.0, 0.0, 1.0), 1.5)),
                      () -> Diff3D.sphere_apply_matrix4(s, m),
                      () -> Diff3D.plane_apply_matrix4(Plane(Vec3(0.0, 1.0, 0.0), -2.0), m),
                      () -> Diff3D.mat4_set_position(m, Vec3()))
            for check in checks
                @test _b3_allocations(check) == 0
            end
        end
    end
end

@testset "audit3b: Matrix3 additions match three.js" begin
    # node: a = new Matrix3().set(2,-1,0.5, 0.25,3,-2, 1,0.75,4) (row-major
    # arguments), b = set(-1,0.5,2, 3,1,-0.25, 0.5,2,1) (src/math/Matrix3.js).
    a = Mat3((2.0, 0.25, 1.0, -1.0, 3.0, 0.75, 0.5, -2.0, 4.0))
    b = Mat3((-1.0, 3.0, 0.5, 0.5, 1.0, 2.0, 2.0, -0.25, 1.0))
    @test Diff3D.mat3_determinant(a) == 28.59375                      # determinant
    @test _b3_close(Diff3D.mat3_inverse(a).e,                          # invert
                    (0.4721311475409836, -0.10491803278688525, -0.09836065573770492,
                     0.15300546448087432, 0.26229508196721313, -0.08743169398907104,
                     0.017486338797814208, 0.14426229508196722, 0.2185792349726776); atol=1e-16)
    @test (a * b).e == (-4.75, 7.75, 3.25, 1.0, -0.875, 9.25, 4.75, -2.25, 5.8125)  # multiplyMatrices
    m = mat4_compose(Vec3(1.0, 2.0, 3.0), quat_from_euler(0.3, -0.4, 0.5), Vec3(2.0, 0.5, 1.5))
    @test _b3_close(Diff3D.mat3_normal_matrix(m).e,                    # getNormalMatrix
                    (0.40415353338717264, 0.178509820849315, 0.234081535604603,
                     -0.8831603262743114, 1.7871188174541672, 0.16196965887557416,
                     -0.2596122282057669, -0.18146142353028752, 0.5866154508541714); atol=2e-15)
    @test _b3_close(Diff3D.mat3_set_uv_transform(0.1, -0.2, 2, 0.5, 0.7, 0.5, 0.25).e,  # setUvTransform
                    (1.529684374568977, -0.3221088436188455, 0.0, 1.288435374475382,
                     0.38242109364224425, 0.0, -0.48695103090333414, 0.11544914839886167, 1.0);
                    atol=4e-16)
    @test Diff3D.mat3_transform_vec3(a, Vec3(1.5, -2.0, 0.75)) == Vec3(5.375, -7.125, 3.0)  # applyMatrix3
    singular = Mat3((1.0, 2.0, 0.0, 2.0, 4.0, 1.0, 3.0, 6.0, 1.0))
    @test Diff3D.mat3_inverse(singular).e == ntuple(_ -> 0.0, 9)
    @test Diff3D.mat3_transpose(Diff3D.mat3_transpose(a)) === a
    @test Diff3D.mat3_from_mat4(mat4_translation(1.0, 2.0, 3.0)) === Mat3()
    @test (@inferred Diff3D.mat3_inverse(Mat3{Float32}(Float32.(a.e)))) isa Mat3{Float32}
    @test (@inferred Diff3D.mat3_set_uv_transform(0f0, 0f0, 1f0, 1f0, 0.5f0, 0f0, 0f0)) isa Mat3{Float32}
end

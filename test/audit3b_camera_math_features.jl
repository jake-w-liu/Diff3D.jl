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

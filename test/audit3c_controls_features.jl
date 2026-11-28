using Test, Diff3D

# Oracles: node v26 running three.js r186 (benchmarks/threejs/node_modules/three)
# with a stubbed DOM element; each control's private event handlers are called
# with the same event sequence the Julia calls below replay, and the camera
# state is printed with full precision after every step.

_c3_vec(v) = (v.x, v.y, v.z)
_c3_close(a, b; atol=1e-12) = all(abs.(_c3_vec(a) .- b) .<= atol)

# ---- FirstPersonControls ----------------------------------------------------

function _c3_first_person_camera(; rotation_driven=false)
    cam = PerspectiveCamera(fov=π / 3, aspect=1.0, near=0.1, far=100.0;
                            rotation_driven=rotation_driven)
    cam.position = Vec3(1.0, 2.0, 3.0)
    cam.target = Vec3(4.0, 1.0, -2.0)
    if rotation_driven
        # Same aim expressed as a rotation (three.js camera.lookAt(4, 1, -2)).
        cam.rotation = Diff3D._rotation_matrix_to_euler(
            mat4_transpose(mat4_look_at(cam.position, cam.target, cam.up)), :XYZ)
    end
    return cam
end

function _c3_first_person_run(fc, steps)
    states = Any[]
    look(fc) = normalize(Diff3D._camera_control_target(fc.camera) - fc.camera.position)
    push!(states, (p=fc.camera.position, d=look(fc), lat=fc.lat, lon=fc.lon))
    for s in steps
        haskey(s, :k) && Diff3D.first_person_key_down!(fc, s.k)
        haskey(s, :ku) && Diff3D.first_person_key_up!(fc, s.ku)
        haskey(s, :pd) && Diff3D.first_person_pointer_down!(
            fc, s.pd...; button=get(s, :b, 0), pointer_type=get(s, :t, :mouse))
        haskey(s, :pm) && Diff3D.first_person_pointer_move!(fc, s.pm...)
        haskey(s, :pu) && Diff3D.first_person_pointer_up!(
            fc; button=get(s, :b, 0), pointer_type=get(s, :t, :mouse))
        haskey(s, :la) && Diff3D.first_person_look_at!(fc, Vec3(s.la...))
        haskey(s, :dt) && Diff3D.first_person_update!(fc, s.dt)
        push!(states, (p=fc.camera.position, d=look(fc), lat=fc.lat, lon=fc.lon,
                       v=fc.velocity))
    end
    return states
end

const _C3_FP_STEPS1 = [
    (k="KeyW", dt=0.1), (dt=0.2,), (k="KeyD", dt=0.15), (k="KeyR", dt=0.1),
    (ku="KeyW", dt=0.1), (pd=(100, 120), dt=0.05), (pm=(160, 90), dt=0.1),
    (pm=(40, 200), dt=0.12), (pu=true, dt=0.1), (ku="KeyD", k="ArrowDown", dt=0.1),
    (pd=(10, 10), b=2, dt=0.1), (pu=true, b=2, dt=0.1), (ku="ArrowDown", dt=0.3),
    (la=(0, 5, 0), dt=0.1), (dt=0.1,)]
const _C3_FP_STEPS2 = [
    (dt=0.1,), (dt=0.1,), (pd=(50, 50), dt=0.1), (pm=(90, 10), dt=0.2),
    (pm=(-300, 400), dt=0.25), (dt=0.3,), (pu=true, dt=0.1),
    (pd=(0, 0), t=:touch, dt=0.1), (pd=(5, 5), t=:touch, dt=0.1),
    (pu=true, t=:touch, dt=0.1), (pu=true, t=:touch, dt=0.1),
    (k="KeyS", dt=0.2), (k="KeyF", dt=0.2)]

@testset "FirstPersonControls follows three.js r186" begin
    # FirstPersonControls.js:222-331 (update), 335-345 (_setOrientation),
    # 359-512 (event handlers); oracle states (position, look direction,
    # lat/lon in degrees, velocity) from node.
    expected_base = Dict(
        0 => (p=(1.0, 2.0, 3.0), d=(0.5070925528371102, -0.1690308509457033, -0.8451542547285166), lat=-9.73147547315763, lon=149.03624346792648),
        5 => (p=(1.1051921903055124, 2.018040722926468, 2.9038617755290783), d=(0.5070925528371103, -0.1690308509457033, -0.8451542547285165), lat=-9.73147547315763, lon=149.03624346792648, v=(0.2817688789494424, 0.12267220234572107, -0.11985904278651766)),
        9 => (p=(1.2799826187798726, 2.102884641075821, 2.835103679030908), d=(0.5071213399110077, -0.16910077727183292, -0.8451229932577424), lat=-9.73554047315763, lon=149.0338734679265, v=(0.5170692354755795, 0.2824349517592809, -0.15965293924858595)),
        13 => (p=(1.4608387225287385, 2.348769890968674, 2.8431195196431522), d=(0.5070878172267238, -0.169281591115324, -0.8451069095266592), lat=-9.74605188365763, lon=149.0350634389265, v=(0.2505119978686516, 0.45776891578066314, 0.04313452232188878)),
        15 => (p=(1.503676274164278, 2.456048375567167, 2.850495522960195), d=(-0.3517825900711667, 0.6383718797599914, -0.6846388481926194), lat=39.670521533003125, lon=-152.8048981260972, v=(0.2029147182736078, 0.5607928217823371, 0.03493896308072991)))
    expected_cfg = Dict(
        7 => (p=(3.5713489161051095, 1.7070796656768141, -1.301510415950513), d=(0.48753859140085626, -0.0671673805357054, -0.8705140233717322), lat=-12.421288253605288, lon=150.7486314679265, v=(2.625786655294745, -0.27214825565445955, -4.47399665653614)),
        13 => (p=(4.614680905189294, 1.4223992948693585, -3.1178925379165023), d=(0.4785641209685984, -0.07703063552613879, -0.8746671728789139), lat=-13.311301152948364, lon=151.31523127731052, v=(0.3660983001521675, -0.768299298597843, -0.6217803921025131)))
    expected_novert = Dict(
        6 => (p=(1.4294134754214263, 1.8563237766961522, 2.280658135194468), d=(0.4934198717395529, -0.16903085094570325, -0.8532088850926803), lat=-9.73147547315763, lon=149.9587434679265, v=(0.5012169834083975, -0.16903085094570325, -0.8486519351133053)),
        13 => (p=(1.307831921034576, 1.6979993353642724, 2.4908938156110745), d=(0.4934198717395529, -0.16903085094570325, -0.8532088850926803), lat=-9.73147547315763, lon=149.9587434679265, v=(-0.35399424521663536, -0.7071067811865475, 0.6121176964877788)))
    configs = (
        (Dict{Symbol,Any}(), _C3_FP_STEPS1, expected_base),
        (Dict{Symbol,Any}(:movement_speed => 3, :look_speed => 0.02,
                          :damping_factor => 0.3, :auto_forward => true,
                          :height_speed => true, :height_coef => 2,
                          :height_min => 0.5, :height_max => 4,
                          :constrain_vertical => true, :vertical_min => 0.5,
                          :vertical_max => 2.5), _C3_FP_STEPS2, expected_cfg),
        (Dict{Symbol,Any}(:look_vertical => false, :damping_factor => 1),
         _C3_FP_STEPS2, expected_novert))
    for rotation_driven in (false, true), (kw, steps, expected) in configs
        cam = _c3_first_person_camera(; rotation_driven=rotation_driven)
        fc = Diff3D.FirstPersonControls(cam; kw...)
        states = _c3_first_person_run(fc, steps)
        for (i, e) in expected
            s = states[i + 1]
            @test _c3_close(s.p, e.p)
            @test _c3_close(s.d, e.d)
            @test isapprox(s.lat, e.lat; atol=1e-11)
            @test isapprox(s.lon, e.lon; atol=1e-11)
            haskey(e, :v) && @test _c3_close(s.v, e.v)
        end
    end

    # A disabled control does not update; key and pointer state still track
    # (three.js handlers do not check `enabled`, update() does).
    cam = _c3_first_person_camera()
    fc = Diff3D.FirstPersonControls(cam; enabled=false)
    Diff3D.first_person_key_down!(fc, "KeyW")
    Diff3D.first_person_update!(fc, 1.0)
    @test cam.position == Vec3(1.0, 2.0, 3.0) && fc.key_forward
    # Orthographic cameras are driven the same way.
    ocam = OrthographicCamera()
    ocam.position = Vec3(0.0, 0.0, 5.0)
    fo = Diff3D.FirstPersonControls(ocam; damping_factor=1)
    Diff3D.first_person_key_down!(fo, "KeyW")
    Diff3D.first_person_update!(fo, 0.5)
    # Looking down -z (lon = 180°): forward key moves along -z at speed 1.
    @test isapprox(ocam.position.z, 4.5; atol=1e-12)
    @test isapprox(ocam.position.x, 0.0; atol=1e-12)

    # Invalid settings fail loudly instead of producing NaN cameras.
    @test_throws ArgumentError Diff3D.FirstPersonControls(cam; movement_speed=NaN)
    @test_throws ArgumentError Diff3D.FirstPersonControls(cam; damping_factor=1.5)
    @test_throws ArgumentError Diff3D.FirstPersonControls(
        cam; constrain_vertical=true, vertical_min=1.0, vertical_max=1.0)
    fc = Diff3D.FirstPersonControls(cam)
    @test_throws ArgumentError Diff3D.first_person_update!(fc, Inf)
    @test_throws ArgumentError Diff3D.first_person_pointer_down!(fc, 0, 0; pointer_type=:stylus)
end

# ---- FlyControls (three.js behaviour) ----------------------------------------

function _c3_fly_run(fc, steps)
    states = Any[]
    function snap()
        q = Diff3D._camera_local_quaternion(fc.camera)
        push!(states, (p=fc.camera.position,
                       d=Diff3D.quat_rotate_vector(q, Vec3(0.0, 0.0, -1.0)),
                       u=Diff3D.quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)),
                       mv=fc.move_vector, rv=fc.rotation_vector))
    end
    snap()
    for s in steps
        haskey(s, :k) && Diff3D.fly_key_down!(fc, s.k; alt_key=get(s, :alt, false))
        haskey(s, :ku) && Diff3D.fly_key_up!(fc, s.ku)
        haskey(s, :pd) && Diff3D.fly_pointer_down!(fc; button=s.pd)
        haskey(s, :pm) && Diff3D.fly_pointer_move!(fc, s.pm...; width=800, height=600,
                                                   left=10, top=20)
        haskey(s, :pu) && Diff3D.fly_pointer_up!(fc; button=s.pu)
        haskey(s, :pc) && Diff3D.fly_pointer_cancel!(fc)
        haskey(s, :en) && (fc.enabled = s.en)
        haskey(s, :dt) && Diff3D.fly_update!(fc, s.dt)
        snap()
    end
    return states
end

@testset "FlyControls event-driven update follows three.js r186" begin
    # FlyControls.js:132-158 (update: translateX/Y/Z then quaternion.multiply),
    # 162-182 (move/rotation vectors), 207-366 (handlers). The element is
    # 800x600 at offset (10, 20).
    steps1 = [
        (k="KeyW", dt=0.1), (k="KeyR", dt=0.2), (k="ArrowLeft", dt=0.3),
        (k="KeyQ", dt=0.25), (ku="KeyW", k="KeyA", dt=0.1), (k="KeyE", ku="KeyQ", dt=0.2),
        (k="ArrowUp", alt=true, dt=0.1), (k="ArrowDown", dt=0.15),
        (pm=(700, 100), dt=0.2), (pd=0, dt=0.1), (pu=0, dt=0.1), (pd=2, dt=0.3),
        (pc=true, dt=0.1), (en=false, k="KeyS", dt=0.5), (en=true, dt=0.2),
        (ku="ArrowLeft", dt=0.1)]
    steps2 = [
        (dt=0.2,), (pm=(300, 400), dt=0.1), (pd=0, dt=0.1), (pm=(600, 150), dt=0.3),
        (pm=(50, 500), dt=0.2), (pu=0, dt=0.2), (pd=2, pm=(410, 320), dt=0.1),
        (k="KeyS", dt=0.2), (ku="KeyS", dt=0.2), (pc=true, dt=0.1)]
    expected1 = Dict(
        7 => (p=(0.9371501717805667, 3.8434754488727143, 1.2792583347849293), d=(-0.3935195031087021, -0.21033751981758844, -0.8949304601085304), u=(0.029850226943336645, 0.9700371854785197, -0.24111578699940697), mv=(-1.0, 1.0, 0.0), rv=(0.0, 1.0, -1.0)),
        9 => (p=(0.3712906979713555, 4.650988952358451, 1.3283970198794794), d=(-0.3800941839068769, -0.24290576430154792, -0.8924826054491182), u=(0.329664413236358, 0.8659568931901842, -0.37608514166599555), mv=(-1.0, 1.0, 0.0), rv=(0.7333333333333333, -0.725, -1.0)),
        14 => (p=(0.0831875229695345, 6.34653458820193, 1.4852279349349613), d=(0.20889127872854873, -0.19075274870770326, -0.9591547437883043), u=(0.8148542169329096, 0.576247227997776, 0.0628628457161683), mv=(-1.0, 1.0, 1.0), rv=(0.7333333333333333, -0.725, -1.0)),
        16 => (p=(0.13594063086064773, 7.279924574381022, 1.9385930890524545), d=(0.4574468510564975, -0.2067503125420864, -0.864868016937986), u=(0.8550840432686249, 0.36923030198104223, 0.3640058557858241), mv=(-1.0, 1.0, 1.0), rv=(0.7333333333333333, 0.0, -1.0)))
    expected2 = Dict(
        4 => (p=(1.0, 2.0, 3.0), d=(0.6886008223817961, 0.10119166750490644, -0.718045370323276), u=(-0.07564864368190397, 0.9948368895571107, 0.0676523900939317), mv=(0.0, 0.0, 0.0), rv=(0.5666666666666667, -0.475, 0.0)),
        10 => (p=(1.0691487708786502, 1.9861534512017218, 2.8676114786986844), d=(0.46099180585766764, -0.0923103253218539, -0.8825901420087696), u=(0.03471224862908458, 0.9956894984066837, -0.0860086190899447), mv=(0.0, 0.0, -1.0), rv=(0.0, 0.0, 0.0)))
    for rotation_driven in (false, true)
        for (kw, steps, expected) in (
                ((movement_speed=2, roll_speed=0.5), steps1, expected1),
                ((movement_speed=1.5, roll_speed=0.8, drag_to_look=true,
                  auto_forward=true), steps2, expected2))
            cam = _c3_first_person_camera(; rotation_driven=rotation_driven)
            states = _c3_fly_run(Diff3D.FlyControls(cam; kw...), steps)
            for (i, e) in expected, key in (:p, :d, :u, :mv, :rv)
                @test _c3_close(getproperty(states[i + 1], key), getproperty(e, key))
            end
        end
    end
    # The roll is carried by camera.up, so the rendered view matches the
    # three.js quaternion: view_matrix rows are the camera's local axes.
    cam = _c3_first_person_camera()
    fc = Diff3D.FlyControls(cam; roll_speed=1.0)
    Diff3D.fly_key_down!(fc, "KeyQ")
    Diff3D.fly_update!(fc, 0.3)
    # Rolling left by 0.3 rad about the view axis (FlyControls.js:148-149:
    # quaternion (0, 0, 0.3, 1) normalized = rotation by 2 atan(0.3)).
    angle = 2 * atan(0.3)
    V = view_matrix(cam)
    right0 = normalize(cross(Vec3(3.0, -1.0, -5.0), Vec3(0.0, 1.0, 0.0)))
    up0 = cross(right0, normalize(Vec3(3.0, -1.0, -5.0)))
    up_expected = up0 * cos(angle) - right0 * sin(angle)
    @test _c3_close(Vec3(mat4_get(V, 2, 1), mat4_get(V, 2, 2), mat4_get(V, 2, 3)),
                    _c3_vec(up_expected))
    # The earlier direct calls keep working on the extended struct.
    fly_translate!(fc, 1.0, 0.0, 0.0)
    fly_rotate!(fc, 0.1, 0.0)
    @test all(isfinite, _c3_vec(cam.target))
    @test_throws ArgumentError Diff3D.fly_update!(fc, NaN)
    @test_throws ArgumentError Diff3D.fly_pointer_move!(fc, 1, 1; width=0, height=10)
    @test_throws ArgumentError Diff3D.FlyControls(cam; roll_speed=Inf)
end

# ---- OrbitControls pointer, wheel and keyboard input --------------------------

# The camera of every OrbitControls oracle run: at (3, 4, 5) looking at the
# orbit target (0.5, 0, -0.5); the element is 800x600 at client (10, 20).
function _c3_orbit_camera(kind)
    cam = kind === :ortho ?
        OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0, near=0.1, far=100.0) :
        PerspectiveCamera(fov=50 * π / 180, aspect=1.5, near=0.1, far=100.0)
    cam.position = Vec3(3.0, 4.0, 5.0)
    cam.target = Vec3(0.5, 0.0, -0.5)
    return cam
end

const _C3_ELEMENT = (element_left=10.0, element_top=20.0, element_width=800.0,
                     element_height=600.0)

function _c3_orbit_run(kind, ctor, cfg, steps)
    oc = ctor(_c3_orbit_camera(kind), Vec3(0.5, 0.0, -0.5); _C3_ELEMENT..., cfg...)
    orbit_update!(oc)
    states = Any[]
    function snap()
        q = Diff3D._camera_local_quaternion(oc.camera)
        push!(states, (p=oc.camera.position, t=oc.target,
                       d=Diff3D.quat_rotate_vector(q, Vec3(0.0, 0.0, -1.0)),
                       u=Diff3D.quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)),
                       z=oc.camera.zoom))
    end
    snap()
    for s in steps
        if haskey(s, :set)
            for (k, v) in pairs(s.set)
                setproperty!(oc, k, v)
            end
        end
        haskey(s, :pd) && Diff3D.orbit_pointer_down!(
            oc, s.pd...; button=get(s, :b, 0), pointer_type=get(s, :t, :mouse),
            pointer_id=get(s, :id, 1), shift_key=get(s, :mod, false))
        haskey(s, :pm) && Diff3D.orbit_pointer_move!(
            oc, s.pm...; pointer_type=get(s, :t, :mouse), pointer_id=get(s, :id, 1))
        haskey(s, :pu) && Diff3D.orbit_pointer_up!(oc; pointer_id=s.pu)
        haskey(s, :w) && Diff3D.orbit_wheel!(
            oc, s.w; x=get(s, :x, 0), y=get(s, :y, 0), delta_mode=get(s, :mode, 0),
            ctrl_key=get(s, :ctrl, false))
        haskey(s, :k) && Diff3D.orbit_key_down!(oc, s.k; shift_key=get(s, :mod, false))
        haskey(s, :ku) && Diff3D.orbit_key_up!(oc, s.ku)
        haskey(s, :upd) && orbit_update!(oc)
        snap()
    end
    return oc, states
end

const _C3_ORBIT_MOUSE = [
    (pd=(400, 300),), (pm=(430, 290),), (pm=(380, 340),), (pu=1,),
    (pd=(200, 200), b=1), (pm=(200, 260),), (pm=(210, 180),), (pu=1,),
    (pd=(100, 100), b=2), (pm=(140, 90),), (pm=(120, 150),), (pu=1,),
    (pd=(300, 300), mod=true), (pm=(330, 320),), (pu=1,),
    (w=-120, x=500, y=250), (w=300, x=100, y=500),
    (k="ArrowUp",), (k="ArrowLeft",), (k="ArrowRight", mod=true),
    (k="ArrowDown", mod=true), (k="KeyX",),
    (set=(enable_rotate=false,), pd=(10, 10)), (pm=(50, 50),), (pu=1,),
    (set=(enable_rotate=true,),)]
const _C3_ORBIT_TOUCH = [
    (pd=(400, 300), t=:touch, id=7), (pm=(420, 330), t=:touch, id=7),
    (pd=(500, 300), t=:touch, id=8), (pm=(540, 290), t=:touch, id=8),
    (pm=(380, 320), t=:touch, id=7), (pu=8,), (pm=(360, 300), t=:touch, id=7), (pu=7,)]
const _C3_ORBIT_DAMPED = [
    (pd=(400, 300),), (pm=(450, 280),), (upd=true,), (pm=(470, 300),), (pu=1,),
    (upd=true,), (upd=true,), (w=-200, x=300, y=300), (upd=true,),
    (pd=(100, 100), b=2), (pm=(130, 110),), (upd=true,), (pu=1,), (upd=true,)]
const _C3_ORBIT_CURSOR = [
    (w=-250, x=600, y=150), (w=-100, x=100, y=500), (w=400, x=410, y=320),
    (pd=(400, 300),), (pm=(420, 360),), (pu=1,), (w=-300, x=700, y=500),
    (pd=(300, 200), b=1), (pm=(300, 240),), (pm=(300, 200),), (pu=1,)]
const _C3_ORBIT_CUSTOM = [
    (pd=(400, 300),), (pm=(430, 270),), (pu=1,), (pd=(400, 300), b=2),
    (pm=(420, 310),), (pu=1,), (w=3, mode=1), (w=-1, mode=2), (w=-20, ctrl=true),
    (k="ControlLeft",), (w=-20, ctrl=true), (ku="ControlLeft",), (k="KeyW",),
    (k="KeyD", mod=true)]

const _C3_ORBIT_CASES = [
    ("mouse", :persp, OrbitControls, (;), _C3_ORBIT_MOUSE),
    ("touch", :persp, OrbitControls, (;), _C3_ORBIT_TOUCH),
    ("damped", :persp, OrbitControls,
     (enable_damping=true, damping_factor=0.2, auto_rotate=true, auto_rotate_speed=3),
     _C3_ORBIT_DAMPED),
    ("cursor_screen", :persp, OrbitControls, (zoom_to_cursor=true,), _C3_ORBIT_CURSOR),
    ("cursor_ground", :persp, OrbitControls,
     (zoom_to_cursor=true, screen_space_panning=false, min_distance=1, max_distance=20),
     _C3_ORBIT_CURSOR),
    ("ortho", :ortho, OrbitControls, (min_zoom=0.5, max_zoom=4),
     vcat(_C3_ORBIT_MOUSE, _C3_ORBIT_TOUCH)),
    ("ortho_cursor", :ortho, OrbitControls, (zoom_to_cursor=true,), _C3_ORBIT_CURSOR),
    ("map", :persp, MapControls, (;), vcat(_C3_ORBIT_MOUSE, _C3_ORBIT_TOUCH)),
    ("map_ortho", :ortho, MapControls, (;), _C3_ORBIT_MOUSE),
    ("custom", :persp, OrbitControls,
     (rotate_speed=0.5, zoom_speed=2, pan_speed=1.5, key_pan_speed=20, key_rotate_speed=3,
      keys=(left="KeyA", up="KeyW", right="KeyD", bottom="KeyS"),
      mouse_buttons=(left=:pan, middle=:none, right=:dolly)), _C3_ORBIT_CUSTOM),
    ("cursor_flat", :persp, OrbitControls, (zoom_to_cursor=true, screen_space_panning=false),
     [(pd=(400, 300),), (pm=(400, 250),), (pu=1,), (w=-250, x=600, y=150),
      (w=200, x=100, y=400)]),
    ("touch_modes", :persp, OrbitControls,
     (touches=(one=:pan, two=:dolly_rotate), screen_space_panning=false), _C3_ORBIT_TOUCH)]

# node + three.js r186: OrbitControls / MapControls driven through their
# private handlers (_onPointerDown/_onPointerMove/_onPointerUp/_onMouseWheel/
# _onKeyDown/_interceptControlDown) with camera.updateMatrixWorld() after
# every event (a render); the middle and last states of each run.
const _C3_ORBIT_EXPECTED = Dict(
    "mouse" => Dict(
        13 => (p=(2.3299247364596662, 6.348526424589346, 2.353379420100264), t=(0.041380078006173604, 0.2994110226800223, -0.74574659212067), d=(-0.3191060358298121, -0.8434658371424445, -0.4321304426565872), u=(-0.5010492329136058, 0.5371828195070979, -0.6785162375530095), z=1.0),
        26 => (p=(2.13599500242508, 7.054751149127451, 2.7220922495683073), t=(-0.4510748913326697, 0.46514742463669817, -0.7055912169002404), d=(-0.3289169684242884, -0.8377943268585906, -0.43579157147211645), u=(-0.5047103617291349, 0.5459859575882526, -0.668705304958533), z=1.0)),
    "touch" => Dict(
        4 => (p=(0.9459450575451532, 3.7956082501874797, 2.5661904244311318), t=(0.28954119364770214, -0.03504894127651153, -0.4084229032041916), d=(-0.13411891716546245, -0.7826943484164292, -0.6077842322858873), u=(-0.16865851875514604, 0.6224062635907366, -0.7643067100937545), z=1.0),
        8 => (p=(1.6586671092195022, 2.360643014177254, 2.258968018508262), t=(0.4445287030421402, -0.058723197439076315, -0.4121364750819333), d=(-0.3192640748333645, -0.6361850603727253, -0.7023809646334016), u=(-0.26325525110266035, 0.7715364987857359, -0.5791615524258524), z=1.0)),
    "damped" => Dict(
        7 => (p=(0.2870549388412089, 3.7638514810662533, 5.68773596959368), t=(0.5, 0.0, -0.5), d=(0.029389210547546608, -0.5194608555127066, -0.8539886965840936), u=(0.01786617580221249, 0.8544942478390402, -0.5191535227388883), z=1.0),
        14 => (p=(-0.9263935585300949, 3.5827630646660507, 4.798965788011284), t=(0.35637043303511434, 0.04202234055118565, -0.5469906083258788), d=(0.1961642662257456, -0.5414611032182995, -0.8175203082234329), u=(0.1263376475225395, 0.8407258017342051, -0.5265158355803258), z=1.0)),
    "cursor_screen" => Dict(
        6 => (p=(1.1782604244315307, 7.140909476295982, 2.011656094842331), t=(0.6174728886560995, 0.17740347584364977, -0.5296544757334338), d=(-0.07543632158721704, -0.9367206731837846, -0.3418533922831643), u=(-0.20184880796206367, 0.35007767770898657, -0.9147145337722457), z=1.0),
        11 => (p=(1.6401888394449222, 6.187916923583114, 1.8300365192732648), t=(1.1593836259594614, 0.2175809664452979, -0.3488196311741334), d=(-0.07543632158721712, -0.9367206731837845, -0.3418533922831646), u=(-0.20184880796206367, 0.3500776777089869, -0.9147145337722455), z=1.0)),
    "cursor_ground" => Dict(
        6 => (p=(1.0902337621200493, 7.30586293037606, 1.904074278980521), t=(0.5018754166009205, 0.0, -0.762178423456481), d=(-0.07543632158721701, -0.9367206731837848, -0.3418533922831641), u=(-0.20184880796206373, 0.35007767770898635, -0.9147145337722459), z=1.0),
        11 => (p=(1.5750716772264703, 6.306067854732259, 1.7135349877433907), t=(1.0672291834513161, 0.0, -0.5878455089429244), d=(-0.07543632158721704, -0.9367206731837846, -0.3418533922831643), u=(-0.20184880796206367, 0.35007767770898657, -0.9147145337722457), z=1.0)),
    "ortho" => Dict(
        17 => (p=(2.066874081640548, 6.483680759349659, 2.4549553809692464), t=(-0.24526881195586783, 0.37219015006404654, -0.6761271430478617), d=(-0.3191060358298121, -0.8434658371424446, -0.4321304426565872), u=(-0.5010492329136058, 0.5371828195070978, -0.6785162375530096), z=0.9212081434582966),
        34 => (p=(1.6167802330657048, 6.83999301844488, 2.0606743732552255), t=(-0.3711361658542108, 0.389331462193179, -0.5731733591700271), d=(-0.2743585283493021, -0.8902758749886104, -0.3635055217397245), u=(-0.5363266908109122, 0.45542163586424406, -0.7105946906011555), z=1.7551703564318102)),
    "ortho_cursor" => Dict(
        6 => (p=(1.1019825291653182, 6.891770585735888, 1.8757224028287052), t=(0.555394450931786, 0.10458449521068047, -0.6012407469404044), d=(-0.075436321587217, -0.9367206731837848, -0.3418533922831641), u=(-0.20184880796206367, 0.35007767770898635, -0.9147145337722459), z=0.9746794344808963),
        11 => (p=(1.5898592948837575, 6.798285429247038, 2.024224220482752), t=(1.0432712166502247, 0.011099338721828113, -0.45273892928635956), d=(-0.07543632158721705, -0.9367206731837846, -0.3418533922831643), u=(-0.20184880796206364, 0.35007767770898657, -0.9147145337722457), z=1.1368181186539104)),
    "map" => Dict(
        17 => (p=(0.18049517190242637, 7.615159821602032, 0.619284541093089), t=(0.3710637140787525, 0.0, -1.3397576609798758), d=(0.024228656257380077, -0.9681823010006118, -0.24907027973068693), u=(0.0937388070171683, 0.2502459430823224, -0.9636337499433264), z=1.0),
        34 => (p=(-0.6097567080569233, 3.851621397699938, -0.9186550171407715), t=(-0.4814131528553724, 2.0776585437441587e-18, -2.398705037531586), d=(0.031089496529453784, -0.9330033743300513, -0.35852217043619955), u=(0.08060354309454126, 0.3598676193946022, -0.9295151237886708), z=1.0)),
    "map_ortho" => Dict(
        13 => (p=(1.0787147744214463, 6.4848631085363975, 1.9137974248264402), t=(0.3822445772649763, 0.0, -1.242383768960835), d=(-0.09612201923321181, -0.8949961376501533, -0.43559438817532736), u=(-0.1928578163021818, 0.44607388804020764, -0.8739702220898867), z=1.010311459317936),
        26 => (p=(-0.24274846356083013, 6.995775114316472, 0.06858664015328442), t=(-0.07976524974594079, 0.0, -1.8109258024564714), d=(0.022493820520917245, -0.9655086934588238, -0.25939736100008326), u=(0.08341172574777053, 0.26037081797973205, -0.961898914206864), z=0.9212081434582966)),
    "custom" => Dict(
        7 => (p=(2.80765966868991, 3.8226427188413736, 5.8016081355298805), t=(0.15439467857064226, -0.42258126534945506, -0.03557484273250633), d=(-0.34503277967117707, -0.5520524474738835, -0.7590721152765896), u=(-0.22844092817336772, 0.8338093878327919, -0.502570041981409), z=1.0),
        14 => (p=(2.1569500750288078, 2.7782226183753274, 4.019534958161964), t=(0.11506625411938785, -0.27903251610237656, -0.12209737652526602), d=(-0.36870555815844375, -0.5520524474738835, -0.7478598174933359), u=(-0.24411431287388075, 0.8338093878327919, -0.49514655104526173), z=1.0)),
    "cursor_flat" => Dict(
        3 => (p=(3.492669398063464, 0.44334012173911136, 6.08387267573962), t=(0.5, 0.0, -0.5), d=(-0.4130276164202823, -0.06118674981736146, -0.9086607561246209), u=(-0.025319257226644104, 0.9981263355140909, -0.055702365898617025), z=1.0),
        5 => (p=(3.9636852739416124, 0.7385557315750908, 5.618173561254932), t=(0.5, 0.0, -0.5), d=(-0.4899633984490281, -0.10447406376929373, -0.8654600153558849), u=(-0.05147013189298934, 0.9945276114817173, -0.09091565059652125), z=1.0)),
    "touch_modes" => Dict(
        4 => (p=(1.0637490154682896, 2.4845745946460602, 3.4031960051320542), t=(0.15512934563738978, -9.377831780506826e-18, -0.7143790554145956), d=(-0.18565260342830445, -0.5076576671443954, -0.841318491315746), u=(-0.1093923705319928, 0.8615588737802601, -0.49573139529374266), z=1.0),
        8 => (p=(1.707431169137329, 1.7564639714929733, 2.4149878397332456), t=(0.31167571087137635, -9.377831780506826e-18, -0.6556741684518506), d=(-0.3670212331721614, -0.461871432436116, -0.8074467129787551), u=(-0.19112375863067016, 0.88694688674092, -0.4204722689874744), z=1.0)),
)

@testset "OrbitControls pointer, wheel and keyboard input follow three.js r186" begin
    # OrbitControls.js:420-574 (update with zoomToCursor), 610-705 (_pan,
    # dolly, _updateZoomParameters), 711-1002 (handlers), 1107-1460 (pointer
    # dispatch); MapControls.js:32-115.
    for (name, kind, ctor, cfg, steps) in _C3_ORBIT_CASES
        _, states = _c3_orbit_run(kind, ctor, cfg, steps)
        for (i, e) in _C3_ORBIT_EXPECTED[name]
            s = states[i + 1]
            for key in (:p, :t, :d, :u)
                @test _c3_close(getproperty(s, key), getproperty(e, key); atol=1e-12)
            end
            @test isapprox(s.z, e.z; atol=1e-12)
        end
    end
    # Without input calls the controls behave exactly as before.
    cam = _c3_orbit_camera(:persp)
    oc = OrbitControls(cam, Vec3(0.5, 0.0, -0.5))
    @test oc.mouse_buttons == (left=:rotate, middle=:dolly, right=:pan)
    @test oc.touches == (one=:rotate, two=:dolly_pan) && oc.key_pan_speed == 7.0
    @test MapControls(cam).mouse_buttons == (left=:pan, middle=:dolly, right=:rotate)
    # Disabled controls ignore input; pointer input needs an element size.
    oc.enabled = false
    Diff3D.orbit_pointer_down!(oc, 1, 1)
    @test isempty(oc.pointers) && oc.state === :none
    oc.enabled = true
    @test_throws ArgumentError Diff3D.orbit_key_down!(oc, "ArrowUp")
    @test cam.position == Vec3(3.0, 4.0, 5.0)
    @test_throws ArgumentError OrbitControls(cam; mouse_buttons=(left=:spin, middle=:dolly, right=:pan))
    @test_throws ArgumentError OrbitControls(cam; zoom_speed=NaN)
    # A wheel step during a drag is ignored (OrbitControls.js onMouseWheel).
    oc = OrbitControls(cam, Vec3(0.5, 0.0, -0.5); _C3_ELEMENT...)
    Diff3D.orbit_pointer_down!(oc, 100, 100)
    Diff3D.orbit_wheel!(oc, -500)
    @test cam.position == Vec3(3.0, 4.0, 5.0)
    Diff3D.orbit_pointer_up!(oc)
    @test oc.state === :none
    # The positional layout of 2.0 (29 fields) still constructs.
    old = OrbitControls(cam, Vec3(0.5, 0.0, -0.5), true, true, true, true, false,
                        0.05, 0.0, Inf, 0.0, Float64(π), -Inf, Inf, 0.0, 0.0, 0.0,
                        Vec3(0.0, 0.0, 0.0), cam.position, Vec3(0.5, 0.0, -0.5),
                        true, 0.0, Inf, 1.0, false, 2.0, Vec3(0.0, 0.0, 0.0), 0.0, Inf)
    @test old.zoom_speed == 1.0 && old.state === :none
end

@testset "OrbitControls polar, azimuthal angle and distance getters" begin
    # three.js getPolarAngle/getAzimuthalAngle/getDistance after update():
    # offset (2.5, 4, 5.5) from the target, Spherical.setFromVector3.
    cam = _c3_orbit_camera(:persp)
    oc = OrbitControls(cam, Vec3(0.5, 0.0, -0.5))
    r = sqrt(2.5^2 + 4^2 + 5.5^2)
    @test Diff3D.orbit_polar_angle(oc) ≈ acos(4 / r) atol=1e-15
    @test Diff3D.orbit_azimuthal_angle(oc) ≈ atan(2.5, 5.5) atol=1e-15
    @test Diff3D.orbit_distance(oc) ≈ r atol=1e-14
    # About a tilted camera.up the angles are measured from that axis.
    cam.up = Vec3(0.0, 0.0, 1.0)
    @test Diff3D.orbit_polar_angle(oc) ≈ acos(5.5 / r) atol=1e-14
end

# ---- Helpers ------------------------------------------------------------------

_c3_vertex(geo, i) = (geo.positions[3i + 1], geo.positions[3i + 2], geo.positions[3i + 3])

@testset "CameraHelper style=:threejs matches three.js CameraHelper" begin
    # CameraHelper.js:39-165 (line list), 229-313 and 327 (update/setPoint
    # with unproject), 167-227 (setColors). three.js stores Float32 attributes, so
    # positions agree to ~1e-6 and colours to ~1e-7. 0-based vertex indices.
    cam = PerspectiveCamera(fov=50 * π / 180, aspect=1.5, near=0.5, far=10.0)
    cam.position = Vec3(1.0, 2.0, 3.0)
    cam.target = Vec3(0.0, 0.0, 0.0)
    h = CameraHelper(cam; style=:threejs)
    @test h isa LineSegments && h.geometry.n_vertices == 50
    expected = Dict(0 => (0.573995867744918, 1.5356878024826068, 2.8279332779676323),
        3 => (1.1587428903426578, 1.9297897136925442, 2.3702829962950944),
        9 => (5.751265853685231, -7.286243698472266, -4.865117441493371),
        11 => (4.17485830959572, 0.5957940219752897, -9.594340073761904),
        24 => (1, 2, 3),
        36 => (0.7875489968018003, 2.126840669297513, 2.362646990405401),
        37 => (1.0552667687346133, 1.949494810512419, 2.3916383056178594),
        38 => (0.8663693790437879, 1.7327387580875757, 2.5991081371313633),
        39 => (-1.6726124191242433, -3.3452248382484875, -5.017837257372731),
        42 => (0.5345856766239242, 1.7327387580875757, 2.709702704604651),
        49 => (-2.4608161911689983, 0.5957940219752897, -7.3824485735069985))
    for (i, e) in expected
        @test all(abs.(_c3_vertex(h.geometry, i) .- e) .<= 1e-6)
    end
    colors = get_attribute(h.geometry, :color).data
    expected_colors = Dict(0 => (1, 0.4019777774810791, 0), 24 => (1, 0, 0),
        32 => (0, 0.4019777774810791, 1), 38 => (1, 1, 1),
        40 => (0.03310476616024971, 0.03310476616024971, 0.03310476616024971),
        49 => (0.03310476616024971, 0.03310476616024971, 0.03310476616024971))
    for (i, e) in expected_colors
        @test all(abs.((colors[3i + 1], colors[3i + 2], colors[3i + 3]) .- e) .<= 1e-7)
    end
    o = OrthographicCamera(left=-2.0, right=3.0, top=1.5, bottom=-1.0, near=0.25, far=8.0)
    o.position = Vec3(-1.0, 0.5, 2.0)
    o.target = Vec3(1.0, 0.0, -1.0)
    o.zoom = 1.25
    ho = CameraHelper(o; style=:threejs)
    expected_ortho = Dict(0 => (-2.167860326390036, -0.2772309758026452, 1.0476270329870618),
        11 => (5.570906196922591, 0.639266879769609, -3.3494202010538974),
        24 => (-1, 0.5, 2),
        36 => (-0.27517794238651083, 2.6943323634592464, 1.8141547324457634),
        39 => (3.8306116764709577, -0.35125423331768824, -4.344529695840437),
        49 => (3.906805608246904, 0.639266879769609, -4.458820593504356))
    for (i, e) in expected_ortho
        @test all(abs.(_c3_vertex(ho.geometry, i) .- e) .<= 1e-6)
    end
    # The default keeps Diff3D's 12-edge box, and bad styles are rejected.
    @test CameraHelper(cam).geometry.n_vertices == 24
    @test !has_attribute(CameraHelper(cam).geometry, :color)
    @test_throws ArgumentError CameraHelper(cam; style=:cone)
end

@testset "PlaneHelper style=:threejs matches three.js PlaneHelper" begin
    # PlaneHelper.js:28-65 (Line strip positions and the filled mesh child)
    # and :67-83 (updateMatrixWorld: scale, lookAt(normal), translateZ(-constant)).
    n = normalize(Vec3(1.0, 2.0, -2.0))
    h = PlaneHelper(Plane(n, -1.5), 3; color=Diff3D._helper_hex_color(0x33cc99), style=:threejs)
    line = [-0.3944271909999153,-0.11803398874989512,-2.5652475842498523,1.3944271909999153,2.118033988749895,0.565247584249853,2.288854381999831,-0.11803398874989512,-1.2236067977499787,-1.288854381999831,2.118033988749895,-0.776393202250021,1.3944271909999153,2.118033988749895,0.565247584249853,2.288854381999831,-0.11803398874989512,-1.2236067977499787,-0.3944271909999153,-0.11803398874989512,-2.5652475842498523,-1.288854381999831,2.118033988749895,-0.776393202250021]
    mesh = [-1.288854381999831,2.118033988749895,-0.776393202250021,1.3944271909999153,2.118033988749895,0.565247584249853,2.288854381999831,-0.11803398874989512,-1.2236067977499787,-1.288854381999831,2.118033988749895,-0.776393202250021,2.288854381999831,-0.11803398874989512,-1.2236067977499787,-0.3944271909999153,-0.11803398874989512,-2.5652475842498523]
    @test h isa LineObject
    @test maximum(abs.(h.geometry.positions .- line)) <= 1e-12
    child = only(h.children)
    @test child isa Mesh && maximum(abs.(child.geometry.positions .- mesh)) <= 1e-12
    @test child.material.opacity == 0.2 && child.material.transparent && !child.material.depth_write
    c = h.material.color
    @test all(abs.((c.r, c.g, c.b) .- (0.033104766565152086, 0.6038273388475408, 0.31854677811435356)) .<= 1e-10)
    # A normal along +y takes three.js's lookAt perturbation (Matrix4.lookAt).
    up = PlaneHelper(Plane(Vec3(0.0, 1.0, 0.0), 2.0), 2; style=:threejs)
    @test maximum(abs.(up.geometry.positions .- [1,-2.0000999899995,0.9997999950010001,-1,-1.9998999900005001,-1.000199994999,-1,-2.0000999899995,0.9997999950010001,1,-1.9998999900005001,-1.000199994999,-1,-1.9998999900005001,-1.000199994999,-1,-2.0000999899995,0.9997999950010001,1,-2.0000999899995,0.9997999950010001,1,-1.9998999900005001,-1.000199994999])) <= 1e-12
    @test PlaneHelper(Plane(n, -1.5), 3) isa LineSegments
    @test_throws ArgumentError PlaneHelper(Plane(n, -1.5); style=:quad)
end

@testset "VertexNormalsHelper and VertexTangentsHelper match three.js" begin
    # VertexNormalsHelper.js:94-144 (normal matrix), VertexTangentsHelper.js:
    # 78-122 (transformDirection); Float32 buffers in three.js.
    g = BoxGeometry(width=1.0, height=2.0, depth=3.0)
    compute_tangents!(g)
    m = Mesh(g, MeshBasicMaterial())
    m.position = Vec3(1.0, -1.0, 2.0)
    m.rotation = Euler(0.3, 0.5, -0.2, :XYZ)
    m.scale = Vec3(2.0, 1.0, 0.5)
    hn = Diff3D.VertexNormalsHelper(m, 0.7)
    ht = Diff3D.VertexTangentsHelper(m, 0.4)
    @test hn.geometry.n_vertices == 48 && ht.geometry.n_vertices == 48
    normals = Dict(0 => (2.3940072059631348, -0.28100699186325073, 2.3198325634002686),
        1 => (2.9960696697235107, -0.3166652023792267, 1.9645169973373413),
        23 => (2.5160512924194336, 0.3941015601158142, 2.4588780403137207),
        46 => (-0.39400723576545715, -1.7189929485321045, 1.680167317390442),
        47 => (-0.7296051383018494, -1.5374525785446167, 1.093296766281128))
    tangents = Dict(1 => (2.202237129211426, -0.17726965248584747, 1.9844779968261719),
        23 => (2.7380430698394775, -0.3013831377029419, 2.116795063018799),
        47 => (-0.738042950630188, -1.698616862297058, 1.8832048177719116))
    for (i, e) in normals
        @test all(abs.(_c3_vertex(hn.geometry, i) .- e) .<= 1e-6)
    end
    for (i, e) in tangents
        @test all(abs.(_c3_vertex(ht.geometry, i) .- e) .<= 1e-6)
    end
    @test hn.material.color == Color3(1.0, 0.0, 0.0)
    @test ht.material.color == Color3(0.0, 1.0, 1.0)
    @test_throws ArgumentError Diff3D.VertexTangentsHelper(Mesh(BoxGeometry(), MeshBasicMaterial()))
    @test_throws ArgumentError Diff3D.VertexNormalsHelper(Group())
end

@testset "RectAreaLightHelper matches three.js RectAreaLightHelper" begin
    # RectAreaLightHelper.js:34-105 for a light at (2, 3, 1) looking at the
    # origin, 4x2, colour 0xff8800 at intensity 3 (normalized to max 1).
    light = RectAreaLight(color=Diff3D._helper_hex_color(0xff8800), intensity=3.0,
                          width=4.0, height=2.0, position=Vec3(2.0, 3.0, 1.0))
    light.target = Vec3(0.0, 0.0, 0.0)
    h = Diff3D.RectAreaLightHelper(light)
    line = [2.1772900253992793,3.5976143046671964,-1.1474229648001506,0.388435643399448,3.597614304667197,2.430285799199514,1.8227099746007205,2.4023856953328036,3.1474229648001506,3.611564356600552,2.402385695332803,-0.43028579919951393,2.1772900253992793,3.5976143046671964,-1.1474229648001506]
    mesh = [2.1772900253992793,3.5976143046671964,-1.1474229648001506,0.388435643399448,3.597614304667197,2.430285799199514,1.8227099746007205,2.4023856953328036,3.1474229648001506,2.1772900253992793,3.5976143046671964,-1.1474229648001506,1.8227099746007205,2.4023856953328036,3.1474229648001506,3.611564356600552,2.402385695332803,-0.43028579919951393]
    @test h isa LineObject && maximum(abs.(h.geometry.positions .- line)) <= 1e-12
    child = only(h.children)
    @test maximum(abs.(child.geometry.positions .- mesh)) <= 1e-12
    @test child.material.side === :back
    c = h.material.color
    @test all(abs.((c.r, c.g, c.b) .- (1.0, 0.24620132669705552, 0.0)) .<= 1e-10)
    @test Diff3D.RectAreaLightHelper(light; color=Color3(0.0, 1.0, 0.0)).material.color ==
          Color3(0.0, 1.0, 0.0)
end

# ---- DragControls pointer input ------------------------------------------------

function _c3_drag_scene()
    scene = Scene()
    g = Group()
    g.position = Vec3(0.0, 0.5, 0.0)
    g.rotation = Euler(0.0, 0.4, 0.1, :XYZ)
    add!(scene, g)
    a = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0), MeshBasicMaterial())
    a.position = Vec3(1.0, 0.0, 0.0)
    a.rotation = Euler(0.2, 0.0, 0.0, :XYZ)
    add!(g, a)
    b = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0), MeshBasicMaterial())
    b.position = Vec3(-1.5, 0.0, 0.5)
    add!(scene, b)
    cam = PerspectiveCamera(fov=50 * π / 180, aspect=800 / 600, near=0.1, far=100.0)
    cam.position = Vec3(0.0, 2.0, 6.0)
    cam.target = Vec3(0.0, 0.0, 0.0)
    return g, a, b, cam
end

# Client pixels of box a and box b centres (rounded) in an 800x600 element
# at (10, 20), and the gesture used for every case below.
const _C3_SA = (501, 252)
const _C3_SB = (245, 337)

function _c3_drag_run(n_steps; kw...)
    g, a, b, cam = _c3_drag_scene()
    dc = DragControls([g, b], cam; element_left=10, element_top=20,
                      element_width=800, element_height=600, kw...)
    sa, sb = _C3_SA, _C3_SB
    steps = [
        () -> Diff3D.drag_pointer_down!(dc, sa...),
        () -> Diff3D.drag_pointer_move!(dc, sa[1] + 40, sa[2] - 25),
        () -> Diff3D.drag_pointer_move!(dc, sa[1] + 90, sa[2] + 10),
        () -> Diff3D.drag_pointer_up!(dc),
        () -> Diff3D.drag_pointer_down!(dc, sb...; button=2),
        () -> Diff3D.drag_pointer_move!(dc, sb[1] + 30, sb[2] + 20),
        () -> Diff3D.drag_pointer_move!(dc, sb[1] - 10, sb[2] + 60),
        () -> Diff3D.drag_pointer_up!(dc),
        () -> Diff3D.drag_pointer_down!(dc, sb...; pointer_type=:touch),
        () -> Diff3D.drag_pointer_move!(dc, sb[1] - 50, sb[2] - 30; pointer_type=:touch),
        () -> Diff3D.drag_pointer_up!(dc),
        () -> Diff3D.drag_pointer_down!(dc, 5, 5),
        () -> Diff3D.drag_pointer_move!(dc, 100, 100),
        () -> Diff3D.drag_pointer_up!(dc),
    ]
    states = []
    for step in steps[1:n_steps]
        step()
        push!(states, (a=(a.position, Diff3D._object_quaternion(a)),
                       b=(b.position, Diff3D._object_quaternion(b)),
                       g=(g.position, Diff3D._object_quaternion(g))))
    end
    return dc, states
end

# q and -q are the same rotation.
_c3_q_close(q, e; atol=1e-12) =
    all(abs.((q.x, q.y, q.z, q.w) .- e) .<= atol) ||
    all(abs.((-q.x, -q.y, -q.z, -q.w) .- e) .<= atol)

@testset "DragControls pointer input follows three.js r186" begin
    # Oracle: three.js r186 DragControls (DragControls.js onPointerMove :239,
    # onPointerDown :329, onPointerCancel :388, findGroup :414) driven in node
    # with the same scene, camera and events.
    _, base = _c3_drag_run(14)
    # Left button pans box a (a child of the rotated group) on the
    # camera-facing plane through its world position.
    @test _c3_close(base[3].a[1], (1.8116952350646645, -0.1778075150580951, 0.3836707227103337))
    # Right button rotates box b about the camera's up and right axes.
    @test _c3_q_close(base[7].b[2], (0.09970099919673374, -0.011353615044300772, 0.005970415708727675, 0.9949347517907211))
    @test _c3_close(base[7].b[1], (-1.5, 0.0, 0.5))
    # A touch uses touches.one (pan).
    @test _c3_close(base[10].b[1], (-1.9546665727959376, 0.25880075027602323, 0.4137330832413255))
    # A press that hits nothing moves nothing.
    @test _c3_close(base[14].a[1], (1.8116952350646645, -0.1778075150580951, 0.3836707227103337))
    @test _c3_close(base[14].b[1], (-1.9546665727959376, 0.25880075027602323, 0.4137330832413255))

    dc, fast = _c3_drag_run(14; rotate_speed=2.5, mouse_buttons=(left=:rotate, middle=:pan, right=:pan))
    @test _c3_q_close(fast[3].a[2], (0.13173236768700622, 0.2664958618775835, -0.0720788915873184, 0.9520667898279211))
    @test _c3_close(fast[7].b[1], (-1.5909333145591897, -0.5176015005520518, 0.6725338335173507))
    @test _c3_close(fast[10].b[1], (-2.0455998873551273, -0.25880075027602856, 0.5862669167586763))
    @test dc.selected === nothing && dc.state === :none

    # transform_group drags the outermost Group above the hit mesh.
    _, group = _c3_drag_run(3; transform_group=true)
    @test _c3_close(group[3].g[1], (0.8626376597371577, 0.40907000665977344, 0.03030999778007626))
    @test _c3_close(group[3].a[1], (1.0, 0.0, 0.0))

    # Hover, disabled controls, missing element size and bad options.
    g, a, b, cam = _c3_drag_scene()
    dc = DragControls([g, b], cam; element_left=10, element_top=20,
                      element_width=800, element_height=600)
    Diff3D.drag_pointer_move!(dc, _C3_SB...)
    @test dc.hovered === b
    Diff3D.drag_pointer_move!(dc, 5, 5)
    @test dc.hovered === nothing
    dc.enabled = false
    Diff3D.drag_pointer_down!(dc, _C3_SB...)
    @test dc.selected === nothing
    # A Group-less hit with transform_group selects nothing (three.js throws).
    dc = DragControls([g, b], cam; transform_group=true, element_left=10,
                      element_top=20, element_width=800, element_height=600)
    Diff3D.drag_pointer_down!(dc, _C3_SB...)
    @test dc.selected === nothing
    @test_throws ArgumentError Diff3D.drag_pointer_down!(DragControls([b], cam), 1, 1)
    @test_throws ArgumentError DragControls([b], cam; mouse_buttons=(left=:dolly, middle=:pan, right=:pan))
    @test_throws ArgumentError Diff3D.drag_pointer_down!(dc, 1, 1; pointer_type=:stylus)
    # The programmatic API and its defaults are unchanged.
    dc = DragControls([b], cam)
    @test dc.rotate_speed == 1.0 && dc.mouse_buttons == (left=:pan, middle=:pan, right=:rotate)
    drag_start!(dc, b)
    drag_move!(dc, Vec3(0.5, 0.0, 0.0))
    @test _c3_close(b.position, (-1.0, 0.0, 0.5))
end

# ---- TrackballControls pointer, wheel and key input ---------------------------

_C3P(x, y) = (x, y)
# Event scripts replayed against three.js r186 TrackballControls in node (DOM
# listener attachment emulated: keydown is detached after the first key until
# keyup, pointermove/pointerup are attached only while a pointer is down).
# Every step is followed by `u` (default 1) update() calls.
const _C3_TB_MOUSE = [
    (pd=_C3P(400, 300),), (pm=_C3P(430, 290),), (pm=_C3P(470, 260),), (u=3,), (pu=_C3P(470, 260),), (u=4,),
    (pd=_C3P(300, 300), b=1), (pm=_C3P(300, 340),), (pm=_C3P(300, 330), u=2), (pu=_C3P(300, 330),), (u=3,),
    (pd=_C3P(500, 200), b=2), (pm=_C3P(540, 230),), (pm=_C3P(600, 180), u=2), (pu=_C3P(600, 180),), (u=3,),
    (w=120,), (w=-300, mode=1), (w=2, mode=2), (u=2,),
    (kd="KeyS",), (pd=_C3P(200, 400),), (pm=_C3P(200, 380),), (pu=_C3P(200, 380),), (ku=true,),
    (kd="KeyQ",), (kd="KeyD",), (pd=_C3P(200, 400),), (pm=_C3P(260, 380),), (pu=_C3P(260, 380),), (ku=true,),
    (kd="KeyD",), (pd=_C3P(200, 400), b=1), (pm=_C3P(240, 350),), (pu=_C3P(240, 350),), (ku=true,), (u=3,),
    (pd=_C3P(100, 100), b=3), (pm=_C3P(150, 150),), (pu=_C3P(150, 150),),
]
const _C3_TB_TOUCH = [
    (pd=_C3P(400, 300), t=:touch, id=5), (pm=_C3P(420, 310), t=:touch, id=5), (pm=_C3P(450, 330), t=:touch, id=5),
    (pd=_C3P(500, 300), t=:touch, id=7), (pm=_C3P(520, 290), t=:touch, id=7), (pm=_C3P(430, 340), t=:touch, id=5),
    (pm=_C3P(560, 250), t=:touch, id=7, u=2),
    (pu=_C3P(560, 250), t=:touch, id=7), (pm=_C3P(440, 360), t=:touch, id=5), (pm=_C3P(460, 380), t=:touch, id=5),
    (pu=_C3P(460, 380), t=:touch, id=5), (u=3,),
    (pd=_C3P(300, 200), t=:touch, id=8), (pd=_C3P(350, 260), t=:touch, id=9), (pm=_C3P(310, 180), t=:touch, id=8),
    (pc=true, id=9), (pm=_C3P(330, 170), t=:touch, id=8), (pu=_C3P(330, 170), t=:touch, id=8),
]
const _C3_TB_ORTHO = [
    (pd=_C3P(300, 300), b=1), (pm=_C3P(300, 360),), (u=2,), (pu=_C3P(300, 360),), (u=2,),
    (w=-400,), (u=2,), (w=3000,), (u=3,),
    (pd=_C3P(500, 200), b=2), (pm=_C3P(560, 260),), (pu=_C3P(560, 260),), (u=2,),
    (pd=_C3P(400, 300),), (pm=_C3P(430, 280),), (pu=_C3P(430, 280),), (u=2,),
    (pd=_C3P(400, 300), t=:touch, id=1), (pd=_C3P(500, 300), t=:touch, id=2), (pm=_C3P(600, 300), t=:touch, id=2),
    (pu=_C3P(600, 300), t=:touch, id=2), (pu=_C3P(400, 300), t=:touch, id=1),
]

# Camera at (1, 2, 5), up +y, target (0.5, 0, -0.5); element 800x600 at (10, 20).
function _c3_tb_run(kind, steps; kw...)
    cam = kind === :ortho ?
        OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0, near=0.1, far=100.0) :
        PerspectiveCamera(fov=50 * π / 180, aspect=800 / 600, near=0.1, far=100.0)
    kind === :ortho && (cam.zoom = 1.5)
    cam.position = Vec3(1.0, 2.0, 5.0)
    cam.up = Vec3(0.0, 1.0, 0.0)
    cam.target = Vec3(0.0, 0.0, 0.0)
    tc = TrackballControls(cam, Vec3(0.5, 0.0, -0.5); element_left=10, element_top=20,
                           element_width=800, element_height=600, kw...)
    Diff3D.trackball_update!(tc)
    states = []
    for s in steps
        t = get(s, :t, :mouse)
        id = get(s, :id, 1)
        haskey(s, :pd) && Diff3D.trackball_pointer_down!(tc, s.pd...; button=get(s, :b, 0),
                                                        pointer_type=t, pointer_id=id)
        haskey(s, :pm) && Diff3D.trackball_pointer_move!(tc, s.pm...; pointer_type=t, pointer_id=id)
        haskey(s, :pu) && Diff3D.trackball_pointer_up!(tc, s.pu...; pointer_type=t, pointer_id=id)
        haskey(s, :pc) && Diff3D.trackball_pointer_cancel!(tc; pointer_id=id)
        haskey(s, :w) && Diff3D.trackball_wheel!(tc, s.w; delta_mode=get(s, :mode, 0))
        haskey(s, :kd) && Diff3D.trackball_key_down!(tc, s.kd)
        haskey(s, :ku) && Diff3D.trackball_key_up!(tc)
        for _ in 1:get(s, :u, 1)
            Diff3D.trackball_update!(tc)
        end
        push!(states, (p=cam.position, up=cam.up, t=tc.target,
                       z=kind === :ortho ? cam.zoom : 1.0))
    end
    return tc, states
end

# three.js r186 camera.position, camera.up, controls.target and camera.zoom
# after the given (1-based) step.
const _C3_TB_EXPECTED = Dict(
"mouse" => Dict(
        4 => (p=(-1.3857608031390185, 0.3205228114497825, 5.053482809974729),
              up=(-0.17365358636608802, 0.953552816037086, 0.24613301072781588),
              t=(0.5, 0, -0.5), z=1),
        6 => (p=(-2.6574067652856175, -0.9061768217949803, 4.36925313432873),
              up=(-0.32340801393113927, 0.8736098902065011, 0.36361107829451667),
              t=(0.5, 0, -0.5), z=1),
        11 => (p=(-4.487260677374847, -2.3002422397589934, 4.52389496900098),
              up=(-0.4527664744153672, 0.7885912325925045, 0.41608459178839263),
              t=(0.5, 0, -0.5), z=1),
        16 => (p=(-5.660498039017303, -3.0711140974149385, 3.2439570173053442),
              up=(-0.5063983478389779, 0.7495721126612254, 0.42626559939378267),
              t=(-0.10069200187249458, -0.2045387451604216, -1.428819264960976), z=1),
        20 => (p=(-6.0686315383625935, -3.381004020473611, 2.9964500795561646),
              up=(-0.522238322829335, 0.7376285661324385, 0.42798508454595274),
              t=(-0.20889239220165776, -0.2720728864170313, -1.659147799686572), z=1),
        31 => (p=(-6.160691572220307, -3.476292624800396, -0.6578232865834786),
              up=(-0.6790105035995612, 0.6513850817078457, 0.33858855758860745),
              t=(-0.25013519832030007, -0.2980689460558435, -1.757938804319618), z=1),
        40 => (p=(-4.4890380706732875, -3.1279172269918276, -5.987482807207837),
              up=(-0.8113081932670874, 0.5826446727382841, 0.048002092323067715),
              t=(0.36509103381890295, -0.552935470871908, -2.267983632779539), z=1)),
"static" => Dict(
        40 => (p=(-3.2567562766752323, -0.3283241221006347, 4.619481734508131),
              up=(-0.26554768695148173, 0.9378381867272905, 0.22348145665979827),
              t=(0.08266730949633488, -0.3995119727736486, -0.7547176401630314), z=1)),
"limits" => Dict(
        40 => (p=(-3.532041505051759, -1.4787767978756179, 0.8438230849351736),
              up=(-0.5738695808831309, 0.7733660705833241, 0.26940420376736657),
              t=(0.5, 0, -0.5), z=1)),
"norot" => Dict(
        40 => (p=(-0.39618977113170184, 0.9349691500173041, 5.126926342830155),
              up=(0, 1, 0),
              t=(-0.8961897711317018, -1.065030849982696, -0.37307365716984536), z=1)),
"touch" => Dict(
        7 => (p=(-0.9000641010892956, 1.9642999591116812, 2.3835311552200737),
              up=(-0.10871372482295023, 0.9614148298361325, -0.2527110029386925),
              t=(0.28296185570036597, 0.012045407668837434, -0.5471943099050047), z=1),
        12 => (p=(-1.8597579398628308, 2.3888563459567234, 1.3379854006432188),
              up=(-0.0761833762797009, 0.8544278142777073, -0.5139544759677113),
              t=(0.1784723225246393, -0.0593373077850882, -0.5730261721281841), z=1),
        18 => (p=(-2.2310906102665213, 1.5943899870846052, 0.8143157684579292),
              up=(-0.17686040121451424, 0.8276670848318958, -0.5326233145179734),
              t=(0.16418299456837593, -0.11038822340153849, -0.5564123632417526), z=1)),
"roll" => Dict(
        18 => (p=(-1.858432778249185, 2.185192525628554, 0.6304089084038681),
              up=(-0.2548883817689508, 0.6608208171862253, -0.7059375046082578),
              t=(0.1453476453597975, -0.04202510841498549, -0.6133216189077776), z=1)),
"ortho" => Dict(
        9 => (p=(1, 2, 5),
              up=(0, 1, 0),
              t=(0.5, 0, -0.5), z=0.17672143629384987),
        22 => (p=(-1.6965495072371777, 0.2887720842226802, 4.987273110288184),
              up=(-0.1863577316045233, 0.9478288756438301, 0.25863336669302506),
              t=(0.37784044552966817, 0.08497527852081616, -0.5041177140700379), z=0.08006827300736569)),
"ortho_lim" => Dict(
        22 => (p=(0.558918869462341, 1.7289364756843943, 5.11356423398924),
              up=(-0.023330685331405632, 0.9985169005437612, 0.04919022718434473),
              t=(0.49844454053832987, 0.0010901839953827727, -0.49989192490589607), z=2.4)),
)

const _C3_TB_CASES = [
    ("mouse", :persp, _C3_TB_MOUSE, (;)),
    ("static", :persp, _C3_TB_MOUSE, (static_moving=true, rotate_speed=2, zoom_speed=0.8, pan_speed=0.5)),
    ("limits", :persp, _C3_TB_MOUSE, (min_distance=4.5, max_distance=6, dynamic_damping_factor=0.35, no_pan=true)),
    ("norot", :persp, _C3_TB_MOUSE, (no_rotate=true, no_zoom=true, keys=("KeyR", "KeyZ", "KeyP"),
                                     mouse_buttons=(left=:pan, middle=:rotate, right=:dolly))),
    ("touch", :persp, _C3_TB_TOUCH, (;)),
    ("roll", :persp, _C3_TB_TOUCH, (multi_touch_roll=true, roll_speed=1.5)),
    ("ortho", :ortho, _C3_TB_ORTHO, (;)),
    ("ortho_lim", :ortho, _C3_TB_ORTHO, (min_zoom=1.2, max_zoom=2.5, static_moving=true)),
]

@testset "TrackballControls pointer, wheel and keyboard input follow three.js r186" begin
    # TrackballControls.js update :347, _panCamera :448, _rotateCamera :486,
    # _rollCamera :529, _getTouchRollAngle :554, _zoomCamera :599,
    # _checkDistances :738, event handlers :762-1104.
    for (name, kind, steps, kw) in _C3_TB_CASES
        _, states = _c3_tb_run(kind, steps; kw...)
        for (i, e) in _C3_TB_EXPECTED[name]
            s = states[i]
            @test _c3_close(s.p, e.p; atol=1e-12)
            @test _c3_close(s.up, e.up; atol=1e-12)
            @test _c3_close(s.t, e.t; atol=1e-12)
            @test abs(s.z - e.z) <= 1e-12
        end
    end
    # Disabled controls ignore input but update() still applies inertia.
    tc, _ = _c3_tb_run(:persp, _C3_TB_MOUSE[1:3])
    tc.enabled = false
    before = tc.camera.position
    Diff3D.trackball_pointer_down!(tc, 100, 100)
    @test length(tc.pointers) == 1  # only the drag from step 1
    Diff3D.trackball_update!(tc)
    @test tc.camera.position != before
    # Validation and the unchanged direct API.
    cam = PerspectiveCamera()
    @test_throws ArgumentError Diff3D.trackball_pointer_down!(TrackballControls(cam), 1, 1)
    @test_throws ArgumentError TrackballControls(cam; dynamic_damping_factor=1.5)
    @test_throws ArgumentError TrackballControls(cam; min_zoom=2, max_zoom=1)
    @test_throws ArgumentError TrackballControls(cam; mouse_buttons=(left=:spin, middle=:dolly, right=:pan))
    tc = TrackballControls(cam)
    @test tc.rotate_speed == 1.0 && tc.zoom_speed == 1.2 && tc.pan_speed == 0.3
    @test tc.dynamic_damping_factor == 0.2 && tc.keys == ("KeyA", "KeyS", "KeyD")
    # trackball_zoom! on an orthographic camera changes zoom, clamped.
    ortho = OrthographicCamera()
    ortho.position = Vec3(0.0, 0.0, 5.0)
    tco = TrackballControls(ortho; max_zoom=3.0)
    trackball_zoom!(tco, 0.5)
    @test ortho.zoom == 2.0 && ortho.position == Vec3(0.0, 0.0, 5.0)
    trackball_zoom!(tco, 0.5)
    @test ortho.zoom == 3.0
end

@testset "Controls reset ends a gesture; orthographic Trackball ignores distances" begin
    # Oracle: three.js r186 OrbitControls with autoRotate (speed 5): update(),
    # saveState(), right-button pointerdown (pan), reset(), update(). reset()
    # sets state NONE (OrbitControls.js:621-633), so the update auto-rotates.
    cam = PerspectiveCamera(fov=50 * π / 180, aspect=1.5, near=0.1, far=100.0)
    cam.position = Vec3(3.0, 4.0, 5.0); cam.target = Vec3(0.5, 0.0, -0.5)
    oc = OrbitControls(cam, Vec3(0.5, 0.0, -0.5); auto_rotate=true, auto_rotate_speed=5,
                       element_left=10, element_top=20, element_width=800, element_height=600)
    orbit_update!(oc); orbit_save_state!(oc)
    Diff3D.orbit_pointer_down!(oc, 300, 300; button=2)
    @test oc.state === :pan
    orbit_reset!(oc)
    @test oc.state === :none
    @test _c3_close(cam.position, (2.9519088624193714, 4.0, 5.021606915598876))
    orbit_update!(oc)
    @test _c3_close(cam.position, (2.903631002485919, 4.0, 5.04279333945336))

    # Oracle: three.js r186 TrackballControls, orthographic camera with zoom
    # 1.5: update(), wheel 900, two updates, rotate drag and update, reset()
    # (restores _zoom0 and sets state NONE, TrackballControls.js:423-445),
    # then a pointer move (ignored) and two updates (inertia only).
    ortho = OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0, near=0.1, far=100.0)
    ortho.zoom = 1.5; ortho.position = Vec3(1.0, 2.0, 5.0); ortho.target = Vec3(0.0, 0.0, 0.0)
    tc = TrackballControls(ortho, Vec3(0.5, 0.0, -0.5); element_left=10, element_top=20,
                           element_width=800, element_height=600)
    Diff3D.trackball_update!(tc); trackball_save_state!(tc)
    Diff3D.trackball_wheel!(tc, 900); Diff3D.trackball_update!(tc); Diff3D.trackball_update!(tc)
    @test isapprox(ortho.zoom, 0.9713012847078325; atol=1e-12)
    Diff3D.trackball_pointer_down!(tc, 400, 300); Diff3D.trackball_pointer_move!(tc, 450, 280)
    Diff3D.trackball_update!(tc)
    trackball_reset!(tc)
    @test ortho.zoom == 1.5 && ortho.position == Vec3(1.0, 2.0, 5.0)
    @test tc.state === :none && tc.key_state === :none
    Diff3D.trackball_pointer_move!(tc, 500, 250)
    Diff3D.trackball_update!(tc); Diff3D.trackball_update!(tc)
    @test _c3_close(ortho.position, (-0.23671533849649118, 1.5085332447234183, 5.128639085923722))
    @test _c3_close(ortho.up, (-0.07322173752649327, 0.9941581964506945, 0.07929727349350417))
    @test isapprox(ortho.zoom, 1.1865959857412491; atol=1e-12)

    # three.js minDistance/maxDistance apply to perspective cameras only
    # (TrackballControls.js:377-395), so the programmatic calls leave an
    # orthographic camera's distance alone.
    ortho2 = OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0, near=0.1, far=100.0)
    ortho2.position = Vec3(0.0, 0.0, 5.0); ortho2.target = Vec3(0.0, 0.0, 0.0)
    tc2 = TrackballControls(ortho2; min_distance=6.0, max_distance=7.0)
    trackball_rotate!(tc2, 0.3, 0.2)
    @test isapprox(norm(ortho2.position - tc2.target), 5.0; atol=1e-12)
    trackball_pan!(tc2, 0.5, -0.25)
    @test isapprox(norm(ortho2.position - tc2.target), 5.0; atol=1e-12)
    persp = PerspectiveCamera(); persp.position = Vec3(0.0, 0.0, 5.0); persp.target = Vec3(0.0, 0.0, 0.0)
    tc3 = TrackballControls(persp; min_distance=6.0, max_distance=7.0)
    trackball_rotate!(tc3, 0.3, 0.2)
    @test isapprox(norm(persp.position - tc3.target), 6.0; atol=1e-12)
end

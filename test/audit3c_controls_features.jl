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

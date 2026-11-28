using Test, Diff3D

# Oracle: node v26 running three.js r186
# (benchmarks/threejs/node_modules/three/examples/jsm/controls/ArcballControls.js)
# with a stubbed DOM element (left 10, top 20, 800 x 600), performance.now and
# requestAnimationFrame driven by the step times, and window pointermove /
# pointerup listeners delivered only while the control registered them. The
# private handlers (_onPointerDown/_onPointerMove/_onPointerUp/_onPointerCancel/
# _onWheel) receive the same events the Julia calls below replay; the camera is
# rendered (updateMatrixWorld) after every step and its state printed with full
# precision. Expected values are those prints; the same harness compared every
# step of 22 longer sequences (7,381 steps) with a worst difference of
# 1.34e-13.

const _A3C_ARC_DEG = Float64(π) / 180.0

function _a3c_arc_persp(; zoom=1.0, up=(0.0, 1.0, 0.0))
    cam = PerspectiveCamera(fov=50 * _A3C_ARC_DEG, aspect=800 / 600, near=0.1, far=100.0)
    cam.zoom = Float64(zoom)
    cam.position = Vec3(1.0, 2.0, 5.0)
    cam.up = Vec3(Float64.(up)...)
    return cam
end

function _a3c_arc_ortho(; zoom=1.5)
    cam = OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0,
                             near=0.1, far=100.0)
    cam.zoom = Float64(zoom)
    cam.position = Vec3(1.0, 2.0, 5.0)
    return cam
end

# Two BoxGeometry meshes; sizes are exact in Float32 like three.js vertex data.
function _a3c_arc_scene()
    scene = Scene()
    for (size, position, rotation) in (((2.0, 2.0, 2.0), (0.3, -0.2, 0.1), (0.3, 0.5, 0.1)),
                                       ((6.0, 0.25, 6.0), (0.0, -1.5, 0.0), (0.0, 0.2, 0.0)))
        mesh = Mesh(BoxGeometry(width=size[1], height=size[2], depth=size[3]),
                    MeshBasicMaterial())
        mesh.position = Vec3(position...)
        mesh.rotation = Euler(rotation..., :XYZ)
        add!(scene, mesh)
    end
    return scene
end

function _a3c_arc_controls(cam; target=(0.0, 0.0, 0.0), dpr=1.0, scene=false, cfg=(;))
    return Diff3D.ArcballControls(cam, scene ? _a3c_arc_scene() : nothing;
                                  target=Vec3(Float64.(target)...), element_left=10,
                                  element_top=20, element_width=800, element_height=600,
                                  device_pixel_ratio=dpr, cfg...)
end

_a3c_arc_get(s, k, default) = haskey(s, k) ? s[k] : default

# Replays one step list; returns the state after construction and after each step.
function _a3c_arc_run(ac, steps)
    snap(ac) = (p=ac.camera.position, q=Diff3D._camera_local_quaternion(ac.camera),
                up=ac.up, zoom=ac.camera.zoom,
                fov=ac.camera isa PerspectiveCamera ? ac.camera.fov : nothing,
                near=ac.camera.near, far=ac.camera.far, target=ac.target,
                tb=ac.tb_radius, anim=ac.animation_id)
    states = Any[snap(ac)]
    rets = Any[]
    clipboard = nothing
    clock = 0.0
    for s in steps
        haskey(s, :time) && (clock = Float64(s.time))
        kind = _a3c_arc_get(s, :t, :mouse)
        id = _a3c_arc_get(s, :id, 1)
        mods = (ctrl_key=_a3c_arc_get(s, :ctrl, false), meta_key=_a3c_arc_get(s, :meta, false),
                shift_key=_a3c_arc_get(s, :shift, false))
        prim = _a3c_arc_get(s, :prim, nothing)
        haskey(s, :pd) && Diff3D.arcball_pointer_down!(
            ac, s.pd...; time=clock, button=_a3c_arc_get(s, :b, 0), pointer_type=kind,
            pointer_id=id, is_primary=prim, mods...)
        haskey(s, :pm) && Diff3D.arcball_pointer_move!(
            ac, s.pm...; time=clock, pointer_type=kind, pointer_id=id, mods...)
        haskey(s, :pu) && Diff3D.arcball_pointer_up!(
            ac, s.pu...; time=clock, pointer_type=kind, pointer_id=id, is_primary=prim)
        haskey(s, :pc) && Diff3D.arcball_pointer_cancel!(ac; pointer_type=kind, pointer_id=id)
        haskey(s, :w) && Diff3D.arcball_wheel!(
            ac, s.w; delta_x=_a3c_arc_get(s, :dx, 0.0), x=_a3c_arc_get(s, :x, 0.0),
            y=_a3c_arc_get(s, :y, 0.0), mods...)
        if haskey(s, :f)
            clock = Float64(s.f)
            Diff3D.arcball_animation_frame!(ac, clock)
        end
        if haskey(s, :set)
            for (k, v) in pairs(s.set)
                setproperty!(ac, k, v)
            end
        end
        if haskey(s, :camset)
            for (k, v) in pairs(s.camset)
                setproperty!(ac.camera, k, Float64(v))
            end
        end
        haskey(s, :target) && (ac.target = Vec3(Float64.(s.target)...))
        haskey(s, :setma) && push!(rets, Diff3D.arcball_set_mouse_action!(ac, s.setma...))
        haskey(s, :unsetma) && push!(rets, Diff3D.arcball_unset_mouse_action!(ac, s.unsetma...))
        haskey(s, :save) && Diff3D.arcball_save_state!(ac)
        haskey(s, :reset) && Diff3D.arcball_reset!(ac)
        haskey(s, :copy) && (clipboard = Diff3D.arcball_copy_state(ac))
        haskey(s, :paste) && Diff3D.arcball_paste_state!(ac, clipboard)
        haskey(s, :settb) && Diff3D.arcball_set_tb_radius!(ac, s.settb)
        haskey(s, :resize) && Diff3D.arcball_resize!(ac)
        haskey(s, :setcam) && Diff3D.arcball_set_camera!(ac, ac.camera)
        for _ in 1:_a3c_arc_get(s, :u, 0)
            Diff3D.arcball_update!(ac)
        end
        push!(states, snap(ac))
    end
    return states, rets
end

_a3c_arc_t(v::Vec3) = (v.x, v.y, v.z)
_a3c_arc_near(a, b; tol=1e-11) = all(abs.(a .- b) .<= tol .* max.(1.0, abs.(b)))

function _a3c_arc_check(s, e)
    @test _a3c_arc_near(_a3c_arc_t(s.p), e.p)
    # Quaternions agree up to sign.
    q = (s.q.x, s.q.y, s.q.z, s.q.w)
    @test _a3c_arc_near(q, e.q) || _a3c_arc_near(.-q, e.q)
    @test _a3c_arc_near(_a3c_arc_t(s.up), e.up)
    @test _a3c_arc_near(s.zoom, e.zoom)
    @test e.fov === nothing ? s.fov === nothing : _a3c_arc_near(s.fov, e.fov)
    @test _a3c_arc_near(s.near, e.near)
    @test _a3c_arc_near(s.far, e.far)
    @test _a3c_arc_near(_a3c_arc_t(s.target), e.target)
    @test _a3c_arc_near(s.tb, e.tb)
    @test s.anim == e.anim
end

# Rotation drag (onSinglePanStart/Move/End, ArcballControls.js:489-910, Holroyd unprojection 2645-2776, rotate 2281) then inertia frames (onRotationAnim 2137-2205).
@testset "ArcballControls oracle: rotate_inertia" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); target=(0.2, 0.1, -0.3))
    steps = [
        (u=1,),
        (pd=(400.0, 300.0), time=0.0),
        (pm=(430.0, 290.0), time=16.0),
        (pm=(470.0, 260.0), time=32.0),
        (pm=(530.0, 250.0), time=48.0),
        (pu=(530.0, 250.0), time=56.0),
        (f=64.0,),
        (f=80.0,),
        (f=300.0,),
        (f=1500.0,),
        (f=1516.0,),
    ]
    expected = [
        (step=0, p=(1.0, 2.0, 5.0), q=(-0.16903029514053547, 0.0737532607711171, 0.012685155983804887, 0.9827656397473394), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.7112283948296336, anim=-1),
        (step=3, p=(0.43002397066008896, 1.8005986412633874, 5.1217205049923855), q=(-0.1507503384927919, 0.02414848397043669, 0.024106125368802588, 0.9879828343073283), up=(-0.054913660397336916, 0.9533864603280244, -0.2967132406296796), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.776713320593494, anim=-1),
        (step=5, p=(-1.6390176982698532, 0.6478664522211174, 5.053303303193356), q=(-0.059630826836544214, -0.1605253540998809, 0.06510990817877307, 0.9830750098740431), up=(-0.10887132806508087, 0.9844097286954837, -0.13814673349388268), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.776713320593494, anim=-1),
        (step=7, p=(-1.6390176982698532, 0.6478664522211174, 5.053303303193356), q=(-0.05963082683654422, -0.1605253540998809, 0.06510990817877307, 0.9830750098740431), up=(-0.10887132806508087, 0.9844097286954837, -0.13814673349388268), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.776713320593494, anim=2),
        (step=9, p=(-1.3193910924593886, -3.1470495796088227, -4.714535053175729), q=(-0.2444834183573324, 0.9101454762381858, -0.25578942464974336, -0.2154874485180819), up=(-0.5552697754177105, 0.7495992567713337, -0.3602449593754637), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.776713320593494, anim=4),
        (step=11, p=(-1.3193910924593886, -3.1470495796088227, -4.714535053175729), q=(-0.2444834183573324, 0.9101454762381858, -0.25578942464974336, -0.2154874485180819), up=(-0.5552697754177105, 0.7495992567713337, -0.3602449593754637), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, -0.3), tb=1.776713320593494, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Pan, CTRL pan, middle-button zoom and Shift+middle FOV drags (onSinglePanMove 616-845, pan 2207, scale 2389, setFov 2504); releasing Shift mid-drag switches the operation (onPointerMove 3143-3231).
@testset "ArcballControls oracle: pan_zoom_fov_drag" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1))
    steps = [
        (pd=(300.0, 300.0), b=2, time=0.0),
        (pm=(360.0, 340.0), time=10.0),
        (pu=(360.0, 340.0), time=20.0),
        (pd=(300.0, 300.0), time=100.0, ctrl=true),
        (pm=(250.0, 200.0), time=110.0, ctrl=true),
        (pu=(250.0, 200.0), time=120.0),
        (pd=(300.0, 300.0), b=1, time=200.0),
        (pm=(300.0, 360.0), time=210.0),
        (pu=(300.0, 360.0), time=220.0),
        (pd=(300.0, 300.0), b=1, time=300.0, shift=true),
        (pm=(300.0, 200.0), time=310.0, shift=true),
        (pu=(300.0, 200.0), time=320.0),
        (pd=(300.0, 300.0), b=1, time=400.0, shift=true),
        (pm=(300.0, 340.0), time=410.0, shift=true),
        (pm=(300.0, 380.0), time=420.0),
        (pu=(300.0, 380.0), time=430.0),
    ]
    expected = [
        (step=3, p=(0.4747184369876797, 2.317028246436012, 4.978245014028059), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=-1),
        (step=6, p=(0.9530977198102557, 1.5244576303459816, 5.199597403899556), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=-1),
        (step=9, p=(1.0323280651091464, 1.6829183209437633, 5.59574913039401), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.8468096114372523, anim=-1),
        (step=12, p=(0.9035359594275282, 1.4253341095805268, 4.9517886019859185), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.9739302599148839, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.8468096114372523, anim=-1),
        (step=16, p=(0.9530977198102557, 1.5244576303459818, 5.199597403899556), q=(-0.18490565855618135, 0.09682165484160263, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.9324938409323381, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.8468096114372523, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Wheel zoom with cursorZoom, Shift wheel FOV and deltaX (onWheel 3362-3600).
@testset "ArcballControls oracle: wheel" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); scene=true, cfg=(cursor_zoom=true,))
    steps = [
        (w=-250.0, x=600.0, y=150.0),
        (w=125.0, x=200.0, y=500.0),
        (w=-125.0, shift=true),
        (w=10.0, dx=400.0, shift=true),
        (u=1,),
    ]
    expected = [
        (step=1, p=(1.0837436502490414, 1.8867336445819345, 3.98723549806783), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.4142383428344076, anim=-1),
        (step=2, p=(1.3022057300047472, 2.16992596763665, 4.326133921489845), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5556621771178487, anim=-1),
        (step=3, p=(1.2195611019055737, 2.004636711438303, 3.912910780993977), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.9478893822791776, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5556621771178487, anim=-1),
        (step=4, p=(1.5142841850544406, 2.5940828777360365, 5.386526196738311), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.7229744002213476, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5556621771178487, anim=-1),
        (step=5, p=(1.5142841850544406, 2.5940828777360365, 5.386526196738311), q=(-0.18490565855618135, 0.09682165484160267, 0.018309268370786645, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.7229744002213476, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.555662177117849, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Orthographic rotate, pan, zoom drag and wheel with and without cursorZoom (onSinglePanMove 616-845, onWheel 3362-3600).
@testset "ArcballControls oracle: ortho_mouse" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5))
    steps = [
        (pd=(400.0, 300.0), time=0.0),
        (pm=(480.0, 260.0), time=10.0),
        (pu=(480.0, 260.0), time=200.0),
        (pd=(300.0, 300.0), b=2, time=300.0),
        (pm=(350.0, 350.0), time=310.0),
        (pu=(350.0, 350.0), time=320.0),
        (pd=(300.0, 300.0), b=1, time=400.0),
        (pm=(300.0, 250.0), time=410.0),
        (pu=(300.0, 250.0), time=420.0),
        (w=250.0, x=100.0, y=100.0),
        (set=(cursor_zoom=true,),),
        (w=-375.0, x=700.0, y=500.0),
    ]
    expected = [
        (step=3, p=(-1.0846414699766944, 0.6797248402390761, 5.325554151745033), q=(-0.06929912308256084, -0.09509613479166189, 0.06939670948079452, 0.9906252840508929), up=(-0.12431211258401237, 0.9807634565064526, -0.1504976446540461), zoom=1.5, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=6, p=(-1.450172722078648, 0.9564218498804186, 5.215791267241486), q=(-0.06929912308256084, -0.0950961347916619, 0.06939670948079452, 0.9906252840508929), up=(-0.12431211258401237, 0.9807634565064526, -0.1504976446540461), zoom=1.5, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=9, p=(-1.450172722078648, 0.9564218498804186, 5.215791267241486), q=(-0.06929912308256085, -0.09509613479166192, 0.06939670948079452, 0.9906252840508929), up=(-0.12431211258401237, 0.9807634565064526, -0.1504976446540461), zoom=1.598403355149916, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=11, p=(-1.450172722078648, 0.9564218498804186, 5.215791267241486), q=(-0.06929912308256085, -0.09509613479166192, 0.06939670948079452, 0.9906252840508929), up=(-0.12431211258401237, 0.9807634565064526, -0.1504976446540461), zoom=1.32099450838836, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=12, p=(-0.8772383149571812, 0.7063379698786126, 5.364398645998817), q=(-0.06929912308256085, -0.09509613479166192, 0.0693967094807945, 0.9906252840508929), up=(-0.12431211258401237, 0.9807634565064526, -0.1504976446540461), zoom=1.7582436906649077, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# One-finger rotation, two-finger pan/rotate/pinch, switch back to one finger, three-finger pan and inertia (onPointerDown 3059-3141, onDoublePanMove 971, onRotateMove 1024, onPinchMove 1085, onTriplePanMove 1170).
@testset "ArcballControls oracle: touch" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); dpr=2.0)
    steps = [
        (pd=(300.0, 300.0), id=1, time=0.0, t=:touch),
        (pm=(330.0, 320.0), id=1, time=10.0, t=:touch),
        (pm=(360.0, 330.0), id=1, time=20.0, t=:touch),
        (pd=(420.0, 330.0), id=2, time=30.0, t=:touch),
        (pm=(440.0, 300.0), id=2, time=40.0, t=:touch),
        (pm=(350.0, 350.0), id=1, time=50.0, t=:touch),
        (pm=(480.0, 280.0), id=2, time=60.0, t=:touch),
        (pm=(500.0, 320.0), id=2, time=70.0, t=:touch),
        (pu=(500.0, 320.0), id=2, time=80.0, t=:touch),
        (pm=(360.0, 360.0), id=1, time=90.0, t=:touch),
        (pm=(400.0, 380.0), id=1, time=100.0, t=:touch),
        (pd=(500.0, 300.0), id=3, time=110.0, t=:touch),
        (pd=(450.0, 200.0), id=4, time=120.0, t=:touch),
        (pm=(450.0, 150.0), id=4, time=130.0, t=:touch),
        (pm=(500.0, 250.0), id=3, time=140.0, t=:touch),
        (pu=(400.0, 380.0), id=1, time=150.0, t=:touch),
        (pu=(500.0, 250.0), id=3, time=160.0, t=:touch),
        (pm=(450.0, 100.0), id=4, time=170.0, t=:touch),
        (pu=(450.0, 100.0), id=4, time=180.0, t=:touch),
        (pd=(200.0, 200.0), id=5, time=300.0, t=:touch),
        (pm=(260.0, 230.0), id=5, time=310.0, t=:touch),
        (pu=(260.0, 230.0), id=5, time=315.0, t=:touch),
        (f=330.0,),
        (f=346.0,),
    ]
    expected = [
        (step=3, p=(-0.2795929442199161, 2.470092284751343, 4.880622080263368), q=(-0.23261993267884432, -0.01871271183315161, 0.03153981983084271, 0.971876042045166), up=(-0.052599690994301423, 0.8897864133710558, -0.45333587006498455), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=-1),
        (step=8, p=(-0.3135683297909675, 0.969374677200797, 1.902391037837254), q=(-0.22964394140626615, -0.04154345723523909, -0.0643800243112009, 0.9702540975466315), up=(0.14401037129447478, 0.8862377452901692, -0.44027681267882435), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=0.6711989982654123, anim=-1),
        (step=11, p=(-0.3135683297909675, 0.969374677200797, 1.902391037837254), q=(-0.22964394140626615, -0.04154345723523909, -0.0643800243112009, 0.9702540975466315), up=(0.14401037129447478, 0.8862377452901692, -0.44027681267882435), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=0.6711989982654123, anim=-1),
        (step=14, p=(-0.31127003763689165, 0.9490701815572232, 1.8622716583394092), q=(-0.22964394140626618, -0.04154345723523909, -0.0643800243112009, 0.9702540975466315), up=(0.14401037129447478, 0.8862377452901692, -0.44027681267882435), zoom=1.0, fov=0.8889997015248199, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=0.6711989982654121, anim=-1),
        (step=19, p=(-0.2896794671033453, 0.7583260916192994, 1.485382979816012), q=(-0.22964394140626618, -0.04154345723523909, -0.0643800243112009, 0.9702540975466315), up=(0.14401037129447478, 0.8862377452901692, -0.44027681267882435), zoom=1.0, fov=1.0752043684744137, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=0.6711989982654123, anim=-1),
        (step=22, p=(-0.8745400831370629, 1.0642166100695443, 1.1026931242020832), q=(-0.343197276403824, -0.22483125715119753, -0.015891786100522377, 0.9118190535469988), up=(0.1833038169321769, 0.7639261612070649, -0.6187216910061684), zoom=1.0, fov=1.0752043684744137, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=0.6711989982654123, anim=1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Orthographic pinch and three-finger dolly (onPinchMove 1085-1132, onTriplePanMove 1170-1245).
@testset "ArcballControls oracle: ortho_touch" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5))
    steps = [
        (pd=(300.0, 300.0), id=1, time=0.0, t=:touch),
        (pd=(420.0, 330.0), id=2, time=10.0, t=:touch),
        (pm=(440.0, 300.0), id=2, time=20.0, t=:touch),
        (pm=(250.0, 320.0), id=1, time=30.0, t=:touch),
        (pd=(500.0, 450.0), id=3, time=40.0, t=:touch),
        (pm=(500.0, 400.0), id=3, time=50.0, t=:touch),
        (pm=(440.0, 250.0), id=2, time=60.0, t=:touch),
        (pu=(440.0, 250.0), id=2, time=70.0, t=:touch),
        (pu=(500.0, 400.0), id=3, time=80.0, t=:touch),
        (pu=(250.0, 320.0), id=1, time=90.0, t=:touch),
        (u=1,),
    ]
    expected = [
        (step=4, p=(0.8718562882195986, 1.9137247408994016, 5.06013884599632), q=(-0.19893438733977684, 0.06316363626414515, -0.1521442240467238, 0.9660681133734096), up=(0.2688325284062391, 0.8745544892459359, -0.40358830137962226), zoom=2.316818305095056, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=7, p=(0.8718562882195986, 1.9137247408994016, 5.06013884599632), q=(-0.1989343873397769, 0.06316363626414515, -0.1521442240467238, 0.9660681133734096), up=(0.2688325284062391, 0.8745544892459359, -0.40358830137962226), zoom=11.591154372163999, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=11, p=(0.8718562882195986, 1.9137247408994016, 5.06013884599632), q=(-0.19893438733977678, 0.06316363626414512, -0.1521442240467238, 0.9660681133734096), up=(0.2688325284062391, 0.8745544892459359, -0.40358830137962226), zoom=11.591154372163999, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Double click focus with animation (onPointerUp double click 3233-3360, onDoubleTap 912-951, onFocusAnim 2070-2135, focus 1723).
@testset "ArcballControls oracle: focus_animated" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); scene=true)
    steps = [
        (pd=(420.0, 330.0), time=0.0),
        (pu=(420.0, 330.0), time=50.0),
        (pd=(424.0, 333.0), time=150.0),
        (pu=(424.0, 333.0), time=200.0),
        (f=216.0,),
        (f=300.0,),
        (f=450.0,),
        (f=716.0,),
    ]
    expected = [
        (step=4, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=3),
        (step=5, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=4),
        (step=6, p=(1.1077005337146246, 2.104320699262174, 5.347060901656814), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.6416125901312797, anim=5),
        (step=7, p=(1.2189239766008364, 2.2153488000834125, 5.711153103831518), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5772517086263733, anim=6),
        (step=8, p=(1.2589917161222752, 2.256044449150672, 5.843519117678297), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5556621771178485, anim=6),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Double tap focus without animations, and the 250 ms / 24 px double click limits (onPointerUp 3233-3360, onDoubleTap 912-951).
@testset "ArcballControls oracle: focus_static_ortho" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5); scene=true, cfg=(enable_animations=false,))
    steps = [
        (pd=(420.0, 380.0), id=1, time=0.0, t=:touch),
        (pu=(420.0, 380.0), id=1, time=50.0, t=:touch),
        (pd=(421.0, 381.0), id=2, time=100.0, t=:touch),
        (pu=(421.0, 381.0), id=2, time=150.0, t=:touch),
        (pd=(300.0, 300.0), time=1000.0),
        (pu=(300.0, 300.0), time=1300.0),
        (pd=(300.0, 300.0), time=1350.0),
        (pu=(300.0, 300.0), time=1400.0),
        (pd=(300.0, 300.0), time=2000.0),
        (pu=(300.0, 300.0), time=2050.0),
        (pd=(340.0, 300.0), time=2100.0),
        (pu=(340.0, 300.0), time=2150.0),
        (pd=(500.0, 400.0), time=3000.0),
        (pu=(500.0, 400.0), time=3050.0),
        (pd=(505.0, 402.0), time=3150.0),
        (pu=(505.0, 402.0), time=3200.0),
    ]
    expected = [
        (step=4, p=(1.3473532132007673, 2.1140578541361466, 6.362837968340365), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.6500000000000001, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=8, p=(1.3473532132007673, 2.1140578541361466, 6.362837968340365), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.6500000000000001, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=12, p=(1.3473532132007673, 2.1140578541361466, 6.362837968340365), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.6500000000000001, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=16, p=(1.836207310440436, 1.4287814553541212, 5.8713093406519565), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.8150000000000004, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# minDistance/maxDistance and minFov/maxFov clamps in scale, setFov and update (scale 2389-2502, setFov 2504, update 2891-2957).
@testset "ArcballControls oracle: limits" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); cfg=(max_fov=1.0471975511965976, min_distance=4.0, min_fov=0.5235987755982988, max_distance=7.0))
    steps = [
        (w=-2000.0,),
        (w=2000.0,),
        (w=10.0, dx=-2500.0, shift=true),
        (u=1,),
        (w=10.0, dx=2500.0, shift=true),
        (u=1,),
        (camset=(fov=1.3962634015954636,),),
        (u=1,),
        (set=(max_distance=5.0,),),
        (u=1,),
    ]
    expected = [
        (step=1, p=(0.7302967433402214, 1.4605934866804429, 3.651483716701107), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.249704523855396, anim=-1),
        (step=2, p=(1.2780193008453877, 2.5560386016907755, 6.390096504226939), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.1869829167469437, anim=-1),
        (step=4, p=(1.03221600310429, 2.06443200620858, 5.16108001552145), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=1.0471975511965976, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.1869829167469437, anim=-1),
        (step=6, p=(1.2780193008453873, 2.5560386016907746, 6.390096504226937), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971649, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.1869829167469437, anim=-1),
        (step=8, p=(1.2780193008453873, 2.5560386016907746, 6.390096504226937), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=1.0471975511965976, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.7077727624993444, anim=-1),
        (step=10, p=(0.9128709291752768, 1.8257418583505536, 4.564354645876384), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=1.0471975511965976, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.9341234017852462, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# minZoom/maxZoom clamps in scale and update (scale 2389-2502, update 2891-2957).
@testset "ArcballControls oracle: ortho_limits" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5); cfg=(max_zoom=2.0, min_zoom=0.75))
    steps = [
        (w=-2000.0,),
        (w=4000.0,),
        (camset=(zoom=5.0,),),
        (u=1,),
        (camset=(zoom=0.25,),),
        (u=1,),
    ]
    expected = [
        (step=1, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=2.0, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=2, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=0.75, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=4, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=0.8, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=6, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=2.0, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# adjustNearFar after zoom, FOV drag and pinch (applyTransformMatrix 1551-1642).
@testset "ArcballControls oracle: near_far" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); scene=true, cfg=(adjust_near_far=true,))
    steps = [
        (w=-250.0,),
        (w=500.0,),
        (pd=(400.0, 300.0), b=1, time=0.0),
        (pm=(400.0, 380.0), time=10.0),
        (pu=(400.0, 380.0), time=20.0),
        (pd=(300.0, 300.0), id=1, time=100.0, t=:touch),
        (pd=(500.0, 300.0), id=2, time=110.0, t=:touch),
        (pm=(600.0, 300.0), id=2, time=120.0, t=:touch),
    ]
    expected = [
        (step=1, p=(0.8264462809917354, 1.652892561983471, 4.132231404958677), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.09999999999999964, far=100.0, target=(0.0, 0.0, 0.0), tb=1.4142383428344079, anim=-1),
        (step=2, p=(1.2100000000000002, 2.4200000000000004, 6.050000000000001), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=1.2502173707608488, far=101.15021737076084, target=(0.0, 0.0, 0.0), tb=2.070586357743857, anim=-1),
        (step=5, p=(1.3394841154960062, 2.6789682309920124, 6.69742057748003), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=1.9594310797185166, far=101.85943107971852, target=(0.0, 0.0, 0.0), tb=2.292163252860022, anim=-1),
        (step=8, p=(0.6638982596255264, 1.8567545373721068, 4.482454995110076), q=(-0.18490565855618135, 0.09682165484160264, 0.018309268370786627, 0.9778037815836903), up=(-0.07161148740394327, 0.9309493362512627, -0.3580574370197164), zoom=1.0, fov=0.8726646259971648, near=0.09999999999999964, far=100.0, target=(0.0, 0.0, 0.0), tb=1.5281088352400147, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Orthographic adjustNearFar (applyTransformMatrix 1551-1642).
@testset "ArcballControls oracle: ortho_near_far" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5); cfg=(adjust_near_far=true,))
    steps = [
        (w=-250.0,),
        (w=500.0,),
    ]
    expected = [
        (step=1, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.8150000000000004, fov=nothing, near=0.09999999999999964, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=2, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.09682165484160261, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.2396694214876032, fov=nothing, near=0.09999999999999964, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# saveState, copyState, reset, pasteState, setTbRadius and window resize (saveState 2359, copyState 2301, reset 2238, setStateFromJSON 2959, setTbRadius 1969, onWindowResize 3008).
@testset "ArcballControls oracle: state" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1); target=(0.2, 0.1, 0.0))
    steps = [
        (pd=(400.0, 300.0), time=0.0),
        (pm=(460.0, 260.0), time=10.0),
        (pu=(460.0, 260.0), time=200.0),
        (save=true,),
        (w=-250.0,),
        (copy=true,),
        (reset=true,),
        (u=1,),
        (paste=true,),
        (settb=0.4,),
        (camset=(aspect=1.0,),),
        (resize=true,),
    ]
    expected = [
        (step=3, p=(-0.05742835132002247, 1.2258002366668745, 5.283588219293539), q=(-0.10547990184770845, -0.02015159142496401, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.7112283948296336, anim=-1),
        (step=4, p=(-0.05742835132002247, 1.2258002366668745, 5.283588219293539), q=(-0.10547990184770845, -0.02015159142496401, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.7112283948296336, anim=-1),
        (step=5, p=(-0.012750703570266475, 1.0304134187329541, 4.366601834126891), q=(-0.10547990184770847, -0.02015159142496401, 0.0358096649473349, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.3964484731218825, anim=-1),
        (step=6, p=(-0.012750703570266475, 1.0304134187329541, 4.366601834126891), q=(-0.10547990184770847, -0.02015159142496401, 0.0358096649473349, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.3964484731218825, anim=-1),
        (step=8, p=(-0.05742835132002247, 1.2258002366668745, 5.283588219293539), q=(-0.1054799018477084, -0.020151591424964, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.6897026524774783, anim=-1),
        (step=9, p=(-0.012750703570266475, 1.0304134187329541, 4.366601834126891), q=(-0.10547990184770842, -0.020151591424963994, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=1.3964484731218825, anim=-1),
        (step=10, p=(-0.012750703570266475, 1.0304134187329541, 4.366601834126891), q=(-0.10547990184770842, -0.020151591424963994, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=0.833700580968288, anim=-1),
        (step=12, p=(-0.012750703570266475, 1.0304134187329541, 4.366601834126891), q=(-0.10547990184770842, -0.020151591424963994, 0.03580966494733491, 0.9935721270071936), up=(-0.06690779416711631, 0.9751833164051148, -0.2110470243448425), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.2, 0.1, 0.0), tb=0.833700580968288, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# setMouseAction/unsetMouseAction return values and the edited bindings in use (setMouseAction 1328-1407, unsetMouseAction 1409-1432, getOpStateFromAction 1476).
@testset "ArcballControls oracle: mouse_actions" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1))
    steps = [
        (setma=(:rotate, 2, :shift),),
        (setma=(:pan, :wheel),),
        (setma=(:fov, 0, :ctrl),),
        (setma=(:zoom, 3),),
        (setma=(:zoom, 2),),
        (unsetma=(1,),),
        (unsetma=(1,),),
        (unsetma=(:wheel, :shift),),
        (unsetma=(0, :ctrl),),
        (pd=(300.0, 300.0), b=2, time=0.0, shift=true),
        (pm=(340.0, 280.0), time=10.0, shift=true),
        (pu=(340.0, 280.0), time=200.0),
        (w=125.0, ctrl=true),
    ]
    expected = [
        (step=9, p=(1.0, 2.0, 5.0), q=(-0.18490565855618135, 0.0968216548416026, 0.018309268370786627, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=-1),
        (step=12, p=(0.2074707289677945, 1.6542848510607682, 5.217307497950683), q=(-0.15174017446500865, 0.026496888658685328, 0.047521730831952685, 0.9869217392698743), up=(-0.10184174350726875, 0.9494332091041284, -0.29699299777879645), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.7112283948296336, anim=-1),
        (step=13, p=(0.22821780186457397, 1.8197133361668452, 5.739038247745752), q=(-0.15174017446500865, 0.026496888658685325, 0.047521730831952685, 0.9869217392698743), up=(-0.10184174350726875, 0.9494332091041284, -0.29699299777879645), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.8823512343125972, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
    @test rets == Any[true, false, true, false, true, true, false, true, true]
    # Final bindings, in three.js order (setMouseAction 1328-1407).
    @test [(a.operation, a.mouse, a.key) for a in ac.mouse_actions] ==
          [(:zoom, 2, nothing), (:rotate, 0, nothing), (:zoom, :wheel, nothing), (:fov, 1, :shift), (:rotate, 2, :shift)]
end

# Random mixed touch sequence (prefix of a 490-step differential run).
@testset "ArcballControls oracle: random_persp_touch" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(zoom=1))
    steps = [
        (u=1,),
        (pd=(394.0, 592.0), id=3, time=13.0, t=:touch),
        (pd=(434.0, 552.0), id=4, time=21.0, t=:touch),
        (pm=(413.0, 533.0), id=4, time=42.0, t=:touch),
        (pm=(383.0, 535.0), id=4, time=56.0, t=:touch),
        (pu=(383.0, 535.0), id=4, time=85.0, t=:touch),
        (pm=(401.0, 623.0), id=3, time=90.0, t=:touch),
        (pm=(388.0, 618.0), id=3, time=109.0, t=:touch),
        (pu=(388.0, 618.0), id=3, time=163.0, t=:touch),
        (f=173.0,),
        (pd=(211.0, 169.0), id=3, time=209.0, t=:touch),
        (pd=(302.0, 441.0), id=4, time=222.0, t=:touch),
        (pm=(261.0, 136.0), id=3, time=235.0, t=:touch),
        (pm=(280.0, 106.0), id=3, time=256.0, t=:touch),
        (pu=(302.0, 441.0), id=4, time=277.0, t=:touch),
        (pm=(295.0, 141.0), id=3, time=285.0, t=:touch),
        (pm=(279.0, 116.0), id=3, time=298.0, t=:touch),
        (pu=(279.0, 116.0), id=3, time=320.0, t=:touch),
        (f=333.0,),
        (pd=(297.0, 253.0), id=3, time=357.0, t=:touch),
        (pd=(427.0, 503.0), id=4, time=384.0, t=:touch),
        (pm=(437.0, 477.0), id=4, time=411.0, t=:touch),
        (pm=(329.0, 205.0), id=3, time=430.0, t=:touch),
        (pm=(420.0, 495.0), id=4, time=450.0, t=:touch),
        (pm=(327.0, 224.0), id=3, time=465.0, t=:touch),
        (pm=(394.0, 508.0), id=4, time=495.0, t=:touch),
        (pu=(327.0, 224.0), id=3, time=513.0, t=:touch),
        (pm=(377.0, 497.0), id=4, time=528.0, t=:touch),
        (pu=(377.0, 497.0), id=4, time=567.0, t=:touch),
        (pd=(661.0, 361.0), id=3, time=598.0, t=:touch),
        (pd=(373.0, 303.0), id=4, time=617.0, t=:touch),
        (pm=(652.0, 385.0), id=3, time=624.0, t=:touch),
        (pm=(343.0, 277.0), id=4, time=643.0, t=:touch),
        (pm=(621.0, 405.0), id=3, time=649.0, t=:touch),
        (pm=(613.0, 359.0), id=3, time=669.0, t=:touch),
        (pu=(343.0, 277.0), id=4, time=697.0, t=:touch),
        (pu=(613.0, 359.0), id=3, time=751.0, t=:touch),
        (f=763.0,),
        (pd=(144.0, 328.0), id=3, time=779.0, t=:touch),
        (pd=(337.0, 62.0), id=4, time=813.0, t=:touch),
        (pm=(190.0, 292.0), id=3, time=818.0, t=:touch),
        (pm=(374.0, 85.0), id=4, time=834.0, t=:touch),
        (pm=(200.0, 331.0), id=3, time=847.0, t=:touch),
        (pm=(236.0, 365.0), id=3, time=854.0, t=:touch),
        (pm=(354.0, 104.0), id=4, time=866.0, t=:touch),
        (pu=(236.0, 365.0), id=3, time=895.0, t=:touch),
        (pm=(387.0, 79.0), id=4, time=912.0, t=:touch),
        (pu=(387.0, 79.0), id=4, time=935.0, t=:touch),
        (f=953.0,),
        (f=966.0,),
        (pd=(620.0, 231.0), id=3, time=1003.0, t=:touch),
        (pd=(513.0, 145.0), id=4, time=1030.0, t=:touch),
        (pm=(636.0, 213.0), id=3, time=1041.0, t=:touch),
        (pm=(474.0, 139.0), id=4, time=1060.0, t=:touch),
        (pm=(675.0, 200.0), id=3, time=1081.0, t=:touch),
        (pm=(491.0, 188.0), id=4, time=1092.0, t=:touch),
        (pm=(665.0, 186.0), id=3, time=1106.0, t=:touch),
        (pm=(692.0, 154.0), id=3, time=1110.0, t=:touch),
        (pm=(498.0, 218.0), id=4, time=1135.0, t=:touch),
        (pu=(692.0, 154.0), id=3, time=1156.0, t=:touch),
        (pm=(510.0, 257.0), id=4, time=1166.0, t=:touch),
        (pm=(526.0, 239.0), id=4, time=1175.0, t=:touch),
        (pm=(495.0, 276.0), id=4, time=1180.0, t=:touch),
        (pm=(501.0, 301.0), id=4, time=1185.0, t=:touch),
        (pu=(501.0, 301.0), id=4, time=1236.0, t=:touch),
        (f=1256.0,),
        (pd=(784.0, 440.0), id=1, time=1292.0, t=:touch),
        (pm=(779.0, 398.0), id=1, time=1300.0, t=:touch),
        (pm=(749.0, 436.0), id=1, time=1330.0, t=:touch),
        (pm=(757.0, 455.0), id=1, time=1346.0, t=:touch),
        (pm=(739.0, 483.0), id=1, time=1363.0, t=:touch),
        (pm=(714.0, 450.0), id=1, time=1385.0, t=:touch),
        (pm=(750.0, 472.0), id=1, time=1400.0, t=:touch),
        (pu=(750.0, 472.0), id=1, time=1433.0, t=:touch),
        (f=1451.0,),
        (pd=(655.0, 349.0), id=1, time=1469.0, t=:touch),
        (pm=(658.0, 360.0), id=1, time=1498.0, t=:touch),
        (pm=(696.0, 317.0), id=1, time=1512.0, t=:touch),
        (pm=(672.0, 345.0), id=1, time=1526.0, t=:touch),
        (pm=(711.0, 308.0), id=1, time=1532.0, t=:touch),
        (pm=(741.0, 276.0), id=1, time=1536.0, t=:touch),
        (pm=(691.0, 260.0), id=1, time=1544.0, t=:touch),
        (pu=(691.0, 260.0), id=1, time=1567.0, t=:touch),
        (f=1583.0,),
        (f=1600.0,),
        (pd=(190.0, 432.0), id=3, time=1605.0, t=:touch),
        (pd=(67.0, 143.0), id=4, time=1615.0, t=:touch),
        (pm=(201.0, 472.0), id=3, time=1629.0, t=:touch),
        (pm=(66.0, 146.0), id=4, time=1634.0, t=:touch),
        (pm=(163.0, 446.0), id=3, time=1654.0, t=:touch),
    ]
    expected = [
        (step=10, p=(2.7554727791367615, 0.7987460471190523, 4.976113470934179), q=(-0.20871786126885436, -0.0011788976702173557, -0.4422974535395334, 0.872243330258296), up=(0.7720741216809384, 0.5216196339595991, -0.36306267792002744), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.6675083476599706, anim=-1),
        (step=20, p=(2.34894118078532, 0.00034192087172990604, 4.447509605211014), q=(-0.12239843928692977, 0.04514796838723704, -0.3371400081731317, 0.9323716522394113), up=(0.6176274911776359, 0.7427104738982888, -0.25868404300110676), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.4246109214550222, anim=-1),
        (step=30, p=(2.259542070149559, 0.0011173872925605366, 4.300745670216244), q=(-0.11587942977564908, 0.05993058271234859, -0.21931075007061204, 0.9668935194291531), up=(0.4102108424671842, 0.8769495053166719, -0.2503729814640695), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.3757101633873579, anim=-1),
        (step=40, p=(2.4305185547873567, -0.17344980452593697, 4.494456705200378), q=(-0.1128664556111152, 0.06542843561598782, -0.17260624031594016, 0.9763131509995268), up=(0.3222661334817608, 0.9149364980035603, -0.2429727224025305), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.432288406744186, anim=-1),
        (step=50, p=(2.1421851234043605, 0.09544726057463085, 5.188475790935667), q=(-0.11891710648511487, 0.05365108362912337, -0.2706783067551758, 0.9537890423268552), up=(0.5035799427074152, 0.8251839520747176, -0.2558880351660596), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.6433359179568652, anim=-1),
        (step=60, p=(2.775191476804203, 0.9876262899194304, 3.1104326376287204), q=(-0.13010246520865987, -0.009647048045949269, -0.6932808430644261, 0.7087608592822457), up=(0.9852508615740536, 0.0048700423730168585, -0.1710468428672991), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.1043069849009342, anim=-1),
        (step=70, p=(3.3523585604493658, 0.6544643009072556, 3.0125980701579467), q=(-0.14772827116999226, 0.09505555134537336, -0.6304363727742069, 0.7561023607547153), up=(0.9252640749897103, 0.1614526755608528, -0.3432483431681469), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.1043069849009342, anim=-1),
        (step=80, p=(2.9823509303911884, 1.497736064975463, 2.9205522462879863), q=(-0.20655911375542413, -0.03483032141418607, -0.6661354466364863, 0.7158098546186461), up=(0.9680416750726419, 0.02719379851796544, -0.24931067495139064), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.1043069849009342, anim=-1),
        (step=90, p=(2.7627694247072094, 0.2120772751843445, 3.174783918102811), q=(-0.05405575041848992, 0.031249057454568345, -0.7767090099351185, 0.6267571987145444), up=(0.9702375440654103, -0.21239782053539616, -0.11630251036729743), zoom=1.0, fov=0.8726646259971648, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=1.1000831469211572, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

# Random mixed mouse/wheel/inertia sequence (prefix of a 366-step differential run).
@testset "ArcballControls oracle: random_ortho_mouse" begin
    ac = _a3c_arc_controls(_a3c_arc_ortho(zoom=1.5))
    steps = [
        (pd=(735.0, 574.0), b=2, time=38.0, ctrl=true),
        (pm=(773.0, 523.0), time=58.0, meta=true),
        (pm=(729.0, 578.0), time=68.0),
        (pm=(684.0, 630.0), time=77.0),
        (pu=(684.0, 630.0), b=2, time=95.0),
        (f=114.0,),
        (f=128.0,),
        (f=141.0,),
        (f=160.0,),
        (pd=(382.0, 367.0), b=1, time=214.0, meta=true),
        (pm=(360.0, 391.0), time=287.0, meta=true),
        (pm=(394.0, 339.0), time=314.0, meta=true),
        (pm=(414.0, 361.0), time=338.0, meta=true),
        (pm=(364.0, 382.0), time=362.0, ctrl=true),
        (pu=(364.0, 382.0), b=1, time=399.0),
        (f=411.0,),
        (f=422.0,),
        (pd=(272.0, 293.0), b=0, time=461.0),
        (pm=(260.0, 340.0), time=487.0),
        (pm=(244.0, 392.0), time=491.0),
        (pu=(244.0, 392.0), b=0, time=525.0),
        (f=538.0,),
        (f=554.0,),
        (pd=(657.0, 248.0), b=1, time=600.0, ctrl=true),
        (pm=(667.0, 238.0), time=608.0, ctrl=true),
        (pm=(644.0, 278.0), time=674.0, ctrl=true),
        (pm=(611.0, 324.0), time=704.0, ctrl=true),
        (pm=(632.0, 269.0), time=714.0, ctrl=true),
        (pu=(632.0, 269.0), b=1, time=752.0),
        (f=766.0,),
        (f=786.0,),
        (f=800.0,),
        (f=812.0,),
        (f=822.0,),
        (w=-125.0, x=76.0, y=40.0),
        (pd=(312.0, 176.0), b=0, time=871.0),
        (pm=(356.0, 178.0), time=901.0),
        (pm=(341.0, 207.0), time=922.0),
        (pm=(339.0, 174.0), time=942.0, meta=true),
        (pm=(364.0, 189.0), time=972.0, ctrl=true),
        (pu=(364.0, 189.0), b=0, time=989.0),
        (f=1009.0,),
        (w=-375.0, x=623.0, y=110.0),
        (f=1027.0,),
        (f=1045.0,),
        (f=1058.0,),
        (f=1070.0,),
        (f=1089.0,),
        (f=1100.0,),
        (f=1120.0,),
        (f=1132.0,),
        (f=1151.0,),
        (u=1,),
        (pd=(73.0, 136.0), b=0, time=1199.0, shift=true),
        (pm=(64.0, 182.0), time=1394.0, shift=true),
        (pu=(64.0, 182.0), b=0, time=1488.0),
        (f=1508.0,),
        (f=1527.0,),
        (f=1540.0,),
        (f=1550.0,),
        (f=1563.0,),
        (pd=(569.0, 423.0), b=0, time=1599.0, meta=true),
        (pm=(618.0, 405.0), time=1615.0, meta=true),
        (pm=(624.0, 459.0), time=1622.0, shift=true),
        (pm=(665.0, 485.0), time=1645.0, meta=true),
        (pm=(672.0, 523.0), time=1656.0),
        (pm=(654.0, 469.0), time=1682.0),
        (pm=(611.0, 450.0), time=1687.0),
        (pu=(611.0, 450.0), b=0, time=1711.0),
        (f=1726.0,),
        (f=1739.0,),
        (pd=(250.0, 413.0), b=1, time=1795.0, ctrl=true),
        (pm=(290.0, 416.0), time=1895.0, ctrl=true),
        (pm=(297.0, 421.0), time=1911.0, ctrl=true),
        (pm=(276.0, 397.0), time=1916.0, ctrl=true),
        (pm=(334.0, 381.0), time=1943.0),
        (pm=(389.0, 335.0), time=1972.0),
        (pu=(389.0, 335.0), b=1, time=2012.0),
        (f=2022.0,),
        (f=2033.0,),
        (f=2045.0,),
        (w=125.0, x=712.0, y=284.0, ctrl=true),
        (f=2059.0,),
        (f=2075.0,),
        (f=2090.0,),
        (f=2108.0,),
        (f=2127.0,),
        (pd=(692.0, 207.0), b=0, time=2157.0, meta=true),
        (pm=(705.0, 220.0), time=2161.0, meta=true),
        (pm=(680.0, 262.0), time=2331.0),
    ]
    expected = [
        (step=10, p=(1.3066624744374407, 2.3475544188671384, 4.7996457375656565), q=(-0.18490565855618135, 0.09682165484160261, 0.01830926837078663, 0.9778037815836903), up=(0.0, 1.0, 0.0), zoom=1.5, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=20, p=(2.518681922097686, 3.630585456038154, 3.5849696566173237), q=(-0.35919765286247385, 0.15945478938144245, -0.16020858550472636, 0.9054746961964119), up=(0.17557806840890947, 0.6906205106173291, -0.7015808237177353), zoom=1.4716777435893966, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=30, p=(3.4241438966175535, 3.8539158589158324, 2.625727660316926), q=(-0.4482091180763291, 0.20278999827037536, -0.2588424689459827, 0.8312553033483085), up=(0.24854369752730543, 0.4642183254863745, -0.8501337404797447), zoom=1.43292272462966, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=40, p=(2.737252279774708, 4.9322516478843745, 1.5623133945231853), q=(-0.5518716302717678, 0.1649383851019041, -0.18532715685664228, 0.7961701311607908), up=(0.11305426260325768, 0.32218309726522953, -0.9399025404497093), zoom=1.5762149970926262, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=50, p=(2.737252279774708, 4.9322516478843745, 1.5623133945231853), q=(-0.5518716302717678, 0.1649383851019041, -0.18532715685664228, 0.7961701311607908), up=(0.11305426260325768, 0.32218309726522953, -0.9399025404497093), zoom=2.097942161130286, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=60, p=(2.7751597629654543, 4.985956997427568, 1.367725258223413), q=(-0.5824281180650664, 0.10152753195598609, -0.2748385039935289, 0.7582436575829107), up=(0.29852412628750574, 0.17048256801956807, -0.9390522030354514), zoom=2.097942161130286, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=70, p=(3.0357745418823208, 3.5710240036142333, 3.151493447747321), q=(-0.4210999799501933, 0.11481230149338463, -0.4553656589748979, 0.7759736200014121), up=(0.6100085619243605, 0.23063384702460749, -0.7580881103048667), zoom=2.097942161130286, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=8),
        (step=80, p=(3.255445284872217, 2.360373970005205, 3.7497860431865373), q=(-0.3184378646211448, 0.18570942978766017, -0.4810330894202225, 0.7954347873624235), up=(0.6469870778713427, 0.3344089865167234, -0.6852578717565813), zoom=2.316551200176183, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
        (step=90, p=(3.266479389452515, 2.435557264961897, 3.7068112681713057), q=(-0.3184378646211448, 0.18570942978766017, -0.4810330894202225, 0.7954347873624235), up=(0.6469870778713427, 0.3344089865167234, -0.6852578717565813), zoom=2.105955636523803, fov=nothing, near=0.1, far=100.0, target=(0.0, 0.0, 0.0), tb=2.0100000000000002, anim=-1),
    ]
    states, rets = _a3c_arc_run(ac, steps)
    for e in expected
        _a3c_arc_check(states[e.step + 1], e)
    end
end

@testset "ArcballControls defaults follow three.js r186" begin
    cam = _a3c_arc_persp()
    ac = Diff3D.ArcballControls(cam)
    @test ac.camera === cam && ac.scene === nothing
    @test ac.target == Vec3(0.0, 0.0, 0.0)                         # ArcballControls.js:138
    @test ac.radius_factor == 0.67                                  # :147
    @test ac.focus_animation_time == 500.0                          # :249
    @test ac.adjust_near_far == false                               # :275
    @test ac.scale_factor == 1.1                                    # :283
    @test ac.damping_factor == 25.0                                 # :291
    @test ac.w_max == 20.0                                          # :299
    @test ac.enable_animations && !ac.enable_grid                   # :307, :316
    @test ac.cursor_zoom == false                                   # :324
    @test ac.min_fov == 5 * _A3C_ARC_DEG && ac.max_fov == 90 * _A3C_ARC_DEG  # :332, :340 (degrees there)
    @test ac.rotate_speed == 1.0                                    # :348
    @test ac.enable_pan && ac.enable_rotate && ac.enable_zoom       # :356-372
    @test ac.enable_gizmos && ac.enable_focus                       # :380, :388
    @test ac.min_distance == 0.0 && ac.max_distance == Inf          # :396, :404
    @test ac.min_zoom == 0.0 && ac.max_zoom == Inf                  # :412, :420
    @test ac.enabled && ac.state === :idle
    # initializeMouseActions, ArcballControls.js:1274-1287.
    @test [(a.operation, a.mouse, a.key) for a in ac.mouse_actions] ==
          [(:pan, 0, :ctrl), (:pan, 2, nothing), (:rotate, 0, nothing), (:zoom, :wheel, nothing),
           (:zoom, 1, nothing), (:fov, :wheel, :shift), (:fov, 1, :shift)]
    # The camera is aimed at the target with lookAt (setCamera, ArcballControls.js:1913-1955).
    @test cam.target == ac.target && cam.up == Vec3(0.0, 1.0, 0.0)
    @test ac.gizmos_visible && !ac.gizmos_active && !ac.grid_active
end

@testset "ArcballControls mouse action edits reject invalid input" begin
    ac = Diff3D.ArcballControls(_a3c_arc_persp())
    before = copy(ac.mouse_actions)
    # setMouseAction returns false for unknown inputs and pan/rotate on the
    # wheel (ArcballControls.js:1328-1350).
    @test !Diff3D.arcball_set_mouse_action!(ac, :spin, 0)
    @test !Diff3D.arcball_set_mouse_action!(ac, :pan, 3)
    @test !Diff3D.arcball_set_mouse_action!(ac, :pan, true)
    @test !Diff3D.arcball_set_mouse_action!(ac, :pan, 0, :alt)
    @test !Diff3D.arcball_set_mouse_action!(ac, :rotate, :wheel)
    @test !Diff3D.arcball_unset_mouse_action!(ac, 2, :shift)
    @test !Diff3D.arcball_unset_mouse_action!(ac, true)
    @test ac.mouse_actions == before
end

@testset "ArcballControls state values, gizmo flags and grid" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(); scene=true, cfg=(enable_grid=true,))
    st = Diff3D.arcball_copy_state(ac)
    @test st isa Diff3D.ArcballState
    @test st.camera_fov == 50 * _A3C_ARC_DEG && st.camera_zoom == 1.0
    @test st.camera_near == 0.1 && st.camera_far == 100.0 && st.target == ac.target
    # The state is a value: later gestures do not change it.
    Diff3D.arcball_wheel!(ac, -250.0)
    @test st.camera_matrix != Diff3D.arcball_copy_state(ac).camera_matrix
    Diff3D.arcball_paste_state!(ac, st)
    @test _a3c_arc_near(_a3c_arc_t(ac.camera.position), (1.0, 2.0, 5.0); tol=1e-12)
    ortho = Diff3D.ArcballControls(_a3c_arc_ortho(); element_width=800, element_height=600)
    @test Diff3D.arcball_copy_state(ortho).camera_fov === nothing
    @test_throws ArgumentError Diff3D.arcball_paste_state!(ac, Diff3D.arcball_copy_state(ortho))
    # The grid shows during a pan with enable_grid and a scene (drawGrid,
    # ArcballControls.js:1754; onSinglePanStart 489-615).
    Diff3D.arcball_pointer_down!(ac, 300, 300; time=0.0, button=2)
    @test ac.grid_active
    Diff3D.arcball_dispose_grid!(ac)
    @test !ac.grid_active
    Diff3D.arcball_pointer_up!(ac, 300, 300; time=10.0)
    # Rotation highlights the gizmos (activateGizmos, ArcballControls.js:1850).
    Diff3D.arcball_pointer_down!(ac, 400, 300; time=100.0)
    @test ac.gizmos_active
    Diff3D.arcball_pointer_up!(ac, 400, 300; time=400.0)
    @test !ac.gizmos_active
    Diff3D.arcball_activate_gizmos!(ac, true)
    @test ac.gizmos_active
    Diff3D.arcball_set_gizmos_visible!(ac, false)               # setGizmosVisible, :1957
    @test !ac.gizmos_visible
end

@testset "ArcballControls disabled input and animation frames" begin
    ac = _a3c_arc_controls(_a3c_arc_persp(); cfg=(enabled=false,))
    p = ac.camera.position
    Diff3D.arcball_pointer_down!(ac, 400, 300; time=0.0)
    Diff3D.arcball_pointer_move!(ac, 450, 300; time=10.0)
    Diff3D.arcball_pointer_up!(ac, 450, 300; time=20.0)
    Diff3D.arcball_wheel!(ac, 125.0)
    @test ac.camera.position == p
    # A frame with nothing requested does nothing.
    Diff3D.arcball_animation_frame!(ac, 30.0)
    @test ac.camera.position == p && ac.animation_id == -1
end

@testset "ArcballControls validates its input" begin
    cam = _a3c_arc_persp()
    @test_throws ArgumentError Diff3D.ArcballControls(cam; min_distance=5, max_distance=1)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; min_zoom=-1)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; min_fov=0.0)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; max_fov=Float64(π))
    @test_throws ArgumentError Diff3D.ArcballControls(cam; min_fov=1.0, max_fov=0.5)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; scale_factor=0)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; damping_factor=-1)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; w_max=true)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; w_max=NaN)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; focus_animation_time=0)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; device_pixel_ratio=0)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; rotate_speed=NaN)
    @test_throws ArgumentError Diff3D.ArcballControls(cam; target=Vec3(NaN, 0.0, 0.0))
    # A camera parented to a non-Scene object is rejected (setCamera,
    # ArcballControls.js:1915-1919).
    holder = Group()
    child = _a3c_arc_persp()
    add!(holder, child)
    @test_throws ArgumentError Diff3D.ArcballControls(child)
    # Pointer input needs the element size.
    ac = Diff3D.ArcballControls(cam)
    @test_throws ArgumentError Diff3D.arcball_pointer_down!(ac, 1, 1; time=0.0)
    ac = _a3c_arc_controls(_a3c_arc_persp())
    @test_throws ArgumentError Diff3D.arcball_pointer_down!(ac, 1, 1; time=0.0, pointer_type=:stylus)
    @test_throws ArgumentError Diff3D.arcball_set_tb_radius!(ac, NaN)
    ac.scale_factor = -1.0
    @test_throws ArgumentError Diff3D.arcball_update!(ac)
end

@testset "ArcballControls public names are documented" begin
    for name in (:ArcballControls, :ArcballState, :arcball_pointer_down!,
                 :arcball_pointer_move!, :arcball_pointer_up!, :arcball_pointer_cancel!,
                 :arcball_wheel!, :arcball_animation_frame!, :arcball_update!,
                 :arcball_set_mouse_action!, :arcball_unset_mouse_action!,
                 :arcball_save_state!, :arcball_reset!, :arcball_copy_state,
                 :arcball_paste_state!, :arcball_set_camera!, :arcball_set_tb_radius!,
                 :arcball_set_gizmos_visible!, :arcball_activate_gizmos!,
                 :arcball_dispose_grid!, :arcball_resize!)
        @test isdefined(Diff3D, name)
        @test Base.Docs.hasdoc(Diff3D, name)
    end
end

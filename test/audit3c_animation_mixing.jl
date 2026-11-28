using Test, Diff3D

# Multi-action mixing (three.js r186 AnimationMixer / AnimationAction /
# PropertyMixer / AnimationUtils.makeClipAdditive). Oracle numbers come from
# three.js r186 (0.186.0) run in node with Float64Array keyframe buffers;
# file:line references are to src/animation/ of that tree.

# Scene of the scripted oracle sequence: object A, mesh M with morph targets
# a/b/c, point light L.
function _mixing_scene()
    A = Group()
    A.position = Vec3(0.5, -0.25, 1.0)
    A.rotation = Euler(0.3, -0.2, 0.1, :XYZ)
    M = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.2, 0.4, 0.6],
             morph_target_names=["a", "b", "c"])
    L = PointLight()
    L.intensity = 1.5
    walk = AnimationClip("walk", 1.2, AbstractKeyframeTrack[
        KeyframeTrack(A, :position, [0.0, 0.5, 1.2],
                      [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 2.0, 0.0), Vec3(2.0, 0.0, -1.0)]),
        QuaternionKeyframeTrack(A, :quaternion, [0.0, 0.6, 1.2],
                                [Quaternion(0.0, 0.0, 0.0, 1.0), Quaternion(0.6, 0.0, 0.0, 0.8),
                                 Quaternion(0.0, 0.28, 0.0, 0.96)]),
        NumberKeyframeTrack(L, :intensity, [0.0, 0.4, 0.8, 1.2], [1.0, 3.0, 0.5, 2.0];
                            interpolation=:cubic),
        NumberKeyframeTrack(M, :visible, [0.0, 0.3], [1.0, 0.0]; interpolation=:step),
    ])
    run = AnimationClip("run", 0.8, AbstractKeyframeTrack[
        KeyframeTrack(A, :position, [0.0, 0.3, 0.8],
                      [Vec3(0.0, 1.0, 0.0), Vec3(0.5, -1.0, 2.0), Vec3(1.0, 1.0, 1.0)];
                      interpolation=:cubic),
        QuaternionKeyframeTrack(A, :quaternion, [0.0, 0.8],
                                [Quaternion(0.36, 0.48, 0.0, 0.8), Quaternion(0.0, 0.0, 0.6, 0.8)]),
        MorphWeightsKeyframeTrack(M, :morph_target_influences, [0.0, 0.8],
                                  [[1.0, 0.0, 0.0], [0.0, 1.0, 0.5]]),
    ])
    wave = AnimationClip("wave", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(A, :position, [0.0, 1.0], [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.5, 0.0)]),
        QuaternionKeyframeTrack(A, :quaternion, [0.0, 1.0],
                                [Quaternion(0.0, 0.0, 0.0, 1.0), Quaternion(0.6, 0.0, 0.0, 0.8)]),
        NumberKeyframeTrack(M, "morphTargetInfluences[c]", [0.0, 0.5, 1.0], [0.0, 1.0, 0.0]),
        NumberKeyframeTrack(L, :intensity, [0.0, 1.0], [0.0, 1.0]),
    ])
    return A, M, L, walk, run, Diff3D.clip_make_additive(wave, 15, wave, 30)
end

function _mixing_apply!(mixer, acts, op)
    kind = op[1]
    if kind === :play
        Diff3D.action_play!(acts[op[2]])
    elseif kind === :stop
        Diff3D.action_stop!(acts[op[2]])
    elseif kind === :reset
        Diff3D.action_reset!(acts[op[2]])
    elseif kind === :weight
        Diff3D.action_set_effective_weight!(acts[op[2]], op[3])
    elseif kind === :update
        mixer_update!(mixer, op[2])
    elseif kind === :set_time
        mixer_set_time!(mixer, op[2])
    elseif kind === :cross_fade_to
        Diff3D.action_cross_fade_to!(acts[op[2]], acts[op[3]], op[4]; warp=op[5])
    elseif kind === :halt
        Diff3D.action_halt!(acts[op[2]], op[3])
    elseif kind === :loop
        Diff3D.action_set_loop!(acts[op[2]], op[3], op[4])
    elseif kind === :clamp
        acts[op[2]].clamp_when_finished = op[3]
    elseif kind === :fade_in
        Diff3D.action_fade_in!(acts[op[2]], op[3])
    elseif kind === :mixer_time_scale
        mixer.time_scale = op[2]
    elseif kind === :start_at
        Diff3D.action_start_at!(acts[op[2]], op[3])
    elseif kind === :sync
        Diff3D.action_sync_with!(acts[op[2]], acts[op[3]])
    elseif kind === :duration
        Diff3D.action_set_duration!(acts[op[2]], op[3])
    elseif kind === :stop_all
        Diff3D.mixer_stop_all_action!(mixer)
    end
    return nothing
end

_mixing_quat(r::Euler) = (q = quat_from_euler(r.x, r.y, r.z; order=r.order); [q.x, q.y, q.z, q.w])

const _MIXING_OPS = Any[
    (:play, 1), (:play, 2), (:play, 3), (:weight, 2, 0.4), (:update, 0.1), (:update, 0.25),
    (:cross_fade_to, 1, 2, 0.3, true), (:update, 0.1), (:update, 0.1), (:update, 0.1),
    (:update, 0.1), (:halt, 3, 0.2), (:update, 0.15), (:update, 0.15),
    (:loop, 2, :pingpong, 2), (:clamp, 2, true), (:update, 0.5), (:update, 0.5),
    (:update, 0.5), (:reset, 1), (:fade_in, 1, 0.4), (:update, 0.2), (:stop, 2),
    (:update, 0.05), (:mixer_time_scale, -1.0), (:update, 0.2), (:mixer_time_scale, 1.0),
    (:start_at, 2, 0.3), (:play, 2), (:update, 0.1), (:update, 0.4), (:set_time, 0.7),
    (:sync, 3, 1), (:duration, 1, 0.6), (:update, 0.3), (:stop_all,),
]

# After each op of _MIXING_OPS: A.position (3), A.quaternion (x, y, z, w), the
# three morph influences of M, L.intensity, M.visible, the effective weight
# of walk/run/wave and their clip-local times, printed by three.js r186.
const _MIXING_EXPECTED = [
    0.5 -0.25 1.0 0.1435721750273919 -0.10602051106179562 0.034270798550482096 0.9833474432563558 0.2 0.4 0.6 1.5 1.0 1.0 1.0 1.0 0.0 0.0 0.0
    0.5 -0.25 1.0 0.1435721750273919 -0.10602051106179562 0.034270798550482096 0.9833474432563558 0.2 0.4 0.6 1.5 1.0 1.0 1.0 1.0 0.0 0.0 0.0
    0.5 -0.25 1.0 0.1435721750273919 -0.10602051106179562 0.034270798550482096 0.9833474432563558 0.2 0.4 0.6 1.5 1.0 1.0 1.0 1.0 0.0 0.0 0.0
    0.5 -0.25 1.0 0.1435721750273919 -0.10602051106179562 0.034270798550482096 0.9833474432563558 0.2 0.4 0.6 1.5 1.0 1.0 0.4 1.0 0.0 0.0 0.0
    0.17142857142857143 0.2317460317460317 0.13333333333333336 -0.07904649242536668 0.11845539939380645 0.05749326877165106 0.9881368804146778 0.47000000000000003 0.29 -0.20000000000000007 0.92421875 1.0 1.0 0.4 1.0 0.1 0.1 0.1
    0.6627142857142856 0.6415714285714282 0.5895714285714286 0.23983429425003033 0.07839477502709816 0.09405171764395535 0.9630618074444977 0.345 0.415 0.29999999999999993 2.78798828125 0.0 1.0 0.4 1.0 0.35 0.35 0.35
    0.6627142857142856 0.6415714285714282 0.5895714285714286 0.23983429425003033 0.07839477502709816 0.09405171764395535 0.9630618074444977 0.345 0.415 0.29999999999999993 2.78798828125 0.0 1.0 0.4 1.0 0.35 0.35 0.35
    0.8133948753890998 1.071189108663265 0.464864161128795 0.35240277872859965 0.011378065063455022 0.05694899357930753 0.9340447705062526 0.23537037436608915 0.417962965325073 0.4999999999999999 2.314969056927496 0.0 0.6666666269302368 0.13333334922790527 1.0 0.4666666746139526 0.4277777791023254 0.44999999999999996
    0.7971647109709923 0.437590606815918 0.8127217654206351 0.3441111518511727 0.01591983618938744 0.1341195502045657 0.9291641513964513 0.24111111534966356 0.46555556403266063 0.5000000000000001 1.6437499506399087 1.0 0.333333283662796 0.26666669845581054 1.0 0.600000011920929 0.5166666686534881 0.5499999999999999
    0.6715629637373817 0.09772099250039912 1.1420222193620824 0.22024477407636173 0.00799510796486149 0.22479342981971145 0.9491555360690753 0.21166666567325598 0.548333334326744 0.30000000000000016 1.65 1.0 0.0 0.4 1.0 0.700000011920929 0.6166666686534881 0.6499999999999999
    0.6990740743610593 0.3404321012379209 1.0249999984326186 0.2597560995723239 -0.001027778902439297 0.25640566262229475 0.931011196807387 0.161666665673256 0.5983333343267441 0.1000000000000002 1.75 1.0 0.0 0.4 1.0 0.700000011920929 0.716666668653488 0.7499999999999999
    0.6990740743610593 0.3404321012379209 1.0249999984326186 0.2597560995723239 -0.001027778902439297 0.25640566262229475 0.931011196807387 0.161666665673256 0.5983333343267441 0.1000000000000002 1.75 1.0 0.0 0.4 1.0 0.700000011920929 0.716666668653488 0.7499999999999999
    0.3244718804150124 0.277426260053519 0.7117146828603022 0.40554760843216103 0.12984413652893423 0.021993924289025323 0.9045373982309293 0.486666665673256 0.273333334326744 0.025000013411045185 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.06666666865348803 0.7874999932944774
    0.44132373277460746 -0.2410922591714249 1.2174554246386053 0.3802190466739145 0.1060861962540849 0.07958232197787768 0.9153391991711757 0.411666665673256 0.348333334326744 0.414166667163372 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.21666666865348802 0.7874999932944774
    0.44132373277460746 -0.2410922591714249 1.2174554246386053 0.3802190466739145 0.1060861962540849 0.07958232197787768 0.9153391991711757 0.411666665673256 0.348333334326744 0.414166667163372 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.21666666865348802 0.7874999932944774
    0.44132373277460746 -0.2410922591714249 1.2174554246386053 0.3802190466739145 0.1060861962540849 0.07958232197787768 0.9153391991711757 0.411666665673256 0.348333334326744 0.414166667163372 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.21666666865348802 0.7874999932944774
    0.33460219350453113 0.22859225246590212 0.7584705016405335 0.40283827790559223 0.1273675126373247 0.02847599015628566 0.9059182946398957 0.478333334326744 0.281666665673256 0.380833332836628 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.716666668653488 0.7874999932944774
    0.7 0.3937499966472387 1.0 0.2640559652793113 -0.014620529955655805 0.2829884737757262 0.9219426289169581 0.12 0.64 0.56 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.8 0.7874999932944774
    0.3 0.3937499966472387 0.6 0.4161124783750063 0.13932741239074914 -0.0041262793847191 0.8985662197721141 0.52 0.24 0.36 1.7874999932944773 1.0 0.0 0.4 1.0 0.700000011920929 0.8 0.7874999932944774
    0.3 0.3937499966472387 0.6 0.4161124783750063 0.13932741239074914 -0.0041262793847191 0.8985662197721141 0.52 0.24 0.36 1.7874999932944773 1.0 0.0 0.4 1.0 0.0 0.8 0.7874999932944774
    0.3 0.3937499966472387 0.6 0.4161124783750063 0.13932741239074914 -0.0041262793847191 0.8985662197721141 0.52 0.24 0.36 1.7874999932944773 1.0 0.0 0.4 1.0 0.0 0.8 0.7874999932944774
    0.25 0.9187499966472388 0.09999999999999998 0.4443051298906313 0.1871176105079405 -0.03145356930365366 0.8755516114820007 0.52 0.24 0.36 2.0531249932944773 1.0 0.5 0.4 1.0 0.2 0.8 0.7874999932944774
    0.25 0.9187499966472388 0.09999999999999998 0.4443051298906313 0.1871176105079405 -0.03145356930365366 0.8755516114820007 0.2 0.4 0.6 2.0531249932944773 1.0 0.5 0.4 1.0 0.2 0.0 0.7874999932944774
    0.5 0.6749999966472386 0.375 0.39561560871221185 -0.03686056049769877 0.020024781158534267 0.9174576815104959 0.2 0.4 0.6 2.3523803643882273 1.0 0.625 0.4 1.0 0.25 0.0 0.7874999932944774
    0.5 0.6749999966472386 0.375 0.39561560871221185 -0.03686056049769877 0.020024781158534267 0.9174576815104959 0.2 0.4 0.6 2.3523803643882273 1.0 0.625 0.4 1.0 0.25 0.0 0.7874999932944774
    0.4499999642372131 -0.049999963119626095 0.8749999105930328 0.3116370115163475 -0.0857383122761301 0.04657799330910239 0.9451781871163226 0.2 0.4 0.6 1.7361693901737452 1.0 0.12500008940696716 0.4 1.0 0.04999999999999999 0.0 0.7874999932944774
    0.4499999642372131 -0.049999963119626095 0.8749999105930328 0.3116370115163475 -0.0857383122761301 0.04657799330910239 0.9451781871163226 0.2 0.4 0.6 1.7361693901737452 1.0 0.12500008940696716 0.4 1.0 0.04999999999999999 0.0 0.7874999932944774
    0.4499999642372131 -0.049999963119626095 0.8749999105930328 0.3116370115163475 -0.0857383122761301 0.04657799330910239 0.9451781871163226 0.2 0.4 0.6 1.7361693901737452 1.0 0.12500008940696716 0.4 1.0 0.04999999999999999 0.0 0.7874999932944774
    0.4499999642372131 -0.049999963119626095 0.8749999105930328 0.3116370115163475 -0.0857383122761301 0.04657799330910239 0.9451781871163226 0.2 0.4 0.6 1.7361693901737452 1.0 0.12500008940696716 0.4 1.0 0.04999999999999999 0.0 0.7874999932944774
    0.6249999940395354 0.7125000219792126 0.6249999701976776 0.2717246218531131 0.024544892390360066 0.26297683862707233 0.9254223146661416 0.12 0.64 0.56 1.8455444315011844 1.0 0.3750000298023224 0.4 1.0 0.15 0.8 0.7874999932944774
    1.0510204081632653 1.755994894606422 0.2346938775510204 0.5778138376382058 0.03526664420883578 0.1884439127859107 0.7933324174480663 0.12 0.64 0.56 2.5038085870444773 0.0 1.0 0.4 1.0 0.55 0.8 0.7874999932944774
    0.9183673469387753 1.056122448979592 -0.20408163265306115 0.18282337873049237 0.16934610599188804 0.05644870199729601 0.9668045576111914 0.52 0.24 0.36 0.4492187500000009 0.0 1.0 0.4 1.0 0.7 0.0 0.0
    0.9183673469387753 1.056122448979592 -0.20408163265306115 0.18282337873049237 0.16934610599188804 0.05644870199729601 0.9668045576111914 0.52 0.24 0.36 0.4492187500000009 0.0 1.0 0.4 1.0 0.7 0.0 0.7
    0.9183673469387753 1.056122448979592 -0.20408163265306115 0.18282337873049237 0.16934610599188804 0.05644870199729601 0.9668045576111914 0.52 0.24 0.36 0.4492187500000009 0.0 1.0 0.4 1.0 0.7 0.0 0.7
    0.14285714285714265 0.671428571428571 0.0 0.3102717423687046 0.14340673340848775 -0.018559060918778757 0.9395858214971148 0.52 0.24 0.20000000000000007 1.699999999999999 1.0 1.0 0.4 1.0 0.09999999999999987 0.0 0.7
    0.5 -0.25 1.0 0.1435721750273919 -0.10602051106179562 0.034270798550482096 0.9833474432563558 0.2 0.4 0.6 1.5 1.0 1.0 0.4 1.0 0.0 0.0 0.0
]

@testset "audit3c mixing: simultaneous actions blend like three.js PropertyMixer" begin
    # walk and run are normal actions on A.position (linear and smooth),
    # A.quaternion (slerp accumulation, PropertyMixer.js:130-170, 336), the
    # whole influence vector, a smooth scalar and a Bool (BooleanKeyframeTrack
    # in three.js: _select, PropertyMixer.js:324); wave is additive
    # (accumulateAdditive/apply, PropertyMixer.js:172-248). The sequence
    # covers a warped cross-fade (AnimationAction.js:334-372), halt, Float32
    # fade ramps (AnimationMixer.js:506), ping-pong with clamping, a negative
    # mixer time scale, startAt, setTime, syncWith, setDuration and
    # stopAllAction, which restores every original value.
    A, M, L, walk, run, wave = _mixing_scene()
    mixer = Diff3D.AnimationActionMixer()
    acts = [Diff3D.mixer_clip_action(mixer, clip) for clip in (walk, run, wave)]
    @test size(_MIXING_EXPECTED) == (length(_MIXING_OPS), 18)
    for (k, op) in enumerate(_MIXING_OPS)
        _mixing_apply!(mixer, acts, op)
        e = _MIXING_EXPECTED[k, :]
        @test [A.position.x, A.position.y, A.position.z] ≈ e[1:3] atol=1e-12
        q = _mixing_quat(A.rotation)
        s = sum(q .* e[4:7]) < 0 ? -1.0 : 1.0
        @test s .* q ≈ e[4:7] atol=1e-12
        @test M.morph_target_influences ≈ e[8:10] atol=1e-12
        @test L.intensity ≈ e[11] atol=1e-12
        @test M.visible == (e[12] == 1.0)
        @test [Diff3D.action_effective_weight(a) for a in acts] ≈ e[13:15] atol=1e-12
        @test [a.time for a in acts] ≈ e[16:18] atol=1e-12
    end
    @test !any(Diff3D.action_is_scheduled, acts)
    @test mixer.n_active_bindings == 0
end

@testset "audit3c mixing: clip_make_additive matches AnimationUtils.makeClipAdditive" begin
    # AnimationUtils.js:263-372 with reference frame 15 at 30 fps (time 0.5):
    # numbers subtract the interpolated reference, quaternions are multiplied
    # by its normalized conjugate. Values printed by node.
    A, M, L, walk, run, wave = _mixing_scene()
    @test wave.blend_mode === :additive
    @test [p for v in wave.tracks[1].values for p in (v.x, v.y, v.z)] ≈
          [0.0, -0.25, 0.0, 0.0, 0.25, 0.0] atol=1e-15
    @test [p for q in wave.tracks[2].values for p in (q.x, q.y, q.z, q.w)] ≈
          [-0.31622776601683794, 0.0, 0.0, 0.9486832980505139,
           0.31622776601683794, 0.0, 0.0, 0.9486832980505139] atol=1e-15
    @test wave.tracks[3].values == [-1.0, 0.0, -1.0]
    @test wave.tracks[4].values == [-0.5, 0.5]
    @test wave.tracks[3].morph_name == "c"

    # The source clip is unchanged (three.js edits it in place), and the
    # time vectors are new.
    obj = Group()
    flag = Mesh(BoxGeometry(), MeshBasicMaterial())
    base = AnimationClip("base", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :position, [0.0, 1.0], [Vec3(1.0, 2.0, 3.0), Vec3(2.0, 2.0, 2.0)]),
        NumberKeyframeTrack(flag, :visible, [0.0, 1.0], [1.0, 0.0]; interpolation=:step),
        NumberKeyframeTrack(obj, "position[y]", [0.0, 1.0], [4.0, 6.0]),
    ]; loop=:pingpong, repetitions=3)
    add = Diff3D.clip_make_additive(base)
    @test base.blend_mode === :normal
    @test base.tracks[1].values[1] == Vec3(1.0, 2.0, 3.0)
    @test add.tracks[1].times !== base.tracks[1].times
    @test add.tracks[1].values == [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, -1.0)]
    # A number track that drives a Bool property is a three.js 'bool' track,
    # which makeClipAdditive skips (AnimationUtils.js:278).
    @test add.tracks[2] === base.tracks[2]
    @test add.tracks[3].values == [0.0, 2.0]
    @test (add.loop, add.repetitions, add.duration) == (:pingpong, 3, 1.0)

    # A reference clip is matched by target, property and kind of value;
    # unmatched tracks stay; fps <= 0 means 30 (frame 15 -> time 0.5).
    ref = AnimationClip("ref", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :position, [0.0, 1.0], [Vec3(0.0, 0.0, 0.0), Vec3(2.0, 4.0, 6.0)]),
        NumberKeyframeTrack(obj, "position[x]", [0.0], [9.0]),
    ])
    add = Diff3D.clip_make_additive(base, 15, ref, 0)
    @test add.tracks[1].values == [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, -1.0)]
    @test add.tracks[3] === base.tracks[3]

    # Cubic-spline tracks subtract the spline value at the reference time and
    # keep their tangents. (three.js r186 slices the value out of a
    # one-value result buffer here and subtracts undefined, giving NaN.)
    spline = Diff3D.CubicSplineKeyframeTrack(obj, :position, [0.0, 2.0],
                                             [Vec3(0.0, 0.0, 0.0), Vec3(4.0, 0.0, 0.0)],
                                             [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0)],
                                             [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0)])
    clip = AnimationClip("spline", AbstractKeyframeTrack[spline])
    add = Diff3D.clip_make_additive(clip, 30)          # time 1: Hermite midpoint 2
    @test add.tracks[1].values == [Vec3(-2.0, 0.0, 0.0), Vec3(2.0, 0.0, 0.0)]
    @test add.tracks[1].in_tangents == spline.in_tangents
end

@testset "audit3c mixing: clip blend modes and players that apply clips directly" begin
    obj = Group()
    tr = KeyframeTrack(obj, :position, [0.0, 1.0], [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0)])
    # AnimationClip.js:31 defaults blendMode to NormalAnimationBlendMode.
    clip = AnimationClip("c", AbstractKeyframeTrack[tr])
    @test clip.blend_mode === :normal
    @test AnimationClip("c", 1.0, AbstractKeyframeTrack[tr]; blend_mode=:additive).blend_mode ===
          :additive
    @test_throws ArgumentError AnimationClip("c", AbstractKeyframeTrack[tr]; blend_mode=:add)
    # The 2.0 positional form still builds a normal clip.
    old = AnimationClip("c", 1.0, AbstractKeyframeTrack[tr], :repeat, -1, false, 1.0)
    @test old.blend_mode === :normal && old.duration == 1.0
    # Clip utilities keep the blend mode (AnimationClip.clone, AnimationUtils.js:185).
    add = Diff3D.clip_make_additive(clip)
    for derived in (clip_subclip(add, "s", 0, 30), clip_trim(add), clip_optimize(add),
                    clip_reset_duration(add))
        @test derived.blend_mode === :additive
    end
    # Players that write clip values directly reject additive clips instead
    # of playing the offsets as poses.
    @test_throws ArgumentError AnimationMixer(add)
    @test_throws ArgumentError AnimationMixer(add, 0.0, :repeat, -1, false, 1.0)
    mktempdir() do dir
        @test_throws ArgumentError save_gltf(joinpath(dir, "a.gltf"), obj; animations=[add])
        @test !isfile(joinpath(dir, "a.gltf"))
        scene = Scene()
        add!(scene, obj)
        case = WebGLExportCase("a", "A", "", scene; animations=[add])
        @test_throws ArgumentError save_webgl_html(joinpath(dir, "a.html"), [case])
        @test !isfile(joinpath(dir, "a.html"))
    end
end

@testset "audit3c mixing: one action at weight 1 reproduces AnimationMixer" begin
    # A single normal action at weight 1 copies its sample into the
    # accumulator and writes it unmixed (PropertyMixer.js:130-160, 198-248),
    # and a finished unclamped action mixes in the original with weight 1, so
    # the pose equals the single-clip AnimationMixer's.
    function scene()
        obj = Group()
        obj.position = Vec3(0.3, -0.2, 0.1)
        obj.rotation = Euler(0.2, 0.1, -0.3, :XYZ)
        mesh = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.5, 0.25],
                    morph_target_names=["a", "b"])
        light = PointLight()
        t = [0.0, 0.3, 0.7, 1.0]
        clip = AnimationClip("c", 1.0, AbstractKeyframeTrack[
            KeyframeTrack(obj, :position, t, [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 2.0, 0.0),
                                              Vec3(-1.0, 0.0, 1.0), Vec3(0.5, 0.5, 0.5)];
                          interpolation=:cubic),
            QuaternionKeyframeTrack(obj, :quaternion, t[[1, 4]],
                                    [Quaternion(0.0, 0.0, 0.0, 1.0), Quaternion(0.0, 0.6, 0.0, 0.8)]),
            MorphWeightsKeyframeTrack(mesh, :morph_target_influences, t[[1, 4]],
                                      [[0.0, 1.0], [1.0, 0.0]]),
            NumberKeyframeTrack(light, :intensity, t, [1.0, 2.0, 0.0, 3.0]),
            NumberKeyframeTrack(mesh, :visible, t[1:2], [1.0, 0.0]; interpolation=:step),
        ])
        return obj, mesh, light, clip
    end
    for loop in (:repeat, :once, :pingpong), clamp in (false, true)
        o1, m1, l1, c1 = scene()
        o2, m2, l2, c2 = scene()
        legacy = AnimationMixer(c1; loop=loop, repetitions=2, clamp_when_finished=clamp)
        mixer = Diff3D.AnimationActionMixer()
        action = Diff3D.mixer_clip_action(mixer, c2)
        Diff3D.action_set_loop!(action, loop, 2)
        action.clamp_when_finished = clamp
        Diff3D.action_play!(action)
        for dt in (0.1, 0.25, 0.4, -0.15, 0.6, 0.35, 0.9, 1.3)
            mixer_update!(legacy, dt)
            mixer_update!(mixer, dt)
            @test o2.position === o1.position
            @test m2.morph_target_influences == m1.morph_target_influences
            @test l2.intensity === l1.intensity
            @test m2.visible == m1.visible
            q1 = _mixing_quat(o1.rotation)
            q2 = _mixing_quat(o2.rotation)
            @test (sum(q1 .* q2) < 0 ? -q2 : q2) ≈ q1 atol=1e-14
            @test (action.time, action.enabled, action.paused) ==
                  (legacy.action_time, legacy.enabled, legacy.paused)
        end
    end
end

@testset "audit3c mixing: Euler, material, Bool and parent morph properties" begin
    # Euler angles blend component-wise: weights 0.25 and 0.75 average the
    # angles; one action at 0.5 mixes with the original. (three.js r186
    # Euler.fromArray ignores the PropertyMixer offset; Diff3D blends.)
    obj = Group()
    obj.rotation = Euler(0.1, 0.2, 0.3, :ZYX)
    tilt(v) = AnimationClip("r", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :rotation, [0.0, 1.0], [v, v])])
    mixer = Diff3D.AnimationActionMixer()
    a = Diff3D.mixer_clip_action(mixer, tilt(Vec3(1.0, 0.0, 0.0)))
    b = Diff3D.mixer_clip_action(mixer, tilt(Vec3(0.0, 1.0, 0.0)))
    Diff3D.action_play!(a); Diff3D.action_play!(b)
    Diff3D.action_set_effective_weight!(a, 0.25)
    Diff3D.action_set_effective_weight!(b, 0.75)
    mixer_update!(mixer, 0.1)
    @test (obj.rotation.x, obj.rotation.y, obj.rotation.z, obj.rotation.order) ==
          (0.25, 0.75, 0.0, :ZYX)
    Diff3D.action_stop!(b)
    Diff3D.action_set_effective_weight!(a, 0.5)
    mixer_update!(mixer, 0.1)
    @test [obj.rotation.x, obj.rotation.y, obj.rotation.z] ≈ [0.55, 0.1, 0.15] atol=1e-15
    Diff3D.mixer_stop_all_action!(mixer)
    @test obj.rotation == Euler(0.1, 0.2, 0.3, :ZYX)

    # A material property at weight 0.25 keeps 3/4 of its original value
    # (PropertyMixer.apply mixes the original by 1 - weight).
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial(; opacity=1.0, transparent=true))
    fade = AnimationClip("o", 1.0, AbstractKeyframeTrack[
        NumberKeyframeTrack(mesh, "material.opacity", [0.0, 1.0], [0.0, 0.0])])
    mixer = Diff3D.AnimationActionMixer()
    act = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, fade))
    Diff3D.action_set_effective_weight!(act, 0.25)
    mixer_update!(mixer, 0.5)
    @test mesh.material.opacity == 0.75
    Diff3D.action_stop!(act)
    @test mesh.material.opacity == 1.0

    # A Bool selects the incoming value only with at least half the weight
    # (PropertyMixer._select, PropertyMixer.js:324).
    for (weight, visible) in ((0.6, false), (0.4, true))
        flag = Mesh(BoxGeometry(), MeshBasicMaterial())
        hide = AnimationClip("h", 1.0, AbstractKeyframeTrack[
            NumberKeyframeTrack(flag, :visible, [0.0, 1.0], [0.0, 0.0]; interpolation=:step)])
        mixer = Diff3D.AnimationActionMixer()
        act = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, hide))
        Diff3D.action_set_effective_weight!(act, weight)
        mixer_update!(mixer, 0.5)
        @test flag.visible == visible
    end

    # A morph track bound to a parent drives each descendant's own morph
    # target of that name, with a binding (and original) per mesh.
    root = Group()
    m1 = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.1, 0.2],
              morph_target_names=["a", "b"])
    m2 = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.3, 0.4],
              morph_target_names=["b", "a"])
    add!(root, m1); add!(root, m2)
    smile = AnimationClip("s", 1.0, AbstractKeyframeTrack[
        NumberKeyframeTrack(root, "morphTargetInfluences[b]", [0.0, 1.0], [1.0, 1.0])])
    mixer = Diff3D.AnimationActionMixer()
    act = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, smile))
    Diff3D.action_set_effective_weight!(act, 0.5)
    mixer_update!(mixer, 0.5)
    @test m1.morph_target_influences ≈ [0.1, 0.6] atol=1e-15
    @test m2.morph_target_influences ≈ [0.65, 0.4] atol=1e-15
    Diff3D.action_stop!(act)
    @test m1.morph_target_influences == [0.1, 0.2]
    @test m2.morph_target_influences == [0.3, 0.4]
end

@testset "audit3c mixing: actions per clip, scheduling and state" begin
    obj = Group()
    clip = AnimationClip("c", 2.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :position, [0.0, 2.0], [Vec3(0.0, 0.0, 0.0), Vec3(2.0, 0.0, 0.0)])])
    mixer = Diff3D.AnimationActionMixer()
    @test Diff3D.mixer_existing_action(mixer, clip) === nothing
    a = Diff3D.mixer_clip_action(mixer, clip)
    # clipAction returns the cached action for the same clip and blend mode,
    # otherwise a new one that becomes the clip's existing action
    # (AnimationMixer.js:557-640).
    @test Diff3D.mixer_clip_action(mixer, clip) === a
    b = Diff3D.mixer_clip_action(mixer, clip; blend_mode=:additive)
    @test b !== a && b.blend_mode === :additive
    @test Diff3D.mixer_existing_action(mixer, clip) === b
    c = Diff3D.mixer_clip_action(mixer, clip)
    @test c !== a && c.blend_mode === :normal
    @test length(mixer.actions) == 3
    @test (a.loop, a.repetitions, a.time_scale, a.weight) == (:repeat, -1, 1.0, 1.0)

    # isRunning needs a played, enabled, unpaused action with a nonzero time
    # scale that is not waiting for startAt (AnimationAction.js:220-249).
    @test !Diff3D.action_is_running(a) && !Diff3D.action_is_scheduled(a)
    Diff3D.action_play!(a)
    @test Diff3D.action_is_running(a) && Diff3D.action_is_scheduled(a)
    Diff3D.action_start_at!(a, 0.5)
    @test !Diff3D.action_is_running(a)
    mixer_update!(mixer, 0.25)
    @test a.time == 0.0 && obj.position.x == 0.0
    mixer_update!(mixer, 0.5)            # mixer time 0.75: runs from 0.5
    @test a.time == 0.25 && Diff3D.action_is_running(a)
    @test obj.position.x == 0.25
    a.time_scale = 0.0
    @test !Diff3D.action_is_running(a)
    Diff3D.action_set_effective_time_scale!(a, 2.0)
    @test Diff3D.action_effective_time_scale(a) == 2.0
    Diff3D.action_set_duration!(a, 4.0)  # duration 2 over 4 s
    @test a.time_scale == 0.5
    Diff3D.action_sync_with!(c, a)
    @test (c.time, c.time_scale) == (0.25, 0.5)
    a.paused = true
    Diff3D.action_set_effective_time_scale!(a, 3.0)
    @test Diff3D.action_effective_time_scale(a) == 0.0
    a.enabled = false
    Diff3D.action_set_effective_weight!(a, 0.7)
    @test a.weight == 0.7 && Diff3D.action_effective_weight(a) == 0.0
    Diff3D.action_stop!(a)
    @test (a.enabled, a.paused, a.time, a.start_time) == (true, false, 0.0, nothing)
    @test obj.position.x == 0.0
    # A fade lends one ramp from the mixer pool; stopping returns it.
    Diff3D.action_fade_in!(a, 1.0)
    Diff3D.action_warp!(a, 1.0, 2.0, 1.0)
    @test mixer.n_active_control_interpolants == 2
    Diff3D.action_stop_fading!(a); Diff3D.action_stop_warping!(a)
    @test mixer.n_active_control_interpolants == 0
    @test sprint(show, a) == "AnimationAction(\"c\", normal, stopped)"
end

@testset "audit3c mixing: originals come back as AnimationMixer restores them" begin
    # A morph-weight track narrower or wider than a driven mesh's influences
    # writes a vector of the track's width while it plays (as AnimationMixer
    # does). Once no action contributes (finished, faded out, or weight 0),
    # PropertyMixer.apply mixes in the original with weight 1, and the mesh
    # gets its own vector back, not one cut or padded to the track's width.
    for width in (2, 4), finish in (:once, :weight, :fade)
        root = Group()
        m1 = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.1, 0.2, 0.3])
        m2 = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.4, 0.5, 0.6])
        add!(root, m1); add!(root, m2)
        clip = AnimationClip("w", 1.0, AbstractKeyframeTrack[
            MorphWeightsKeyframeTrack(root, :morph_target_influences, [0.0, 1.0],
                                      [fill(0.9, width), fill(0.7, width)])])
        legacy_root = Group()
        l1 = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=[0.1, 0.2, 0.3])
        add!(legacy_root, l1)
        legacy = AnimationMixer(AnimationClip("w", 1.0, AbstractKeyframeTrack[
            MorphWeightsKeyframeTrack(legacy_root, :morph_target_influences, [0.0, 1.0],
                                      [fill(0.9, width), fill(0.7, width)])]); loop=:once)
        mixer = Diff3D.AnimationActionMixer()
        act = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, clip))
        Diff3D.action_set_loop!(act, :once)
        mixer_update!(mixer, 0.5); mixer_update!(legacy, 0.5)
        @test m1.morph_target_influences == fill(0.8, width) == l1.morph_target_influences
        if finish === :once
            mixer_update!(mixer, 1.0); mixer_update!(legacy, 1.0)
            @test l1.morph_target_influences == [0.1, 0.2, 0.3]
        elseif finish === :weight
            Diff3D.action_set_effective_weight!(act, 0.0)
            mixer_update!(mixer, 0.1)
        else
            Diff3D.action_fade_out!(act, 0.2)
            mixer_update!(mixer, 0.1); mixer_update!(mixer, 0.15)
            @test !act.enabled
        end
        @test m1.morph_target_influences == [0.1, 0.2, 0.3]
        @test m2.morph_target_influences == [0.4, 0.5, 0.6]
        Diff3D.action_stop!(act)
        @test m1.morph_target_influences == [0.1, 0.2, 0.3]
    end

    # A quaternion track drives the rotation through its quaternion; when the
    # action stops contributing or stops, the original Euler angles come
    # back as they were (y = 2 is outside the range a quaternion converts
    # to), as AnimationMixer restores them.
    for (track, stop) in ((:quaternion, false), (:quaternion, true), (:component, false),
                          (:component, true))
        obj = Group()
        obj.rotation = Euler(0.3, 2.0, -0.1, :XYZ)
        tr = track === :quaternion ?
            QuaternionKeyframeTrack(obj, :quaternion, [0.0, 1.0],
                                    [Quaternion(0.0, 0.0, 0.0, 1.0), Quaternion(0.0, 0.6, 0.0, 0.8)]) :
            NumberKeyframeTrack(obj, "quaternion[y]", [0.0, 1.0], [0.1, 0.3])
        legacy_obj = Group()
        legacy_obj.rotation = obj.rotation
        legacy = AnimationMixer(AnimationClip("q", 1.0, AbstractKeyframeTrack[
            track === :quaternion ?
                QuaternionKeyframeTrack(legacy_obj, :quaternion, tr.times, tr.values) :
                NumberKeyframeTrack(legacy_obj, "quaternion[y]", tr.times, tr.values)]);
            loop=:once)
        mixer = Diff3D.AnimationActionMixer()
        act = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer,
                                                           AnimationClip("q", 1.0, AbstractKeyframeTrack[tr])))
        Diff3D.action_set_loop!(act, :once)
        mixer_update!(mixer, 0.5); mixer_update!(legacy, 0.5)
        @test obj.rotation != Euler(0.3, 2.0, -0.1, :XYZ)
        if stop
            Diff3D.action_stop!(act); mixer_stop!(legacy)
        else
            mixer_update!(mixer, 1.0); mixer_update!(legacy, 1.0)
        end
        @test legacy_obj.rotation === Euler(0.3, 2.0, -0.1, :XYZ)
        @test obj.rotation === Euler(0.3, 2.0, -0.1, :XYZ)
    end
end

@testset "audit3c mixing: invalid inputs are rejected without changing state" begin
    obj = Group()
    clip = AnimationClip("c", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :position, [0.0, 1.0], [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0)])])
    mixer = Diff3D.AnimationActionMixer()
    a = Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, clip))
    other = Diff3D.mixer_clip_action(Diff3D.AnimationActionMixer(), clip)
    @test_throws ArgumentError Diff3D.action_cross_fade_to!(a, other, 0.5)
    @test a.weight_interpolant === nothing
    # A warp divides by the time scale (AnimationAction.js:475-500): with a
    # zero time scale three.js stores Infinity/NaN; Diff3D refuses.
    a.time_scale = 0.0
    @test_throws ArgumentError Diff3D.action_halt!(a, 1.0)
    @test a.time_scale_interpolant === nothing
    a.time_scale = 1.0
    @test_throws ArgumentError Diff3D.action_set_duration!(a, 0.0)
    @test_throws ArgumentError Diff3D.action_fade_in!(a, NaN)
    @test_throws ArgumentError Diff3D.mixer_clip_action(mixer, clip; blend_mode=:mix)
    a.loop = :bogus
    @test_throws ArgumentError mixer_update!(mixer, 0.1)
    @test mixer.time == 0.0 && a.time == 0.0
    a.loop = :repeat
    a.weight = Inf
    @test_throws ArgumentError mixer_update!(mixer, 0.1)
    a.weight = 1.0
    @test_throws ArgumentError mixer_update!(mixer, NaN)
    mixer_update!(mixer, 0.5)
    @test obj.position.x == 0.5
    # An unreadable property fails when the clip is bound, before the mixer
    # keeps any binding.
    bad = AnimationClip("bad", 1.0, AbstractKeyframeTrack[
        KeyframeTrack(obj, :scale, [0.0, 1.0], [Vec3(1.0, 1.0, 1.0), Vec3(2.0, 1.0, 1.0)]),
        NumberKeyframeTrack(Group(), "morphTargetInfluences[2]", [0.0], [1.0])])
    nbindings = length(mixer.bindings)
    @test_throws ArgumentError Diff3D.mixer_clip_action(mixer, bad)
    @test length(mixer.bindings) == nbindings
end

function _mixing_frames!(mixer, n)
    for _ in 1:n
        mixer_update!(mixer, 1 / 60)
    end
    return mixer
end

@testset "audit3c mixing: per-frame updates do not allocate" begin
    A, M, L, walk, run, wave = _mixing_scene()
    mixer = Diff3D.AnimationActionMixer()
    acts = [Diff3D.action_play!(Diff3D.mixer_clip_action(mixer, clip))
            for clip in (walk, run, wave)]
    Diff3D.action_set_loop!(acts[2], :pingpong)
    Diff3D.action_cross_fade_to!(acts[1], acts[2], 5.0; warp=true)
    _mixing_frames!(mixer, 10)
    if Base.JLOptions().opt_level > 0
        # Transforms, quaternions, morph vectors and components, scalars and
        # a Bool, three actions with a warped cross-fade in progress.
        @test (@allocated _mixing_frames!(mixer, 100)) == 0
        @test (@allocated mixer_set_time!(mixer, 0.4)) == 0
    end
end

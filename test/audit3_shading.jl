using Test, Diff3D, ForwardDiff

# Reference values come from a JavaScript transcription of the three.js r186
# shader chunks (common.glsl.js, lights_physical_pars_fragment.glsl.js,
# lights_physical_fragment.glsl.js, lights_fragment_begin.glsl.js,
# iridescence_fragment.glsl.js, transmission_pars_fragment.glsl.js and the
# meshphysical.glsl.js composition), run under node with three.js' own DFG table
# (src/renderers/shaders/DFGLUTData.js decoded by DataUtils.fromHalfFloat).
# Geometry for those cases: normal +Z, one directional light of colour
# (0.9, 0.8, 0.7) and intensity 1, no envmap, flat geometry (geometryRoughness 0).

const AUDIT3_N = Vec3(0.0, 0.0, 1.0)
const AUDIT3_VIEWS = Dict(
    :head => (Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, 1.0)),
    :oblique => (normalize(Vec3(0.3, -0.2, 1.0)), normalize(Vec3(-0.5, 0.4, 0.8))),
    :grazing => (normalize(Vec3(0.99, 0.0, 0.05)), normalize(Vec3(-0.7, 0.1, 0.5))),
    :mirror => (normalize(Vec3(0.6, 0.0, 0.8)), normalize(Vec3(-0.6, 0.0, 0.8))),
)

function audit3_direct(material, view::Symbol)
    v, l = AUDIT3_VIEWS[view]
    light = DirectionalLight(color=Color3(0.9, 0.8, 0.7), intensity=1.0, position=l)
    c = shade_face(AUDIT3_N, v, Vec3(0.0, 0.0, 0.0), material, AbstractLight[light])
    return (c.r, c.g, c.b)
end

audit3_close(actual, expected; rtol=1e-12) =
    all(isapprox.(actual, expected; rtol=rtol, atol=1e-15))

const AUDIT3_ALBEDO = Color3(0.8, 0.4, 0.2)

audit3_physical(; kwargs...) = MeshPhysicalMaterial(; color=AUDIT3_ALBEDO, kwargs...)

@testset "DFG table and BRDF terms follow three.js r186" begin
    # DFGLUTData.js sampled as texture2D(dfgLUT, vec2(roughness, dotNV)) with
    # LinearFilter and ClampToEdgeWrapping (lights_fragment_begin.glsl.js:61).
    for (u, v, expected) in ((0.0, 0.0, (0.1470947265625, 0.85205078125)),
                             (1.0, 1.0, (0.34521484375, 0.00007051229476928711)),
                             (0.5, 0.5, (0.83447265625, 0.022686004638671875)),
                             (0.3, 0.123, (0.5873802734375, 0.30095048828125004)),
                             (0.77, 0.01, (0.86205078125, 0.06691894531249999)))
        @test audit3_close(Diff3D._dfg_lut(u, v), expected; rtol=1e-14)
    end
    # lights_physical_pars_fragment.glsl.js D_GGX / V_GGX_SmithCorrelated and
    # common.glsl.js:109 F_Schlick.
    @test Diff3D._d_ggx(0.25, 0.9) ≈ 0.3435964364270974 rtol=1e-14
    @test Diff3D._v_ggx_smith_correlated(0.25, 0.6, 0.3) ≈ 1.191377367147722 rtol=1e-14
    F = Diff3D._f_schlick(Color3(0.04, 0.5, 0.9), 1.0, Diff3D._schlick_weight(0.3))
    @test audit3_close((F.r, F.g, F.b),
                       (0.1989045798587685, 0.5827628020097753, 0.9165525604019551))
    # D_Charlie / V_Neubelt / IBLSheenBRDF (lights_physical_pars_fragment.glsl.js).
    @test Diff3D._d_charlie(0.4, 0.9) ≈ 0.0073177755238273655 rtol=1e-13
    @test Diff3D._d_charlie(1.0, 0.2) ≈ 0.4678180807402057 rtol=1e-13
    @test Diff3D._v_neubelt(0.3, 0.6) ≈ 0.3472222222222222 rtol=1e-14
    @test Diff3D._ibl_sheen_brdf(0.8, 0.4) ≈ 0.040382062101666144 rtol=1e-13
    # iridescence_fragment.glsl.js evalIridescence(1.0, eta2, cosθ, d, F0).
    for (args, expected) in (((1.3, 0.8, 400.0, Color3(0.04, 0.04, 0.04)),
                              (0.0, 0.020920403981858602, 0.041951467893506185)),
                             ((1.8, 0.35, 250.0, Color3(0.8, 0.4, 0.2)),
                              (0.8928691312509524, 0.0561790960152612, 0.19130276671508264)),
                             # φ23 = π (base IOR below the film's)
                             ((1.8, 0.6, 500.0, Color3(0.04, 0.04, 0.04)),
                              (0.14901179086550836, 0.062299712731236856, 0.13108930760716495)),
                             # φ12 = π (film IOR below the outside medium's)
                             ((0.9, 0.95, 350.0, Color3(0.04, 0.5, 0.9)),
                              (0.031904132020481084, 0.506590614800979, 0.9142398120674972)),
                             # φ23 differs per channel
                             ((1.6, 0.45, 620.0, Color3(0.02, 0.3, 0.7)),
                              (0.08565064005656903, 0.3311560434431925, 0.5026141899038934)),
                             # total internal reflection inside the film
                             ((0.8, 0.1, 300.0, Color3(0.04, 0.04, 0.04)), (1.0, 1.0, 1.0)))
        I = Diff3D._eval_iridescence(args...)
        @test audit3_close((I.r, I.g, I.b), expected; rtol=1e-11)
    end
end

@testset "Standard direct lighting follows three.js RE_Direct_Physical" begin
    # Zero roughness is clamped to 0.0525 (lights_physical_fragment.glsl.js:10):
    # the head-on highlight stays finite and strong instead of vanishing.
    smooth = MeshStandardMaterial(color=AUDIT3_ALBEDO, roughness=0.0)
    @test audit3_close(audit3_direct(smooth, :head),
                       (378.8409138063962, 336.64971058533564, 294.52572310743227))
    @test audit3_close(audit3_direct(smooth, :grazing),
                       (0.11063901683086527, 0.04923614989314087, 0.021596162411633108))
    rough = MeshStandardMaterial(color=AUDIT3_ALBEDO, roughness=0.5)
    @test audit3_close(audit3_direct(rough, :grazing),
                       (0.28217030313386504, 0.20170840438469623, 0.15500938509174403))
    metal = MeshStandardMaterial(color=AUDIT3_ALBEDO, metalness=1.0, roughness=0.3)
    @test audit3_close(audit3_direct(metal, :oblique),
                       (0.40109178509217636, 0.17769550259058725, 0.07773066331030994))
    half = MeshStandardMaterial(color=AUDIT3_ALBEDO, metalness=0.4, roughness=0.8)
    @test audit3_close(audit3_direct(half, :head),
                       (0.20859576194855536, 0.09146310674079539, 0.04099835168772948))
    # shade_pbr is the same single-light response.
    v, l = AUDIT3_VIEWS[:oblique]
    c = shade_pbr(AUDIT3_N, l, v, Color3(0.9, 0.8, 0.7), 1.0, AUDIT3_ALBEDO, 1.0, 0.3)
    @test audit3_close((c.r, c.g, c.b),
                       (0.40109178509217636, 0.17769550259058725, 0.07773066331030994))
end

@testset "Physical direct lobes follow three.js meshphysical" begin
    # IOR-derived F0 and specularF90 (lights_physical_fragment.glsl.js:21-44).
    @test audit3_close(audit3_direct(audit3_physical(ior=2.2, metalness=0.3, roughness=0.25), :oblique),
                       (0.21176652292727405, 0.10763102973831272, 0.05892457408620767))
    @test audit3_close(audit3_direct(audit3_physical(specular_intensity=0.4,
                                                     specular_color=Color3(1.0, 0.5, 0.25),
                                                     metalness=0.2, roughness=0.5), :head),
                       (0.3817936306903857, 0.16964606468726773, 0.07424063023476199))
    # GGX clearcoat and the clearcoat layering of the base
    # (meshphysical.glsl.js: outgoingLight·(1 - clearcoat·Fcc) + clearcoatSpecular·clearcoat).
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.5, clearcoat=0.8,
                                                     clearcoat_roughness=0.1), :head),
                       (23.26843226777274, 20.58842376469267, 17.973471420358614))
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.6, clearcoat=1.0,
                                                     clearcoat_roughness=0.0), :grazing),
                       (0.054537399733959324, 0.037904545135172905, 0.028540726704485795))
    # Charlie sheen with Neubelt visibility and the sheen energy compensation.
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.5, sheen=0.7,
                                                     sheen_color=Color3(0.9, 0.3, 0.6),
                                                     sheen_roughness=0.4), :grazing),
                       (0.20739676375721652, 0.1481770253695701, 0.11392689514121213))
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.5, sheen=1.0,
                                                     sheen_roughness=0.0), :oblique),
                       (0.19640801976715971, 0.09830542795995229, 0.052644977621319713))
    # Thin-film iridescence replaces the specular Fresnel term.
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.3, iridescence=1.0,
                                                     iridescence_ior=1.3,
                                                     iridescence_thickness=400.0), :head),
                       (0.28618162162529254, 0.4045505256039539, 0.15451208258907728))
    @test audit3_close(audit3_direct(audit3_physical(metalness=0.7, roughness=0.4,
                                                     iridescence=0.6, iridescence_ior=1.8,
                                                     iridescence_thickness=250.0), :oblique),
                       (0.3662272608937478, 0.14682762038307495, 0.09427701007730117))
    @test audit3_close(audit3_direct(audit3_physical(roughness=0.5, iridescence=1.0,
                                                     iridescence_ior=1.3,
                                                     iridescence_thickness=0.01), :grazing),
                       (1.0403662998936685, 0.8538147546498672, 0.7227536083245942))
    # Transmission replaces the diffuse lobe (transmission_fragment.glsl.js:
    # totalDiffuse = mix(totalDiffuse, transmitted, transmission)); a direct
    # light leaves only the specular reflection of clear glass.
    @test audit3_close(audit3_direct(audit3_physical(transmission=1.0, roughness=0.2), :oblique),
                       (0.005953396303659685, 0.005291907825475276, 0.004630419347290866))
    @test audit3_close(audit3_direct(audit3_physical(transmission=0.6, thickness=0.5,
                                                     attenuation_distance=0.8,
                                                     attenuation_color=Color3(0.9, 0.5, 0.2),
                                                     roughness=0.4), :head),
                       (0.20050591723771688, 0.13912014051580784, 0.10462066105677456))
    # Every extension together.
    combined = audit3_physical(metalness=0.25, roughness=0.35, ior=1.7,
                               specular_intensity=0.8, specular_color=Color3(0.9, 1.0, 0.7),
                               clearcoat=0.5, clearcoat_roughness=0.3, sheen=0.5,
                               sheen_color=Color3(0.4, 0.8, 0.3), sheen_roughness=0.6,
                               iridescence=0.5, iridescence_ior=1.4,
                               iridescence_thickness=300.0, transmission=0.3,
                               thickness=0.2, attenuation_distance=2.0,
                               attenuation_color=Color3(0.8, 0.9, 0.6))
    @test audit3_close(audit3_direct(combined, :mirror),
                       (1.636580057013443, 0.734069558171496, 0.46395284318164803))
    @test audit3_close(audit3_direct(combined, :grazing),
                       (0.2907582214369721, 0.23128150018180493, 0.1766157085016857))
    # The vertex-colour and texture-mapped physical paths share the same lobes.
    v, l = AUDIT3_VIEWS[:mirror]
    lights = Diff3D.SceneLight[DirectionalLight(color=Color3(0.9, 0.8, 0.7), position=l)]
    plain = shade_face(AUDIT3_N, v, Vec3(0.0, 0.0, 0.0), combined, lights)
    white = Diff3D._shade_lit_vertex_color(combined, AUDIT3_N, v, Vec3(0.0, 0.0, 0.0),
                                           lights, nothing, Color3(1.0, 1.0, 1.0))
    terms = Diff3D._physical_mapped_terms(combined, nothing, nothing, 0.5, 0.5, 0.5, 0.5)
    mapped = Diff3D._shade_physical_mapped(AUDIT3_N, v, Vec3(0.0, 0.0, 0.0), combined,
                                           lights, nothing, terms)
    @test (white.r, white.g, white.b) == (plain.r, plain.g, plain.b)
    @test (mapped.r, mapped.g, mapped.b) == (plain.r, plain.g, plain.b)
end

@testset "Physical fill light keeps three.js layering and transmission mix" begin
    v = normalize(Vec3(0.6, 0.0, 0.8))
    fill = AmbientLight(color=Color3(0.3, 0.25, 0.2), intensity=1.0)
    fc = Color3(0.3, 0.25, 0.2)
    shade(m) = shade_face(AUDIT3_N, v, Vec3(0.0, 0.0, 0.0), m, AbstractLight[fill])
    # Transmission: totalDiffuse = mix(totalDiffuse, transmitted, transmission)
    # (transmission_fragment.glsl.js); the transmitted term is the package's
    # background stand-in `_transmission_response`.
    opaque = audit3_physical(roughness=0.4)
    glass = audit3_physical(roughness=0.4, transmission=1.0)
    a = shade(opaque); b = shade(glass)
    t = Diff3D._transmission_response(glass, AUDIT3_N, v, fc)
    lambert = (AUDIT3_ALBEDO.r * fc.r / π, AUDIT3_ALBEDO.g * fc.g / π, AUDIT3_ALBEDO.b * fc.b / π)
    @test audit3_close((b.r, b.g, b.b), (a.r - lambert[1] + t.r, a.g - lambert[2] + t.g,
                                         a.b - lambert[3] + t.b))
    # Clearcoat attenuates everything underneath by 1 - clearcoat·F_Schlick(0.04, 1, N·V)
    # (meshphysical.glsl.js); a fill light adds no clearcoat highlight.
    coated = audit3_physical(roughness=0.4, clearcoat=0.7, clearcoat_roughness=0.2)
    c = shade(coated)
    dot_nv = 0.8
    fcc = 0.04 + 0.96 * exp2((-5.55473 * dot_nv - 6.98316) * dot_nv)
    @test audit3_close((c.r, c.g, c.b), (a.r, a.g, a.b) .* (1 - 0.7 * fcc))
    # Sheen: RE_IndirectDiffuse/IndirectSpecular_Physical scale the base by
    # 1 - max3(sheenColor)·IBLSheenBRDF and add sheenColor·IBLSheenBRDF·irradiance/π.
    sheen = audit3_physical(roughness=0.4, sheen=0.5, sheen_color=Color3(0.4, 0.8, 0.3),
                            sheen_roughness=0.6)
    s = shade(sheen)
    albedo_v = Diff3D._ibl_sheen_brdf(dot_nv, 0.6)
    sc = (0.2, 0.4, 0.15)
    @test audit3_close((s.r, s.g, s.b),
                       (a.r, a.g, a.b) .* (1 - 0.4 * albedo_v) .+
                       sc .* (fc.r, fc.g, fc.b) .* (albedo_v / π))
end

@testset "PBR shading stays differentiable and generic" begin
    v = normalize(Vec3(0.3, -0.2, 1.0))
    l = normalize(Vec3(0.2, 0.1, 1.0))
    pbr(r) = shade_pbr(AUDIT3_N, l, v, Color3(1.0, 1.0, 1.0), 1.0,
                       Color3(0.5, 0.5, 0.5), 0.2, r).r
    for r in (0.1, 0.4, 0.9)
        h = 1e-6
        @test ForwardDiff.derivative(pbr, r) ≈ (pbr(r + h) - pbr(r - h)) / (2h) rtol=1e-6
    end
    # Below the 0.0525 roughness clamp the response is flat in roughness.
    @test ForwardDiff.derivative(pbr, 0.01) == 0.0
    m = audit3_physical(roughness=0.4, metalness=0.3, clearcoat=0.5, sheen=0.6,
                        iridescence=0.7, transmission=0.4, thickness=0.3,
                        attenuation_distance=1.0)
    lights = Diff3D.SceneLight[AmbientLight(intensity=0.3), DirectionalLight(position=l),
                              PointLight(position=Vec3(0.0, 1.0, 2.0))]
    total(t) = begin
        c = shade_face(normalize(Vec3(t, 0.0, 1.0)), v, Vec3(0.0, 0.0, 0.0), m, lights)
        c.r + c.g + c.b
    end
    @test ForwardDiff.derivative(total, 0.1) ≈ (total(0.1 + 1e-6) - total(0.1 - 1e-6)) / 2e-6 rtol=1e-6
    big = shade_face(Vec3(big"0.0", big"0.0", big"1.0"), Vec3(big"0.0", big"0.6", big"0.8"),
                     Vec3(big"0.0", big"0.0", big"0.0"), m, lights)
    small = shade_face(AUDIT3_N, Vec3(0.0, 0.6, 0.8), Vec3(0.0, 0.0, 0.0), m, lights)
    @test big isa Color3{BigFloat}
    @test audit3_close(Float64.((big.r, big.g, big.b)), (small.r, small.g, small.b); rtol=1e-12)
    # A NaN view direction propagates instead of failing the DFG lookup.
    nan = shade_pbr(AUDIT3_N, l, Vec3(NaN, 0.0, 1.0), Color3(1.0, 1.0, 1.0), 1.0,
                    Color3(0.5, 0.5, 0.5), 0.0, 0.5)
    @test isnan(nan.r)
end

audit3_bytes(f::F, args...) where {F} = (f(args...); @allocated f(args...))

@testset "Per-fragment PBR shading does not allocate" begin
    if Base.JLOptions().opt_level > 0
        n = AUDIT3_N
        v = normalize(Vec3(0.3, -0.2, 1.0))
        p = Vec3(0.1, 0.2, 0.3)
        lights = Diff3D.SceneLight[AmbientLight(intensity=0.3),
                                  DirectionalLight(position=Vec3(1.0, 2.0, 3.0)),
                                  PointLight(position=Vec3(0.0, 1.0, 2.0)),
                                  SpotLight(position=Vec3(0.0, 0.0, 3.0)),
                                  HemisphereLight(), RectAreaLight(position=Vec3(0.0, 0.0, 2.0)),
                                  LightProbe()]
        physical = audit3_physical(roughness=0.4, metalness=0.3, clearcoat=0.5, sheen=0.6,
                                   iridescence=0.7, transmission=0.4, thickness=0.3,
                                   attenuation_distance=1.0, anisotropy=0.3)
        for m in (MeshStandardMaterial(color=AUDIT3_ALBEDO, roughness=0.4), physical,
                  MeshPhongMaterial(), MeshLambertMaterial(), MeshToonMaterial())
            @test audit3_bytes(shade_face, n, v, p, m, lights) == 0
            @test audit3_bytes(Diff3D._shade_lit_vertex_color, m, n, v, p, lights, nothing,
                               Color3(0.5, 0.6, 0.7)) == 0
            @test audit3_bytes(Diff3D._shade_lit, m, n, v, p,
                               Diff3D._DirectLightView(lights), nothing) == 0
            @test @inferred(shade_face(n, v, p, m, lights)) isa Color3{Float64}
        end
        terms = Diff3D._physical_mapped_terms(physical, nothing, nothing, 0.5, 0.5, 0.5, 0.5)
        @test audit3_bytes(Diff3D._shade_physical_mapped, n, v, p, physical, lights,
                           nothing, terms) == 0
        @test audit3_bytes(shade_pbr, n, normalize(Vec3(1.0, 2.0, 3.0)), v,
                           Color3(1.0, 1.0, 1.0), 1.0, AUDIT3_ALBEDO, 0.3, 0.4) == 0
    end
end

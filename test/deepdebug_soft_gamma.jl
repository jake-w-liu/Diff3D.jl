using Test, Diff3D, ForwardDiff

# Regression tests for the soft rasterizer's softmax reference (deep-debug
# finding XB-1). `_soft_pixel_color` adds the eps floor to the background
# weight on the scale of the reference m. A nearer candidate whose padded
# bounding box holds the pixel but whose coverage there is exactly zero used to
# set m, so a farther face that fully covers the pixel had relative weight
# exp(-dz/γ) below eps and the pixel turned into the background as γ -> 0. A
# zero-coverage face adds nothing to the sums, so it must not set m either.

# Identity view-projection: NDC x maps to screen (x + 1) W / 2, NDC y to
# (1 - y) H / 2, and z is the NDC depth.
const SG_VP = Mat4{Float64}((1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0))
const SG_RED = Color3(1.0, 0.0, 0.0)
const SG_GREEN = Color3(0.0, 1.0, 0.0)
const SG_BLUE = Color3(0.0, 0.0, 1.0)

# Far red triangle covering the whole 9x9 image at depth 0.5, and a near blue
# right triangle at depth -0.5 in the upper-left half of the box [-0.4, 0.4]^2.
# The centre pixel (5, 5), at NDC (0, 0), lies in the near triangle's bounding
# box but 0.169 px outside its hypotenuse.
const SG_FAR = [Vec3(-3.0, -3.0, 0.5), Vec3(3.0, -3.0, 0.5), Vec3(0.0, 3.0, 0.5)]
const SG_NEAR = [Vec3(-0.4, -0.4, -0.5), Vec3(-0.4, 0.4, -0.5), Vec3(0.3, 0.4, -0.5)]

sg_screen(v, W, H) = Diff3D._soft_project_clip_to_screen(
    Diff3D.mat4_transform_vec4(SG_VP, Vec4(v.x, v.y, v.z, 1.0)), Float64(W), Float64(H))

# The pixel stage in the relative-depth form (`use_relative_depth`), which
# `soft_render` selects only when 1/γ overflows; the forms are mathematically
# equivalent, so this renders the same image model at ordinary γ.
function sg_relative_render(triangles, colors, σ, γ, bg, W, H; eps=1e-8)
    screen = [Diff3D._soft_screen_triangle(sg_screen(t[1], W, H), sg_screen(t[2], W, H),
                                           sg_screen(t[3], W, H), c, σ, γ, eps, true, W, H)
              for (t, c) in zip(triangles, colors)]
    return Diff3D._soft_render_screen(Float64, screen, length(screen), W, H, σ, γ, bg,
                                      eps, true, nothing)
end

function sg_render(triangles, colors, σ, γ, form; bg=SG_GREEN, W=9, H=9)
    form === :relative && return sg_relative_render(triangles, colors, σ, γ, bg, W, H)
    vertices = reduce(vcat, triangles)
    faces = [(3i - 2, 3i - 1, 3i) for i in eachindex(triangles)]
    return soft_render(vertices, faces, colors, SG_VP, W, H,
                       SoftRasterizerConfig(sigma=σ, gamma=γ, bg_color=bg))
end

@testset "A zero-coverage nearer face does not turn a covered pixel into the background" begin
    σ = 1e-4
    # Preconditions: the near triangle is a candidate of the centre pixel (its
    # padded integer bounding box holds it) and its coverage there is exactly
    # zero (sigmoid(-0.169 / 1e-4) underflows).
    near = Diff3D._soft_screen_triangle(sg_screen.(SG_NEAR, 9, 9)..., SG_BLUE,
                                        σ, 1e-2, 1e-8, false, 9, 9)
    @test Diff3D._soft_covers(near, 5, 5)
    d = signed_distance_to_triangle(4.5, 4.5, near.s1.x, near.s1.y, near.s2.x,
                                    near.s2.y, near.s3.x, near.s3.y)
    @test -0.17 < d < -0.16
    @test sigmoid_approx(d / σ) == 0.0
    for form in (:logit, :relative), γ in (1e-2, 1e-4, 1e-8)
        both = sg_render([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], σ, γ, form)
        alone = sg_render([SG_FAR], [SG_RED], σ, γ, form)
        # The near face covers pixel (4, 4) (centre 0.8 px inside both legs),
        # so it is rendered; the far face alone is red at the centre.
        @test both[4, 4, 3] > 0.99
        @test isapprox(alone[5, 5, :], [1.0, 0.0, 0.0]; atol=1e-7)
        # A face with zero coverage contributes nothing: the centre pixel is
        # exactly the far face rendered alone (before the fix it was the
        # green background for every γ here).
        @test both[5, 5, :] == alone[5, 5, :]
    end
    # soft_render's own relative-depth form (1/γ overflows).
    both = sg_render([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], σ, 1e-310, :logit)
    alone = sg_render([SG_FAR], [SG_RED], σ, 1e-310, :logit)
    @test both[5, 5, :] == alone[5, 5, :]
    @test isapprox(both[5, 5, :], [1.0, 0.0, 0.0]; atol=1e-7)
end

# Derivative scene. Red F1 and green F2 share the vertical edge x = δ (NDC),
# 2e-3 px right of the centre pixel's centre, so at σ = 4e-3 both cover it
# partially (sigmoid(±0.5)) and every input kind has a derivative there. The
# blue N lies nearer (depth -0.5); its padded bounding box holds the centre
# pixel, 3.5 px from its hypotenuse, where its coverage sigmoid(-875) is
# exactly zero. N therefore owns the pass-1 reference and the changed branch
# is active. eps = 1e-3 makes the floor, whose scale is set by the reference
# owner, a sizeable part of the pixel. Parameters: N's vertices 19:27 and
# colour 34:36 last among the geometry and colours; then σ, γ, eps, bg.
const SG_DELTA = 2e-3 / 4.5
const SG_PARAMS = [SG_DELTA, -3.0, 0.5, SG_DELTA, 3.0, 0.52, -3.0, 0.0, 0.48,
                   SG_DELTA, -3.0, 0.56, 3.0, 0.0, 0.55, SG_DELTA, 3.0, 0.54,
                   -0.9, 0.2, -0.5, -0.9, 0.9, -0.45, -0.2, 0.9, -0.55,
                   0.9, 0.2, 0.1, 0.2, 0.8, 0.3, 0.1, 0.3, 0.9,
                   4e-3, 0.05, 1e-3, 0.05, 0.6, 0.4]
const SG_N_PARAMS = vcat(19:27, 34:36)
const SG_WEIGHTS = [sin(0.37i + 0.11j + 0.7c) for i in 1:9, j in 1:9, c in 1:3]

function sg_derivative_image(p, form; with_near=true)
    T = eltype(p)
    count = with_near ? 3 : 2
    vertices = [Vec3(p[3i - 2], p[3i - 1], p[3i]) for i in 1:3count]
    colors = [Color3(p[27 + 3i - 2], p[27 + 3i - 1], p[27 + 3i]) for i in 1:count]
    gamma = form === :relative ? T(1e-310) : p[38]
    config = SoftRasterizerConfig(sigma=p[37], gamma=gamma, eps=p[39],
                                  bg_color=Color3(p[40], p[41], p[42]))
    faces = [(3i - 2, 3i - 1, 3i) for i in 1:count]
    return soft_render(vertices, faces, colors, convert(Mat4{T}, SG_VP), 9, 9, config)
end

sg_centre(p, form; with_near=true) =
    sum(sg_derivative_image(p, form; with_near)[5, 5, :] .* [0.3, -0.5, 0.7])

# Central differences with steps scaled to each parameter (σ and γ are small).
function sg_central_differences(f, p)
    g = similar(p)
    for i in eachindex(p)
        h = i in (37, 38) ? 1e-6 * p[i] : 1e-7
        plus = copy(p); plus[i] += h
        minus = copy(p); minus[i] -= h
        g[i] = (f(plus) - f(minus)) / (plus[i] - minus[i])
    end
    return g
end

sg_expand(q) = vcat(q[1:18], zeros(eltype(q), 9), q[19:24], zeros(eltype(q), 3), q[25:30])

sg_normwise(a, b) = maximum(abs, a .- b) / maximum(abs, b)

@testset "Soft derivatives follow the covering reference face" begin
    p = SG_PARAMS
    # Preconditions for the changed branch at the centre pixel: N is the
    # nearest candidate there and its coverage is exactly zero.
    n_tri = Diff3D._soft_screen_triangle(
        sg_screen(Vec3(p[19], p[20], p[21]), 9, 9), sg_screen(Vec3(p[22], p[23], p[24]), 9, 9),
        sg_screen(Vec3(p[25], p[26], p[27]), 9, 9), SG_BLUE, p[37], p[38], p[39], false, 9, 9)
    @test Diff3D._soft_covers(n_tri, 5, 5)
    @test sigmoid_approx(signed_distance_to_triangle(4.5, 4.5, n_tri.s1.x, n_tri.s1.y,
        n_tri.s2.x, n_tri.s2.y, n_tri.s3.x, n_tri.s3.y) / p[37]) == 0.0
    shared = setdiff(eachindex(p), SG_N_PARAMS)
    for form in (:logit, :relative)
        centre = q -> sg_centre(q, form)
        forward = ForwardDiff.gradient(centre, p)
        reverse = reverse_gradient(centre, p)
        @test all(isfinite, forward) && all(isfinite, reverse)
        # The two AD modes differentiate the same branch choices.
        @test sg_normwise(reverse, forward) <= 1e-9
        # Central differences of the Float64 renderer agree; the parameters
        # include F1's depths, whose logit sets the reference after the fix and
        # so carries the eps-floor derivative.
        @test sg_normwise(sg_central_differences(centre, p), forward) <= 1e-6
        # N has zero coverage at the centre pixel, so it has no influence
        # there: no derivative (before the fix its depths received the
        # reference's eps-floor derivative), and the pixel and its gradient
        # are exactly those of the scene without N.
        @test all(iszero, forward[SG_N_PARAMS])
        @test all(iszero, reverse[SG_N_PARAMS])
        # `sg_expand` re-inserts unused N slots, so `without` sees F1, F2 and
        # the scalars at the same parameter positions.
        without = q -> sg_centre(sg_expand(q), form; with_near=false)
        @test sg_centre(p, form) == without(p[shared])
        @test forward[shared] == ForwardDiff.gradient(without, p[shared])
        @test reverse[shared] == reverse_gradient(without, p[shared])
        # Whole image: the changed branch also runs at other pixels of N's box.
        image = q -> sum(sg_derivative_image(q, form) .* SG_WEIGHTS)
        @test sg_normwise(reverse_gradient(image, p), ForwardDiff.gradient(image, p)) <= 1e-9
    end
end

function sg_camera()
    camera = PerspectiveCamera(fov=0.8, aspect=1.0, near=0.1, far=50.0)
    camera.position = Vec3(0.0, 0.0, 4.0)
    look_at!(camera, Vec3(0.0, 0.0, 0.0))
    return camera
end

function sg_lit_scene(kind)
    scene = Scene()
    add!(scene, DirectionalLight(position=Vec3(1.0, 2.0, 3.0)))
    material = MeshLambertMaterial(color=Color3(0.8, 0.8, 0.8))
    if kind === :sphere
        add!(scene, Mesh(SphereGeometry(radius=1.0), material))
    else
        mesh = Mesh(BoxGeometry(), material)
        mesh.rotation = Euler(0.4, 0.5, 0.0)
        add!(scene, mesh)
    end
    return scene
end

# Interior pixels (the hard pixel and its 8 neighbours belong to the object)
# whose soft colour differs from render! by more than 0.02.
function sg_differing_interior(scene, camera, target, σ, γ)
    image = soft_render_scene(scene, camera, 40, 40; sigma=σ, gamma=γ)
    count = 0
    for y in 2:39, x in 2:39
        all(target.depth[y + dy, x + dx] < Inf for dy in -1:1, dx in -1:1) || continue
        maximum(abs.(image[y, x, :] .- target.color[y, x, :])) > 0.02 && (count += 1)
    end
    return count
end

@testset "soft_render_scene converges to render! as gamma shrinks at small sigma" begin
    # Flat-shaded neighbouring faces differ in colour; adjacent faces' padded
    # bounding boxes hold each interior pixel, and at σ = 1e-7 their coverage
    # there is exactly zero (a pixel centre 7.5e-5 px or more outside a face
    # gives sigmoid(<= -745)). Before the fix those nearer non-covering
    # neighbours set the reference, so pixels turned towards the background
    # as γ shrank (sphere: 0 differing at γ = 1e-3, hundreds at 1e-4 and 1e-6).
    # Now the count falls monotonically and reaches zero; at γ = 1e-2 nearby
    # faces blend legitimately (depth gaps comparable to γ).
    camera = sg_camera()
    for kind in (:sphere, :box)
        scene = sg_lit_scene(kind)
        target = RenderTarget(40, 40)
        render!(target, scene, camera)
        counts = [sg_differing_interior(scene, camera, target, 1e-7, γ)
                  for γ in (1e-2, 1e-3, 1e-4, 1e-6, 1e-8)]
        @test issorted(counts; rev=true)
        @test counts[end] == 0
    end
end

# FNV-1a over the Float64 bit patterns: a checksum that does not depend on the
# Julia version's `hash`.
function sg_checksum(image)
    h = 0xcbf29ce484222325
    for x in image
        h = (h ⊻ reinterpret(UInt64, Float64(x))) * 0x00000100000001b3
    end
    return h
end

# Checksums of the images before the fix. Julia 1.10 and 1.13 round some of
# the scene and pixel math differently, so each has its own values; on each
# version the code before and after the fix gives the same bits. (Recorded on
# 1.10 and 1.13; the second set is assumed for 1.11 and later.)
const SG_PINNED = VERSION < v"1.11" ?
    (0x365338aee837936f, 0x27cc03e769899a8a, 0x13f2f7dce59950ce) :
    (0xb2af542443f4a073, 0xdd962baeea661237, 0xfb0290ada526f99e)

@testset "Soft images without zero-coverage reference owners are unchanged" begin
    # No pixel of these renders has a pass-1 reference owner with zero
    # coverage, so the fix must leave every bit as it was. This guards the
    # compatibility of the 2.x image model rather than the defect itself, so
    # it also passes on the code before the fix.
    camera = sg_camera()
    scene = sg_lit_scene(:sphere)
    @test sg_checksum(soft_render_scene(scene, camera, 40, 40; sigma=0.5, gamma=0.1)) ==
          SG_PINNED[1]
    @test sg_checksum(soft_render_scene(scene, camera, 40, 40; sigma=1e-2, gamma=1e-3)) ==
          SG_PINNED[2]
    # The two-triangle scene at σ = 0.3: the near face has non-zero coverage
    # at every pixel of its box, so it keeps the reference where it is nearest.
    image = sg_render([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], 0.3, 1e-4, :logit)
    @test sg_checksum(image) == SG_PINNED[3]
end

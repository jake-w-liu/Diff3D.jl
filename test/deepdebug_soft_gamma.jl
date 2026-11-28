using Test, Diff3D, ForwardDiff

# Regression tests for the soft rasterizer's background floor (deep-debug
# finding XB-1). `_soft_pixel_color` used to add eps to the background weight
# on the scale of the reference m, the nearest candidate face. A nearer face
# whose padded bounding box holds the pixel but whose coverage there is zero or
# tiny then set m, a farther face that fully covers the pixel had relative
# weight exp(-dz/γ) below eps, and the pixel turned into the background as
# γ -> 0. Now a zero-coverage face does not set m, and the floor is
# eps * S / C (S = Σ c_i d_i, C = Σ c_i), so a barely-covering face cannot
# hide a covering one; with one covering face S / C = 1 and nothing changes.

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

sg_screen_tris(triangles, colors, σ, γ, eps, relative, W, H) =
    [Diff3D._soft_screen_triangle(sg_screen(t[1], W, H), sg_screen(t[2], W, H),
                                  sg_screen(t[3], W, H), c, σ, γ, eps, relative, W, H)
     for (t, c) in zip(triangles, colors)]

# Pixel (px, py) under the floor before this change, w_bg = d_bg + eps, for
# pixels whose nearest candidate has non-zero coverage (passes 1 and 2 of
# `_soft_pixel_color`, in the same order and with the same helpers). Returns
# the colour, S against that reference and the number of covering faces.
function sg_old_floor_pixel(tris, px, py, σ, γ, eps, bg, relative)
    background = relative ? 1.0 : -1.0 / γ
    m = background
    for t in tris
        Diff3D._soft_covers(t, px, py) || continue
        relative ? (t.depth < m && (m = t.depth)) : (t.logit > m && (m = t.logit))
    end
    total = 0.0
    average = Color3(0.0, 0.0, 0.0)
    covering = 0
    for t in tris
        Diff3D._soft_covers(t, px, py) || continue
        @assert !Diff3D._soft_is_faded(t.area, eps)
        d = Diff3D._signed_distance_to_triangle_area(px - 0.5, py - 0.5, t.s1.x, t.s1.y,
                                                     t.s2.x, t.s2.y, t.s3.x, t.s3.y, t.area)
        c = sigmoid_approx(d / σ)
        c == 0 || (covering += 1)
        weight = c * (relative ? Diff3D._soft_relative_depth_weight(m, t.depth, γ) :
                      exp(t.logit - m))
        next = total + weight
        average = iszero(total) ? t.color :
            Diff3D._stable_color_lerp(average, t.color, weight / next)
        total = next
    end
    iszero(total) && return bg, total, covering
    w_bg = (relative ? Diff3D._soft_relative_depth_weight(m, 1.0, γ) : exp(background - m)) + eps
    return Diff3D._stable_color_lerp(average, bg, w_bg / (total + w_bg)), total, covering
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

@testset "A barely-covering nearer face does not hide the covering face" begin
    # At σ = 1e-3 the near face's coverage at the centre pixel is
    # sigmoid(-169.3), about 3e-74: tiny but not zero, so it is the reference.
    σ = 1e-3
    near = Diff3D._soft_screen_triangle(sg_screen.(SG_NEAR, 9, 9)..., SG_BLUE,
                                        σ, 1e-2, 1e-8, false, 9, 9)
    d = signed_distance_to_triangle(4.5, 4.5, near.s1.x, near.s1.y, near.s2.x,
                                    near.s2.y, near.s3.x, near.s3.y)
    c_near = sigmoid_approx(d / σ)
    @test 0 < c_near < 1e-70
    dz = 1.0   # depth 0.5 (far) - depth -0.5 (near)
    # In the floor-free softmax the far face has weight 1 and the near face
    # c_near exp(dz/γ), so the near face takes the pixel once that exceeds 1,
    # below γ* = dz / -log(c_near) ≈ 5.9e-3. That is the image model at fixed
    # σ, not a defect. Blue fraction r / (1 + r), r = c_near exp(dz/γ); the
    # background weight exp(-0.5/γ) <= e^-50 and the floor (about 1e-8 of the
    # pixel) are below the tolerance.
    γ_star = dz / -log(c_near)
    for form in (:logit, :relative),
        γ in (1e-2, γ_star / 0.98, γ_star / 0.995, γ_star, γ_star / 1.005, γ_star / 1.02, 1e-3, 1e-4)
        image = sg_render([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], σ, γ, form)
        blue = 1 / (1 + exp(-(log(c_near) + dz / γ)))
        @test isapprox(image[5, 5, :], [1 - blue, 0.0, blue]; atol=1e-6)
    end
    # At γ = 1e-2 the covering far face wins (before the change the floor,
    # scaled by the near reference, made the pixel the green background).
    for form in (:logit, :relative)
        image = sg_render([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], σ, 1e-2, form)
        @test image[5, 5, 1] > 1 - 1e-7 && image[5, 5, 2] < 1e-7
    end
end

# Derivative scene. Red F1 and green F2 share the vertical edge x = δ (NDC),
# 2e-3 px right of the centre pixel's centre, so at σ = 4e-3 both cover it
# partially (sigmoid(±0.5)) and every input kind has a derivative there. The
# blue N lies nearer (depth -0.5); its padded bounding box holds the centre
# pixel, 3.5 px from its hypotenuse. At σ = 4e-3 its coverage there,
# sigmoid(-875), is exactly zero, so N owns the pass-1 reference and is
# dropped; at σ = 0.1 it is sigmoid(-35) ≈ 6e-16, so N is the reference. eps =
# 1e-3 makes the floor eps * S / C, with both its S and C adjoints, a sizeable
# part of the pixel. Parameters: N's vertices 19:27 and colour 34:36 last
# among the geometry and colours; then σ, γ, eps, bg.
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
    for σ in (4e-3, 0.1)
        p = copy(SG_PARAMS)
        p[37] = σ
        # N is a candidate of the centre pixel; its coverage there is exactly
        # zero at σ = 4e-3 and tiny but non-zero at σ = 0.1.
        n_tri = Diff3D._soft_screen_triangle(
            sg_screen(Vec3(p[19], p[20], p[21]), 9, 9), sg_screen(Vec3(p[22], p[23], p[24]), 9, 9),
            sg_screen(Vec3(p[25], p[26], p[27]), 9, 9), SG_BLUE, p[37], p[38], p[39], false, 9, 9)
        @test Diff3D._soft_covers(n_tri, 5, 5)
        c_n = sigmoid_approx(signed_distance_to_triangle(4.5, 4.5, n_tri.s1.x, n_tri.s1.y,
            n_tri.s2.x, n_tri.s2.y, n_tri.s3.x, n_tri.s3.y) / σ)
        @test σ == 4e-3 ? c_n == 0.0 : 0 < c_n < 1e-12
        shared = setdiff(eachindex(p), SG_N_PARAMS)
        for form in (:logit, :relative)
            centre = q -> sg_centre(q, form)
            forward = ForwardDiff.gradient(centre, p)
            reverse = reverse_gradient(centre, p)
            @test all(isfinite, forward) && all(isfinite, reverse)
            # The two AD modes differentiate the same branch choices; the
            # fused reverse pullback carries the floor's S / C adjoints.
            @test sg_normwise(reverse, forward) <= 1e-9
            # Central differences of the Float64 renderer agree.
            @test sg_normwise(sg_central_differences(centre, p), forward) <= 1e-6
            if iszero(c_n)
                # N has no influence: no derivative (before the fix its depths
                # received the reference's eps-floor derivative), and the
                # pixel and its gradient are exactly those of the scene
                # without N. `sg_expand` re-inserts unused N slots, so
                # `without` sees F1, F2 and the scalars at the same positions.
                @test all(iszero, forward[SG_N_PARAMS])
                @test all(iszero, reverse[SG_N_PARAMS])
                without = q -> sg_centre(sg_expand(q), form; with_near=false)
                @test sg_centre(p, form) == without(p[shared])
                @test forward[shared] == ForwardDiff.gradient(without, p[shared])
                @test reverse[shared] == reverse_gradient(without, p[shared])
            else
                # N's tiny coverage enters through the softmax and C.
                @test any(!iszero, forward[19:27])
            end
            # Whole image: the reference changes at other pixels of N's box too.
            image = q -> sum(sg_derivative_image(q, form) .* SG_WEIGHTS)
            @test sg_normwise(reverse_gradient(image, p), ForwardDiff.gradient(image, p)) <= 1e-9
        end
    end
end

@testset "Reverse derivatives stay finite when the reference coverage is subnormal" begin
    # σ puts the near face's coverage at the centre pixel near e^-730, a
    # subnormal number; at γ = 1e-3 the far face's relative depth weight
    # e^-1000 underflows to zero. Then S = c_near and the denominator are
    # subnormal and 1 / denom overflows; the fused pullback must not form it
    # (it gave Inf * 0 = NaN). The derivatives here are rounding-level: the
    # floor eps * S / C itself underflows, so the two AD modes need not agree
    # beyond that. Parameters: the 18 vertex coordinates of both faces.
    near = Diff3D._soft_screen_triangle(sg_screen.(SG_NEAR, 9, 9)..., SG_BLUE,
                                        1e-3, 1e-3, 1e-8, false, 9, 9)
    d = signed_distance_to_triangle(4.5, 4.5, near.s1.x, near.s1.y, near.s2.x,
                                    near.s2.y, near.s3.x, near.s3.y)
    σ = -d / 730
    @test 0 < sigmoid_approx(d / σ) < floatmin(Float64)
    p = [c for v in vcat(SG_FAR, SG_NEAR) for c in (v.x, v.y, v.z)]
    for form in (:logit, :relative)
        function centre(q)
            triangles = [[Vec3(q[9k + 3i - 2], q[9k + 3i - 1], q[9k + 3i]) for i in 1:3] for k in 0:1]
            T = eltype(q)
            colors = [Color3{T}(1, 0, 0), Color3{T}(0, 0, 1)]
            vertices = reduce(vcat, triangles)
            γ = form === :relative ? T(1e-310) : T(1e-3)
            config = SoftRasterizerConfig(sigma=T(σ), gamma=γ, bg_color=Color3{T}(0, 1, 0))
            image = soft_render(vertices, [(1, 2, 3), (4, 5, 6)], colors,
                                convert(Mat4{T}, SG_VP), 9, 9, config)
            return sum(image[5, 5, :] .* [0.3, -0.5, 0.7])
        end
        # c_near exp(dz/γ) is huge, so the near face takes the pixel.
        @test isapprox(centre(p), 0.7; atol=1e-7)
        @test all(isfinite, ForwardDiff.gradient(centre, p))
        @test all(isfinite, reverse_gradient(centre, p))
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

@testset "Pixels with one covering face keep the eps floor; others move by at most eps / (S + eps)" begin
    # No candidate of these renders has zero coverage (σ >= 0.3 with a
    # bounding-box margin of max(3σ, 1) px), so the exact-zero rule is inactive
    # and the floor is the only change. With b = d_bg and r = S / C <= 1 the
    # background fraction moves from (b + eps) / (S + b + eps) to
    # (b + eps r) / (S + b + eps r), a difference of at most eps / (S + eps);
    # colours lie in [0, 1], so that bounds each channel. Exactly one covering
    # face gives r = 1: the same bits as before.
    disjoint = [[Vec3(-0.9, -0.9, 0.2), Vec3(-0.2, -0.8, 0.3), Vec3(-0.6, -0.1, 0.25)],
                [Vec3(0.3, 0.3, -0.4), Vec3(0.9, 0.2, -0.3), Vec3(0.5, 0.9, -0.35)]]
    scenes = ((disjoint, [Color3(0.9, 0.2, 0.1), Color3(0.1, 0.3, 0.8)], 0.5, 0.05, 24),
              ([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], 0.3, 1e-4, 9),
              ([SG_FAR, SG_NEAR], [SG_RED, SG_BLUE], 0.3, 0.05, 9))
    bg = Color3(0.2, 0.6, 0.4)
    counts = zeros(Int, 3)   # single-face pixels, multi-face pixels, changed multi-face pixels
    for (triangles, colors, σ, γ, W) in scenes, relative in (false, true), eps in (1e-8, 1e-3)
        tris = sg_screen_tris(triangles, colors, σ, γ, eps, relative, W, W)
        image = Diff3D._soft_render_screen(Float64, tris, length(tris), W, W, σ, γ, bg,
                                           eps, relative, nothing)
        for py in 1:W, px in 1:W
            old, total, covering = sg_old_floor_pixel(tris, px, py, σ, γ, eps, bg, relative)
            new = image[py, px, :]
            if covering <= 1
                counts[1] += 1
                @test new == [old.r, old.g, old.b]
            else
                counts[2] += 1
                change = maximum(abs, new .- [old.r, old.g, old.b])
                change > 0 && (counts[3] += 1)
                @test change <= eps / (total + eps) * (1 + 1e-12) + 1e-15
            end
        end
    end
    # Both kinds occur, and the floor does move multi-face pixels.
    @test all(>(0), counts)
end

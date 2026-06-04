# --------------------------------------------------------------------------
# Per-vertex geometry inverse rendering.
#
# A higher-dimensional inverse task: recover all vertex positions of a mesh by
# optimising them through the differentiable soft rasterizer to match a target
# image. Unlike the low-dimensional camera/light/colour demonstrations (3 DOF
# each), this optimises every vertex coordinate of an icosahedron stored as a
# non-indexed buffer (20 faces -> 60 vertices -> 180 DOF) so that a round mesh
# deforms into a target ellipsoid. Initialisation
# sensitivity is probed across three random seeds.
#
#   julia --project=Diff3D.jl Diff3D.jl/examples/inverse_geometry.jl
#
# Outputs:
#   paper/data/inverse_geometry_convergence.csv   (loss per iteration, 3 seeds)
#   paper/figs/fig_inverse_geometry.pdf           (PlotlySupply convergence)
#   paper/figs/fig_geometry_render.{pdf,png}      (engine target/init/recovered)
# --------------------------------------------------------------------------

using Pkg

const THREE_ROOT = normpath(joinpath(@__DIR__, ".."))
const PLOTLYSUPPLY_ROOT = normpath(joinpath(@__DIR__, "..", "..", "PlotlySupply.jl"))

# Keep figure-only plotting dependencies out of the package environment.
Pkg.activate(; temp=true)
Pkg.develop(path=THREE_ROOT)
if isdir(PLOTLYSUPPLY_ROOT)
    Pkg.develop(path=PLOTLYSUPPLY_ROOT)
else
    Pkg.add("PlotlySupply")
end
Pkg.instantiate()

using Diff3D
using PlotlySupply
using Printf
using Random

const PAPER_DATA = joinpath(@__DIR__, "..", "..", "paper", "data")
const PAPER_FIGS = joinpath(@__DIR__, "..", "..", "paper", "figs")
mkpath(PAPER_DATA)
mkpath(PAPER_FIGS)

const COLORS = ["#0072B2", "#D55E00", "#009E73", "#CC79A7"]
const DASHES = ["solid", "dash", "dashdot", "dot"]
const IEEE_W = 504
const IEEE_H = 360

# Base mesh: icosahedron, non-indexed buffer (20 faces -> 60 vertices -> 180 vertex DOF).
const GEO    = IcosahedronGeometry(radius = 1.0, detail = 0)
const NV     = GEO.n_vertices
const NF     = GEO.n_faces
const FACES  = [get_face(GEO, fi) for fi in 1:NF]

# Distinct per-face colours give the optimiser stable correspondence cues; only
# vertex positions are differentiated (colours are fixed Float64).
function face_palette()
    cols = Color3{Float64}[]
    for fi in 1:NF
        h = 2π * (fi - 1) / NF
        push!(cols, Color3(0.50 + 0.42cos(h),
                           0.50 + 0.42cos(h + 2.0944),
                           0.50 + 0.42cos(h + 4.1888)))
    end
    cols
end
const FCOLS = face_palette()

base_vertices()   = [get_vertex(GEO, vi) for vi in 1:NV]
flatten(verts)    = collect(Iterators.flatten((v.x, v.y, v.z) for v in verts))
# Anisotropic deformation: a round mesh becomes a flattened, widened ellipsoid.
target_vertices() = [Vec3(1.35v.x, 0.70v.y, 1.0v.z) for v in base_vertices()]

const EYE   = Vec3(2.2, 1.6, 2.8)
const W_OPT = 48
const SIGMA = 1.0

view_proj(T) = mat4_perspective(T(π / 4), one(T), T(0.1), T(100.0)) *
               mat4_look_at(Vec3(T(EYE.x), T(EYE.y), T(EYE.z)),
                            Vec3(zero(T), zero(T), zero(T)),
                            Vec3(zero(T), one(T), zero(T)))

# Soft render from a flat vertex vector (for display panels). The optimisation
# target/render use the package's vertex_render_fn with a black background.
function render_flat(p::Vector{Float64}, npx::Int; sigma = SIGMA,
                     bg = Color3(0.07, 0.08, 0.11))
    rf = vertex_render_fn(FACES, FCOLS, view_proj(Float64), npx, npx;
                          sigma = sigma, gamma = 1.0, bg = bg)
    rf(p)
end

function main()
    tgt_p = flatten(target_vertices())
    base_p = flatten(base_vertices())

    # Target rendered with the same (black-background) pipeline the optimiser uses.
    rf_opt = vertex_render_fn(FACES, FCOLS, view_proj(Float64), W_OPT, W_OPT;
                              sigma = SIGMA, gamma = 1.0)
    target_img = rf_opt(tgt_p)

    seeds   = [11, 23, 37]
    n_iters = 140
    histories = Vector{Vector{Float64}}()
    finals    = Float64[]
    init1     = base_p
    est1      = base_p

    @info "Per-vertex geometry optimisation" dof = length(base_p) faces = NF resolution = W_OPT
    for (si, sd) in enumerate(seeds)
        rng = MersenneTwister(sd)
        init_p = base_p .+ 0.06 .* randn(rng, length(base_p))
        est, hist = optimize_vertices(copy(init_p), FACES, FCOLS, view_proj(Float64),
                                      target_img; W = W_OPT, H = W_OPT, sigma = SIGMA,
                                      gamma = 1.0, lr = 0.02, n_iters = n_iters,
                                      verbose = false)
        push!(histories, hist)
        push!(finals, hist[end])
        if si == 1
            init1 = init_p
            est1  = est
        end
        @printf("  seed %2d: loss %.3e -> %.3e  (%.0fx reduction)\n",
                sd, hist[1], hist[end], hist[1] / hist[end])
    end

    # Absolute quality: SSIM of the recovered image to the target (best seed).
    rec_img = rf_opt(est1)
    ssim = 1.0 - loss_ssim(rec_img, target_img)
    mean_final = sum(finals) / length(finals)
    spread = maximum(finals) - minimum(finals)
    @printf("  final loss mean %.3e  spread %.3e  recovered SSIM %.4f\n",
            mean_final, spread, ssim)

    # --- CSV ---
    csv = joinpath(PAPER_DATA, "inverse_geometry_convergence.csv")
    open(csv, "w") do f
        println(f, "# Per-vertex geometry inverse rendering: 180-DOF icosahedron (non-indexed, 60 vertices)")
        println(f, "# vertex-position optimisation to a target ellipsoid, three seeds.")
        @printf(f, "# recovered_ssim=%.6f mean_final_mse=%.6e seed_spread=%.6e\n",
                ssim, mean_final, spread)
        println(f, "iteration,loss_seed1,loss_seed2,loss_seed3")
        for i in 1:n_iters
            @printf(f, "%d,%.15e,%.15e,%.15e\n",
                    i, histories[1][i], histories[2][i], histories[3][i])
        end
    end
    @info "CSV written" csv

    # --- PlotlySupply convergence figure ---
    iters = collect(1:n_iters)
    fig = plot_scatter(iters, histories[1];
        xlabel = "Iteration", ylabel = "MSE loss",
        mode = "lines", color = COLORS[1], dash = DASHES[1],
        legend = "Seed 1", linewidth = 2, fontsize = 12, yscale = "log")
    plot_scatter!(fig, iters, histories[2];
        color = COLORS[2], dash = DASHES[2], mode = "lines",
        legend = "Seed 2", linewidth = 2)
    plot_scatter!(fig, iters, histories[3];
        color = COLORS[3], dash = DASHES[3], mode = "lines",
        legend = "Seed 3", linewidth = 2)
    # Least-obstructive inside placement: curves decrease left->right, so the
    # upper-right region is clear of data.
    set_legend!(fig; position = :topright)
    savefig(fig, joinpath(PAPER_FIGS, "fig_inverse_geometry.pdf");
            width = IEEE_W, height = IEEE_H)
    @info "Convergence figure written"

    # --- Engine before/after render (target | init | recovered), best seed ---
    W_DISP = 240
    target_d = render_flat(tgt_p,  W_DISP)
    init_d   = render_flat(init1,  W_DISP)
    rec_d    = render_flat(est1,   W_DISP)
    gap = 8
    out = Array{Float64}(undef, W_DISP, 3W_DISP + 2gap, 3)
    fill!(out, 0.10)
    place!(panel, x0) = (@inbounds out[:, x0:(x0 + W_DISP - 1), :] .= panel)
    place!(target_d, 1)
    place!(init_d, W_DISP + gap + 1)
    place!(rec_d, 2W_DISP + 2gap + 1)
    save_pdf(joinpath(PAPER_FIGS, "fig_geometry_render.pdf"), out; dpi = 150)
    save_png(joinpath(PAPER_FIGS, "fig_geometry_render.png"), out)
    @info "Engine render written"

    @printf("GEOMETRY_OK dof=%d ssim=%.4f mean_final=%.3e\n", length(base_p), ssim, mean_final)
end

main()

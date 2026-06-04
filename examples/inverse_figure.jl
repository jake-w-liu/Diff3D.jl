# Renders the inverse-rendering before/after panel as real Diff3D.jl output.
#
# Task: material inference. Per-face surface colors of a cube are unknown and
# initialised to neutral gray; ForwardDiff gradients through the differentiable
# soft rasterizer drive them to reproduce a target rendering. The camera is
# fixed, so the three faces visible to it are the recoverable parameters and the
# converged image matches the target. This is the contract's preferred
# non-trivial inverse task (material inference), and it converges to ~0 loss.
#
# Optimization runs at low resolution (stable, fast gradients); the displayed
# panels are re-rendered at high resolution from the same recovered colors.
#
#   julia --project=Diff3D.jl Diff3D.jl/examples/inverse_figure.jl
#
# Output: paper/figs/fig_inverse_render.{pdf,png}

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using Diff3D
using Printf

const PROJECT_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const FIGS = joinpath(PROJECT_ROOT, "paper", "figs")
isdir(FIGS) || mkpath(FIGS)

function cube_geometry()
    geo = BoxGeometry(width = 1.7, height = 1.7, depth = 1.7)
    verts = [get_vertex(geo, i) for i in 1:geo.n_vertices]
    faces = [get_face(geo, fi) for fi in 1:geo.n_faces]
    return verts, faces, geo.n_faces
end

const VERTS, FACES, NFACES = cube_geometry()
const NPARAM = NFACES * 3                       # one RGB triple per face
const EYE    = Vec3(2.4, 1.8, 3.0)              # fixed viewpoint
const W_OPT  = 48
const W_DISP = 320

# Target per-face colors (rainbow); two triangles share a face color.
const TARGET_FACE = [Color3(0.85, 0.25, 0.20), Color3(0.20, 0.55, 0.85),
                     Color3(0.25, 0.70, 0.40), Color3(0.95, 0.78, 0.20),
                     Color3(0.65, 0.30, 0.75), Color3(0.90, 0.55, 0.20)]

view_proj(T) = projection_matrix_from_params(T(π/4), one(T), T(0.1), T(100.0)) *
               view_matrix_from_params(T(EYE.x), T(EYE.y), T(EYE.z),
                                       zero(T), zero(T), zero(T),
                                       zero(T), one(T), zero(T))

# Render from a flat parameter vector of per-face RGB colors.
function render_params(params::AbstractVector{T}, npx::Int; sigma) where T
    vts = [Vec3(T(v.x), T(v.y), T(v.z)) for v in VERTS]
    cls = Vector{Color3{T}}(undef, NFACES)
    @inbounds for fi in 1:NFACES
        k = (fi - 1) * 3
        cls[fi] = Color3(params[k+1], params[k+2], params[k+3])
    end
    config = SoftRasterizerConfig(sigma = T(sigma), gamma = one(T),
                                  bg_color = Color3(T(0.08), T(0.09), T(0.12)),
                                  eps = T(1e-8))
    soft_render(vts, FACES, cls, view_proj(T), npx, npx, config)
end

target_params() = vcat(([c.r, c.g, c.b] for c in TARGET_FACE)...)
clamp01(p) = clamp.(p, 0.0, 1.0)

function main()
    tgt = target_params()
    init = fill(0.5, NPARAM)                    # neutral gray cube

    target_opt = render_params(tgt, W_OPT; sigma = 0.6)
    render_fn(p) = render_params(p, W_OPT; sigma = 0.6)

    @info "Optimizing per-face material colors" nparams=NPARAM
    est, hist = inverse_render_adam(copy(init), target_opt, render_fn, loss_mse;
                                    lr = 0.06, n_iters = 220, verbose = false)

    @info "Converged" loss0=round(hist[1], sigdigits=4) lossN=round(hist[end], sigdigits=4)
    if hist[end] > 0.15 * hist[1]
        error("Material inference did not converge: loss $(hist[1]) -> $(hist[end])")
    end

    target    = render_params(clamp01(tgt),  W_DISP; sigma = 0.6)
    initial   = render_params(clamp01(init), W_DISP; sigma = 0.6)
    converged = render_params(clamp01(est),  W_DISP; sigma = 0.6)

    gap = 8
    out = Array{Float64}(undef, W_DISP, 3W_DISP + 2gap, 3)
    fill!(out, 0.5)
    place!(panel, x0) = (@inbounds out[:, x0:(x0 + W_DISP - 1), :] .= panel)
    place!(target, 1)
    place!(initial, W_DISP + gap + 1)
    place!(converged, 2W_DISP + 2gap + 1)

    pdf = joinpath(FIGS, "fig_inverse_render.pdf")
    png = joinpath(FIGS, "fig_inverse_render.png")
    save_pdf(pdf, out; dpi = 150)
    save_png(png, out)
    @info "Inverse figure written" pdf png
    @printf("INVERSE_OK loss %.4g -> %.4g  (%.1f%% reduction)\n",
            hist[1], hist[end], 100 * (1 - hist[end] / hist[1]))
end

main()

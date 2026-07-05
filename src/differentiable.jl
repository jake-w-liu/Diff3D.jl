# --------------------------------------------------------------------------
# High-dimensional differentiable rendering: gradients of the soft rasterizer
# with respect to vertex positions and per-face colors ("differentiable
# textures"), plus optimization demos. Gradients use ForwardDiff; the pipeline
# is fully dual-number compatible. (Full reverse-mode via Enzyme/Zygote is left
# as future work — see THREEJS_PARITY.md §12.)
# --------------------------------------------------------------------------

# Promote a Float64 Mat4 to element type T (so AD duals flow through projection).
@inline _promote_mat4(vp::Mat4{T}, ::Type{T}) where {T} = vp
@inline _promote_mat4(vp::Mat4, ::Type{T}) where {T} =
    Mat4{T}(ntuple(k -> T(vp.e[k]), 16))

@inline _promote_vec3_vector(vertices::Vector{Vec3{T}}, ::Type{T}) where {T} = vertices
@inline _promote_vec3_vector(vertices, ::Type{T}) where {T} =
    Vec3{T}[Vec3(T(v.x), T(v.y), T(v.z)) for v in vertices]

@inline _promote_color_vector(colors::Vector{Color3{T}}, ::Type{T}) where {T} = colors
@inline _promote_color_vector(colors, ::Type{T}) where {T} =
    Color3{T}[Color3(T(c.r), T(c.g), T(c.b)) for c in colors]

function _max_face_vertex_index(faces)
    max_index = 0
    for face in faces
        i1, i2, i3 = face
        (i1 >= 1 && i2 >= 1 && i3 >= 1) ||
            throw(ArgumentError("faces must use positive 1-based vertex indices"))
        max_index = max(max_index, i1, i2, i3)
    end
    return max_index
end

"""
    vertex_render_fn(faces, face_colors, vp, W, H; sigma, gamma)

Return a closure `p -> image` where `p` is a flat vector of vertex positions
`[x1,y1,z1, x2,...]`. Differentiable w.r.t. `p` (vertex-position gradients).
"""
function vertex_render_fn(faces, face_colors, vp::Mat4, W::Int, H::Int;
                          sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0))
    expected_vertices = _max_face_vertex_index(faces)
    length(face_colors) == length(faces) ||
        throw(ArgumentError("vertex_render_fn face_colors length must match faces length"))
    expected_params = 3 * expected_vertices
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("vertex_render_fn parameter length must be 3 * maximum face index ($expected_params); got $(length(p))"))
        T = eltype(p)
        verts = [Vec3(p[3i-2], p[3i-1], p[3i]) for i in 1:expected_vertices]
        cols = _promote_color_vector(face_colors, T)
        cfg = SoftRasterizerConfig(sigma=T(sigma), gamma=T(gamma),
                                   bg_color=Color3(T(bg.r), T(bg.g), T(bg.b)))
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg)
    end
end

"""
    color_render_fn(vertices, faces, vp, W, H; sigma, gamma)

Return a closure `p -> image` where `p` is a flat vector of per-face RGB colors
`[r1,g1,b1, r2,...]`. Differentiable w.r.t. `p` (a differentiable texture/colour
field over the surface).
"""
function color_render_fn(vertices, faces, vp::Mat4, W::Int, H::Int;
                         sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0))
    _max_face_vertex_index(faces) <= length(vertices) ||
        throw(ArgumentError("color_render_fn faces must reference vertices"))
    expected_params = 3 * length(faces)
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("color_render_fn parameter length must be 3 * number of faces ($expected_params); got $(length(p))"))
        T = eltype(p)
        cols = [Color3(p[3i-2], p[3i-1], p[3i]) for i in 1:length(faces)]
        verts = _promote_vec3_vector(vertices, T)
        cfg = SoftRasterizerConfig(sigma=T(sigma), gamma=T(gamma),
                                   bg_color=Color3(T(bg.r), T(bg.g), T(bg.b)))
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg)
    end
end

"""
    optimize_vertices(initial, faces, face_colors, vp, target; ...)

Adam optimization of a flat vertex-position vector to match `target`. Returns
`(optimized_params, loss_history)`.
"""
function optimize_vertices(initial::Vector{Float64}, faces, face_colors, vp::Mat4,
                           target::Array{Float64,3}; W::Int, H::Int,
                           sigma=1.0, gamma=1.0, lr=0.05, n_iters=50, verbose=false)
    rf = vertex_render_fn(faces, face_colors, vp, W, H; sigma=sigma, gamma=gamma)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

"""
    optimize_face_colors(initial, vertices, faces, vp, target; ...)

Adam optimization of a flat per-face colour vector to match `target` — a
differentiable-texture demo. Returns `(optimized_params, loss_history)`.
"""
function optimize_face_colors(initial::Vector{Float64}, vertices, faces, vp::Mat4,
                              target::Array{Float64,3}; W::Int, H::Int,
                              sigma=1.0, gamma=1.0, lr=0.05, n_iters=50, verbose=false)
    rf = color_render_fn(vertices, faces, vp, W, H; sigma=sigma, gamma=gamma)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

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

struct _FlatVec3Params{T,P<:AbstractVector{T}} <: AbstractVector{Vec3{T}}
    p::P
    n::Int
end

Base.IndexStyle(::Type{<:_FlatVec3Params}) = IndexLinear()
Base.size(v::_FlatVec3Params) = (v.n,)
@inline function Base.getindex(v::_FlatVec3Params{T}, i::Int) where {T}
    @boundscheck 1 <= i <= v.n || throw(BoundsError(v, i))
    @inbounds return Vec3{T}(v.p[3i - 2], v.p[3i - 1], v.p[3i])
end

struct _FlatColorParams{T,P<:AbstractVector{T}} <: AbstractVector{Color3{T}}
    p::P
    n::Int
end

Base.IndexStyle(::Type{<:_FlatColorParams}) = IndexLinear()
Base.size(v::_FlatColorParams) = (v.n,)
@inline function Base.getindex(v::_FlatColorParams{T}, i::Int) where {T}
    @boundscheck 1 <= i <= v.n || throw(BoundsError(v, i))
    @inbounds return Color3{T}(v.p[3i - 2], v.p[3i - 1], v.p[3i])
end

struct _PromotedVec3Vector{T,V<:AbstractVector} <: AbstractVector{Vec3{T}}
    data::V
end

Base.IndexStyle(::Type{<:_PromotedVec3Vector}) = IndexLinear()
Base.size(v::_PromotedVec3Vector) = size(v.data)
@inline function Base.getindex(v::_PromotedVec3Vector{T}, i::Int) where {T}
    x = v.data[i]
    return Vec3{T}(T(x.x), T(x.y), T(x.z))
end

struct _PromotedColorVector{T,V<:AbstractVector} <: AbstractVector{Color3{T}}
    data::V
end

Base.IndexStyle(::Type{<:_PromotedColorVector}) = IndexLinear()
Base.size(v::_PromotedColorVector) = size(v.data)
@inline function Base.getindex(v::_PromotedColorVector{T}, i::Int) where {T}
    x = v.data[i]
    return Color3{T}(T(x.r), T(x.g), T(x.b))
end

@inline _promote_vec3_source(vertices::AbstractVector{Vec3{T}}, ::Type{T}) where {T} =
    vertices
@inline _promote_vec3_source(vertices::AbstractVector, ::Type{T}) where {T} =
    _PromotedVec3Vector{T,typeof(vertices)}(vertices)

@inline _promote_color_source(colors::AbstractVector{Color3{T}}, ::Type{T}) where {T} =
    colors
@inline _promote_color_source(colors::AbstractVector, ::Type{T}) where {T} =
    _PromotedColorVector{T,typeof(colors)}(colors)

function _render_workspace_for_type(workspace, cache::Base.RefValue{Any},
                                    ::Type{T}) where {T}
    workspace === nothing && return nothing
    if workspace === :auto
        cached = cache[]
        cached isa SoftRenderWorkspace{T} && return cached
        cached = SoftRenderWorkspace{T}()
        cache[] = cached
        return cached
    end
    return workspace
end

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
Pass `workspace=SoftRenderWorkspace{T}()` or `workspace=:auto` only when the
returned image may be overwritten by the next closure call.
"""
function vertex_render_fn(faces, face_colors, vp::Mat4, W::Int, H::Int;
                          sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0),
                          workspace=nothing)
    expected_vertices = _max_face_vertex_index(faces)
    length(face_colors) == length(faces) ||
        throw(ArgumentError("vertex_render_fn face_colors length must match faces length"))
    expected_params = 3 * expected_vertices
    workspace_cache = Ref{Any}(nothing)
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("vertex_render_fn parameter length must be 3 * maximum face index ($expected_params); got $(length(p))"))
        T = eltype(p)
        verts = _FlatVec3Params{T,typeof(p)}(p, expected_vertices)
        cols = _promote_color_source(face_colors, T)
        cfg = SoftRasterizerConfig(sigma=T(sigma), gamma=T(gamma),
                                   bg_color=Color3(T(bg.r), T(bg.g), T(bg.b)))
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg;
                    workspace=_render_workspace_for_type(workspace, workspace_cache, T))
    end
end

"""
    color_render_fn(vertices, faces, vp, W, H; sigma, gamma)

Return a closure `p -> image` where `p` is a flat vector of per-face RGB colors
`[r1,g1,b1, r2,...]`. Differentiable w.r.t. `p` (a differentiable texture/colour
field over the surface).
Pass `workspace=SoftRenderWorkspace{T}()` or `workspace=:auto` only when the
returned image may be overwritten by the next closure call.
"""
function color_render_fn(vertices, faces, vp::Mat4, W::Int, H::Int;
                         sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0),
                         workspace=nothing)
    _max_face_vertex_index(faces) <= length(vertices) ||
        throw(ArgumentError("color_render_fn faces must reference vertices"))
    expected_params = 3 * length(faces)
    workspace_cache = Ref{Any}(nothing)
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("color_render_fn parameter length must be 3 * number of faces ($expected_params); got $(length(p))"))
        T = eltype(p)
        cols = _FlatColorParams{T,typeof(p)}(p, length(faces))
        verts = _promote_vec3_source(vertices, T)
        cfg = SoftRasterizerConfig(sigma=T(sigma), gamma=T(gamma),
                                   bg_color=Color3(T(bg.r), T(bg.g), T(bg.b)))
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg;
                    workspace=_render_workspace_for_type(workspace, workspace_cache, T))
    end
end

"""
    optimize_vertices(initial, faces, face_colors, vp, target; ...)

Adam optimization of a flat vertex-position vector to match `target`. Returns
`(optimized_params, loss_history)`.
Uses an internal workspace by default because intermediate renders are consumed
immediately by the loss function.
"""
function optimize_vertices(initial::Vector{Float64}, faces, face_colors, vp::Mat4,
                           target::Array{Float64,3}; W::Int, H::Int,
                           sigma=1.0, gamma=1.0, lr=0.05, n_iters=50,
                           verbose=false, workspace=:auto)
    rf = vertex_render_fn(faces, face_colors, vp, W, H; sigma=sigma, gamma=gamma,
                          workspace=workspace)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

"""
    optimize_face_colors(initial, vertices, faces, vp, target; ...)

Adam optimization of a flat per-face colour vector to match `target` — a
differentiable-texture demo. Returns `(optimized_params, loss_history)`.
Uses an internal workspace by default because intermediate renders are consumed
immediately by the loss function.
"""
function optimize_face_colors(initial::Vector{Float64}, vertices, faces, vp::Mat4,
                              target::Array{Float64,3}; W::Int, H::Int,
                              sigma=1.0, gamma=1.0, lr=0.05, n_iters=50,
                              verbose=false, workspace=:auto)
    rf = color_render_fn(vertices, faces, vp, W, H; sigma=sigma, gamma=gamma,
                         workspace=workspace)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

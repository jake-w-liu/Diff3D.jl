# --------------------------------------------------------------------------
# Renderer extras: tone mapping + sRGB output encoding, supersample anti-
# aliasing, line/point rasterization, a small post-processing EffectComposer,
# and a tiled (optionally threaded) rasterizer.
# --------------------------------------------------------------------------

# ========================== Tone mapping / sRGB ==========================

"""Reinhard tone map `c/(1+c)`, mapping HDR radiance into [0,1)."""
function tone_map_reinhard(img::AbstractArray)
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        c = Float64(img[i])
        out[i] = c == Inf ? 1.0 : c / (1 + c)   # limit c->Inf is 1, not Inf/Inf=NaN
    end
    return out
end

"""ACES filmic tone map (Narkowicz approximation)."""
function tone_map_aces(img::AbstractArray)
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        # Clamp unphysical negative radiance to black first (the ACES rational is
        # positive for small negative x, so raw negatives map to spurious grays);
        # +Inf maps to the x->Inf limit a/c≈1.03 -> 1, not Inf/Inf=NaN.
        x = Float64(img[i])
        xc = x <= 0.0 ? 0.0 : x
        out[i] = isinf(xc) ? 1.0 : clamp((xc * (a*xc + b)) / (xc * (c*xc + d) + e), 0.0, 1.0)
    end
    return out
end

linear_to_srgb(c) = c <= 0.0031308 ? 12.92*c : 1.055*c^(1/2.4) - 0.055
srgb_to_linear(c) = c <= 0.04045 ? c/12.92 : ((c + 0.055)/1.055)^2.4

"""Encode a linear-light image to sRGB for display/output."""
function srgb_encode(img::AbstractArray)
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        out[i] = clamp(linear_to_srgb(clamp(Float64(img[i]), 0.0, 1.0)), 0.0, 1.0)
    end
    return out
end

# ========================== Supersample (MSAA) ==========================

"""Box-average downsample an H·ss × W·ss image to H × W."""
function downsample(img::AbstractArray, ss::Int)
    ss > 0 || throw(ArgumentError("downsample scale must be positive"))
    Hb, Wb = _rgb_image_size(img, "downsample")
    (Hb % ss == 0 && Wb % ss == 0) ||
        throw(ArgumentError("downsample image dimensions must be divisible by scale"))
    H, W = Hb ÷ ss, Wb ÷ ss
    out = zeros(Float64, H, W, 3)
    downsample!(out, img, ss)
    return out
end

function downsample!(out::AbstractArray, img::AbstractArray, ss::Int)
    ss > 0 || throw(ArgumentError("downsample scale must be positive"))
    Hb, Wb = _rgb_image_size(img, "downsample")
    (Hb % ss == 0 && Wb % ss == 0) ||
        throw(ArgumentError("downsample image dimensions must be divisible by scale"))
    H, W = Hb ÷ ss, Wb ÷ ss
    Ho, Wo = _rgb_image_size(out, "downsample output")
    (Ho == H && Wo == W) ||
        throw(ArgumentError("downsample output dimensions must match input ÷ scale"))
    inv = 1.0 / (ss * ss)
    @inbounds for c in 1:3, i in 1:H, j in 1:W
        s = 0.0
        for di in 0:ss-1, dj in 0:ss-1
            s += img[(i-1)*ss + di + 1, (j-1)*ss + dj + 1, c]
        end
        out[i, j, c] = s * inv
    end
    return out
end

"""Render at `ss`× resolution and box-downsample — supersampled anti-aliasing."""
function render_aa(scene::Scene, camera::AbstractCamera, width::Int, height::Int;
                   ss::Int=2, shading::Symbol=:flat, shadows::Bool=false)
    ss > 0 || throw(ArgumentError("render_aa ss must be positive"))
    rt = RenderTarget(width*ss, height*ss)
    render!(rt, scene, camera; shading=shading, shadows=shadows)
    return downsample(rt.color, ss)
end

"""
    render_msaa!(rt, scene, camera; samples=4, shading=:flat, shadows=false, cache=nothing)

In-renderer multisample anti-aliasing: render an internal ⌈√samples⌉× target and
box-downsample into `rt.color`. Unlike `render_aa` (which returns an array), this
fills the supplied `RenderTarget`, so the renderer itself yields an AA frame.
Pass `cache=RenderCache()` to reuse the internal high-resolution render target
and renderer scratch buffers across frames.
"""
function render_msaa!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                      samples::Int=4, shading::Symbol=:flat, shadows::Bool=false,
                      cache=nothing)
    samples > 0 || throw(ArgumentError("render_msaa! samples must be positive"))
    ss = max(ceil(Int, sqrt(samples)), 1)
    big_w = rt.width * ss
    big_h = rt.height * ss
    big = cache === nothing ? RenderTarget(big_w, big_h) :
          _render_cache_msaa_target!(cache, big_w, big_h)
    render!(big, scene, camera; shading=shading, shadows=shadows,
            cache=cache === nothing ? nothing : cache)
    downsample!(rt.color, big.color, ss)
    return rt
end

# ========================== Pooled rendering (bounded allocation) ==========================

mutable struct _SpriteRenderState
    stamp::Union{Nothing,Matrix{Int}}
    stamp_id::Int
end

mutable struct _InstancedMaterialState
    mesh::Union{Nothing,InstancedMesh}
    base_material::Any
    colors::Vector{Color3{Float64}}
    materials::Any
end

_InstancedMaterialState() =
    _InstancedMaterialState(nothing, nothing, Color3{Float64}[], AbstractMaterial[])

"""
Reusable scratch buffers for the flat opaque path, so repeated frames allocate a
bounded amount (independent of frame count). Mesh/light lists and the per-face
colour buffer are reused via [`render_pooled!`].
"""
mutable struct RenderCache
    meshes::Vector{Mesh}
    lights::Vector{SceneLight}
    instanced::Vector{InstancedMesh}
    instanced_materials::Vector{_InstancedMaterialState}
    skinned::Vector{SkinnedMesh}
    skinned_meshes::Vector{Mesh}
    transparent::Vector{Mesh}
    opaque_flat::Vector{Mesh}
    smooth_meshes::Vector{Mesh}
    wireframe_meshes::Vector{Mesh}
    tri::Vector{Vec4{Float64}}
    clipped::Vector{Vec4{Float64}}
    sx::Vector{Float64}
    sy::Vector{Float64}
    sz::Vector{Float64}
    colors::Vector{Color3{Float64}}
    stamp::Matrix{Int}
    wire_edges::Set{Tuple{Int,Int}}
    sprite_state::_SpriteRenderState
    smooth_tri::Vector{ShadeVtx}
    smooth_clipped::Vector{ShadeVtx}
    smooth_iw::Vector{Float64}
    msaa_target::Union{Nothing,RenderTarget{Float64}}
    bound_geometries::Vector{BufferGeometry}
    bounds::Vector{BoundingSphere{Float64}}
    shadow_depths::Vector{Matrix{Float64}}
    shadow_maps::IdDict{AbstractLight,ShadowMap}
    mesh_depths::Vector{Float64}
    skinned_matrices::Vector{Mat4{Float64}}
    morph_positions::Vector{Vec3{Float64}}
end
function RenderCache()
    cl = Vector{Vec4{Float64}}(undef, 0); sizehint!(cl, 6)
    scl = Vector{ShadeVtx}(undef, 0); sizehint!(scl, 6)
    RenderCache(Mesh[], SceneLight[], InstancedMesh[], _InstancedMaterialState[],
                SkinnedMesh[],
                Mesh[], Mesh[], Mesh[], Mesh[], Mesh[],
                Vector{Vec4{Float64}}(undef, 3), cl,
                Vector{Float64}(undef, 8), Vector{Float64}(undef, 8), Vector{Float64}(undef, 8),
                Color3{Float64}[], zeros(Int, 0, 0), Set{Tuple{Int,Int}}(),
                _SpriteRenderState(nothing, 0),
                Vector{ShadeVtx}(undef, 3), scl, Vector{Float64}(undef, 8), nothing,
                BufferGeometry[], BoundingSphere{Float64}[],
                Matrix{Float64}[], IdDict{AbstractLight,ShadowMap}(),
                Float64[], Mat4{Float64}[], Vec3{Float64}[])
end

function _render_cache_msaa_target!(cache::RenderCache, width::Int, height::Int)
    target = cache.msaa_target
    if target === nothing || target.width != width || target.height != height
        target = RenderTarget(width, height)
        cache.msaa_target = target
    end
    return target
end

@inline _instanced_geometry(mesh::InstancedMesh)::BufferGeometry = mesh.geometry
@inline _instanced_material(mesh::InstancedMesh)::AbstractMaterial = mesh.material
@inline _line_geometry(obj::LineObject)::BufferGeometry = obj.geometry
@inline _line_geometry(obj::LineSegments)::BufferGeometry = obj.geometry
@inline _line_geometry(obj::LineLoop)::BufferGeometry = obj.geometry
@inline _points_geometry(obj::PointsObject)::BufferGeometry = obj.geometry

@inline _same_instanced_base_material(a, b) = a === b || a == b

function _instanced_material_state!(states::Vector{_InstancedMaterialState}, slot::Int)
    @inbounds while length(states) < slot
        push!(states, _InstancedMaterialState())
    end
    return states[slot]
end

function _instanced_materials!(states::Vector{_InstancedMaterialState}, slot::Int,
                               mesh::InstancedMesh, mat,
                               colors::Vector{Color3{Float64}})
    state = _instanced_material_state!(states, slot)
    n = length(colors)
    M = typeof(mat)
    same_base = state.mesh === mesh &&
                _same_instanced_base_material(state.base_material, mat) &&
                state.materials isa Vector{M}
    if !same_base
        state.mesh = mesh
        state.base_material = mat
        resize!(state.colors, n)
        materials = Vector{M}(undef, n)
        state.materials = materials
        @inbounds for i in 1:n
            c = colors[i]
            state.colors[i] = c
            materials[i] = _with_vertex_color(mat, c)
        end
        return materials
    end
    materials = state.materials::Vector{M}
    initialized_n = min(length(state.colors), length(materials))
    length(state.colors) == n || resize!(state.colors, n)
    length(materials) == n || resize!(materials, n)
    @inbounds for i in 1:n
        c = colors[i]
        if i > initialized_n || state.colors[i] != c
            state.colors[i] = c
            materials[i] = _with_vertex_color(mat, c)
        end
    end
    return materials
end

function _rasterize_flat_mesh_cached!(rt::RenderTarget, geo::BufferGeometry,
                                      mat::AbstractMaterial, mesh::Mesh, world::Mat4,
                                      lights, proj::Mat4, view::Mat4, near,
                                      cam_pos::Vec3, tri, clipped, sx, sy, sz,
                                      colorbuf::Vector{Color3{Float64}},
                                      alpha, stamp, stamp_id::Int, shadow_fn,
                                      xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                      clipping_planes, log_depth::Bool,
                                      inv_log_far::Float64, ortho_dir,
                                      flat_attr_tri=nothing,
                                      flat_attr_clipped=nothing,
                                      flat_iw=nothing)
    mesh_shadow_fn = shadow_fn === nothing ? nothing : (mesh.receive_shadow ? shadow_fn : nothing)
    mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                     material_clipping_planes(mat))
    _rasterize_geo_flat!(rt, geo, world, mat, lights, proj, view, near, cam_pos,
                         tri, clipped, sx, sy, sz; alpha=alpha, stamp=stamp,
                         stamp_id=stamp_id, shadow_fn=mesh_shadow_fn, xlo=xlo, xhi=xhi,
                         ylo=ylo, yhi=yhi, colorbuf=colorbuf,
                         clipping_planes=mesh_clipping_planes, log_depth=log_depth,
                         inv_log_far=inv_log_far, ortho_dir=ortho_dir,
                         flat_attr_tri=flat_attr_tri,
                         flat_attr_clipped=flat_attr_clipped,
                         flat_iw=flat_iw)
end

function _rasterize_flat_mesh_from_mesh!(rt::RenderTarget, mesh::Mesh, world::Mat4,
                                         lights, proj::Mat4, view::Mat4, near,
                                         cam_pos::Vec3, tri, clipped, sx, sy, sz,
                                         colorbuf::Vector{Color3{Float64}},
                                         alpha, stamp, stamp_id::Int, shadow_fn,
                                         xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                         clipping_planes, log_depth::Bool,
                                         inv_log_far::Float64, ortho_dir,
                                         flat_attr_tri=nothing,
                                         flat_attr_clipped=nothing,
                                         flat_iw=nothing)
    geo = _mesh_geometry(mesh)
    mat = mesh.material
    if mat isa MeshBasicMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshLambertMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshPhongMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshStandardMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshNormalMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshPhysicalMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshToonMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshMatcapMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa MeshDepthMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    elseif mat isa ShaderMaterial
        _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view, near,
                                     cam_pos, tri, clipped, sx, sy, sz, colorbuf,
                                     alpha, stamp, stamp_id, shadow_fn, xlo, xhi,
                                     ylo, yhi, clipping_planes, log_depth, inv_log_far,
                                     ortho_dir, flat_attr_tri, flat_attr_clipped,
                                     flat_iw)
    else
        _rasterize_flat_mesh_cached!(rt, geo, mat::AbstractMaterial, mesh, world, lights,
                                     proj, view, near, cam_pos, tri, clipped, sx, sy,
                                     sz, colorbuf, alpha, stamp, stamp_id, shadow_fn,
                                     xlo, xhi, ylo, yhi, clipping_planes, log_depth,
                                     inv_log_far, ortho_dir, flat_attr_tri,
                                     flat_attr_clipped, flat_iw)
    end
end

function _rasterize_flat_mesh_material_opacity_cached!(rt::RenderTarget,
                                                       geo::BufferGeometry,
                                                       mat::AbstractMaterial,
                                                       mesh::Mesh, world::Mat4,
                                                       lights, proj::Mat4, view::Mat4,
                                                       near, cam_pos::Vec3, tri,
                                                       clipped, sx, sy, sz,
                                                       colorbuf::Vector{Color3{Float64}},
                                                       stamp, stamp_id::Int, shadow_fn,
                                                       xlo::Int, xhi::Int, ylo::Int,
                                                       yhi::Int, clipping_planes,
                                                       log_depth::Bool,
                                                       inv_log_far::Float64,
                                                       ortho_dir,
                                                       flat_attr_tri=nothing,
                                                       flat_attr_clipped=nothing,
                                                       flat_iw=nothing)
    _rasterize_flat_mesh_cached!(rt, geo, mat, mesh, world, lights, proj, view,
                                 near, cam_pos, tri, clipped, sx, sy, sz,
                                 colorbuf, Float64(material_opacity(mat)), stamp,
                                 stamp_id, shadow_fn, xlo, xhi, ylo, yhi,
                                 clipping_planes, log_depth, inv_log_far, ortho_dir,
                                 flat_attr_tri, flat_attr_clipped, flat_iw)
end

function _rasterize_flat_mesh_material_opacity_from_mesh!(rt::RenderTarget,
                                                          mesh::Mesh, world::Mat4,
                                                          lights, proj::Mat4, view::Mat4,
                                                          near, cam_pos::Vec3, tri,
                                                          clipped, sx, sy, sz,
                                                          colorbuf::Vector{Color3{Float64}},
                                                          stamp, stamp_id::Int, shadow_fn,
                                                          xlo::Int, xhi::Int, ylo::Int,
                                                          yhi::Int, clipping_planes,
                                                          log_depth::Bool,
                                                          inv_log_far::Float64,
                                                          ortho_dir,
                                                          flat_attr_tri=nothing,
                                                          flat_attr_clipped=nothing,
                                                          flat_iw=nothing)
    geo = _mesh_geometry(mesh)
    mat = mesh.material
    if mat isa MeshBasicMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshLambertMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshPhongMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshStandardMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshNormalMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshPhysicalMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshToonMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshMatcapMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa MeshDepthMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    elseif mat isa ShaderMaterial
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat, mesh, world, lights, proj, view, near, cam_pos, tri,
            clipped, sx, sy, sz, colorbuf, stamp, stamp_id, shadow_fn, xlo, xhi,
            ylo, yhi, clipping_planes, log_depth, inv_log_far, ortho_dir,
            flat_attr_tri, flat_attr_clipped, flat_iw)
    else
        _rasterize_flat_mesh_material_opacity_cached!(
            rt, geo, mat::AbstractMaterial, mesh, world, lights, proj, view, near,
            cam_pos, tri, clipped, sx, sy, sz, colorbuf, stamp, stamp_id,
            shadow_fn, xlo, xhi, ylo, yhi, clipping_planes, log_depth,
            inv_log_far, ortho_dir, flat_attr_tri, flat_attr_clipped,
            flat_iw)
    end
    return nothing
end

function _rasterize_flat_mesh_pooled_from_mesh!(rt::RenderTarget, mesh::Mesh, world::Mat4,
                                                lights, proj::Mat4, view::Mat4, near,
                                                cam_pos::Vec3, tri, clipped, sx, sy, sz,
                                                colorbuf::Vector{Color3{Float64}},
                                                xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                                ortho_dir)
    geo = _mesh_geometry(mesh)
    mat = mesh.material
    if mat isa MeshBasicMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshLambertMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshPhongMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshStandardMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshNormalMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshPhysicalMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshToonMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshMatcapMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa MeshDepthMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    elseif mat isa ShaderMaterial
        _rasterize_geo_flat_pooled!(rt, geo, world, mat, lights, proj, view, near,
                                    cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    else
        _rasterize_geo_flat_pooled!(rt, geo, world, mat::AbstractMaterial, lights,
                                    proj, view, near, cam_pos, tri, clipped, sx, sy,
                                    sz, colorbuf; xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    end
end

function _render_cache_stamp!(cache::RenderCache, H::Int, W::Int)
    if size(cache.stamp) != (H, W)
        cache.stamp = zeros(Int, H, W)
    else
        fill!(cache.stamp, 0)
    end
    return cache.stamp
end

# Collect into a reused vector (clears then refills), avoiding per-frame allocation.
function _collect_into!(out::Vector, root, pred)
    empty!(out)
    traverse(root, o -> pred(o) && push!(out, o))
    return out
end

function _collect_meshes_into!(out::Vector{Mesh}, root::AbstractObject3D)
    empty!(out)
    _collect_meshes!(out, root)
    return out
end

function _collect_lights_into!(out::Vector{SceneLight}, root::AbstractObject3D)
    empty!(out)
    _collect_lights!(out, root)
    return out
end

function _collect_instanced_into!(out::Vector{InstancedMesh}, root::AbstractObject3D)
    empty!(out)
    _collect_instanced_into_visit!(out, root)
    return out
end

function _collect_instanced_into_visit!(out::Vector{InstancedMesh}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    obj isa InstancedMesh && push!(out, obj)
    @inbounds for child in get_children(obj)
        _collect_instanced_into_visit!(out, child)
    end
    return nothing
end

function _render_pooled_uses_fragment_alpha(geo::BufferGeometry, mat)
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    has_uvs || return false
    albedo_map = _material_field(mat, :map)
    alpha_map = _material_field(mat, :alpha_map)
    _needs_fragment_alpha(material_alpha_test(mat), 1.0, albedo_map, alpha_map)
end

function _rasterize_geo_flat_pooled!(rt::RenderTarget, geo::BufferGeometry, world_mat::Mat4, mat,
                                     lights, proj::Mat4, view::Mat4, near, cam_pos::Vec3,
                                     tri, clipped, sx, sy, sz, colorbuf::Vector{Color3{Float64}};
                                     xlo::Int=1, xhi::Int=rt.width,
                                     ylo::Int=1, yhi::Int=rt.height,
                                     ortho_dir=nothing)
    if _render_pooled_uses_fragment_alpha(geo, mat)
        return _rasterize_geo_flat!(rt, geo, world_mat, mat, lights, proj, view, near, cam_pos,
                                    tri, clipped, sx, sy, sz; colorbuf=colorbuf,
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    end

    side = material_side(mat)
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    has_normals = length(geo.normals) >= geo.n_vertices * 3
    normal_mat = side === :double ? world_mat : mat4_transpose(mat4_inverse(world_mat))
    modelview = view * world_mat
    face_colors = shade_mesh_faces!(colorbuf, geo, world_mat, mat, lights, cam_pos)

    @inbounds for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        if side !== :double
            wc = mat4_transform_point(world_mat, Vec3((v1.x+v2.x+v3.x)/3,
                                                      (v1.y+v2.y+v3.y)/3,
                                                      (v1.z+v2.z+v3.z)/3))
            fn = _flat_face_normal(geo, i1, i2, i3,
                                   mat4_transform_point(world_mat, v1),
                                   mat4_transform_point(world_mat, v2),
                                   mat4_transform_point(world_mat, v3), normal_mat, has_normals)
            facing = ortho_dir === nothing ? dot(fn, cam_pos - wc) : dot(fn, ortho_dir)
            (side === :front ? facing <= 0 : facing > 0) && continue
        end
        tri[1] = mat4_transform_vec4(modelview, Vec4(v1.x, v1.y, v1.z, 1.0))
        tri[2] = mat4_transform_vec4(modelview, Vec4(v2.x, v2.y, v2.z, 1.0))
        tri[3] = mat4_transform_vec4(modelview, Vec4(v3.x, v3.y, v3.z, 1.0))
        m = _clip_near!(clipped, tri, 3, near)
        m < 3 && continue
        for k in 1:m
            cv = mat4_transform_vec4(proj, clipped[k])
            invw = 1.0 / cv.w
            ndcx = cv.x * invw; ndcy = cv.y * invw; ndcz = cv.z * invw
            sx[k] = (ndcx + 1) * 0.5 * rt.width
            sy[k] = (1 - ndcy) * 0.5 * rt.height
            sz[k] = ndcz
        end
        fc = face_colors[fi]
        for k in 2:(m - 1)
            if depth_test && depth_write
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi)
            else
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi,
                                depth_test=depth_test, depth_write=depth_write)
            end
        end
    end
    return nothing
end

# Function barrier for `InstancedMesh`'s `Any`-typed geometry/material fields:
# dispatch once per instanced object, then rasterize each instance in a
# specialized loop.
function _rasterize_instanced_geo_flat_pooled!(rt::RenderTarget, geo, mat,
                                               instance_colors::Vector{Color3{Float64}},
                                               instance_matrices::Vector{Mat4{Float64}},
                                               base::Mat4, lights, proj::Mat4,
                                               view::Mat4, near, cam_pos::Vec3,
                                               tri, clipped, sx, sy, sz,
                                               colorbuf::Vector{Color3{Float64}},
                                               ortho_dir;
                                               xlo::Int=1, xhi::Int=rt.width,
                                               ylo::Int=1, yhi::Int=rt.height)
    @inbounds for instance_index in eachindex(instance_matrices)
        instance_material = _with_vertex_color(mat, instance_colors[instance_index])
        _rasterize_geo_flat_pooled!(rt, geo, base * instance_matrices[instance_index],
                                    instance_material, lights, proj, view, near, cam_pos,
                                    tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    end
    return nothing
end

function _rasterize_instanced_geo_flat_pooled_materials!(rt::RenderTarget, geo,
                                                         instance_materials::AbstractVector,
                                                         instance_matrices::Vector{Mat4{Float64}},
                                                         base::Mat4, lights, proj::Mat4,
                                                         view::Mat4, near, cam_pos::Vec3,
                                                         tri, clipped, sx, sy, sz,
                                                         colorbuf::Vector{Color3{Float64}},
                                                         ortho_dir;
                                                         xlo::Int=1, xhi::Int=rt.width,
                                                         ylo::Int=1, yhi::Int=rt.height)
    @boundscheck length(instance_materials) == length(instance_matrices) ||
        throw(ArgumentError("instance material count must match instance matrix count"))
    @inbounds for instance_index in eachindex(instance_matrices)
        _rasterize_geo_flat_pooled!(rt, geo, base * instance_matrices[instance_index],
                                    instance_materials[instance_index], lights, proj, view,
                                    near, cam_pos, tri, clipped, sx, sy, sz, colorbuf;
                                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                    ortho_dir=ortho_dir)
    end
    return nothing
end

"""
    render_pooled!(rt, scene, camera, cache; shading=:flat)

Flat opaque meshes/instances are rasterized reusing `cache`'s buffers — the same
image as `render!` for opaque flat scenes, but with bounded per-frame allocation
across repeated calls. Transparent meshes, lines and points are skipped here.
"""
function render_pooled!(rt::RenderTarget, scene::Scene, camera::AbstractCamera,
                        cache::RenderCache; shading::Symbol=:flat)
    shading === :flat || throw(ArgumentError("render_pooled! supports only :flat shading"))
    clear!(rt, scene.background)
    proj = projection_matrix(camera); view = view_matrix(camera); near = _camera_near(camera)
    # Same orthographic back-face-culling direction as `render!`.
    ortho_dir = camera isa OrthographicCamera ?
        normalize(camera.position - camera.target) : nothing
    _collect_meshes_into!(cache.meshes, scene)
    _append_skinned_render_meshes!(cache.meshes, scene, cache.skinned, cache.skinned_meshes,
                                   cache.skinned_matrices, cache.morph_positions)
    _collect_lights_into!(cache.lights, scene)
    _collect_instanced_into!(cache.instanced, scene)
    for mesh in cache.meshes
        mat = _mesh_material(mesh)
        (_visible_in_tree(mesh) && !is_transparent_material(mat) &&
         !material_wireframe(mat)) || continue
        _rasterize_flat_mesh_pooled_from_mesh!(rt, mesh, compute_world_matrix(mesh),
                                               cache.lights, proj, view, near,
                                               camera.position, cache.tri, cache.clipped,
                                               cache.sx, cache.sy, cache.sz, cache.colors,
                                               1, rt.width, 1, rt.height, ortho_dir)
    end
    for (instanced_slot, im) in pairs(cache.instanced)
        mat = _instanced_material(im)
        (_visible_in_tree(im) && !material_wireframe(mat)) || continue
        base = compute_world_matrix(im)
        instance_materials = _instanced_materials!(cache.instanced_materials,
                                                   instanced_slot, im, mat,
                                                   im.instance_colors)
        _rasterize_instanced_geo_flat_pooled_materials!(
            rt, _instanced_geometry(im), instance_materials, im.instance_matrices,
            base, cache.lights, proj, view, near, camera.position, cache.tri,
            cache.clipped, cache.sx, cache.sy, cache.sz, cache.colors, ortho_dir)
    end
    return rt
end

# ========================== Line / point rasterization ==========================

@inline function _put_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                             xlo::Int=1, xhi::Int=rt.width,
                             ylo::Int=1, yhi::Int=rt.height,
                             depth_test::Bool=true, depth_write::Bool=true,
                             alpha::Float64=1.0)
    (1 <= x <= rt.width && 1 <= y <= rt.height && xlo <= x <= xhi && ylo <= y <= yhi) || return false
    @inbounds if !depth_test || z < rt.depth[y, x]
        depth_write && (rt.depth[y, x] = z)
        if alpha >= 1.0
            rt.color[y, x, 1] = col.r; rt.color[y, x, 2] = col.g; rt.color[y, x, 3] = col.b
        elseif alpha > 0.0
            ia = 1.0 - alpha
            rt.color[y, x, 1] = col.r * alpha + rt.color[y, x, 1] * ia
            rt.color[y, x, 2] = col.g * alpha + rt.color[y, x, 2] * ia
            rt.color[y, x, 3] = col.b * alpha + rt.color[y, x, 3] * ia
        end
        return true
    end
    return false
end

@inline function _put_stamped_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                                     xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                     depth_test::Bool, depth_write::Bool,
                                     alpha::Float64, stamp, stamp_id::Int)
    if stamp !== nothing &&
       1 <= x <= rt.width && 1 <= y <= rt.height && xlo <= x <= xhi && ylo <= y <= yhi &&
       stamp[y, x] == stamp_id
        return false
    end
    wrote = _put_pixel!(rt, x, y, z, col, xlo, xhi, ylo, yhi, depth_test, depth_write, alpha)
    wrote && stamp !== nothing && (stamp[y, x] = stamp_id)
    return wrote
end

@inline function _put_line_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                                  radius::Float64,
                                  xlo::Int=1, xhi::Int=rt.width,
                                  ylo::Int=1, yhi::Int=rt.height,
                                  depth_test::Bool=true, depth_write::Bool=true,
                                  alpha::Float64=1.0,
                                  stamp=nothing, stamp_id::Int=0)
    if radius <= 0.5
        _put_stamped_pixel!(rt, x, y, z, col, xlo, xhi, ylo, yhi,
                            depth_test, depth_write, alpha, stamp, stamp_id)
        return nothing
    end
    r = ceil(Int, radius)
    r2 = radius * radius
    @inbounds for oy in -r:r, ox in -r:r
        ox * ox + oy * oy <= r2 &&
            _put_stamped_pixel!(rt, x + ox, y + oy, z, col, xlo, xhi, ylo, yhi,
                                depth_test, depth_write, alpha, stamp, stamp_id)
    end
    return nothing
end

# Liang–Barsky: clip the parametric segment P(t)=P0+t·(P1−P0), t∈[0,1], to the
# axis-aligned box [xmin,xmax]×[ymin,ymax]. Returns (t0, t1, visible) with
# 0≤t0≤t1≤1 for the portion inside the box, or visible=false if it misses.
@inline function _liang_barsky_t(x0, y0, dx, dy, xmin, xmax, ymin, ymax)
    t0 = 0.0; t1 = 1.0
    @inbounds for k in 1:4
        p = k == 1 ? -dx : k == 2 ? dx : k == 3 ? -dy : dy
        q = k == 1 ? x0 - xmin : k == 2 ? xmax - x0 : k == 3 ? y0 - ymin : ymax - y0
        if p == 0
            q < 0 && return (0.0, 0.0, false)   # parallel to this edge and outside
        else
            r = q / p
            if p < 0
                r > t1 && return (0.0, 0.0, false)
                r > t0 && (t0 = r)
            else
                r < t0 && return (0.0, 0.0, false)
                r < t1 && (t1 = r)
            end
        end
    end
    return (t0, t1, true)
end

# DDA line with depth interpolation and z-test.
function _draw_line!(rt::RenderTarget, x0, y0, z0, x1, y1, z1, col::Color3,
                     linewidth::Real=1.0,
                     xlo::Int=1, xhi::Int=rt.width,
                     ylo::Int=1, yhi::Int=rt.height,
                     depth_test::Bool=true, depth_write::Bool=true,
                     alpha::Float64=1.0,
                     stamp=nothing, stamp_id::Int=0)
    # A non-finite projected endpoint has no well-defined rasterization; skip it.
    (isfinite(x0) && isfinite(y0) && isfinite(x1) && isfinite(y1)) || return nothing
    dx = x1 - x0; dy = y1 - y0
    radius = max(0.5, Float64(linewidth) / 2)
    # Clip the DDA parameter range to the viewport (expanded by the stamp radius)
    # so an endpoint projecting far off-screen drives a step count bounded by the
    # visible span — not the raw off-axis delta, which would hang the loop or
    # overflow ceil(Int, ...). Downstream pixels are still bounds-checked, so the
    # drawn set (and density) is identical to the un-clipped version for any
    # on-screen segment.
    m = radius + 1.0
    t0, t1, vis = _liang_barsky_t(Float64(x0), Float64(y0), Float64(dx), Float64(dy),
                                  xlo - m, xhi + m, ylo - m, yhi + m)
    vis || return nothing
    span = max(abs(dx), abs(dy)) * (t1 - t0)
    n = max(ceil(Int, span), 1)
    @inbounds for s in 0:n
        t = t0 + (t1 - t0) * (s / n)
        _put_line_pixel!(rt, round(Int, x0 + dx*t), round(Int, y0 + dy*t),
                         z0 + (z1 - z0)*t, col, radius, xlo, xhi, ylo, yhi,
                         depth_test, depth_write, alpha, stamp, stamp_id)
    end
    return nothing
end

# Project a world point; returns (sx, sy, ndcz, ok) — ok=false if behind the camera.
@inline function _project(vp::Mat4, p::Vec3, W, H)
    c = mat4_transform_vec4(vp, Vec4(p.x, p.y, p.z, 1.0))
    c.w <= 1e-6 && return (0.0, 0.0, 0.0, false)
    iw = 1.0 / c.w
    ((c.x*iw + 1)*0.5*W, (1 - c.y*iw)*0.5*H, c.z*iw, true)
end

# Clip a world-space segment against the view-space near plane (z ≤ -near,
# matching the mesh path's `_clip_near!`), then project and rasterize it.
# Segments straddling the plane are shortened instead of dropped, and clipped
# endpoints keep NDC z ≥ -1, bounding the DDA step count.
function _draw_segment_near_clipped!(rt::RenderTarget, proj::Mat4, view::Mat4, near,
                                     a::Vec3, b::Vec3, col::Color3, linewidth::Real,
                                     xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                     depth_test::Bool=true, depth_write::Bool=true,
                                     alpha::Float64=1.0,
                                     stamp=nothing, stamp_id::Int=0)
    av = mat4_transform_point(view, a)
    bv = mat4_transform_point(view, b)
    a_in = av.z <= -near; b_in = bv.z <= -near
    (a_in || b_in) || return nothing
    if a_in != b_in
        t = (-near - av.z) / (bv.z - av.z)
        c = Vec3(av.x + t*(bv.x - av.x), av.y + t*(bv.y - av.y), av.z + t*(bv.z - av.z))
        a_in ? (bv = c) : (av = c)
    end
    W, H = rt.width, rt.height
    (ax, ay, az, oka) = _project(proj, av, W, H)
    (bx, by, bz, okb) = _project(proj, bv, W, H)
    (oka && okb) && _draw_line!(rt, ax, ay, az, bx, by, bz, col, linewidth,
                                xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                stamp, stamp_id)
    return nothing
end

@inline function _line_geometry_has_segment(geo, line_mode::Symbol)
    entries = _draw_entry_range(geo)
    !isempty(entries) && last(entries) - first(entries) + 1 >= 2
end

function _draw_line_geometry_stamped!(rt::RenderTarget, geo, material, wm::Mat4,
                                      line_mode::Symbol, proj::Mat4, view::Mat4, near,
                                      xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                      stamp::Matrix{Int}, stamp_id::Int,
                                      morphed_positions, instance_color::Color3)
    col = _point_material_color(material, instance_color)
    linewidth = hasfield(typeof(material), :linewidth) ? Float64(getfield(material, :linewidth)) : 1.0
    alpha = clamp(Float64(material_opacity(material)), 0.0, 1.0)
    depth_test = material_depth_test(material)
    depth_write = material_depth_write(material)
    stride = line_mode === :lines ? 2 : 1
    entries = _draw_entry_range(geo)
    isempty(entries) && return stamp_id
    first_entry = first(entries)
    last_entry = last(entries)
    i = first_entry
    while i + 1 <= last_entry
        i1 = _draw_vertex_index(geo, i)
        i2 = _draw_vertex_index(geo, i + 1)
        a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i1))
        b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i2))
        stamp_id += 1
        _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, linewidth,
                                    xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                    stamp, stamp_id)
        i += stride
    end
    if line_mode === :line_loop && last_entry - first_entry + 1 > 2
        i1 = _draw_vertex_index(geo, last_entry)
        i2 = _draw_vertex_index(geo, first_entry)
        a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i1))
        b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i2))
        stamp_id += 1
        _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, linewidth,
                                    xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                    stamp, stamp_id)
    end
    return stamp_id
end

@inline function _draw_line_geometry_from_material!(rt::RenderTarget, geo::BufferGeometry,
                                                    material, wm::Mat4, line_mode::Symbol,
                                                    proj::Mat4, view::Mat4, near,
                                                    xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                                    stamp::Matrix{Int}, stamp_id::Int,
                                                    morphed_positions, instance_color::Color3)
    if material isa LineBasicMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa LineDashedMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa MeshBasicMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa MeshLambertMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa MeshPhongMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa MeshStandardMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    elseif material isa MeshPhysicalMaterial
        return _draw_line_geometry_stamped!(rt, geo, material, wm, line_mode, proj, view,
                                            near, xlo, xhi, ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    else
        return _draw_line_geometry_stamped!(rt, geo, material::AbstractMaterial, wm,
                                            line_mode, proj, view, near, xlo, xhi,
                                            ylo, yhi, stamp, stamp_id,
                                            morphed_positions, instance_color)
    end
end

"""Rasterize `LineObject` strips, `LineLoop` closed strips, and `LineSegments` pairs."""
function _draw_line_object!(rt::RenderTarget, obj::LineObject,
                            proj::Mat4, view::Mat4, near,
                            xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                            stamp::Matrix{Int}, stamp_id::Int,
                            morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    geo = _line_geometry(obj)
    return _draw_line_geometry_from_material!(
        rt, geo, obj.material, compute_world_matrix(obj), :line_strip, proj, view,
        near, xlo, xhi, ylo, yhi, stamp, stamp_id,
        _object_morph_positions(obj, geo, morph_scratch),
        Color3(1.0,1.0,1.0))
end

function _draw_line_object!(rt::RenderTarget, obj::LineSegments,
                            proj::Mat4, view::Mat4, near,
                            xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                            stamp::Matrix{Int}, stamp_id::Int,
                            morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    geo = _line_geometry(obj)
    return _draw_line_geometry_from_material!(
        rt, geo, obj.material, compute_world_matrix(obj), :lines, proj, view, near,
        xlo, xhi, ylo, yhi, stamp, stamp_id,
        _object_morph_positions(obj, geo, morph_scratch),
        Color3(1.0,1.0,1.0))
end

function _draw_line_object!(rt::RenderTarget, obj::LineLoop,
                            proj::Mat4, view::Mat4, near,
                            xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                            stamp::Matrix{Int}, stamp_id::Int,
                            morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    geo = _line_geometry(obj)
    return _draw_line_geometry_from_material!(
        rt, geo, obj.material, compute_world_matrix(obj), :line_loop, proj, view, near,
        xlo, xhi, ylo, yhi, stamp, stamp_id,
        _object_morph_positions(obj, geo, morph_scratch),
        Color3(1.0,1.0,1.0))
end

function _draw_instanced_lines_geometry!(rt::RenderTarget, geo, material,
                                         instance_matrices::Vector{Mat4{Float64}},
                                         instance_colors::Vector{Color3{Float64}},
                                         base::Mat4, line_mode::Symbol,
                                         proj::Mat4, view::Mat4, near,
                                         xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                         stamp::Matrix{Int}, stamp_id::Int)
    @inbounds for instance_index in eachindex(instance_matrices)
        stamp_id = _draw_line_geometry_stamped!(rt, geo, material,
                                                base * instance_matrices[instance_index],
                                                line_mode, proj, view, near,
                                                xlo, xhi, ylo, yhi, stamp,
                                                stamp_id, nothing,
                                                instance_colors[instance_index])
    end
    return stamp_id
end

function _draw_instanced_lines!(rt::RenderTarget, obj::InstancedMesh,
                                proj::Mat4, view::Mat4, near,
                                xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                stamp::Matrix{Int}, stamp_id::Int)
    _draw_instanced_lines_geometry!(rt, _instanced_geometry(obj), _instanced_material(obj),
                                    obj.instance_matrices, obj.instance_colors,
                                    compute_world_matrix(obj), obj.draw_mode,
                                    proj, view, near, xlo, xhi, ylo, yhi,
                                    stamp, stamp_id)
end

@inline _object_has_children(obj::AbstractObject3D) = !isempty(get_children(obj))
@inline _object_has_children(obj::Object3D) = !isempty(obj.children)
@inline _object_has_children(obj::Scene) = !isempty(obj.children)
@inline _object_has_children(obj::Group) = !isempty(obj.children)
@inline _object_has_children(obj::Mesh) = !isempty(obj.children)
@inline _object_has_children(obj::LineObject) = !isempty(obj.children)
@inline _object_has_children(obj::PointsObject) = !isempty(obj.children)
@inline _object_has_children(obj::PerspectiveCamera) = !isempty(obj.children)
@inline _object_has_children(obj::OrthographicCamera) = !isempty(obj.children)
@inline _object_has_children(obj::AmbientLight) = !isempty(obj.children)
@inline _object_has_children(obj::DirectionalLight) = !isempty(obj.children)
@inline _object_has_children(obj::PointLight) = !isempty(obj.children)
@inline _object_has_children(obj::SpotLight) = !isempty(obj.children)
@inline _object_has_children(obj::HemisphereLight) = !isempty(obj.children)
@inline _object_has_children(obj::RectAreaLight) = !isempty(obj.children)
@inline _object_has_children(obj::LightProbe) = !isempty(obj.children)
@inline _object_has_children(obj::InstancedMesh) = !isempty(obj.children)
@inline _object_has_children(obj::LineSegments) = !isempty(obj.children)
@inline _object_has_children(obj::LineLoop) = !isempty(obj.children)
@inline _object_has_children(obj::Sprite) = !isempty(obj.children)
@inline _object_has_children(obj::LOD) = !isempty(obj.children)
@inline _object_has_children(obj::Bone) = !isempty(obj.children)
@inline _object_has_children(obj::SkinnedMesh) = !isempty(obj.children)

@inline _line_subtree_may_draw(obj::AbstractObject3D) =
    is_visible(obj) && (_object_has_children(obj) || obj isa LineObject ||
                        obj isa LineSegments || obj isa LineLoop ||
                        (obj isa InstancedMesh && _instanced_line_drawable(obj)))

function _render_lines_visible_tree!(rt::RenderTarget, obj::AbstractObject3D,
                                     proj::Mat4, view::Mat4, near,
                                     xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                     cache::Union{Nothing,RenderCache},
                                     stamp::Union{Nothing,Matrix{Int}},
                                     stamp_id::Int)
    is_visible(obj) || return stamp, stamp_id
    if obj isa LineObject || obj isa LineSegments || obj isa LineLoop
        line_mode = obj isa LineSegments ? :lines :
                    obj isa LineLoop ? :line_loop : :line_strip
        if _line_geometry_has_segment(obj.geometry, line_mode)
            stamp === nothing &&
                (stamp = cache === nothing ? zeros(Int, rt.height, rt.width) :
                         _render_cache_stamp!(cache, rt.height, rt.width))
            stamp_id = _draw_line_object!(rt, obj, proj, view, near,
                                          xlo, xhi, ylo, yhi, stamp, stamp_id,
                                          cache === nothing ? nothing :
                                          cache.morph_positions)
        end
    elseif obj isa InstancedMesh && _instanced_line_drawable(obj)
        if _line_geometry_has_segment(obj.geometry, obj.draw_mode)
            stamp === nothing &&
                (stamp = cache === nothing ? zeros(Int, rt.height, rt.width) :
                         _render_cache_stamp!(cache, rt.height, rt.width))
            stamp_id = _draw_instanced_lines!(rt, obj, proj, view, near,
                                              xlo, xhi, ylo, yhi, stamp, stamp_id)
        end
    end
    for child in get_children(obj)
        _line_subtree_may_draw(child) || continue
        # Keep drawable children type-narrowed; abstract recursive calls allocate
        # in scenes with many primitive objects.
        if child isa LineObject || child isa LineSegments || child isa LineLoop ||
           child isa InstancedMesh
            stamp, stamp_id = _render_lines_visible_tree!(rt, child, proj, view, near,
                                                          xlo, xhi, ylo, yhi, cache,
                                                          stamp, stamp_id)
        else
            stamp, stamp_id = _render_lines_visible_tree!(rt, child, proj, view, near,
                                                          xlo, xhi, ylo, yhi, cache,
                                                          stamp, stamp_id)
        end
    end
    return stamp, stamp_id
end

function _render_lines_visible_tree_cached!(rt::RenderTarget, obj::AbstractObject3D,
                                            proj::Mat4, view::Mat4, near,
                                            xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                            stamp::Matrix{Int}, stamp_id::Int,
                                            morph_scratch::Vector{Vec3{Float64}})
    is_visible(obj) || return stamp_id
    if obj isa LineObject
        geo = _line_geometry(obj)
        _line_geometry_has_segment(geo, :line_strip) &&
            (stamp_id = _draw_line_object!(rt, obj, proj, view, near,
                                           xlo, xhi, ylo, yhi, stamp, stamp_id,
                                           morph_scratch))
    elseif obj isa LineSegments
        geo = _line_geometry(obj)
        _line_geometry_has_segment(geo, :lines) &&
            (stamp_id = _draw_line_object!(rt, obj, proj, view, near,
                                           xlo, xhi, ylo, yhi, stamp, stamp_id,
                                           morph_scratch))
    elseif obj isa LineLoop
        geo = _line_geometry(obj)
        _line_geometry_has_segment(geo, :line_loop) &&
            (stamp_id = _draw_line_object!(rt, obj, proj, view, near,
                                           xlo, xhi, ylo, yhi, stamp, stamp_id,
                                           morph_scratch))
    elseif obj isa InstancedMesh && _instanced_line_drawable(obj)
        geo = _instanced_geometry(obj)
        if _line_geometry_has_segment(geo, obj.draw_mode)
            stamp_id = _draw_instanced_lines!(rt, obj, proj, view, near,
                                              xlo, xhi, ylo, yhi, stamp, stamp_id)
        end
    end
    for child in get_children(obj)
        _line_subtree_may_draw(child) || continue
        # Keep drawable children type-narrowed; abstract recursive calls allocate
        # in scenes with many primitive objects.
        if child isa LineObject || child isa LineSegments || child isa LineLoop ||
           child isa InstancedMesh
            stamp_id = _render_lines_visible_tree_cached!(rt, child, proj, view, near,
                                                          xlo, xhi, ylo, yhi, stamp,
                                                          stamp_id, morph_scratch)
        else
            stamp_id = _render_lines_visible_tree_cached!(rt, child, proj, view, near,
                                                          xlo, xhi, ylo, yhi, stamp,
                                                          stamp_id, morph_scratch)
        end
    end
    return stamp_id
end

function render_lines!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                       xlo::Int=1, xhi::Int=rt.width,
                       ylo::Int=1, yhi::Int=rt.height,
                       cache::Union{Nothing,RenderCache}=nothing)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    if cache === nothing
        _render_lines_visible_tree!(rt, scene, proj, view, near, xlo, xhi, ylo, yhi,
                                    cache, nothing, 0)
    else
        stamp = _render_cache_stamp!(cache, rt.height, rt.width)
        _render_lines_visible_tree_cached!(rt, scene, proj, view, near,
                                           xlo, xhi, ylo, yhi, stamp, 0,
                                           cache.morph_positions)
    end
    return rt
end

function _render_wireframe_mesh_cached!(rt::RenderTarget, geo::BufferGeometry, mat::AbstractMaterial,
                                        world::Mat4, proj::Mat4, view::Mat4, near,
                                        xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                        cache::Union{Nothing,RenderCache})
    _validate_triangle_geometry_indices(geo, "wireframe_geometry")
    col = hasfield(typeof(mat), :color) ? mat.color : Color3(1.0, 1.0, 1.0)
    alpha = clamp(Float64(material_opacity(mat)), 0.0, 1.0)
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    stamp = cache === nothing ? zeros(Int, rt.height, rt.width) :
            _render_cache_stamp!(cache, rt.height, rt.width)
    seen = cache === nothing ? Set{Tuple{Int,Int}}() : cache.wire_edges
    empty!(seen)
    stamp_id = 0
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        for (ia, ib) in ((i1, i2), (i2, i3), (i3, i1))
            key = ia < ib ? (ia, ib) : (ib, ia)
            key in seen && continue
            push!(seen, key)
            a = mat4_transform_point(world, get_vertex(geo, ia))
            b = mat4_transform_point(world, get_vertex(geo, ib))
            stamp_id += 1
            _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, 1.0,
                                        xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                        stamp, stamp_id)
        end
    end
    return nothing
end

function _render_wireframe_mesh!(rt::RenderTarget, geo::BufferGeometry, mat::AbstractMaterial,
                                 world::Mat4, proj::Mat4, view::Mat4, near;
                                 xlo::Int=1, xhi::Int=rt.width,
                                 ylo::Int=1, yhi::Int=rt.height,
                                 cache::Union{Nothing,RenderCache}=nothing)
    _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                   xlo, xhi, ylo, yhi, cache)
end

function _render_wireframe_mesh_from_mesh!(rt::RenderTarget, mesh::Mesh, world::Mat4,
                                           proj::Mat4, view::Mat4, near,
                                           xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                           cache::Union{Nothing,RenderCache})
    geo = _mesh_geometry(mesh)
    mat = mesh.material
    if mat isa MeshBasicMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshLambertMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshPhongMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshStandardMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshNormalMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshPhysicalMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshToonMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshMatcapMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa MeshDepthMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    elseif mat isa ShaderMaterial
        _render_wireframe_mesh_cached!(rt, geo, mat, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    else
        _render_wireframe_mesh_cached!(rt, geo, mat::AbstractMaterial, world, proj, view, near,
                                       xlo, xhi, ylo, yhi, cache)
    end
end

# ========================== Sprite rasterization ==========================

# Camera-facing quad corner: project local (lx,ly) on the sprite plane through
# the sprite's screen-aligned world matrix, returning screen x/y, ndc z, 1/w and
# the world position (for clipping). `ok=false` if behind the near plane.
@inline function _sprite_corner(M::Mat4, vp::Mat4, lx, ly, W, H)
    wp = mat4_transform_point(M, Vec3(lx, ly, 0.0))
    c = mat4_transform_vec4(vp, Vec4(wp.x, wp.y, wp.z, 1.0))
    c.w <= 1e-6 && return (0.0, 0.0, 0.0, 0.0, wp, false)
    iw = 1.0 / c.w
    ((c.x*iw + 1)*0.5*W, (1 - c.y*iw)*0.5*H, c.z*iw, iw, wp, true)
end

# Rasterize one sprite quad triangle with z-test, optional albedo/alpha textures
# (perspective-correct UV), tint colour, and world-space clipping planes.
@inline function _rasterize_sprite_tri!(rt::RenderTarget,
        s1x, s1y, z1, iw1, u1, v1, wp1::Vec3,
        s2x, s2y, z2, iw2, u2, v2, wp2::Vec3,
        s3x, s3y, z3, iw3, u3, v3, wp3::Vec3,
        tint::Color3, tex, clipping_planes,
        xlo::Int, xhi::Int, ylo::Int, yhi::Int,
        depth_test::Bool=true, depth_write::Bool=true,
        alpha::Float64=1.0,
        alpha_test::Float64=0.0,
        alpha_map=nothing,
        stamp=nothing, stamp_id::Int=0)
    W, H = rt.width, rt.height
    # Reject non-finite projected corners (no well-defined raster footprint).
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    (isfinite(area) && abs(area) >= 1e-10) || return nothing
    inv_area = 1.0 / area
    # Clamp the float screen-space extent into [1, W]/[1, H] BEFORE the Int
    # conversion so a finite-but-extreme corner cannot overflow floor/ceil(Int,…)
    # (InexactError) — matching the hardened mesh rasterizer _rasterize_tri!.
    fW = Float64(W); fH = Float64(H)
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int,  clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int,  clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    (min_x <= max_x && min_y <= max_y) || return nothing
    has_tex = tex !== nothing
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, Float64(alpha), tex, alpha_map)
    needs_uv = has_tex || has_alpha
    @inbounds for py in min_y:max_y
        for px in min_x:max_x
            cx = px - 0.5; cy = py - 0.5
            b0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            b1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            b2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            (b0 >= 0 && b1 >= 0 && b2 >= 0) || continue
            stamp !== nothing && stamp[py, px] == stamp_id && continue
            z = b0 * z1 + b1 * z2 + b2 * z3
            (!depth_test || z < rt.depth[py, px]) || continue
            a0 = b0; a1 = b1; a2 = b2
            if has_clip || needs_uv
                iw = b0*iw1 + b1*iw2 + b2*iw3
                a0 = b0*iw1/iw; a1 = b1*iw2/iw; a2 = b2*iw3/iw
                if has_clip
                    wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                              a0*wp1.y + a1*wp2.y + a2*wp3.y,
                              a0*wp1.z + a1*wp2.z + a2*wp3.z)
                    _clip_keep(clipping_planes, wp) || continue
                end
            end
            u = a0*u1 + a1*u2 + a2*u3
            v = a0*v1 + a1*v2 + a2*v3
            frag_alpha = alpha
            col = tint
            if has_tex
                col = col * sample_texture(tex, u, v)
            end
            if has_alpha
                frag_alpha = _fragment_alpha(Float64(alpha), tex, alpha_map, u, v, u, v)
                frag_alpha >= alpha_test || continue
            end
            col = clamp_color(col)
            depth_write && (rt.depth[py, px] = z)
            if frag_alpha >= 1.0
                rt.color[py, px, 1] = col.r; rt.color[py, px, 2] = col.g; rt.color[py, px, 3] = col.b
            elseif frag_alpha > 0.0
                ia = 1.0 - frag_alpha
                rt.color[py, px, 1] = col.r * frag_alpha + rt.color[py, px, 1] * ia
                rt.color[py, px, 2] = col.g * frag_alpha + rt.color[py, px, 2] * ia
                rt.color[py, px, 3] = col.b * frag_alpha + rt.color[py, px, 3] * ia
            end
            stamp !== nothing && (stamp[py, px] = stamp_id)
        end
    end
    return nothing
end

function _draw_sprite_object!(rt::RenderTarget, obj::Sprite, camera::AbstractCamera,
                              view::Mat4, vp::Mat4, W::Int, H::Int,
                              clipping_planes, xlo::Int, xhi::Int,
                              ylo::Int, yhi::Int,
                              cache::Union{Nothing,RenderCache},
                              state::_SpriteRenderState)
    mat = obj.material
    if mat isa SpriteMaterial
        return _draw_sprite_object_material!(rt, obj, mat::SpriteMaterial,
                                             camera, view, vp, W, H,
                                             clipping_planes, xlo, xhi, ylo, yhi,
                                             cache, state)
    end
    return _draw_sprite_object_material!(rt, obj, mat, camera, view, vp, W, H,
                                         clipping_planes, xlo, xhi, ylo, yhi,
                                         cache, state)
end

function _draw_sprite_object_material!(rt::RenderTarget, obj::Sprite, mat,
                                       camera::AbstractCamera, view::Mat4,
                                       vp::Mat4, W::Int, H::Int, clipping_planes,
                                       xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                       cache::Union{Nothing,RenderCache},
                                       state::_SpriteRenderState)
    state.stamp_id += 1
    stamp_id = state.stamp_id
    M = sprite_world_matrix(obj, camera)
    tint = _material_field(mat, :color)
    tint === nothing && (tint = Color3(1.0, 1.0, 1.0))
    alpha = clamp(Float64(material_opacity(mat)), 0.0, 1.0)
    tex = _material_field(mat, :map)
    alpha_test = material_alpha_test(mat)
    alpha_map = _material_field(mat, :alpha_map)
    rot = _material_field(mat, :rotation)
    rot === nothing && (rot = 0.0)
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    size_attenuation = _material_field(mat, :size_attenuation)
    size_attenuation === nothing && (size_attenuation = true)
    center_world = Vec3(mat4_get(M, 1, 4), mat4_get(M, 2, 4), mat4_get(M, 3, 4))
    center_view = mat4_transform_vec4(view, Vec4(center_world.x, center_world.y, center_world.z, 1.0))
    attenuation = size_attenuation ? 1.0 : max(0.0001, -center_view.z)
    c = cos(rot)
    sr = sin(rot)
    cx = obj.center.x
    cy = obj.center.y
    px0 = -cx;       py0 = -cy
    px1 = 1.0 - cx;  py1 = -cy
    px2 = 1.0 - cx;  py2 = 1.0 - cy
    px3 = -cx;       py3 = 1.0 - cy
    x0 = (c * px0 - sr * py0) * attenuation
    y0 = (sr * px0 + c * py0) * attenuation
    x1 = (c * px1 - sr * py1) * attenuation
    y1 = (sr * px1 + c * py1) * attenuation
    x2 = (c * px2 - sr * py2) * attenuation
    y2 = (sr * px2 + c * py2) * attenuation
    x3 = (c * px3 - sr * py3) * attenuation
    y3 = (sr * px3 + c * py3) * attenuation
    (s0x, s0y, z0, iw0, wp0, ok0) = _sprite_corner(M, vp, x0, y0, W, H)
    (s1x, s1y, z1, iw1, wp1, ok1) = _sprite_corner(M, vp, x1, y1, W, H)
    (s2x, s2y, z2, iw2, wp2, ok2) = _sprite_corner(M, vp, x2, y2, W, H)
    (s3x, s3y, z3, iw3, wp3, ok3) = _sprite_corner(M, vp, x3, y3, W, H)
    (ok0 && ok1 && ok2 && ok3) || return nothing
    stamp = state.stamp
    if stamp === nothing
        stamp = cache === nothing ? zeros(Int, H, W) : _render_cache_stamp!(cache, H, W)
        state.stamp = stamp
    end
    stamp_matrix = stamp::Matrix{Int}
    if tex isa Texture && alpha_map === nothing
        _draw_sprite_triangles!(rt, s0x, s0y, z0, iw0, wp0,
                                s1x, s1y, z1, iw1, wp1,
                                s2x, s2y, z2, iw2, wp2,
                                s3x, s3y, z3, iw3, wp3,
                                tint, tex, nothing, clipping_planes,
                                xlo, xhi, ylo, yhi, depth_test, depth_write,
                                alpha, alpha_test, stamp_matrix, stamp_id)
    elseif tex === nothing && alpha_map isa Texture
        _draw_sprite_triangles!(rt, s0x, s0y, z0, iw0, wp0,
                                s1x, s1y, z1, iw1, wp1,
                                s2x, s2y, z2, iw2, wp2,
                                s3x, s3y, z3, iw3, wp3,
                                tint, nothing, alpha_map, clipping_planes,
                                xlo, xhi, ylo, yhi, depth_test, depth_write,
                                alpha, alpha_test, stamp_matrix, stamp_id)
    elseif tex isa Texture && alpha_map isa Texture
        _draw_sprite_triangles!(rt, s0x, s0y, z0, iw0, wp0,
                                s1x, s1y, z1, iw1, wp1,
                                s2x, s2y, z2, iw2, wp2,
                                s3x, s3y, z3, iw3, wp3,
                                tint, tex, alpha_map, clipping_planes,
                                xlo, xhi, ylo, yhi, depth_test, depth_write,
                                alpha, alpha_test, stamp_matrix, stamp_id)
    elseif tex === nothing && alpha_map === nothing
        _draw_sprite_triangles!(rt, s0x, s0y, z0, iw0, wp0,
                                s1x, s1y, z1, iw1, wp1,
                                s2x, s2y, z2, iw2, wp2,
                                s3x, s3y, z3, iw3, wp3,
                                tint, nothing, nothing, clipping_planes,
                                xlo, xhi, ylo, yhi, depth_test, depth_write,
                                alpha, alpha_test, stamp_matrix, stamp_id)
    else
        _draw_sprite_triangles!(rt, s0x, s0y, z0, iw0, wp0,
                                s1x, s1y, z1, iw1, wp1,
                                s2x, s2y, z2, iw2, wp2,
                                s3x, s3y, z3, iw3, wp3,
                                tint, tex, alpha_map, clipping_planes,
                                xlo, xhi, ylo, yhi, depth_test, depth_write,
                                alpha, alpha_test, stamp_matrix, stamp_id)
    end
    return nothing
end

@inline function _draw_sprite_triangles!(rt::RenderTarget,
        s0x, s0y, z0, iw0, wp0::Vec3,
        s1x, s1y, z1, iw1, wp1::Vec3,
        s2x, s2y, z2, iw2, wp2::Vec3,
        s3x, s3y, z3, iw3, wp3::Vec3,
        tint::Color3, tex, alpha_map, clipping_planes,
        xlo::Int, xhi::Int, ylo::Int, yhi::Int,
        depth_test::Bool, depth_write::Bool,
        alpha::Float64, alpha_test::Float64,
        stamp::Matrix{Int}, stamp_id::Int)
    # Triangle (0,1,2): UVs (0,0),(1,0),(1,1).
    _rasterize_sprite_tri!(rt,
        s0x, s0y, z0, iw0, 0.0, 0.0, wp0,
        s1x, s1y, z1, iw1, 1.0, 0.0, wp1,
        s2x, s2y, z2, iw2, 1.0, 1.0, wp2,
        tint, tex, clipping_planes, xlo, xhi, ylo, yhi, depth_test, depth_write,
        alpha, alpha_test, alpha_map, stamp, stamp_id)
    # Triangle (0,2,3): UVs (0,0),(1,1),(0,1).
    _rasterize_sprite_tri!(rt,
        s0x, s0y, z0, iw0, 0.0, 0.0, wp0,
        s2x, s2y, z2, iw2, 1.0, 1.0, wp2,
        s3x, s3y, z3, iw3, 0.0, 1.0, wp3,
        tint, tex, clipping_planes, xlo, xhi, ylo, yhi, depth_test, depth_write,
        alpha, alpha_test, alpha_map, stamp, stamp_id)
    return nothing
end

@inline _sprite_subtree_may_draw(obj::AbstractObject3D) =
    is_visible(obj) && (_object_has_children(obj) || obj isa Sprite)

function _render_sprites_visible_tree!(rt::RenderTarget, obj::AbstractObject3D,
                                       camera::AbstractCamera, view::Mat4, vp::Mat4,
                                       W::Int, H::Int, clipping_planes,
                                       xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                       cache::Union{Nothing,RenderCache},
                                       state::_SpriteRenderState)
    is_visible(obj) || return nothing
    if obj isa Sprite
        _draw_sprite_object!(rt, obj, camera, view, vp, W, H,
                             clipping_planes, xlo, xhi, ylo, yhi,
                             cache, state)
    end
    _render_sprite_children!(rt, obj, camera, view, vp, W, H, clipping_planes,
                             xlo, xhi, ylo, yhi, cache, state)
    return nothing
end

function _render_sprites_visible_tree!(rt::RenderTarget, obj::Sprite,
                                       camera::AbstractCamera, view::Mat4, vp::Mat4,
                                       W::Int, H::Int, clipping_planes,
                                       xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                       cache::Union{Nothing,RenderCache},
                                       state::_SpriteRenderState)
    is_visible(obj) || return nothing
    _draw_sprite_object!(rt, obj, camera, view, vp, W, H,
                         clipping_planes, xlo, xhi, ylo, yhi, cache, state)
    _render_sprite_children!(rt, obj, camera, view, vp, W, H, clipping_planes,
                             xlo, xhi, ylo, yhi, cache, state)
    return nothing
end

function _render_sprite_children!(rt::RenderTarget, obj::AbstractObject3D,
                                  camera::AbstractCamera, view::Mat4, vp::Mat4,
                                  W::Int, H::Int, clipping_planes,
                                  xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                  cache::Union{Nothing,RenderCache},
                                  state::_SpriteRenderState)
    for child in get_children(obj)
        _sprite_subtree_may_draw(child) || continue
        if child isa Sprite
            _render_sprites_visible_tree!(rt, child::Sprite, camera, view, vp,
                                          W, H, clipping_planes,
                                          xlo, xhi, ylo, yhi,
                                          cache, state)
        else
            _render_sprites_visible_tree!(rt, child, camera, view, vp,
                                          W, H, clipping_planes,
                                          xlo, xhi, ylo, yhi,
                                          cache, state)
        end
    end
    return nothing
end

"""
    render_sprites!(rt, scene, camera; clipping_planes=Plane[])

Rasterize every visible [`Sprite`](@ref) under `scene` as a camera-facing
billboard. Each sprite is a unit quad oriented by [`sprite_world_matrix`](@ref)
so it squarely faces the camera, shifted by `Sprite.center`, scaled by the
sprite's scale, projected, and drawn depth-tested. `SpriteMaterial.rotation` is
applied in the billboard plane, and `SpriteMaterial.size_attenuation=false`
keeps approximate screen size under perspective projection. The sprite
material's `map` texture (if any) is sampled per pixel and modulated by its
`color` tint; `alpha_map`, map alpha, and `alpha_test` mask the same fragments
as other CPU-rasterized materials. Without a map the flat tint colour is used.
"""
function render_sprites!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                         clipping_planes=_NO_PLANES,
                         xlo::Int=1, xhi::Int=rt.width,
                         ylo::Int=1, yhi::Int=rt.height,
                         cache::Union{Nothing,RenderCache}=nothing)
    view = view_matrix(camera)
    vp = projection_matrix(camera) * view
    W, H = rt.width, rt.height
    state = cache === nothing ? _SpriteRenderState(nothing, 0) : cache.sprite_state
    state.stamp = nothing
    state.stamp_id = 0
    _render_sprites_visible_tree!(rt, scene, camera, view, vp, W, H, clipping_planes,
                                  xlo, xhi, ylo, yhi, cache, state)
    return rt
end

@inline _point_material_color(material, ::Color3) =
    hasfield(typeof(material), :color) ? getfield(material, :color) : Color3(1.0,1.0,1.0)
@inline _point_material_color(material::LineBasicMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::LineDashedMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::PointsMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::MeshBasicMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::MeshLambertMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::MeshPhongMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::MeshStandardMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)
@inline _point_material_color(material::MeshPhysicalMaterial, vc::Color3) =
    _is_identity_vertex_color(vc) ? material.color : _modulate(material.color, vc)

function _draw_points_geometry!(rt::RenderTarget, geo, material, wm::Mat4,
                                camera::AbstractCamera, proj::Mat4, view::Mat4,
                                near, W::Int, H::Int, xlo::Int, xhi::Int,
                                ylo::Int, yhi::Int, morphed_positions,
                                instance_color::Color3)
    col = _point_material_color(material, instance_color)
    alpha = clamp(Float64(material_opacity(material)), 0.0, 1.0)
    depth_test = material_depth_test(material)
    depth_write = material_depth_write(material)
    alpha_test = material_alpha_test(material)
    albedo_map = _material_field(material, :map)
    alpha_map = _material_field(material, :alpha_map)
    use_color_map = albedo_map isa Texture
    use_fragment_alpha = _needs_fragment_alpha(alpha_test, alpha, albedo_map, alpha_map)
    base_size = hasfield(typeof(material), :size) ? Float64(getfield(material, :size)) : 1.0
    size_attenuation = _material_field(material, :size_attenuation)
    size_attenuation === nothing && (size_attenuation = true)
    reference_depth = camera isa PerspectiveCamera ?
        max(norm(camera.position - camera.target), near) : 1.0
    for entry in _draw_entry_range(geo)
        vi = _draw_vertex_index(geo, entry)
        pv = mat4_transform_point(view, mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi)))
        pv.z <= -near || continue      # near-plane cull, matching the mesh path
        (px, py, pz, ok) = _project(proj, pv, W, H)
        ok || continue
        effective_size = base_size
        if size_attenuation && camera isa PerspectiveCamera
            effective_size *= reference_depth / max(1e-6, -pv.z)
        end
        r = max(Int(round(effective_size)) ÷ 2, 0)
        diameter = max(2r + 1, 1)
        # Skip a point whose footprint cannot touch the buffer; this also keeps
        # round(Int, ...) below from overflowing on finite extreme screen coords.
        (isfinite(px) && isfinite(py)) || continue
        (px + r < xlo || px - r > xhi || py + r < ylo || py - r > yhi) && continue
        cx = round(Int, px); cy = round(Int, py)
        min_px = max(cx - r, xlo)
        max_px = min(cx + r, xhi)
        min_py = max(cy - r, ylo)
        max_py = min(cy + r, yhi)
        for py in min_py:max_py, px in min_px:max_px
            u = clamp((px - (cx - r) + 0.5) / diameter, 0.0, 1.0)
            v = clamp(1.0 - (py - (cy - r) + 0.5) / diameter, 0.0, 1.0)
            frag_alpha = use_fragment_alpha ?
                _fragment_alpha(alpha, albedo_map, alpha_map, u, v, u, v) : alpha
            frag_alpha >= alpha_test || continue
            point_col = col
            if use_color_map
                tex_col = sample_texture_linear(albedo_map, u, v)
                point_col = Color3(col.r * tex_col.r, col.g * tex_col.g, col.b * tex_col.b)
            end
            _put_pixel!(rt, px, py, pz, point_col, xlo, xhi, ylo, yhi,
                        depth_test, depth_write, frag_alpha)
        end
    end
    return nothing
end

@inline function _draw_points_geometry_from_material!(rt::RenderTarget, geo::BufferGeometry,
                                                      material, wm::Mat4,
                                                      camera::AbstractCamera, proj::Mat4,
                                                      view::Mat4, near, W::Int, H::Int,
                                                      xlo::Int, xhi::Int, ylo::Int,
                                                      yhi::Int, morphed_positions,
                                                      instance_color::Color3)
    if material isa PointsMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    elseif material isa MeshBasicMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    elseif material isa MeshLambertMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    elseif material isa MeshPhongMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    elseif material isa MeshStandardMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    elseif material isa MeshPhysicalMaterial
        _draw_points_geometry!(rt, geo, material, wm, camera, proj, view, near,
                               W, H, xlo, xhi, ylo, yhi, morphed_positions,
                               instance_color)
    else
        _draw_points_geometry!(rt, geo, material::AbstractMaterial, wm, camera,
                               proj, view, near, W, H, xlo, xhi, ylo, yhi,
                               morphed_positions, instance_color)
    end
    return nothing
end

function _draw_points_object!(rt::RenderTarget, obj::PointsObject,
                              camera::AbstractCamera, proj::Mat4, view::Mat4,
                              near, W::Int, H::Int, xlo::Int, xhi::Int,
                              ylo::Int, yhi::Int,
                              morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    geo = _points_geometry(obj)
    _draw_points_geometry_from_material!(
        rt, geo, obj.material, compute_world_matrix(obj), camera, proj, view, near,
        W, H, xlo, xhi, ylo, yhi,
        _object_morph_positions(obj, geo, morph_scratch),
        Color3(1.0,1.0,1.0))
    return nothing
end

function _draw_instanced_points_geometry!(rt::RenderTarget, geo, material,
                                          instance_matrices::Vector{Mat4{Float64}},
                                          instance_colors::Vector{Color3{Float64}},
                                          base::Mat4, camera::AbstractCamera,
                                          proj::Mat4, view::Mat4, near,
                                          W::Int, H::Int, xlo::Int, xhi::Int,
                                          ylo::Int, yhi::Int)
    @inbounds for instance_index in eachindex(instance_matrices)
        _draw_points_geometry!(rt, geo, material, base * instance_matrices[instance_index],
                               camera, proj, view, near, W, H, xlo, xhi, ylo, yhi,
                               nothing, instance_colors[instance_index])
    end
    return nothing
end

function _draw_instanced_points!(rt::RenderTarget, obj::InstancedMesh,
                                 camera::AbstractCamera, proj::Mat4, view::Mat4,
                                 near, W::Int, H::Int, xlo::Int, xhi::Int,
                                 ylo::Int, yhi::Int)
    _draw_instanced_points_geometry!(rt, _instanced_geometry(obj), _instanced_material(obj),
                                     obj.instance_matrices, obj.instance_colors,
                                     compute_world_matrix(obj), camera, proj, view,
                                     near, W, H, xlo, xhi, ylo, yhi)
    return nothing
end

@inline _point_subtree_may_draw(obj::AbstractObject3D) =
    is_visible(obj) && (_object_has_children(obj) || obj isa PointsObject ||
                        (obj isa InstancedMesh && _instanced_point_drawable(obj)))

function _render_points_visible_tree!(rt::RenderTarget, obj::AbstractObject3D,
                                      camera::AbstractCamera, proj::Mat4, view::Mat4,
                                      near, W::Int, H::Int,
                                      xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                      morph_scratch::Union{Nothing,Vector{Vec3{Float64}}})
    is_visible(obj) || return nothing
    if obj isa PointsObject
        _draw_points_object!(rt, obj, camera, proj, view, near, W, H, xlo, xhi,
                             ylo, yhi, morph_scratch)
    elseif obj isa InstancedMesh && _instanced_point_drawable(obj)
        _draw_instanced_points!(rt, obj, camera, proj, view, near, W, H, xlo, xhi, ylo, yhi)
    end
    for child in get_children(obj)
        _point_subtree_may_draw(child) || continue
        # Keep drawable children type-narrowed; abstract recursive calls allocate
        # in scenes with many primitive objects.
        if child isa PointsObject || child isa InstancedMesh
            _render_points_visible_tree!(rt, child, camera, proj, view, near, W, H,
                                         xlo, xhi, ylo, yhi, morph_scratch)
        else
            _render_points_visible_tree!(rt, child, camera, proj, view, near, W, H,
                                         xlo, xhi, ylo, yhi, morph_scratch)
        end
    end
    return nothing
end

"""Rasterize `PointsObject` vertices as small point sprites sized by the material."""
function render_points!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                        xlo::Int=1, xhi::Int=rt.width,
                        ylo::Int=1, yhi::Int=rt.height,
                        cache::Union{Nothing,RenderCache}=nothing)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    W, H = rt.width, rt.height

    _render_points_visible_tree!(rt, scene, camera, proj, view, near, W, H,
                                 xlo, xhi, ylo, yhi,
                                 cache === nothing ? nothing : cache.morph_positions)
    return rt
end

# ========================== EffectComposer (post-processing) ==========================

mutable struct EffectComposer
    passes::Vector{Function}     # each maps an H×W×3 image to an H×W×3 image
end
EffectComposer() = EffectComposer(Function[])
add_pass!(c::EffectComposer, f::Function) = (push!(c.passes, f); c)

"""Run the image through every pass in order."""
function compose(c::EffectComposer, img::AbstractArray)
    out = img
    for p in c.passes
        out = p(out)
    end
    return out
end

# Built-in passes.
function grayscale_pass(img::AbstractArray)
    H, W = _rgb_image_size(img, "grayscale_pass")
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for i in 1:H, j in 1:W
        g = 0.299*img[i,j,1] + 0.587*img[i,j,2] + 0.114*img[i,j,3]
        out[i,j,1] = g; out[i,j,2] = g; out[i,j,3] = g
    end
    return out
end
reinhard_pass(img) = tone_map_reinhard(img)
aces_pass(img) = tone_map_aces(img)
srgb_pass(img) = srgb_encode(img)

# --------------------------------------------------------------------------
# Additional post-processing passes.
#
# Convention: every pass consumed by [`EffectComposer`] is a `Function` that maps
# an H×W×3 colour image to an H×W×3 image (see `compose`). The colour-only passes
# below (`bloom_pass`, `fxaa_pass`) match the built-ins exactly; they are factory
# functions that read keyword parameters and return such a mapping. The passes
# that need scene depth (`outline_pass`, `ssao_pass`, `bokeh_pass`) capture a
# depth buffer (the `H×W` `RenderTarget.depth`, smaller = nearer, `Inf` =
# background) and likewise return an `img -> img` mapping, so they slot into the
# composer identically. No G-buffer normal channel exists, so the SSAO pass
# reconstructs view-space normals from the depth gradient (documented below).
# --------------------------------------------------------------------------

# Rec.601 luma of an RGB pixel at (i,j) — shared by several passes.
@inline _luma(img, i, j) = @inbounds 0.299*img[i,j,1] + 0.587*img[i,j,2] + 0.114*img[i,j,3]

function _rgb_image_size(img::AbstractArray, label::AbstractString)
    (ndims(img) == 3 && size(img, 3) == 3) ||
        throw(ArgumentError("$label expects an H×W×3 image"))
    H, W = size(img, 1), size(img, 2)
    (H > 0 && W > 0) || throw(ArgumentError("$label image dimensions must be positive"))
    return H, W
end

function _check_depth_size(depth::AbstractMatrix, H::Int, W::Int, label::AbstractString)
    size(depth) == (H, W) || throw(ArgumentError("$label depth dimensions must match image"))
    return nothing
end

# Build a 1-D Gaussian kernel of the given integer radius (σ = radius/2, clamped),
# normalized to sum 1. Returned as an OffsetVector-free plain Vector indexed 1..2r+1
# (centre at r+1).
function _gaussian_kernel(radius::Int)
    r = max(radius, 0)
    σ = max(r / 2, 1e-3)
    k = Vector{Float64}(undef, 2r + 1)
    s = 0.0
    @inbounds for t in -r:r
        w = exp(-(t*t) / (2σ*σ)); k[t + r + 1] = w; s += w
    end
    inv = 1.0 / s
    @inbounds for t in eachindex(k); k[t] *= inv; end
    return k
end

# Separable Gaussian blur of an H×W×3 image with the given radius. Edges are
# handled by clamping the sample index (replicate border). Uses one scratch
# buffer for the horizontal pass, then writes the vertical pass into `out`.
function _blur_separable(img::AbstractArray, radius::Int)
    H, W = _rgb_image_size(img, "blur")
    r = max(radius, 0)
    r == 0 && return Float64.(img)
    k = _gaussian_kernel(r)
    tmp = Array{Float64}(undef, H, W, 3)
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for c in 1:3, i in 1:H, j in 1:W           # horizontal
        acc = 0.0
        for t in -r:r
            jj = clamp(j + t, 1, W)
            acc += k[t + r + 1] * img[i, jj, c]
        end
        tmp[i, j, c] = acc
    end
    @inbounds for c in 1:3, i in 1:H, j in 1:W           # vertical
        acc = 0.0
        for t in -r:r
            ii = clamp(i + t, 1, H)
            acc += k[t + r + 1] * tmp[ii, j, c]
        end
        out[i, j, c] = acc
    end
    return out
end

"""
    bloom_pass(; threshold=0.8, intensity=0.6, radius=2)

Bloom post-process. Extracts a bright-pass image (pixels whose Rec.601 luma
exceeds `threshold`, keeping their colour), blurs it with a separable Gaussian of
the given pixel `radius`, and adds the blurred glow back to the original image
scaled by `intensity`. Returns a new H×W×3 image; the input is not mutated. The
returned closure matches the [`EffectComposer`] pass convention (`img -> img`).
"""
function bloom_pass(; threshold::Real=0.8, intensity::Real=0.6, radius::Int=2)
    thr = Float64(threshold); inten = Float64(intensity); rad = max(Int(radius), 0)
    return function (img::AbstractArray)
        H, W = _rgb_image_size(img, "bloom_pass")
        bright = Array{Float64}(undef, H, W, 3)        # bright-pass extraction
        @inbounds for i in 1:H, j in 1:W
            if _luma(img, i, j) > thr
                bright[i,j,1] = img[i,j,1]; bright[i,j,2] = img[i,j,2]; bright[i,j,3] = img[i,j,3]
            else
                bright[i,j,1] = 0.0; bright[i,j,2] = 0.0; bright[i,j,3] = 0.0
            end
        end
        glow = _blur_separable(bright, rad)
        out = Array{Float64}(undef, H, W, 3)
        @inbounds for idx in eachindex(out)
            out[idx] = img[idx] + inten * glow[idx]
        end
        return out
    end
end

"""
    fxaa_pass()

Compact luma-based anti-aliasing (FXAA-style). For each pixel the Rec.601 luma of
the 4-neighbourhood is measured; where the local luma contrast (max − min)
exceeds an internal threshold, the pixel is blended toward its neighbours along
the dominant edge direction (horizontal or vertical, whichever has the larger
gradient). Colour-only: the depth buffer is not used. Returns a new H×W×3 image.
The returned closure matches the [`EffectComposer`] pass convention.
"""
function fxaa_pass()
    # Edge thresholds follow the original FXAA quality presets (relative + absolute).
    EDGE_MIN = 0.0312     # absolute luma floor below which no AA is applied
    EDGE_REL = 0.125      # contrast must exceed this fraction of the local max luma
    return function (img::AbstractArray)
        H, W = _rgb_image_size(img, "fxaa_pass")
        out = Float64.(img)
        @inbounds for i in 2:H-1, j in 2:W-1
            lC = _luma(img, i, j)
            lN = _luma(img, i-1, j); lS = _luma(img, i+1, j)
            lW = _luma(img, i, j-1); lE = _luma(img, i, j+1)
            lmax = max(lC, lN, lS, lW, lE)
            lmin = min(lC, lN, lS, lW, lE)
            contrast = lmax - lmin
            (contrast < max(EDGE_MIN, EDGE_REL*lmax)) && continue
            # Dominant edge direction: vertical gradient vs horizontal gradient.
            gv = abs(lN - lS); gh = abs(lW - lE)
            if gv >= gh
                # Edge is horizontal-ish → blend vertically (with N and S).
                for c in 1:3
                    out[i,j,c] = 0.5*img[i,j,c] + 0.25*img[i-1,j,c] + 0.25*img[i+1,j,c]
                end
            else
                # Edge is vertical-ish → blend horizontally (with W and E).
                for c in 1:3
                    out[i,j,c] = 0.5*img[i,j,c] + 0.25*img[i,j-1,c] + 0.25*img[i,j+1,c]
                end
            end
        end
        return out
    end
end

"""
    outline_pass(depth; threshold=0.1, color=Color3(0,0,0))

Edge outlining from the depth buffer. A Sobel gradient magnitude is computed on
the supplied `depth` matrix (the `H×W` `RenderTarget.depth`; smaller = nearer,
`Inf` = background). Wherever the normalized depth-gradient magnitude exceeds
`threshold`, the output pixel is set to `color`; elsewhere the original colour is
kept. Background/foreground silhouettes (finite↔`Inf` transitions) always count
as edges. Returns a new H×W×3 image. The returned closure matches the
[`EffectComposer`] pass convention; the depth buffer is captured here because the
composer only forwards the colour image.

The depth matrix is captured at construction time, so the returned pass can be
applied to any colour image of the matching size.
"""
function outline_pass(depth::AbstractMatrix; threshold::Real=0.1, color::Color3=Color3(0.0,0.0,0.0))
    thr = Float64(threshold)
    oc = (Float64(color.r), Float64(color.g), Float64(color.b))
    # Map a raw depth to a bounded finite value so Sobel differences are well
    # defined at silhouettes: Inf (background) → a large sentinel beyond any face.
    @inline function dval(d)
        isfinite(d) ? Float64(d) : 1.0e9
    end
    return function (img::AbstractArray)
        H, W = _rgb_image_size(img, "outline_pass")
        _check_depth_size(depth, H, W, "outline_pass")
        out = Float64.(img)
        (H >= 3 && W >= 3) || return out
        # Normalize the gradient by the finite depth range so `threshold` is scale-free.
        dmin = Inf; dmax = -Inf
        @inbounds for i in 1:H, j in 1:W
            d = depth[i,j]
            if isfinite(d)
                d < dmin && (dmin = d); d > dmax && (dmax = d)
            end
        end
        span = (isfinite(dmin) && dmax > dmin) ? (dmax - dmin) : 1.0
        invspan = 1.0 / span
        @inbounds for i in 2:H-1, j in 2:W-1
            d11 = dval(depth[i-1,j-1]); d12 = dval(depth[i-1,j]); d13 = dval(depth[i-1,j+1])
            d21 = dval(depth[i  ,j-1]);                            d23 = dval(depth[i  ,j+1])
            d31 = dval(depth[i+1,j-1]); d32 = dval(depth[i+1,j]); d33 = dval(depth[i+1,j+1])
            gx = (d13 + 2*d23 + d33) - (d11 + 2*d21 + d31)
            gy = (d31 + 2*d32 + d33) - (d11 + 2*d12 + d13)
            mag = sqrt(gx*gx + gy*gy) * 0.25 * invspan
            if mag > thr
                out[i,j,1] = oc[1]; out[i,j,2] = oc[2]; out[i,j,3] = oc[3]
            end
        end
        return out
    end
end

"""
    ssao_pass(depth; radius=1.0, intensity=1.0, samples=8)

Screen-space ambient occlusion derived from the depth buffer alone (no G-buffer
normal channel exists in this rasterizer). For each foreground pixel the
view-space normal is reconstructed from the local depth gradient (finite
differences of `depth`, treated as a height field), then `samples` neighbours are
probed on the image-plane circle of the given pixel `radius`. A neighbour
contributes occlusion when it is nearer than the centre by more than a small bias
and lies in front of the reconstructed surface plane (its depth delta projects
onto the normal). The accumulated occlusion darkens the pixel by up to
`intensity`. Background pixels (`Inf` depth) are left unchanged. Returns a new
H×W×3 image. The returned closure matches the [`EffectComposer`] pass convention;
the depth buffer is captured here because the composer only forwards colour.
"""
function ssao_pass(depth::AbstractMatrix; radius::Real=1.0, intensity::Real=1.0, samples::Int=8)
    # Bound the radius to a finite sane range so round(Int, rad*…) below can't
    # overflow on a NaN/Inf/huge radius (1e6 px exceeds any real SSAO kernel).
    r0 = Float64(radius)
    rad = isnan(r0) ? 1e-3 : clamp(r0, 1e-3, 1e6)
    inten = clamp(Float64(intensity), 0.0, 1.0)
    ns = max(Int(samples), 1)
    bias = 1e-4
    # Precompute fixed hemisphere sample offsets on the image-plane circle (in
    # pixels), distributed by angle with mild radial jitter for coverage. Fixed
    # (deterministic) so the pass is reproducible.
    offs = Vector{NTuple{2,Float64}}(undef, ns)
    @inbounds for s in 1:ns
        θ = 2π * (s - 1) / ns
        rr = rad * (0.4 + 0.6 * (s / ns))      # spread samples over the radius
        offs[s] = (rr*cos(θ), rr*sin(θ))
    end
    return function (img::AbstractArray)
        H, W = _rgb_image_size(img, "ssao_pass")
        _check_depth_size(depth, H, W, "ssao_pass")
        out = Float64.(img)
        (H >= 3 && W >= 3) || return out
        @inline df(i, j) = (d = depth[clamp(i,1,H), clamp(j,1,W)]; isfinite(d) ? Float64(d) : NaN)
        @inbounds for i in 2:H-1, j in 2:W-1
            dC = depth[i,j]
            isfinite(dC) || continue
            dc = Float64(dC)
            # Reconstruct a view-space normal from the depth height field. The
            # surface (x=col, y=row, z=depth) has tangents (1,0,dz/dx),(0,1,dz/dy);
            # their cross product gives (-dz/dx, -dz/dy, 1) (smaller depth = nearer).
            dzx = df(i, j+1); isnan(dzx) && (dzx = dc); dzx -= dc
            dzy = df(i+1, j); isnan(dzy) && (dzy = dc); dzy -= dc
            nx = -dzx; ny = -dzy; nz = 1.0
            ninv = 1.0 / sqrt(nx*nx + ny*ny + nz*nz)
            nx *= ninv; ny *= ninv; nz *= ninv
            occ = 0.0
            cnt = 0
            for s in 1:ns
                (ox, oy) = offs[s]
                si = i + round(Int, oy); sj = j + round(Int, ox)
                dN = df(si, sj)
                isnan(dN) && continue          # background neighbour: no occlusion
                cnt += 1
                Δ = dc - dN                    # >0 when neighbour is nearer (occluder)
                if Δ > bias
                    # Project the (image-plane offset, depth delta) onto the normal:
                    # only count occluders sitting above the surface plane. Uses the
                    # rounded offsets actually sampled so flat tilted surfaces
                    # (dN = dc + dzx*oxr + dzy*oyr) contribute exactly zero.
                    oxr = sj - j; oyr = si - i
                    proj = nz*Δ - (nx*oxr + ny*oyr)
                    if proj > bias
                        # Range check: distant depth gaps shouldn't over-darken.
                        rcheck = rad / (rad + Δ)
                        occ += rcheck
                    end
                end
            end
            cnt == 0 && continue
            ao = 1.0 - inten * (occ / cnt)
            ao = clamp(ao, 0.0, 1.0)
            out[i,j,1] = img[i,j,1]*ao; out[i,j,2] = img[i,j,2]*ao; out[i,j,3] = img[i,j,3]*ao
        end
        return out
    end
end

"""
    bokeh_pass(depth; focus_depth, aperture=0.02)
    bokeh_pass(; focus_depth, aperture=0.02, depth)

Depth-of-field (bokeh) blur driven by the depth buffer. Each pixel's circle of
confusion radius is `|depth - focus_depth| * aperture` (in pixels, rounded and
capped), so geometry near `focus_depth` stays sharp while out-of-focus regions
are box-blurred over their circle of confusion. Background pixels (`Inf` depth)
are treated as maximally defocused at the cap. Returns a new H×W×3 image. The
returned closure matches the [`EffectComposer`] pass convention; the depth buffer
is captured here because the composer only forwards the colour image.

`focus_depth` is required (the in-focus depth plane, in the same units as the
depth buffer). This is a scatter-as-gather approximation: each output pixel
averages a disc sized by its own circle of confusion. It does not model true lens
occlusion or partial-occlusion bleeding, which a CPU gather DoF cannot represent
exactly.
"""
function bokeh_pass(; focus_depth::Real, aperture::Real=0.02, depth::AbstractMatrix)
    fd = Float64(focus_depth); ap = max(Float64(aperture), 0.0)
    maxr = 16                                  # cap CoC radius to bound work
    return function (img::AbstractArray)
        H, W = _rgb_image_size(img, "bokeh_pass")
        _check_depth_size(depth, H, W, "bokeh_pass")
        out = Array{Float64}(undef, H, W, 3)
        @inbounds for i in 1:H, j in 1:W
            dC = depth[i,j]
            coc = isfinite(dC) ? abs(Float64(dC) - fd) * ap : Float64(maxr)
            # Clamp the float CoC into [0, maxr] BEFORE the Int conversion: a large
            # finite coc (extreme depth or aperture) would overflow round(Int, …).
            r = round(Int, clamp(coc, 0.0, Float64(maxr)))
            if r <= 0
                out[i,j,1] = img[i,j,1]; out[i,j,2] = img[i,j,2]; out[i,j,3] = img[i,j,3]
                continue
            end
            r2 = r * r
            sr = 0.0; sg = 0.0; sb = 0.0; wsum = 0.0
            for dy in -r:r, dx in -r:r
                (dx*dx + dy*dy) <= r2 || continue   # disc-shaped circle of confusion
                ii = clamp(i + dy, 1, H); jj = clamp(j + dx, 1, W)
                sr += img[ii,jj,1]; sg += img[ii,jj,2]; sb += img[ii,jj,3]; wsum += 1.0
            end
            iw = 1.0 / wsum
            out[i,j,1] = sr*iw; out[i,j,2] = sg*iw; out[i,j,3] = sb*iw
        end
        return out
    end
end
# Positional-depth convenience form, matching `outline_pass`/`ssao_pass`.
bokeh_pass(depth::AbstractMatrix; focus_depth::Real, aperture::Real=0.02) =
    bokeh_pass(; focus_depth=focus_depth, aperture=aperture, depth=depth)

# ========================== Tiled / parallel rasterization ==========================

function _render_tiled_band!(rt::RenderTarget, meshes::Vector{Mesh},
                             instanced::Vector{InstancedMesh}, instanced_material_states,
                             lights,
                             camera::AbstractCamera, proj::Mat4, view::Mat4,
                             near, ortho_dir, thread_caches::Vector{RenderCache},
                             thread_count::Int, ylo::Int, yhi::Int)
    ylo > yhi && return nothing
    cache_idx = mod1(Threads.threadid() - 1, thread_count)
    thread_cache = thread_caches[cache_idx]
    tri = thread_cache.tri
    clipped = thread_cache.clipped
    empty!(clipped)
    sx = thread_cache.sx
    sy = thread_cache.sy
    sz = thread_cache.sz
    colorbuf = thread_cache.colors
    for mesh in meshes
        is_visible(mesh) || continue
        mat = _mesh_material(mesh)
        is_transparent_material(mat) && continue
        _rasterize_flat_mesh_pooled_from_mesh!(rt, mesh, compute_world_matrix(mesh),
                                               lights, proj, view, near, camera.position,
                                               tri, clipped, sx, sy, sz, colorbuf,
                                               1, rt.width, ylo, yhi, ortho_dir)
    end
    for (instanced_slot, im) in pairs(instanced)
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        base = compute_world_matrix(im)
        instance_materials = instanced_material_states[instanced_slot].materials
        _rasterize_instanced_geo_flat_pooled_materials!(
            rt, _instanced_geometry(im), instance_materials, im.instance_matrices,
            base, lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz,
            colorbuf, ortho_dir; ylo=ylo, yhi=yhi)
    end
    return nothing
end

"""
    render_tiled!(rt, scene, camera; tiles=Threads.nthreads(), shading=:flat, cache=nothing)

Flat-rasterize the scene in horizontal row bands. Bands write disjoint rows, so
they can run on separate threads (used when Julia is started with > 1 thread).
Produces the same image as [`render!`] for opaque flat scenes.

Passing a `cache` vector reuses per-thread scratch buffers across repeated calls.
Each thread uses one cache entry, so the vector must have at least as many
entries as active worker threads used by this invocation.
"""
function render_tiled!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                       tiles::Int=max(Threads.nthreads(), 1), shading::Symbol=:flat,
                       cache::Union{Nothing, Vector{RenderCache}}=nothing)
    shading === :flat || throw(ArgumentError("render_tiled! supports only :flat shading"))
    tiles > 0 || throw(ArgumentError("render_tiled! tiles must be positive"))
    clear!(rt, scene.background)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    # Same orthographic back-face-culling direction as `render!`.
    ortho_dir = camera isa OrthographicCamera ?
        normalize(camera.position - camera.target) : nothing
    H = rt.height
    thread_count = Threads.nthreads()
    thread_caches = if cache === nothing
        [RenderCache() for _ in 1:thread_count]
    else
        length(cache) >= thread_count ||
            throw(ArgumentError("render_tiled! cache must have at least $(thread_count) entries"))
        cache
    end

    # Reuse scene collection buffers on the shared cache entry so repeated calls do
    # not reallocate mesh/light/instance vectors.
    shared_cache = thread_caches[1]
    meshes = shared_cache.meshes
    _collect_meshes_into!(meshes, scene)
    _append_skinned_render_meshes!(meshes, scene, shared_cache.skinned, shared_cache.skinned_meshes,
                                   shared_cache.skinned_matrices,
                                   shared_cache.morph_positions)
    lights = shared_cache.lights
    _collect_lights_into!(lights, scene)
    instanced = shared_cache.instanced
    _collect_instanced_into!(instanced, scene)
    instanced_material_states = shared_cache.instanced_materials
    for (instanced_slot, im) in pairs(instanced)
        (_visible_in_tree(im) && _instanced_triangle_drawable(im)) || continue
        _instanced_materials!(instanced_material_states, instanced_slot, im,
                              _instanced_material(im), im.instance_colors)
    end
    band = cld(H, tiles)
    if thread_count == 1
        for t in 1:tiles
            ylo = (t - 1) * band + 1
            yhi = min(t * band, H)
            _render_tiled_band!(rt, meshes, instanced, instanced_material_states,
                                lights, camera, proj, view,
                                near, ortho_dir, thread_caches, thread_count, ylo, yhi)
        end
    else
        Threads.@threads for t in 1:tiles
            ylo = (t - 1) * band + 1
            yhi = min(t * band, H)
            _render_tiled_band!(rt, meshes, instanced, instanced_material_states,
                                lights, camera, proj, view,
                                near, ortho_dir, thread_caches, thread_count, ylo, yhi)
        end
    end
    return rt
end

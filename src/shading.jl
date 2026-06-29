# --------------------------------------------------------------------------
# Shading models: Phong, Lambert, PBR (simplified Cook-Torrance).
# Pure Julia, AD-compatible — no branching on types in hot path.
# --------------------------------------------------------------------------

# Blinn-Phong half-vector, guarded against the antiparallel case light_dir = -view_dir
# where light_dir + view_dir is the zero vector and normalize would divide by zero
# (producing NaN). In that degenerate configuration every lobe that uses the half
# vector is gated to zero by N·L or N·H, so any finite unit vector is a safe fallback.
@inline function _half_vec(light_dir::Vec3, view_dir::Vec3)
    s = light_dir + view_dir
    n = norm(s)
    n > 1e-12 ? s / n : view_dir
end

"""
Compute Lambertian diffuse contribution for one light.
Returns Color3 — the diffuse color modulated by light.
"""
function shade_lambert(normal::Vec3, light_dir::Vec3, light_color::Color3,
                       light_intensity, surface_color::Color3)
    ndotl = max(dot(normal, light_dir), zero(light_intensity))
    surface_color * light_color * (ndotl * light_intensity)
end

"""
Blinn-Phong shading: diffuse + specular.
`view_dir` points from surface toward camera.
"""
function shade_phong(normal::Vec3, light_dir::Vec3, view_dir::Vec3,
                     light_color::Color3, light_intensity,
                     diffuse_color::Color3, specular_color::Color3,
                     shininess)
    # Diffuse
    ndotl = max(dot(normal, light_dir), zero(light_intensity))
    diffuse = diffuse_color * light_color * (ndotl * light_intensity)

    # Specular (Blinn-Phong half-vector). Mask the lobe by N·L so a light behind
    # the surface (N·L≤0, but N·H can still be >0) produces no specular leak.
    half_vec = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, half_vec), zero(shininess))
    spec_mask = ndotl > zero(ndotl) ? one(light_intensity) : zero(light_intensity)
    spec = specular_color * light_color * (ndoth^shininess * light_intensity * spec_mask)

    diffuse + spec
end

"""
Simplified PBR shading (Cook-Torrance with GGX distribution).
"""
function shade_pbr(normal::Vec3, light_dir::Vec3, view_dir::Vec3,
                   light_color::Color3, light_intensity,
                   albedo::Color3, metalness, roughness,
                   specular_intensity=1.0,
                   specular_color::Color3=Color3(1.0, 1.0, 1.0))
    α = roughness * roughness
    α2 = α * α

    ndotl = max(dot(normal, light_dir), zero(α))
    ndotv = max(dot(normal, view_dir), zero(α))

    h = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, h), zero(α))
    vdoth = max(dot(view_dir, h), zero(α))

    # GGX/Trowbridge-Reitz normal distribution
    denom_d = ndoth * ndoth * (α2 - 1) + 1
    D = α2 / (π * denom_d * denom_d + 1e-7)

    # Schlick-GGX geometry (Smith model)
    k = (roughness + 1)^2 / 8
    G1_l = ndotl / (ndotl * (1 - k) + k + 1e-7)
    G1_v = ndotv / (ndotv * (1 - k) + k + 1e-7)
    G = G1_l * G1_v

    # Schlick Fresnel. KHR_materials_specular modulates only the dielectric F0;
    # metals continue to use base-color F0.
    F0 = Color3(
        lerp_scalar(0.04 * specular_intensity * specular_color.r, albedo.r, metalness),
        lerp_scalar(0.04 * specular_intensity * specular_color.g, albedo.g, metalness),
        lerp_scalar(0.04 * specular_intensity * specular_color.b, albedo.b, metalness)
    )
    F = Color3(
        F0.r + (1 - F0.r) * (1 - vdoth)^5,
        F0.g + (1 - F0.g) * (1 - vdoth)^5,
        F0.b + (1 - F0.b) * (1 - vdoth)^5
    )

    # Specular BRDF
    spec_num = D * G
    spec_den = 4 * ndotv * ndotl + 1e-7
    spec = Color3(
        F.r * spec_num / spec_den,
        F.g * spec_num / spec_den,
        F.b * spec_num / spec_den
    )

    # Diffuse BRDF (energy-conserving Lambert)
    kD = Color3(
        (1 - F.r) * (1 - metalness),
        (1 - F.g) * (1 - metalness),
        (1 - F.b) * (1 - metalness)
    )
    diffuse = Color3(
        kD.r * albedo.r / π,
        kD.g * albedo.g / π,
        kD.b * albedo.b / π
    )

    # Final
    result = Color3(
        (diffuse.r + spec.r) * light_color.r * light_intensity * ndotl,
        (diffuse.g + spec.g) * light_color.g * light_intensity * ndotl,
        (diffuse.b + spec.b) * light_color.b * light_intensity * ndotl
    )
    return result
end

lerp_scalar(a, b, t) = a + (b - a) * t

"""
Compute per-face shading for a mesh given scene lights and camera.
Returns Vector{Color3} with one color per face.
"""
# Flat-shading face normal: average of the authored per-vertex normals
# transformed to world space, so orientation follows the geometry's normals
# rather than its (possibly inconsistent) triangle winding. Falls back to the
# geometric winding normal when authored normals are absent or degenerate
# (e.g. a freshly loaded mesh before `compute_vertex_normals!`).
@inline function _flat_face_normal(geo::BufferGeometry, i1, i2, i3,
                                   v1::Vec3, v2::Vec3, v3::Vec3,
                                   normal_mat::Mat4, has_normals::Bool)
    geo_n = cross(v2 - v1, v3 - v1)
    if has_normals
        n = mat4_transform_direction(normal_mat, get_normal(geo, i1)) +
            mat4_transform_direction(normal_mat, get_normal(geo, i2)) +
            mat4_transform_direction(normal_mat, get_normal(geo, i3))
        nl = norm(n)
        nl > 1e-12 && return n / nl
    end
    gl = norm(geo_n)
    return gl > 1e-12 ? geo_n / gl : Vec3(0.0, 0.0, 1.0)
end

# Optional material texture field (nothing if the material has no such map).
@inline _material_field(m, f::Symbol) = hasfield(typeof(m), f) ? getfield(m, f) : nothing
@inline _material_scalar(m, f::Symbol, default::Float64=1.0) =
    hasfield(typeof(m), f) ? Float64(getfield(m, f)) : default

# Centroid UV of a face (average of its three vertex UVs).
@inline function _face_centroid_uv(geo::BufferGeometry, i1, i2, i3)
    b1 = (i1-1)*2; b2 = (i2-1)*2; b3 = (i3-1)*2
    ((geo.uvs[b1+1] + geo.uvs[b2+1] + geo.uvs[b3+1]) / 3,
     (geo.uvs[b1+2] + geo.uvs[b2+2] + geo.uvs[b3+2]) / 3)
end

@inline _vertex_uv(geo::BufferGeometry, i) = (geo.uvs[(i-1)*2+1], geo.uvs[(i-1)*2+2])

@inline function _uv2_attribute(geo::BufferGeometry)
    has_attribute(geo, :uv2) || return nothing
    attr = get_attribute(geo, :uv2)
    attr.item_size >= 2 && length(attr.data) >= geo.n_vertices * attr.item_size ? attr : nothing
end

@inline function _face_centroid_uv_attr(attr::BufferAttribute, i1, i2, i3)
    s = attr.item_size
    b1 = (i1-1)*s; b2 = (i2-1)*s; b3 = (i3-1)*s
    d = attr.data
    ((d[b1+1] + d[b2+1] + d[b3+1]) / 3,
     (d[b1+2] + d[b2+2] + d[b3+2]) / 3)
end

@inline function _vertex_uv_attr(attr::BufferAttribute, i)
    b = (i - 1) * attr.item_size
    (attr.data[b + 1], attr.data[b + 2])
end

@inline _texture_uv_set(tex) = tex isa Texture ? tex.tex_coord : 0
@inline _map_uv(tex, u, v, u2, v2; default_uv2::Bool=false) =
    (_texture_uv_set(tex) == 1 || (default_uv2 && _texture_uv_set(tex) == 0)) ? (u2, v2) : (u, v)

@inline function _pack_depth_rgba(depth::Float64)
    v = clamp(depth, 0.0, 1.0)
    v <= 0.0 && return (0.0, 0.0, 0.0, 0.0)
    v >= 1.0 && return (1.0, 1.0, 1.0, 1.0)
    vuf = floor(v * 16777216.0)
    af = v * 16777216.0 - vuf
    next = vuf / 256.0
    vuf = floor(next)
    bf = next - vuf
    next = vuf / 256.0
    vuf = floor(next)
    gf = next - vuf
    return (vuf / 255.0, gf * (256.0 / 255.0), bf * (256.0 / 255.0), af)
end

@inline function _pack_depth_rgb(depth::Float64)
    v = clamp(depth, 0.0, 1.0)
    v <= 0.0 && return (0.0, 0.0, 0.0)
    v >= 1.0 && return (1.0, 1.0, 1.0)
    vuf = floor(v * 65536.0)
    bf = v * 65536.0 - vuf
    next = vuf / 256.0
    vuf = floor(next)
    gf = next - vuf
    return (vuf / 255.0, gf * (256.0 / 255.0), bf)
end

@inline function _pack_depth_rg(depth::Float64)
    v = clamp(depth, 0.0, 1.0)
    v <= 0.0 && return (0.0, 0.0)
    v >= 1.0 && return (1.0, 1.0)
    vuf = floor(v * 256.0)
    gf = v * 256.0 - vuf
    return (vuf / 255.0, gf)
end

@inline function _depth_material_color(material::MeshDepthMaterial, depth::Float64)
    d = clamp(depth, 0.0, 1.0)
    if material.depth_packing === :rgba
        r, g, b, _ = _pack_depth_rgba(d)
        return Color3(r, g, b)
    elseif material.depth_packing === :rgb
        r, g, b = _pack_depth_rgb(d)
        return Color3(r, g, b)
    elseif material.depth_packing === :rg
        r, g = _pack_depth_rg(d)
        return Color3(r, g, 0.0)
    end
    g = 1.0 - d
    return Color3(g, g, g)
end

# Material opt-in for per-vertex color modulation (three.js `vertexColors`).
@inline _wants_vertex_colors(m) = hasfield(typeof(m), :vertex_colors) && getfield(m, :vertex_colors)

@inline _modulate(c::Color3, v::Color3) = Color3(c.r * v.r, c.g * v.g, c.b * v.b)
@inline _is_identity_vertex_color(vc::Color3) = vc.r == 1.0 && vc.g == 1.0 && vc.b == 1.0
@inline _with_vertex_color(m::AbstractMaterial, vc::Color3) = m
function _with_vertex_color(m::LineBasicMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    LineBasicMaterial(color=_modulate(m.color, vc), linewidth=m.linewidth,
                      opacity=m.opacity, depth_test=m.depth_test,
                      depth_write=m.depth_write)
end
function _with_vertex_color(m::LineDashedMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    LineDashedMaterial(color=_modulate(m.color, vc), linewidth=m.linewidth,
                       scale=m.scale, dash_size=m.dash_size,
                       gap_size=m.gap_size, opacity=m.opacity,
                       depth_test=m.depth_test, depth_write=m.depth_write)
end
function _with_vertex_color(m::PointsMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    PointsMaterial(color=_modulate(m.color, vc), size=m.size, opacity=m.opacity,
                   transparent=m.transparent, map=m.map, alpha_map=m.alpha_map,
                   alpha_test=m.alpha_test, size_attenuation=m.size_attenuation,
                   depth_test=m.depth_test, depth_write=m.depth_write)
end
function _with_vertex_color(m::MeshBasicMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    MeshBasicMaterial(color=_modulate(m.color, vc), opacity=m.opacity,
                      transparent=m.transparent, wireframe=m.wireframe,
                      side=m.side, map=m.map, alpha_map=m.alpha_map,
                      ao_map=m.ao_map, light_map=m.light_map,
                      ao_map_intensity=m.ao_map_intensity,
                      light_map_intensity=m.light_map_intensity,
                      vertex_colors=m.vertex_colors,
                      alpha_test=m.alpha_test, depth_test=m.depth_test,
                      depth_write=m.depth_write,
                      clipping_planes=m.clipping_planes)
end
function _with_vertex_color(m::MeshLambertMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    MeshLambertMaterial(color=_modulate(m.color, vc), emissive=m.emissive,
                        opacity=m.opacity, transparent=m.transparent,
                        wireframe=m.wireframe, side=m.side,
                        map=m.map, normal_map=m.normal_map,
                        normal_scale=m.normal_scale,
                        alpha_map=m.alpha_map, ao_map=m.ao_map,
                        emissive_map=m.emissive_map,
                        emissive_intensity=m.emissive_intensity,
                        ao_map_intensity=m.ao_map_intensity,
                        light_map_intensity=m.light_map_intensity,
                        vertex_colors=m.vertex_colors, light_map=m.light_map,
                        alpha_test=m.alpha_test, depth_test=m.depth_test,
                        depth_write=m.depth_write,
                        clipping_planes=m.clipping_planes)
end
function _with_vertex_color(m::MeshPhongMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    MeshPhongMaterial(color=_modulate(m.color, vc), specular=m.specular,
                      emissive=m.emissive, shininess=m.shininess,
                      glossiness=m.glossiness,
                      opacity=m.opacity, transparent=m.transparent,
                      wireframe=m.wireframe, side=m.side, map=m.map,
                      specular_map=m.specular_map,
                      glossiness_map=m.glossiness_map,
                      alpha_map=m.alpha_map,
                      normal_map=m.normal_map, normal_scale=m.normal_scale,
                      ao_map=m.ao_map, emissive_map=m.emissive_map, light_map=m.light_map,
                      vertex_colors=m.vertex_colors,
                      alpha_test=m.alpha_test, clipping_planes=m.clipping_planes,
                      emissive_intensity=m.emissive_intensity,
                      ao_map_intensity=m.ao_map_intensity,
                      light_map_intensity=m.light_map_intensity,
                      depth_test=m.depth_test, depth_write=m.depth_write)
end
function _with_vertex_color(m::MeshStandardMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    MeshStandardMaterial(color=_modulate(m.color, vc), emissive=m.emissive,
                         metalness=m.metalness, roughness=m.roughness,
                         opacity=m.opacity, transparent=m.transparent, side=m.side,
                         map=m.map, normal_map=m.normal_map, normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         alpha_map=m.alpha_map, ao_map=m.ao_map,
                         emissive_map=m.emissive_map, vertex_colors=m.vertex_colors,
                         alpha_test=m.alpha_test, envmap=m.envmap,
                         light_map=m.light_map, emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end

function _phong_with_maps(m::MeshPhongMaterial, specular::Color3, glossiness)
    g = clamp(Float64(glossiness), 0.0, 1.0)
    MeshPhongMaterial(color=m.color, specular=specular, emissive=m.emissive,
                      shininess=_phong_shininess_from_glossiness(g),
                      glossiness=g, opacity=m.opacity,
                      transparent=m.transparent, wireframe=m.wireframe,
                      side=m.side, map=m.map, specular_map=m.specular_map,
                      glossiness_map=m.glossiness_map, normal_map=m.normal_map,
                      normal_scale=m.normal_scale, alpha_map=m.alpha_map,
                      ao_map=m.ao_map, emissive_map=m.emissive_map,
                      light_map=m.light_map, vertex_colors=m.vertex_colors,
                      alpha_test=m.alpha_test,
                      clipping_planes=m.clipping_planes,
                      emissive_intensity=m.emissive_intensity,
                      ao_map_intensity=m.ao_map_intensity,
                      light_map_intensity=m.light_map_intensity,
                      depth_test=m.depth_test, depth_write=m.depth_write)
end

function _apply_phong_maps(m::MeshPhongMaterial, specular_map, glossiness_map, u, v)
    specular = specular_map === nothing ? m.specular : begin
        s = sample_texture_linear(specular_map, u, v)
        Color3(m.specular.r * s.r, m.specular.g * s.g, m.specular.b * s.b)
    end
    glossiness = glossiness_map === nothing ? m.glossiness :
                 m.glossiness * sample_texture_channel(glossiness_map, u, v, 4)
    return _phong_with_maps(m, specular, glossiness)
end

function _apply_phong_maps(m::MeshPhongMaterial, specular_map, glossiness_map, u, v, u2, v2)
    su, sv = specular_map === nothing ? (u, v) : _map_uv(specular_map, u, v, u2, v2)
    gu, gv = glossiness_map === nothing ? (u, v) : _map_uv(glossiness_map, u, v, u2, v2)
    specular = specular_map === nothing ? m.specular : begin
        s = sample_texture_linear(specular_map, su, sv)
        Color3(m.specular.r * s.r, m.specular.g * s.g, m.specular.b * s.b)
    end
    glossiness = glossiness_map === nothing ? m.glossiness :
                 m.glossiness * sample_texture_channel(glossiness_map, gu, gv, 4)
    return _phong_with_maps(m, specular, glossiness)
end
function _with_vertex_color(m::MeshPhysicalMaterial, vc::Color3)
    _is_identity_vertex_color(vc) && return m
    MeshPhysicalMaterial(color=_modulate(m.color, vc), emissive=m.emissive,
                         metalness=m.metalness, roughness=m.roughness,
                         clearcoat=m.clearcoat, clearcoat_roughness=m.clearcoat_roughness,
                         transmission=m.transmission, ior=m.ior, opacity=m.opacity,
                         transparent=m.transparent, side=m.side, envmap=m.envmap,
                         map=m.map, normal_map=m.normal_map, normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         ao_map=m.ao_map, emissive_map=m.emissive_map, alpha_map=m.alpha_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         alpha_test=m.alpha_test,
                         sheen=m.sheen, sheen_color=m.sheen_color,
                         sheen_roughness=m.sheen_roughness,
                         iridescence=m.iridescence, iridescence_ior=m.iridescence_ior,
                         iridescence_thickness=m.iridescence_thickness,
                         light_map=m.light_map,
                         clearcoat_map=m.clearcoat_map,
                         clearcoat_roughness_map=m.clearcoat_roughness_map,
                         transmission_map=m.transmission_map,
                         thickness=m.thickness, thickness_map=m.thickness_map,
                         attenuation_distance=m.attenuation_distance,
                         attenuation_color=m.attenuation_color,
                         sheen_color_map=m.sheen_color_map,
                         sheen_roughness_map=m.sheen_roughness_map,
                         iridescence_map=m.iridescence_map,
                         iridescence_thickness_map=m.iridescence_thickness_map,
                         specular_intensity=m.specular_intensity,
                         specular_color=m.specular_color,
                         specular_intensity_map=m.specular_intensity_map,
                         specular_color_map=m.specular_color_map,
                         vertex_colors=m.vertex_colors,
                         clearcoat_normal_map=m.clearcoat_normal_map,
                         clearcoat_normal_scale=m.clearcoat_normal_scale,
                         dispersion=m.dispersion,
                         anisotropy=m.anisotropy,
                         anisotropy_rotation=m.anisotropy_rotation,
                         anisotropy_map=m.anisotropy_map,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end

# Per-face average of the three vertices' RGB colors from the geometry's :color
# attribute (item_size 3, flat [r,g,b,...]). three.js multiplies the interpolated
# vertex color into the material color; for flat per-face shading we use the
# face's vertex-color centroid.
@inline function _face_vertex_color(attr::BufferAttribute, i1, i2, i3)
    s = attr.item_size
    b1 = (i1-1)*s; b2 = (i2-1)*s; b3 = (i3-1)*s
    d = attr.data
    Color3((d[b1+1] + d[b2+1] + d[b3+1]) / 3,
           (d[b1+2] + d[b2+2] + d[b3+2]) / 3,
           (d[b1+3] + d[b2+3] + d[b3+3]) / 3)
end

# Perturb a face normal by a tangent-space normal map. The tangent frame is
# derived from the triangle's world positions and UV gradients (standard
# tangent-from-UV), then the sampled normal `2·texel-1` is rotated into world.
function _apply_normal_map(face_n::Vec3, nmap, u, v, p1::Vec3, p2::Vec3, p3::Vec3,
                           uv1, uv2, uv3, normal_scale::Real=1.0)
    e1 = p2 - p1; e2 = p3 - p1
    du1 = uv2[1]-uv1[1]; dv1 = uv2[2]-uv1[2]
    du2 = uv3[1]-uv1[1]; dv2 = uv3[2]-uv1[2]
    det = du1*dv2 - du2*dv1
    abs(det) < 1e-12 && return face_n
    r = 1.0 / det
    T = (e1*dv2 - e2*dv1) * r
    tl = norm(T); tl < 1e-12 && return face_n
    T = T / tl
    T = T - face_n * dot(face_n, T)                  # Gram-Schmidt orthonormalize
    tl2 = norm(T); tl2 < 1e-12 && return face_n
    T = T / tl2
    # Bitangent handedness follows the UV winding (sign of det), matching three.js
    # getTangentFrame; otherwise mirrored UVs perturb the normal the wrong way.
    B = cross(face_n, T) * sign(det)
    s = sample_texture(nmap, u, v)
    ns = Float64(normal_scale)
    tn = Vec3((s.r*2 - 1) * ns, (s.g*2 - 1) * ns, s.b*2 - 1)
    return normalize(T*tn.x + B*tn.y + face_n*tn.z)
end

# Per-face PBR overrides from packed metalness/roughness maps
# (glTF metallicRoughnessTexture: B = metalness, G = roughness).
_physical_pbr_map(m::AbstractMaterial) = nothing
function _physical_pbr_map(m::MeshPhysicalMaterial)
    m.roughness_map !== nothing && return m.roughness_map
    m.metalness_map !== nothing && return m.metalness_map
    m.clearcoat_map !== nothing && return m.clearcoat_map
    m.clearcoat_roughness_map !== nothing && return m.clearcoat_roughness_map
    m.transmission_map !== nothing && return m.transmission_map
    m.thickness_map !== nothing && return m.thickness_map
    m.sheen_color_map !== nothing && return m.sheen_color_map
    m.sheen_roughness_map !== nothing && return m.sheen_roughness_map
    m.iridescence_map !== nothing && return m.iridescence_map
    m.iridescence_thickness_map !== nothing && return m.iridescence_thickness_map
    m.specular_intensity_map !== nothing && return m.specular_intensity_map
    m.specular_color_map !== nothing && return m.specular_color_map
    m.anisotropy_map !== nothing && return m.anisotropy_map
    return nothing
end

function _apply_pbr_maps(m::MeshStandardMaterial, roughness_map, metalness_map, u, v)
    roughness = roughness_map === nothing ? m.roughness : m.roughness * sample_texture(roughness_map, u, v).g
    metalness = metalness_map === nothing ? m.metalness : m.metalness * sample_texture(metalness_map, u, v).b
    MeshStandardMaterial(color=m.color, emissive=m.emissive, metalness=metalness,
                         roughness=roughness, opacity=m.opacity, transparent=m.transparent,
                          side=m.side, map=m.map, normal_map=m.normal_map,
                          normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         alpha_map=m.alpha_map, ao_map=m.ao_map, emissive_map=m.emissive_map,
                         vertex_colors=m.vertex_colors, alpha_test=m.alpha_test,
                         envmap=m.envmap, light_map=m.light_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end
function _apply_pbr_maps(m::MeshStandardMaterial, roughness_map, metalness_map, u, v, u2, v2)
    ru, rv = roughness_map === nothing ? (u, v) : _map_uv(roughness_map, u, v, u2, v2)
    mu, mv = metalness_map === nothing ? (u, v) : _map_uv(metalness_map, u, v, u2, v2)
    roughness = roughness_map === nothing ? m.roughness : m.roughness * sample_texture(roughness_map, ru, rv).g
    metalness = metalness_map === nothing ? m.metalness : m.metalness * sample_texture(metalness_map, mu, mv).b
    MeshStandardMaterial(color=m.color, emissive=m.emissive, metalness=metalness,
                         roughness=roughness, opacity=m.opacity, transparent=m.transparent,
                         side=m.side, map=m.map, normal_map=m.normal_map,
                         normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         alpha_map=m.alpha_map, ao_map=m.ao_map, emissive_map=m.emissive_map,
                         vertex_colors=m.vertex_colors, alpha_test=m.alpha_test,
                         envmap=m.envmap, light_map=m.light_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end
function _apply_pbr_maps(m::MeshPhysicalMaterial, roughness_map, metalness_map, u, v)
    roughness = roughness_map === nothing ? m.roughness : m.roughness * sample_texture(roughness_map, u, v).g
    metalness = metalness_map === nothing ? m.metalness : m.metalness * sample_texture(metalness_map, u, v).b
    clearcoat = m.clearcoat_map === nothing ? m.clearcoat : m.clearcoat * sample_texture_channel(m.clearcoat_map, u, v, 1)
    clearcoat_roughness = m.clearcoat_roughness_map === nothing ? m.clearcoat_roughness : m.clearcoat_roughness * sample_texture_channel(m.clearcoat_roughness_map, u, v, 2)
    transmission = m.transmission_map === nothing ? m.transmission : m.transmission * sample_texture_channel(m.transmission_map, u, v, 1)
    thickness = m.thickness_map === nothing ? m.thickness : m.thickness * sample_texture_channel(m.thickness_map, u, v, 2)
    sheen_color = m.sheen_color_map === nothing ? m.sheen_color : begin
        c = sample_texture_linear(m.sheen_color_map, u, v)
        Color3(m.sheen_color.r * c.r, m.sheen_color.g * c.g, m.sheen_color.b * c.b)
    end
    sheen_roughness = m.sheen_roughness_map === nothing ? m.sheen_roughness : m.sheen_roughness * sample_texture_channel(m.sheen_roughness_map, u, v, 4)
    iridescence = m.iridescence_map === nothing ? m.iridescence : m.iridescence * sample_texture_channel(m.iridescence_map, u, v, 1)
    iridescence_thickness = m.iridescence_thickness_map === nothing ? m.iridescence_thickness : m.iridescence_thickness * sample_texture_channel(m.iridescence_thickness_map, u, v, 2)
    specular_intensity = m.specular_intensity_map === nothing ? m.specular_intensity : m.specular_intensity * sample_texture_channel(m.specular_intensity_map, u, v, 4)
    specular_color = m.specular_color_map === nothing ? m.specular_color : begin
        c = sample_texture_linear(m.specular_color_map, u, v)
        Color3(m.specular_color.r * c.r, m.specular_color.g * c.g, m.specular_color.b * c.b)
    end
    anisotropy = m.anisotropy_map === nothing ? m.anisotropy : m.anisotropy * sample_texture_channel(m.anisotropy_map, u, v, 3)
    MeshPhysicalMaterial(color=m.color, emissive=m.emissive, metalness=metalness,
                          roughness=roughness, clearcoat=clearcoat, clearcoat_roughness=clearcoat_roughness,
                          transmission=transmission, ior=m.ior, opacity=m.opacity,
                          transparent=m.transparent, side=m.side, envmap=m.envmap,
                          map=m.map, normal_map=m.normal_map, normal_scale=m.normal_scale,
                          roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                          ao_map=m.ao_map, emissive_map=m.emissive_map, alpha_map=m.alpha_map,
                          emissive_intensity=m.emissive_intensity,
                          ao_map_intensity=m.ao_map_intensity,
                          light_map_intensity=m.light_map_intensity,
                          env_map_intensity=m.env_map_intensity,
                          alpha_test=m.alpha_test,
                          sheen=m.sheen, sheen_color=sheen_color, sheen_roughness=sheen_roughness,
                          iridescence=iridescence, iridescence_ior=m.iridescence_ior,
                          iridescence_thickness=iridescence_thickness, light_map=m.light_map,
                          clearcoat_map=m.clearcoat_map,
                          clearcoat_roughness_map=m.clearcoat_roughness_map,
                          transmission_map=m.transmission_map,
                          vertex_colors=m.vertex_colors,
                          clearcoat_normal_map=m.clearcoat_normal_map,
                          clearcoat_normal_scale=m.clearcoat_normal_scale,
                          dispersion=m.dispersion,
                          sheen_color_map=m.sheen_color_map,
                          sheen_roughness_map=m.sheen_roughness_map,
                          iridescence_map=m.iridescence_map,
                          iridescence_thickness_map=m.iridescence_thickness_map,
                          specular_intensity=specular_intensity,
                          specular_color=specular_color,
                          specular_intensity_map=m.specular_intensity_map,
                          specular_color_map=m.specular_color_map,
                          anisotropy=anisotropy,
                          anisotropy_rotation=m.anisotropy_rotation,
                          anisotropy_map=m.anisotropy_map,
                          thickness=thickness,
                          thickness_map=m.thickness_map,
                          attenuation_distance=m.attenuation_distance,
                         attenuation_color=m.attenuation_color,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end
function _apply_pbr_maps(m::MeshPhysicalMaterial, roughness_map, metalness_map, u, v, u2, v2)
    uv_for(tex) = tex === nothing ? (u, v) : _map_uv(tex, u, v, u2, v2)
    ru, rv = uv_for(roughness_map)
    mu, mv = uv_for(metalness_map)
    cu, cv = uv_for(m.clearcoat_map)
    cru, crv = uv_for(m.clearcoat_roughness_map)
    tu, tv = uv_for(m.transmission_map)
    thu, thv = uv_for(m.thickness_map)
    scu, scv = uv_for(m.sheen_color_map)
    sru, srv = uv_for(m.sheen_roughness_map)
    iu, iv = uv_for(m.iridescence_map)
    itu, itv = uv_for(m.iridescence_thickness_map)
    siu, siv = uv_for(m.specular_intensity_map)
    spcu, spcv = uv_for(m.specular_color_map)
    au, av = uv_for(m.anisotropy_map)
    roughness = roughness_map === nothing ? m.roughness : m.roughness * sample_texture(roughness_map, ru, rv).g
    metalness = metalness_map === nothing ? m.metalness : m.metalness * sample_texture(metalness_map, mu, mv).b
    clearcoat = m.clearcoat_map === nothing ? m.clearcoat : m.clearcoat * sample_texture_channel(m.clearcoat_map, cu, cv, 1)
    clearcoat_roughness = m.clearcoat_roughness_map === nothing ? m.clearcoat_roughness : m.clearcoat_roughness * sample_texture_channel(m.clearcoat_roughness_map, cru, crv, 2)
    transmission = m.transmission_map === nothing ? m.transmission : m.transmission * sample_texture_channel(m.transmission_map, tu, tv, 1)
    thickness = m.thickness_map === nothing ? m.thickness : m.thickness * sample_texture_channel(m.thickness_map, thu, thv, 2)
    sheen_color = m.sheen_color_map === nothing ? m.sheen_color : begin
        c = sample_texture_linear(m.sheen_color_map, scu, scv)
        Color3(m.sheen_color.r * c.r, m.sheen_color.g * c.g, m.sheen_color.b * c.b)
    end
    sheen_roughness = m.sheen_roughness_map === nothing ? m.sheen_roughness : m.sheen_roughness * sample_texture_channel(m.sheen_roughness_map, sru, srv, 4)
    iridescence = m.iridescence_map === nothing ? m.iridescence : m.iridescence * sample_texture_channel(m.iridescence_map, iu, iv, 1)
    iridescence_thickness = m.iridescence_thickness_map === nothing ? m.iridescence_thickness : m.iridescence_thickness * sample_texture_channel(m.iridescence_thickness_map, itu, itv, 2)
    specular_intensity = m.specular_intensity_map === nothing ? m.specular_intensity : m.specular_intensity * sample_texture_channel(m.specular_intensity_map, siu, siv, 4)
    specular_color = m.specular_color_map === nothing ? m.specular_color : begin
        c = sample_texture_linear(m.specular_color_map, spcu, spcv)
        Color3(m.specular_color.r * c.r, m.specular_color.g * c.g, m.specular_color.b * c.b)
    end
    anisotropy = m.anisotropy_map === nothing ? m.anisotropy : m.anisotropy * sample_texture_channel(m.anisotropy_map, au, av, 3)
    MeshPhysicalMaterial(color=m.color, emissive=m.emissive, metalness=metalness,
                         roughness=roughness, clearcoat=clearcoat,
                         clearcoat_roughness=clearcoat_roughness,
                         transmission=transmission, ior=m.ior, opacity=m.opacity,
                         transparent=m.transparent, side=m.side, envmap=m.envmap,
                         map=m.map, normal_map=m.normal_map, normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         ao_map=m.ao_map, emissive_map=m.emissive_map, alpha_map=m.alpha_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         alpha_test=m.alpha_test,
                         sheen=m.sheen, sheen_color=sheen_color, sheen_roughness=sheen_roughness,
                         iridescence=iridescence, iridescence_ior=m.iridescence_ior,
                         iridescence_thickness=iridescence_thickness, light_map=m.light_map,
                         clearcoat_map=m.clearcoat_map,
                         clearcoat_roughness_map=m.clearcoat_roughness_map,
                         transmission_map=m.transmission_map,
                         vertex_colors=m.vertex_colors,
                         clearcoat_normal_map=m.clearcoat_normal_map,
                         clearcoat_normal_scale=m.clearcoat_normal_scale,
                         dispersion=m.dispersion,
                         sheen_color_map=m.sheen_color_map,
                         sheen_roughness_map=m.sheen_roughness_map,
                         iridescence_map=m.iridescence_map,
                         iridescence_thickness_map=m.iridescence_thickness_map,
                         specular_intensity=specular_intensity,
                         specular_color=specular_color,
                         specular_intensity_map=m.specular_intensity_map,
                         specular_color_map=m.specular_color_map,
                         anisotropy=anisotropy,
                         anisotropy_rotation=m.anisotropy_rotation,
                         anisotropy_map=m.anisotropy_map,
                         thickness=thickness,
                         thickness_map=m.thickness_map,
                         attenuation_distance=m.attenuation_distance,
                         attenuation_color=m.attenuation_color,
                         depth_test=m.depth_test, depth_write=m.depth_write,
                         clipping_planes=m.clipping_planes)
end
_apply_pbr_maps(m::AbstractMaterial, roughness_map, metalness_map, u, v) = m
_apply_pbr_maps(m::AbstractMaterial, roughness_map, metalness_map, u, v, u2, v2) = m
_apply_roughness_map(m::AbstractMaterial, rmap, u, v) = _apply_pbr_maps(m, rmap, nothing, u, v)

shade_mesh_faces(geo::BufferGeometry, world_mat::Mat4, material::AbstractMaterial,
                 lights::Vector{<:AbstractLight}, cam_pos::Vec3; shadow_fn=nothing) =
    shade_mesh_faces!(Vector{Color3{Float64}}(undef, geo.n_faces),
                      geo, world_mat, material, lights, cam_pos; shadow_fn=shadow_fn)

function _shade_mesh_faces_fast!(colors::Vector{Color3{Float64}},
                                 geo::BufferGeometry, world_mat::Mat4, material,
                                 lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                                 normal_mat::Mat4, has_normals::Bool; shadow_fn=nothing)
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
        v2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
        v3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
        center = Vec3((v1.x+v2.x+v3.x)/3, (v1.y+v2.y+v3.y)/3, (v1.z+v2.z+v3.z)/3)

        if material isa MeshDepthMaterial
            d = norm(cam_pos - center)
            depth = clamp((d - material.near) / max(material.far - material.near, 1e-9), 0.0, 1.0)
            colors[fi] = _depth_material_color(material, depth)
            continue
        end

        face_n = _flat_face_normal(geo, i1, i2, i3, v1, v2, v3, normal_mat, has_normals)
        view_dir = normalize(cam_pos - center)
        color = shade_face(face_n, view_dir, center, material, lights; shadow_fn=shadow_fn)
        colors[fi] = clamp_color(color)
    end
    return colors
end

# In-place variant: writes one colour per face into `colors` (resized to fit),
# so a caller can reuse the buffer across frames/meshes (bounded allocation).
function shade_mesh_faces!(colors::Vector{Color3{Float64}},
                           geo::BufferGeometry, world_mat::Mat4, material::AbstractMaterial,
                           lights::Vector{<:AbstractLight}, cam_pos::Vec3; shadow_fn=nothing)
    n_faces = geo.n_faces
    length(colors) == n_faces || resize!(colors, n_faces)

    # Normal matrix (transpose of inverse) for transforming normals to world space.
    normal_mat = mat4_transpose(mat4_inverse(world_mat))
    has_normals = length(geo.normals) >= geo.n_vertices * 3
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = _material_field(material, :map)
    ao_map = _material_field(material, :ao_map)
    emissive_map = _material_field(material, :emissive_map)
    normal_map = _material_field(material, :normal_map)
    normal_scale = _material_scalar(material, :normal_scale, 1.0)
    roughness_map = _material_field(material, :roughness_map)
    metalness_map = _material_field(material, :metalness_map)
    specular_map = _material_field(material, :specular_map)
    glossiness_map = _material_field(material, :glossiness_map)
    physical_pbr_map = _physical_pbr_map(material)
    light_map = _material_field(material, :light_map)
    use_maps = has_uvs && (albedo_map !== nothing || ao_map !== nothing || emissive_map !== nothing ||
                           normal_map !== nothing || roughness_map !== nothing || metalness_map !== nothing ||
                           specular_map !== nothing || glossiness_map !== nothing ||
                           physical_pbr_map !== nothing || light_map !== nothing)
    uv2_attr = _uv2_attribute(geo)

    # Per-vertex color modulation: material opt-in AND a geometry :color attribute
    # with at least RGB components. Resolved once so the hot loop stays type-stable.
    color_attr = (_wants_vertex_colors(material) && has_attribute(geo, :color)) ?
                 get_attribute(geo, :color) : nothing
    use_vertex_colors = color_attr !== nothing && color_attr.item_size >= 3 &&
                        length(color_attr.data) >= geo.n_vertices * color_attr.item_size

    # Environment-map reflection (basic IBL specular) for PBR materials.
    env_map = _envmap_field(material)

    if !use_maps && !use_vertex_colors && env_map === nothing
        return _shade_mesh_faces_fast!(colors, geo, world_mat, material, lights, cam_pos,
                                       normal_mat, has_normals; shadow_fn=shadow_fn)
    end

    if use_maps && albedo_map isa Texture && ao_map === nothing &&
       emissive_map === nothing && normal_map === nothing &&
       roughness_map === nothing && metalness_map === nothing &&
       specular_map === nothing && glossiness_map === nothing &&
       physical_pbr_map === nothing && light_map === nothing &&
       !use_vertex_colors && env_map === nothing
        return _shade_mesh_faces_mapped!(colors, geo, world_mat, material, lights, cam_pos,
                                         normal_mat, has_normals, true,
                                         albedo_map, nothing, nothing, nothing,
                                         normal_scale, nothing, nothing, nothing,
                                         nothing, nothing, nothing, uv2_attr,
                                         nothing, false, nothing;
                                         shadow_fn=shadow_fn)
    end

    return _shade_mesh_faces_mapped!(colors, geo, world_mat, material, lights, cam_pos,
                                     normal_mat, has_normals, use_maps,
                                     albedo_map, ao_map, emissive_map, normal_map,
                                     normal_scale, roughness_map, metalness_map,
                                     specular_map, glossiness_map, physical_pbr_map,
                                     light_map, uv2_attr, color_attr,
                                     use_vertex_colors, env_map;
                                     shadow_fn=shadow_fn)
end

function _shade_mesh_faces_mapped!(colors::Vector{Color3{Float64}},
                                   geo::BufferGeometry, world_mat::Mat4,
                                   material::AbstractMaterial,
                                   lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                                   normal_mat::Mat4, has_normals::Bool,
                                   use_maps::Bool, albedo_map, ao_map,
                                   emissive_map, normal_map,
                                   normal_scale::Float64, roughness_map,
                                   metalness_map, specular_map, glossiness_map,
                                   physical_pbr_map, light_map, uv2_attr,
                                   color_attr, use_vertex_colors::Bool,
                                   env_map; shadow_fn=nothing)
    n_faces = geo.n_faces
    for fi in 1:n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
        v2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
        v3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
        center = Vec3((v1.x+v2.x+v3.x)/3, (v1.y+v2.y+v3.y)/3, (v1.z+v2.z+v3.z)/3)

        if material isa MeshDepthMaterial
            d = norm(cam_pos - center)
            depth = clamp((d - material.near) / max(material.far - material.near, 1e-9), 0.0, 1.0)
            colors[fi] = _depth_material_color(material, depth)
            continue
        end

        face_n = _flat_face_normal(geo, i1, i2, i3, v1, v2, v3, normal_mat, has_normals)
        view_dir = normalize(cam_pos - center)
        eff_mat = material

        # normalMap perturbs the shading normal and roughnessMap overrides the
        # material roughness — both must apply BEFORE shading. Albedo/AO/emissive
        # modulate the result AFTER (they commute with diffuse lighting).
        if use_maps
            u, v = _face_centroid_uv(geo, i1, i2, i3)
            u2, v2uv = uv2_attr === nothing ? (u, v) : _face_centroid_uv_attr(uv2_attr, i1, i2, i3)
            if normal_map !== nothing
                nu, nv = _map_uv(normal_map, u, v, u2, v2uv)
                normal_uvs = _texture_uv_set(normal_map) == 1 && uv2_attr !== nothing ?
                    (_vertex_uv_attr(uv2_attr, i1), _vertex_uv_attr(uv2_attr, i2), _vertex_uv_attr(uv2_attr, i3)) :
                    (_vertex_uv(geo, i1), _vertex_uv(geo, i2), _vertex_uv(geo, i3))
                face_n = _apply_normal_map(face_n, normal_map, nu, nv, v1, v2, v3,
                                           normal_uvs[1], normal_uvs[2], normal_uvs[3],
                                           normal_scale)
            end
            if specular_map !== nothing || glossiness_map !== nothing
                eff_mat = _apply_phong_maps(material, specular_map, glossiness_map, u, v, u2, v2uv)
            elseif roughness_map !== nothing || metalness_map !== nothing || physical_pbr_map !== nothing
                eff_mat = _apply_pbr_maps(material, roughness_map, metalness_map, u, v, u2, v2uv)
            end
        end

        shade_mat = use_vertex_colors ? _with_vertex_color(eff_mat, _face_vertex_color(color_attr, i1, i2, i3)) : eff_mat
        color = shade_face(face_n, view_dir, center, shade_mat, lights; shadow_fn=shadow_fn)

        if use_maps
            u, v = _face_centroid_uv(geo, i1, i2, i3)
            u2, v2 = uv2_attr === nothing ? (u, v) : _face_centroid_uv_attr(uv2_attr, i1, i2, i3)
            # three.js keeps emission OUT of the diffuse map chain: remove the
            # base `emissive · intensity` added by `shade_face` before the
            # multiplicative maps below, and add the modulated form
            # `emissive · emissiveMap texel · intensity` back afterwards.
            em = _material_field(material, :emissive)
            emi = em === nothing ? 0.0 : _material_scalar(material, :emissive_intensity)
            if em !== nothing
                color = Color3(color.r - em.r * emi, color.g - em.g * emi,
                               color.b - em.b * emi)
            end
            if albedo_map !== nothing
                tu, tv = _map_uv(albedo_map, u, v, u2, v2)
                color = color * sample_texture_linear(albedo_map, tu, tv)
            end
            if ao_map !== nothing
                tu, tv = _map_uv(ao_map, u, v, u2, v2; default_uv2=true)
                ao = sample_texture(ao_map, tu, tv)
                aoi = _material_scalar(material, :ao_map_intensity)
                aor = 1.0 + (ao.r - 1.0) * aoi
                aog = 1.0 + (ao.g - 1.0) * aoi
                aob = 1.0 + (ao.b - 1.0) * aoi
                color = Color3(color.r*aor, color.g*aog, color.b*aob)
            end
            # lightMap: baked indirect lighting, multiplied into the lit result
            # (like aoMap) so pre-baked GI tints the surface (three.js lightMap).
            if light_map !== nothing
                tu, tv = _map_uv(light_map, u, v, u2, v2; default_uv2=true)
                lm = sample_texture(light_map, tu, tv)
                lmi = _material_scalar(material, :light_map_intensity)
                color = Color3(color.r*lm.r*lmi, color.g*lm.g*lmi, color.b*lm.b*lmi)
            end
            if em !== nothing
                t = Color3(1.0, 1.0, 1.0)
                if emissive_map !== nothing
                    tu, tv = _map_uv(emissive_map, u, v, u2, v2)
                    t = sample_texture_linear(emissive_map, tu, tv)
                end
                color = color + Color3(em.r * t.r * emi, em.g * t.g * emi,
                                       em.b * t.b * emi)
            end
        end

        # Environment reflection (basic IBL specular) added on top of the lit/
        # textured result. Metals reflect albedo-tinted env; dielectrics a small
        # Fresnel reflection. Uses `eff_mat` so a roughness-map override applies.
        if env_map !== nothing
            color = color + _envmap_reflection(env_map, face_n, view_dir,
                                               shade_mat.color, shade_mat.metalness, shade_mat.roughness) *
                            _material_scalar(shade_mat, :env_map_intensity)
        end

        colors[fi] = clamp_color(color)
    end
    return colors
end

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshBasicMaterial, lights; shadow_fn=nothing)
    material.color
end

# --------------------------------------------------------------------------
# Ambient / hemisphere lights are view-independent fill, not directional. They
# add uniform (hemisphere: normal-weighted) irradiance rather than an N·L term.
# `_is_fill_light` selects them; `_fill_color` returns the effective irradiance.
# --------------------------------------------------------------------------
@inline _is_fill_light(l::AbstractLight) =
    (l isa AmbientLight) || (l isa HemisphereLight) || (l isa LightProbe)

_fill_color(normal::Vec3, light::AmbientLight) = light.color * light.intensity
function _fill_color(normal::Vec3, light::HemisphereLight)
    w = clamp(normal.y * 0.5 + 0.5, zero(normal.y), one(normal.y))
    blended = Color3(light.color.r * w + light.ground_color.r * (1 - w),
                     light.color.g * w + light.ground_color.g * (1 - w),
                     light.color.b * w + light.ground_color.b * (1 - w))
    return blended * light.intensity
end
# Order-1 SH irradiance, clamped to non-negative per channel.
function _fill_color(normal::Vec3, light::LightProbe)
    c = light.coeffs
    r = c[1].r + c[2].r*normal.x + c[3].r*normal.y + c[4].r*normal.z
    g = c[1].g + c[2].g*normal.x + c[3].g*normal.y + c[4].g*normal.z
    b = c[1].b + c[2].b*normal.x + c[3].b*normal.y + c[4].b*normal.z
    Color3(max(r,0.0), max(g,0.0), max(b,0.0)) * light.intensity
end

# Environment (ambient/IBL) response of a metallic-roughness surface. Without
# this term metals (low diffuse, narrow specular) render black under directional
# light alone. Diffuse scales by (1-metalness); specular uses Schlick F0 (≈albedo
# for metals) attenuated by roughness.
function _pbr_ambient(normal::Vec3, albedo::Color3, metalness, roughness, fill::Color3)
    kd = one(metalness) - metalness
    F0r = lerp_scalar(0.04, albedo.r, metalness)
    F0g = lerp_scalar(0.04, albedo.g, metalness)
    F0b = lerp_scalar(0.04, albedo.b, metalness)
    spec_scale = one(roughness) - roughness * 0.7
    Color3((albedo.r * kd + F0r * spec_scale) * fill.r,
           (albedo.g * kd + F0g * spec_scale) * fill.g,
           (albedo.b * kd + F0b * spec_scale) * fill.b)
end

# Environment-map (basic IBL) specular reflection. Reflect the view direction
# about the shading normal, sample the cube map along that mirror direction, and
# weight by a Schlick-Fresnel F0 (≈albedo for metals, ≈0.04 for dielectrics).
# When cube faces carry mipmaps, roughness also selects a coarser cube-face LOD
# before the scalar lobe attenuation below. This is not PMREM convolution, but
# it makes authored prefiltered/mipped cubemaps participate in roughness-aware
# CPU shading instead of always sampling the sharp base face.
# `view_dir` points from the surface toward the camera, so the incident ray is
# `-view_dir`; its reflection about `normal` is `2(N·V)N - V`.
function _envmap_reflection(env::CubeTexture, normal::Vec3, view_dir::Vec3,
                            albedo::Color3, metalness, roughness)
    ndotv = dot(normal, view_dir)
    refl = normal * (2 * ndotv) - view_dir            # mirror reflection direction
    max_lod = maximum(length(face.mipmaps) for face in env.faces)
    env_c = if max_lod > 0
        lod = clamp(Float64(roughness), 0.0, 1.0) * max_lod
        sample_cube_lod(env, refl, lod)
    else
        sample_cube(env, refl)
    end
    # Grazing-angle Fresnel boost from the view/normal angle (vdotn analog).
    fres = (one(ndotv) - max(ndotv, zero(ndotv)))^5
    F0r = lerp_scalar(0.04, albedo.r, metalness)
    F0g = lerp_scalar(0.04, albedo.g, metalness)
    F0b = lerp_scalar(0.04, albedo.b, metalness)
    Fr = F0r + (one(F0r) - F0r) * fres
    Fg = F0g + (one(F0g) - F0g) * fres
    Fb = F0b + (one(F0b) - F0b) * fres
    spec_scale = one(roughness) - roughness * 0.7     # sharp reflection fades with roughness
    Color3(env_c.r * Fr * spec_scale,
           env_c.g * Fg * spec_scale,
           env_c.b * Fb * spec_scale)
end

# Dispatch helper: only MeshStandardMaterial / MeshPhysicalMaterial carry envmap.
@inline _envmap_field(m) = hasfield(typeof(m), :envmap) ? getfield(m, :envmap) : nothing

# Dielectric clearcoat highlight: Schlick-Fresnel-weighted Blinn-Phong lobe (F0 = 0.04).
@inline function _clearcoat_spec(normal::Vec3, light_dir::Vec3, view_dir::Vec3, cc_roughness)
    h = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, h), zero(cc_roughness))
    vdoth = max(dot(view_dir, h), zero(cc_roughness))
    shininess = 2 / max((cc_roughness*cc_roughness)^2, 1e-4) + 2   # roughness → exponent
    fresnel = 0.04 + 0.96 * (1 - vdoth)^5
    return fresnel * ndoth^shininess
end

# Charlie/Ashikhmin sheen distribution (the inverted-Gaussian "fabric" lobe used
# by three.js' sheen model). `c = N·H`, `r = sheen_roughness`. With a = max(r²,ε)
# this peaks at grazing half-angles (retroreflective rim glow on cloth/velvet).
@inline function _d_charlie(c, r)
    a = max(r * r, 1e-3)
    inv_a = one(a) / a
    s = sin(acos(clamp(c, -one(c), one(c))))         # sinθ_h, finite at c=±1
    return (2 + inv_a) * s^inv_a / (2 * π)
end

# Sheen lobe contribution for one light: f = sheen·sheen_color·D_charlie(N·H,r)·(N·L).
# Returned as a Color3 (before the light colour/intensity scaling applied by the caller).
@inline function _sheen_lobe(m::MeshPhysicalMaterial, normal::Vec3, light_dir::Vec3, view_dir::Vec3)
    ndotl = max(dot(normal, light_dir), 0.0)
    ndotl <= 0.0 && return Color3(0.0, 0.0, 0.0)
    h = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, h), 0.0)
    d = _d_charlie(ndoth, m.sheen_roughness)
    return m.sheen_color * (m.sheen * d * ndotl)
end

# Iridescence tint of the dielectric Fresnel F0. A thin film of index
# `iridescence_ior` and thickness `thickness` (nm) produces an optical path
# difference Δ = 2·n·d·cosθ_t (θ_t the refraction angle inside the film). The
# per-wavelength reflectance modulation is taken as a cosine interference term
# I(λ) = 0.5·(1 + cos(2π·Δ/λ)) evaluated at red/green/blue reference wavelengths
# (650/550/450 nm), giving an RGB hue that shifts with viewing angle. We blend
# the base F0 toward this hue by `iridescence`. This is a compact 3-wavelength
# approximation of three.js' full Airy/thin-film model, kept finite at θ=0 and
# grazing by clamping cosθ.
@inline function _iridescent_f0(base_f0::Color3, ndotv, film_ior, thickness, blend)
    cti = clamp(ndotv, 0.0, 1.0)                      # cosθ_i (view vs normal)
    # Snell refraction into the film (n_outside ≈ 1). sinθ_t = sinθ_i / n_film.
    sti = sqrt(max(1.0 - cti * cti, 0.0)) / max(film_ior, 1e-3)
    ctt = sqrt(max(1.0 - sti * sti, 0.0))             # cosθ_t, finite at all angles
    opd = 2.0 * film_ior * thickness * ctt            # optical path difference (nm)
    ir = 0.5 * (1 + cos(2π * opd / 650.0))
    ig = 0.5 * (1 + cos(2π * opd / 550.0))
    ib = 0.5 * (1 + cos(2π * opd / 450.0))
    tint = Color3(ir, ig, ib)
    b = clamp(blend, 0.0, 1.0)
    return Color3(base_f0.r * (1 - b) + tint.r * b,
                  base_f0.g * (1 - b) + tint.g * b,
                  base_f0.b * (1 - b) + tint.b * b)
end

# Iridescent specular boost added on top of the base PBR specular. We recompute a
# Schlick specular highlight whose Fresnel uses the thin-film-tinted F0 and blend
# in only the *difference* from the untinted dielectric F0 (≈0.04), so a material
# with iridescence=0 is byte-identical to before and metals/albedo are untouched.
@inline function _iridescence_spec(m::MeshPhysicalMaterial, normal::Vec3,
                                   light_dir::Vec3, view_dir::Vec3)
    ndotl = max(dot(normal, light_dir), 0.0)
    ndotv = max(dot(normal, view_dir), 0.0)
    (ndotl <= 0.0) && return Color3(0.0, 0.0, 0.0)
    h = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, h), 0.0)
    vdoth = max(dot(view_dir, h), 0.0)
    base_f0 = Color3(0.04, 0.04, 0.04)
    tinted = _iridescent_f0(base_f0, ndotv, m.iridescence_ior, m.iridescence_thickness, m.iridescence)
    # Schlick Fresnel of the tinted vs base F0, masked by a Blinn-Phong lobe so
    # the tint shows up in the highlight rather than as a flat colour shift.
    fres = (1 - vdoth)^5
    Ft = Color3(tinted.r + (1 - tinted.r) * fres,
                tinted.g + (1 - tinted.g) * fres,
                tinted.b + (1 - tinted.b) * fres)
    Fb = Color3(base_f0.r + (1 - base_f0.r) * fres,
                base_f0.g + (1 - base_f0.g) * fres,
                base_f0.b + (1 - base_f0.b) * fres)
    roughness = _physical_roughness(m)
    α = roughness * roughness
    α2 = α * α
    denom_d = ndoth * ndoth * (α2 - 1) + 1
    D = α2 / (π * denom_d * denom_d + 1e-7)
    lobe = D / (4 * ndotv * ndotl + 1e-7) * ndotl
    Color3((Ft.r - Fb.r) * lobe, (Ft.g - Fb.g) * lobe, (Ft.b - Fb.b) * lobe)
end

# APPROXIMATE transmission/refraction fill. A CPU rasterizer cannot ray-trace
# true refraction (no screen-space colour buffer to refract through and no scene
# ray queries), so genuine `transmission` is not physically reproducible here.
# This is a Fresnel-tint approximation: at near-grazing angles the surface
# reflects (low transmittance) and near normal incidence it transmits, revealing
# a tinted background. The transmitted radiance is attenuated by the material
# colour (a single-sample Beer-Lambert-style tint, treating `color` as the per-
# unit transmittance) and weighted by transmission·(1-Fresnel). `background` is
# the ambient/environment fill colour the ray would see behind the surface.
@inline function _transmission_fill(m::MeshPhysicalMaterial, normal::Vec3, view_dir::Vec3,
                                    background::Color3)
    m.transmission <= 0.0 && return Color3(0.0, 0.0, 0.0)
    ndotv = clamp(dot(normal, view_dir), 0.0, 1.0)
    # Schlick reflectance from the IOR-derived F0; transmittance = 1 - reflectance.
    r0 = ((m.ior - 1) / (m.ior + 1))^2
    refl = r0 + (1 - r0) * (1 - ndotv)^5
    transmit = (1 - refl) * m.transmission
    # Beer-Lambert tint: longer optical path near grazing darkens/colours more.
    path = 1.0 / max(ndotv, 1e-3)
    att = Color3(m.color.r^path, m.color.g^path, m.color.b^path)
    if m.thickness > 0.0 && m.attenuation_distance > 0.0
        volume_path = path * m.thickness / m.attenuation_distance
        att = att * Color3(m.attenuation_color.r^volume_path,
                           m.attenuation_color.g^volume_path,
                           m.attenuation_color.b^volume_path)
    end
    Color3(background.r * att.r * transmit,
           background.g * att.g * transmit,
           background.b * att.b * transmit)
end

# Lit materials share one accumulation loop so direct lighting can be modulated
# by a per-light shadow visibility (`shadow_fn(light, position) ∈ [0,1]`). Each
# material supplies its fill response and its per-light direct response.
const LitMaterial = Union{MeshLambertMaterial, MeshPhongMaterial, MeshStandardMaterial,
                          MeshPhysicalMaterial, MeshToonMaterial}

_fill_response(m::MeshLambertMaterial,  n, fc) = m.color * fc
_fill_response(m::MeshPhongMaterial,    n, fc) = m.color * fc
_fill_response(m::MeshToonMaterial,     n, fc) = m.color * fc
_fill_response(m::MeshStandardMaterial, n, fc) = _pbr_ambient(n, m.color, m.metalness, m.roughness, fc)
@inline function _anisotropic_effective_roughness(roughness, anisotropy)
    strength = clamp(anisotropy, 0.0, 1.0)
    alpha = clamp(roughness * roughness, 0.0, 1.0)
    return sqrt(alpha + (1.0 - alpha) * strength * strength)
end

@inline _physical_roughness(m::MeshPhysicalMaterial) =
    _anisotropic_effective_roughness(m.roughness, m.anisotropy)

function _fill_response(m::MeshPhysicalMaterial, n, fc)
    _pbr_ambient(n, m.color, m.metalness, _physical_roughness(m), fc)
end

_direct_response(m::MeshLambertMaterial, n, v, lc, li, ldir) =
    shade_lambert(n, ldir, lc, li, m.color)
_direct_response(m::MeshPhongMaterial, n, v, lc, li, ldir) =
    shade_phong(n, ldir, v, lc, li, m.color, m.specular, m.shininess)
_direct_response(m::MeshStandardMaterial, n, v, lc, li, ldir) =
    shade_pbr(n, ldir, v, lc, li, m.color, m.metalness, m.roughness)
function _direct_response(m::MeshPhysicalMaterial, n, v, lc, li, ldir)
    roughness = _physical_roughness(m)
    base = shade_pbr(n, ldir, v, lc, li, m.color, m.metalness, roughness,
                     m.specular_intensity, m.specular_color)
    cc = m.clearcoat * _clearcoat_spec(n, ldir, v, m.clearcoat_roughness) * max(dot(n, ldir), 0.0)
    result = base + lc * (cc * li)
    # Retroreflective sheen lobe (Charlie distribution), scaled by the light.
    if m.sheen > 0.0
        result = result + _sheen_lobe(m, n, ldir, v) * lc * li
    end
    # Thin-film iridescence shifts the dielectric specular hue with view angle.
    if m.iridescence > 0.0
        result = result + _iridescence_spec(m, n, ldir, v) * lc * li
    end
    return result
end
function _direct_response(m::MeshToonMaterial, n, v, lc, li, ldir)
    dotnl = dot(n, ldir)
    irradiance = if m.gradient_map isa Texture
        coord = clamp(dotnl * 0.5 + 0.5, 0.0, 1.0)
        sample_texture(m.gradient_map, coord, 0.0).r
    else
        ndotl = max(dotnl, 0.0)
        ceil(ndotl * m.gradient_steps) / m.gradient_steps
    end
    m.color * lc * (irradiance * li)
end

# Per-light accumulation, factored into a function barrier so that once a light
# is dispatched to its concrete type the inner work (light_contribution, fill
# response, direct response) stays type-stable when called from the concrete
# `collect_lights`/`RenderCache` scene-light vectors. The arithmetic and
# accumulation order are byte-identical to the inlined loop:
# `light_contribution` is queried only for non-fill lights, and a non-positive
# visibility leaves `result` unchanged (the previous loop `continue` skipped
# the addition).
# Transmission contribution is gated to MeshPhysicalMaterial and treats the
# fill irradiance as the background radiance the refracted ray would reveal. A
# CPU rasterizer cannot ray-trace true refraction, so this is the documented
# Fresnel-tint approximation in `_transmission_fill` (no screen-space refraction).
@inline _transmission_response(m, n::Vec3, v::Vec3, fc::Color3) = Color3(0.0, 0.0, 0.0)
@inline _transmission_response(m::MeshPhysicalMaterial, n::Vec3, v::Vec3, fc::Color3) =
    m.transmission > 0.0 ? _transmission_fill(m, n, v, fc) : Color3(0.0, 0.0, 0.0)

@inline function _rect_area_basis(light::RectAreaLight)
    f = normalize(light.target - light.position)
    ref = abs(f.y) < 0.95 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    u = normalize(cross(ref, f))
    v = cross(f, u)
    return f, u, v
end

function _rect_area_response(m, normal::Vec3, view_dir::Vec3, position::Vec3,
                             light::RectAreaLight)
    f, u, v = _rect_area_basis(light)
    hx = max(light.width, 0.0) * 0.5
    hy = max(light.height, 0.0) * 0.5
    (hx <= 0.0 || hy <= 0.0) && return Color3(0.0, 0.0, 0.0)
    nodes = (-0.7745966692414834, 0.0, 0.7745966692414834)
    weights = (0.5555555555555556, 0.8888888888888888, 0.5555555555555556)
    area_scale = hx * hy
    result = Color3(0.0, 0.0, 0.0)
    @inbounds for ix in 1:3, iy in 1:3
        sample_pos = light.position + u * (hx * nodes[ix]) + v * (hy * nodes[iy])
        diff = sample_pos - position
        dist2 = max(dot(diff, diff), 1e-10)
        ldir = diff / sqrt(dist2)
        emit = max(dot(-ldir, f), 0.0)
        emit <= 0.0 && continue
        li = light.intensity * area_scale * weights[ix] * weights[iy] * emit / dist2
        result = result + _direct_response(m, normal, view_dir, light.color, li, ldir)
    end
    return result
end

function _rect_area_standard_response(m::MeshStandardMaterial, normal::Vec3,
                                      view_dir::Vec3, position::Vec3,
                                      light::RectAreaLight,
                                      metalness::Float64, roughness::Float64)
    f, u, v = _rect_area_basis(light)
    hx = max(light.width, 0.0) * 0.5
    hy = max(light.height, 0.0) * 0.5
    (hx <= 0.0 || hy <= 0.0) && return Color3(0.0, 0.0, 0.0)
    nodes = (-0.7745966692414834, 0.0, 0.7745966692414834)
    weights = (0.5555555555555556, 0.8888888888888888, 0.5555555555555556)
    area_scale = hx * hy
    result = Color3(0.0, 0.0, 0.0)
    @inbounds for ix in 1:3, iy in 1:3
        sample_pos = light.position + u * (hx * nodes[ix]) + v * (hy * nodes[iy])
        diff = sample_pos - position
        dist2 = max(dot(diff, diff), 1e-10)
        ldir = diff / sqrt(dist2)
        emit = max(dot(-ldir, f), 0.0)
        emit <= 0.0 && continue
        li = light.intensity * area_scale * weights[ix] * weights[iy] * emit / dist2
        result = result + shade_pbr(normal, ldir, view_dir, light.color, li,
                                    m.color, metalness, roughness)
    end
    return result
end

function _accumulate_standard_light(result::Color3, m::MeshStandardMaterial,
                                    normal::Vec3, view_dir::Vec3, position::Vec3,
                                    light::RectAreaLight, shadow_fn,
                                    metalness::Float64, roughness::Float64)
    vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
    vis <= 0.0 && return result
    return result + _rect_area_standard_response(m, normal, view_dir, position,
                                                 light, metalness, roughness) * vis
end

function _accumulate_standard_light(result::Color3, m::MeshStandardMaterial,
                                    normal::Vec3, view_dir::Vec3, position::Vec3,
                                    light, shadow_fn,
                                    metalness::Float64, roughness::Float64)
    if _is_fill_light(light)
        fc = _fill_color(normal, light)
        return result + _pbr_ambient(normal, m.color, metalness, roughness, fc)
    else
        lc, li, ldir = light_contribution(light, position)
        vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
        vis <= 0.0 && return result
        return result + shade_pbr(normal, ldir, view_dir, lc, li, m.color,
                                  metalness, roughness) * vis
    end
end

function _shade_standard_mapped(normal::Vec3, view_dir::Vec3, position::Vec3,
                                material::MeshStandardMaterial, lights, shadow_fn,
                                metalness::Float64, roughness::Float64)
    result = material.emissive * material.emissive_intensity
    for light in lights
        result = _accumulate_standard_light(result, material, normal, view_dir,
                                            position, light, shadow_fn,
                                            metalness, roughness)
    end
    return result
end

function _accumulate_light(result, m, normal::Vec3, view_dir::Vec3,
                           position::Vec3, light::RectAreaLight, shadow_fn)
    vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
    vis <= 0.0 && return result
    return result + _rect_area_response(m, normal, view_dir, position, light) * vis
end

function _accumulate_light(result, m, normal::Vec3, view_dir::Vec3,
                           position::Vec3, light, shadow_fn)
    if _is_fill_light(light)
        fc = _fill_color(normal, light)
        return result + _fill_response(m, normal, fc) +
               _transmission_response(m, normal, view_dir, fc)
    else
        lc, li, ldir = light_contribution(light, position)
        vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
        vis <= 0.0 && return result
        return result + _direct_response(m, normal, view_dir, lc, li, ldir) * vis
    end
end

function _shade_lit(m, normal::Vec3, view_dir::Vec3, position::Vec3, lights, shadow_fn)
    result = m.emissive * _material_scalar(m, :emissive_intensity)
    for light in lights
        result = _accumulate_light(result, m, normal, view_dir, position, light, shadow_fn)
    end
    return result
end

shade_face(normal::Vec3, view_dir::Vec3, position::Vec3, material::LitMaterial, lights;
           shadow_fn=nothing) = _shade_lit(material, normal, view_dir, position, lights, shadow_fn)

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshNormalMaterial, lights; shadow_fn=nothing)
    Color3((normal.x + 1) / 2, (normal.y + 1) / 2, (normal.z + 1) / 2)
end

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshMatcapMaterial, lights; shadow_fn=nothing)
    if material.matcap isa Texture
        # View-dependent matcap basis (matches the web-export shader / three.js):
        # for an un-rolled camera, mx/my are the camera's right/up axes, so the
        # sphere image follows the view instead of being glued to world axes.
        s = Vec3(view_dir.z, 0.0, -view_dir.x)
        sl = norm(s)
        mx = sl > 1e-6 ? s / sl : Vec3(1.0, 0.0, 0.0)   # fallback when view_dir ≈ ±Y
        my = cross(view_dir, mx)
        u = clamp(dot(mx, normal) * 0.495 + 0.5, 0.0, 1.0)
        v = clamp(dot(my, normal) * 0.495 + 0.5, 0.0, 1.0)
        return material.color * sample_texture_linear(material.matcap, u, v)
    end
    # Procedural fallback: brighter where the surface faces the viewer.
    f = max(dot(normal, view_dir), 0.0)
    material.color * (0.35 + 0.65 * f)
end

# MeshDepthMaterial is resolved in `shade_mesh_faces` (it needs the camera
# distance); this fallback keeps direct `shade_face` calls well-defined.
function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshDepthMaterial, lights; shadow_fn=nothing)
    Color3(0.5, 0.5, 0.5)
end

# ShaderMaterial: run the user-supplied CPU fragment program (the engine's
# analog of a GLSL fragment shader). Signature: (normal, view_dir, position,
# uniforms) -> Color3. Without a program, falls back to mid-gray.
function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::ShaderMaterial, lights; shadow_fn=nothing)
    material.program === nothing && return Color3(0.5, 0.5, 0.5)
    return material.program(normal, view_dir, position, material.uniforms)
end

# Fallback (MeshBasicMaterial is defined earlier; this covers any other material).
function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::AbstractMaterial, lights; shadow_fn=nothing)
    Color3(0.5, 0.5, 0.5)
end

# ========================== Light contribution ==========================

function light_contribution(light::AmbientLight, position::Vec3)
    (light.color, light.intensity, Vec3(0.0, 1.0, 0.0))
end

function light_contribution(light::DirectionalLight, position::Vec3)
    dir = normalize(light.position - light.target)
    (light.color, light.intensity, dir)
end

function light_contribution(light::PointLight, position::Vec3)
    diff = light.position - position
    dist = norm(diff)
    dir = diff / max(dist, 1e-10)
    attenuation = if light.distance > 0
        factor = max(1.0 - (dist / light.distance)^2, 0.0)
        factor / max(dist^light.decay, 1e-10)
    else
        1.0 / max(dist^light.decay, 1e-10)
    end

    # IES photometric distribution (mirrors the SpotLight branch). A PointLight
    # has no target, so the vertical angle θ is measured from the luminaire aim
    # axis per the LM-63 convention (0° = straight down; see IESProfile): -Y,
    # rotated by the light's `rotation` so an oriented luminaire works.
    if light.ies_profile !== nothing
        rot = light.rotation
        axis = Vec3(0.0, -1.0, 0.0)
        if rot.x != 0.0 || rot.y != 0.0 || rot.z != 0.0
            q = quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)
            axis = mat4_transform_direction(quat_to_mat4(q), axis)
        end
        θ = acosd(clamp(dot(-dir, axis), -1.0, 1.0))
        attenuation *= ies_intensity(light.ies_profile, θ)
    end

    (light.color, light.intensity * attenuation, dir)
end

function light_contribution(light::SpotLight, position::Vec3)
    diff = light.position - position
    dist = norm(diff)
    dir = diff / max(dist, 1e-10)

    # Spot cone
    target_dir = normalize(light.target - light.position)
    cos_angle = dot(-dir, target_dir)  # note: dir points toward light
    # Actually: dir points from surface to light, target_dir points from light to target
    cos_angle = dot(normalize(position - light.position), target_dir)
    cos_outer = cos(light.angle)
    cos_inner = cos(light.angle * (1 - light.penumbra))

    spot_effect = clamp((cos_angle - cos_outer) / max(cos_inner - cos_outer, 1e-10), 0.0, 1.0)

    # Range cutoff (mirrors PointLight): a finite `distance` applies a smooth
    # window that vanishes at the range limit; `distance <= 0` means unbounded.
    dwin = light.distance > 0 ? max(1.0 - (dist / light.distance)^2, 0.0) : 1.0
    attenuation = spot_effect * dwin / max(dist^light.decay, 1e-10)

    # IES photometric distribution: when a measured profile is attached, modulate
    # the intensity by the profile's normalized candela at the vertical angle θ
    # between the light's aim axis and the light→surface direction (0° = beam
    # axis). `cos_angle` above is exactly that cosine, so θ = acos(cos_angle).
    if light.ies_profile !== nothing
        θ = acosd(clamp(cos_angle, -1.0, 1.0))
        attenuation *= ies_intensity(light.ies_profile, θ)
    end

    (light.color, light.intensity * attenuation, dir)
end

function light_contribution(light::HemisphereLight, position::Vec3)
    # Blend between sky and ground based on normal direction
    # We return the sky color; the shade function should handle hemisphere blending
    (light.color, light.intensity, Vec3(0.0, 1.0, 0.0))
end

function light_contribution(light::RectAreaLight, position::Vec3)
    diff = light.position - position
    dir = diff / max(norm(diff), 1e-10)
    (light.color, light.intensity, dir)
end

# Special handling for ambient in shade functions
function shade_face_with_ambient(normal, view_dir, position, material, lights)
    result = Color3(0.0, 0.0, 0.0)
    for light in lights
        if light isa AmbientLight
            mc = _material_color(material)
            result = result + mc * light.color * light.intensity
        elseif light isa HemisphereLight
            mc = _material_color(material)
            weight = dot(normal, Vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5
            blended = Color3(
                light.color.r * weight + light.ground_color.r * (1 - weight),
                light.color.g * weight + light.ground_color.g * (1 - weight),
                light.color.b * weight + light.ground_color.b * (1 - weight)
            )
            result = result + mc * blended * light.intensity
        end
    end
    return result
end

_material_color(m::MeshBasicMaterial) = m.color
_material_color(m::MeshLambertMaterial) = m.color
_material_color(m::MeshPhongMaterial) = m.color
_material_color(m::MeshStandardMaterial) = m.color
_material_color(m::MeshNormalMaterial) = Color3(0.5, 0.5, 0.5)
_material_color(m::AbstractMaterial) = Color3(0.5, 0.5, 0.5)

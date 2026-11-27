# --------------------------------------------------------------------------
# Shading models: Lambert, Phong, Toon and three.js physically based shading.
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

# three.js `BRDF_Lambert`: every diffuse response is albedo / π times irradiance.
@inline _brdf_lambert(c::Color3) = Color3(c.r / π, c.g / π, c.b / π)

"""
Compute Lambertian diffuse contribution for one light.
Returns Color3 — the three.js `BRDF_Lambert` response `albedo/π · N·L · light`.
"""
function shade_lambert(normal::Vec3, light_dir::Vec3, light_color::Color3,
                       light_intensity, surface_color::Color3)
    ndotl = max(dot(normal, light_dir), zero(light_intensity))
    surface_color * light_color * (ndotl * light_intensity / π)
end

"""
Blinn-Phong shading: diffuse + specular, following three.js
`RE_Direct_BlinnPhong` (`BRDF_Lambert` diffuse and normalized `BRDF_BlinnPhong`
specular, both scaled by the irradiance `N·L · light`).
`view_dir` points from surface toward camera.
"""
function shade_phong(normal::Vec3, light_dir::Vec3, view_dir::Vec3,
                     light_color::Color3, light_intensity,
                     diffuse_color::Color3, specular_color::Color3,
                     shininess)
    ndotl = max(dot(normal, light_dir), zero(light_intensity))
    irradiance = ndotl * light_intensity
    diffuse = diffuse_color * light_color * (irradiance / π)

    half_vec = _half_vec(light_dir, view_dir)
    ndoth = max(dot(normal, half_vec), zero(shininess))
    vdoth = max(dot(view_dir, half_vec), zero(shininess))
    fresnel = exp2((-5.55473 * vdoth - 6.98316) * vdoth)
    F = Color3(specular_color.r * (1 - fresnel) + fresnel,
               specular_color.g * (1 - fresnel) + fresnel,
               specular_color.b * (1 - fresnel) + fresnel)
    D = (shininess * 0.5 + 1) / π * ndoth^shininess
    spec = F * light_color * (irradiance * 0.25 * D)

    diffuse + spec
end

"""
    shade_pbr(normal, light_dir, view_dir, light_color, light_intensity,
              albedo, metalness, roughness, specular_intensity=1.0,
              specular_color=Color3(1.0, 1.0, 1.0)) -> Color3

Physically based response to one light, following three.js
`RE_Direct_Physical` for a metallic-roughness surface with an index of
refraction of 1.5: GGX distribution (`D_GGX`), height-correlated Smith
visibility (`V_GGX_SmithCorrelated`), Schlick Fresnel (`F_Schlick`), the
DFG-table multiple-scattering compensation and a `BRDF_Lambert` diffuse term
weighted by `1 - F`, all scaled by the irradiance `N·L · light`. `roughness` is
clamped to `[0.0525, 1]` like three.js; `specular_intensity` and
`specular_color` act as in `KHR_materials_specular`. `view_dir` points from the
surface toward the camera and `light_dir` from the surface toward the light.
"""
function shade_pbr(normal::Vec3, light_dir::Vec3, view_dir::Vec3,
                   light_color::Color3, light_intensity,
                   albedo::Color3, metalness, roughness,
                   specular_intensity=1.0,
                   specular_color::Color3=Color3(1.0, 1.0, 1.0))
    surface = _standard_surface(normal, view_dir, albedo, metalness, roughness,
                                specular_intensity, specular_color)
    return _direct_response(surface, normal, view_dir, light_color,
                            light_intensity, light_dir)
end

lerp_scalar(a, b, t) = a + (b - a) * t

# Flat-shading face normal: average of the authored per-vertex normals
# transformed to world space, so orientation follows the geometry's normals
# rather than its (possibly inconsistent) triangle winding. Falls back to the
# geometric winding normal when authored normals are absent or degenerate
# (e.g. a freshly loaded mesh before `compute_vertex_normals!`).
@inline function _flat_face_normal(geo::BufferGeometry, i1, i2, i3,
                                   v1::Vec3, v2::Vec3, v3::Vec3,
                                   normal_mat::Mat4, has_normals::Bool)
    if has_normals
        n = _mean3_vec3(
            mat4_transform_direction(normal_mat, get_normal(geo, i1)),
            mat4_transform_direction(normal_mat, get_normal(geo, i2)),
            mat4_transform_direction(normal_mat, get_normal(geo, i3)),
        )
        nl = norm(n)
        nl > 1e-12 && return normalize(n)
    end
    tri = Triangle(v1, v2, v3)
    return triangle_area(tri) > 5e-13 ?
        triangle_normal(tri) : Vec3(0.0, 0.0, 1.0)
end

# Optional material texture field (nothing if the material has no such map).
@inline _material_field(m, f::Symbol) = hasfield(typeof(m), f) ? getfield(m, f) : nothing
@inline _material_scalar(m, f::Symbol, default::Float64=1.0) =
    hasfield(typeof(m), f) ? Float64(getfield(m, f)) : default

# Centroid UV of a face (average of its three vertex UVs).
@inline function _face_centroid_uv(geo::BufferGeometry, i1, i2, i3)
    b1 = (i1-1)*2; b2 = (i2-1)*2; b3 = (i3-1)*2
    (_mean3_scaled(
         geo.uvs[b1+1], geo.uvs[b2+1], geo.uvs[b3+1]),
     _mean3_scaled(
         geo.uvs[b1+2], geo.uvs[b2+2], geo.uvs[b3+2]))
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
    (_mean3_scaled(d[b1+1], d[b2+1], d[b3+1]),
     _mean3_scaled(d[b1+2], d[b2+2], d[b3+2]))
end

@inline function _vertex_uv_attr(attr::BufferAttribute, i)
    b = (i - 1) * attr.item_size
    (attr.data[b + 1], attr.data[b + 2])
end

@inline _texture_uv_set(tex) =
    tex isa Texture ? _texture_tex_coord(tex.tex_coord) : 0
@inline _map_uv(tex, u, v, u2, v2; default_uv2::Bool=false) =
    (_texture_uv_set(tex) == 1 || (default_uv2 && _texture_uv_set(tex) == 0)) ? (u2, v2) : (u, v)

@inline function _ambient_occlusion_factor(tex::Texture, u, v, intensity)
    occlusion = _sample_texture_unit_channel(tex, u, v, 1)
    return 1.0 + (occlusion - 1.0) * intensity
end

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
@inline _albedo_map_before_lighting(::AbstractMaterial) = false
@inline _albedo_map_before_lighting(::MeshPhongMaterial) = true
@inline _albedo_map_before_lighting(::MeshStandardMaterial) = true
@inline _albedo_map_before_lighting(::MeshPhysicalMaterial) = true
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
                 m.glossiness * _sample_texture_unit_channel(glossiness_map, u, v, 4)
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
                 m.glossiness * _sample_texture_unit_channel(glossiness_map, gu, gv, 4)
    return _phong_with_maps(m, specular, glossiness)
end

function _phong_mapped_terms(m::MeshPhongMaterial, specular_map, glossiness_map,
                             u, v, u2, v2)
    su, sv = specular_map === nothing ? (u, v) : _map_uv(specular_map, u, v, u2, v2)
    gu, gv = glossiness_map === nothing ? (u, v) : _map_uv(glossiness_map, u, v, u2, v2)
    specular = specular_map === nothing ? m.specular : begin
        s = sample_texture_linear(specular_map, su, sv)
        Color3(m.specular.r * s.r, m.specular.g * s.g, m.specular.b * s.b)
    end
    glossiness = glossiness_map === nothing ? m.glossiness :
                 m.glossiness * _sample_texture_unit_channel(glossiness_map, gu, gv, 4)
    return specular, _phong_shininess_from_glossiness(glossiness)
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
                         iridescence_thickness_min=m.iridescence_thickness_min,
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
    Color3(
        _mean3_scaled(d[b1+1], d[b2+1], d[b3+1]),
        _mean3_scaled(d[b1+2], d[b2+2], d[b3+2]),
        _mean3_scaled(d[b1+3], d[b2+3], d[b3+3]))
end

# Perturb a face normal by a tangent-space normal map. The tangent frame is
# derived from the triangle's world positions and UV gradients (standard
# tangent-from-UV), then the sampled normal `2·texel-1` is rotated into world.
function _normal_map_tangent_seed(p1::Vec3, p2::Vec3, p3::Vec3, uv1, uv2, uv3)
    e1 = p2 - p1; e2 = p3 - p1
    du1 = uv2[1]-uv1[1]; dv1 = uv2[2]-uv1[2]
    du2 = uv3[1]-uv1[1]; dv2 = uv3[2]-uv1[2]
    z = zero(e1.x + e1.y + e1.z + du1 + dv1 + du2 + dv2)
    fallback = Vec3(z, z, z)
    det = du1*dv2 - du2*dv1
    abs(det) < 1e-12 && return false, fallback, z
    r = 1.0 / det
    T = (e1*dv2 - e2*dv1) * r
    tl = norm(T); tl < 1e-12 && return false, fallback, z
    return true, T / tl, sign(det)
end

function _normal_map_tangent_seed(
        p1::Vec3{Float64}, p2::Vec3{Float64}, p3::Vec3{Float64},
        uv1::NTuple{2,Float64}, uv2::NTuple{2,Float64},
        uv3::NTuple{2,Float64})
    e1 = p2 - p1
    e2 = p3 - p1
    du1 = uv2[1] - uv1[1]
    dv1 = uv2[2] - uv1[2]
    du2 = uv3[1] - uv1[1]
    dv2 = uv3[2] - uv1[2]
    det = du1 * dv2 - du2 * dv1
    fallback = Vec3(0.0, 0.0, 0.0)
    if isfinite(det) && abs(det) >= 1e-12
        tangent = (e1 * dv2 - e2 * dv1) * (1.0 / det)
        tangent_length = norm(tangent)
        if isfinite(tangent_length) &&
           isfinite(tangent.x) && isfinite(tangent.y) &&
           isfinite(tangent.z) && tangent_length >= 1e-12
            return true, tangent / tangent_length, sign(det)
        end
    end

    # Extreme finite positions or UVs can overflow the ordinary determinant
    # and tangent products even when their normalized tangent is well-defined.
    # Retain each product as a mantissa and binary exponent until the final
    # unit direction is formed.
    edge1 = _float_vector_difference(p1, p2)
    edge2 = _float_vector_difference(p1, p3)
    du1_rep = _float_difference_representation(uv1[1], uv2[1])
    dv1_rep = _float_difference_representation(uv1[2], uv2[2])
    du2_rep = _float_difference_representation(uv1[1], uv3[1])
    dv2_rep = _float_difference_representation(uv1[2], uv3[2])
    determinant = _float_representation_add(
        _float_representation_multiply(du1_rep, dv2_rep),
        _float_representation_negate(
            _float_representation_multiply(du2_rep, dv1_rep)),
    )
    determinant.nonzero ||
        return false, fallback, 0.0
    determinant_value = _float_representation_value(determinant)
    abs(determinant_value) < 1e-12 &&
        return false, fallback, 0.0

    tangent = ntuple(3) do axis
        _float_representation_add(
            _float_representation_multiply(edge1[axis], dv2_rep),
            _float_representation_negate(
                _float_representation_multiply(edge2[axis], dv1_rep)),
        )
    end
    tangent_exponent = typemin(Int)
    for component in tangent
        component.nonzero &&
            (tangent_exponent = max(
                tangent_exponent, component.exponent))
    end
    tangent_exponent == typemin(Int) &&
        return false, fallback, 0.0
    scaled_tangent = Vec3(
        tangent[1].nonzero ? ldexp(
            tangent[1].mantissa,
            tangent[1].exponent - tangent_exponent) : 0.0,
        tangent[2].nonzero ? ldexp(
            tangent[2].mantissa,
            tangent[2].exponent - tangent_exponent) : 0.0,
        tangent[3].nonzero ? ldexp(
            tangent[3].mantissa,
            tangent[3].exponent - tangent_exponent) : 0.0,
    )
    scaled_length = norm(scaled_tangent)
    tangent_length = ldexp(
        scaled_length / abs(determinant.mantissa),
        tangent_exponent - determinant.exponent)
    tangent_length < 1e-12 &&
        return false, fallback, 0.0
    handedness = sign(determinant.mantissa)
    return true,
           (scaled_tangent / scaled_length) * handedness,
           handedness
end

function _apply_normal_map_tangent_seed(face_n::Vec3, nmap, u, v, tangent::Vec3,
                                        handedness, normal_scale::Real=1.0)
    T = tangent - face_n * dot(face_n, tangent)       # Gram-Schmidt orthonormalize
    tl2 = norm(T); tl2 < 1e-12 && return face_n
    T = T / tl2
    # Bitangent handedness follows the UV winding (sign of det), matching three.js
    # getTangentFrame; otherwise mirrored UVs perturb the normal the wrong way.
    B = cross(face_n, T) * handedness
    s = sample_texture(nmap, u, v)
    ns = Float64(normal_scale)
    tn = Vec3((s.r*2 - 1) * ns, (s.g*2 - 1) * ns, s.b*2 - 1)
    return normalize(T*tn.x + B*tn.y + face_n*tn.z)
end

function _apply_normal_map(face_n::Vec3, nmap, u, v, p1::Vec3, p2::Vec3, p3::Vec3,
                           uv1, uv2, uv3, normal_scale::Real=1.0)
    ok, tangent, handedness = _normal_map_tangent_seed(p1, p2, p3, uv1, uv2, uv3)
    ok || return face_n
    return _apply_normal_map_tangent_seed(face_n, nmap, u, v, tangent, handedness,
                                          normal_scale)
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
    roughness = roughness_map === nothing ? m.roughness :
                m.roughness * _sample_texture_unit_channel(roughness_map, u, v, 2)
    metalness = metalness_map === nothing ? m.metalness :
                m.metalness * _sample_texture_unit_channel(metalness_map, u, v, 3)
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
    roughness = roughness_map === nothing ? m.roughness :
                m.roughness * _sample_texture_unit_channel(roughness_map, ru, rv, 2)
    metalness = metalness_map === nothing ? m.metalness :
                m.metalness * _sample_texture_unit_channel(metalness_map, mu, mv, 3)
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
function _standard_mapped_terms(m::MeshStandardMaterial, roughness_map, metalness_map,
                                u, v, u2, v2)
    ru, rv = roughness_map === nothing ? (u, v) : _map_uv(roughness_map, u, v, u2, v2)
    mu, mv = metalness_map === nothing ? (u, v) : _map_uv(metalness_map, u, v, u2, v2)
    roughness = roughness_map === nothing ? Float64(m.roughness) :
                m.roughness * _sample_texture_unit_channel(roughness_map, ru, rv, 2)
    metalness = metalness_map === nothing ? Float64(m.metalness) :
                m.metalness * _sample_texture_unit_channel(metalness_map, mu, mv, 3)
    return metalness, roughness
end
@inline function _mapped_iridescence_thickness(m::MeshPhysicalMaterial,u,v)
    m.iridescence_thickness_map === nothing && return m.iridescence_thickness
    sample = _sample_texture_unit_channel(m.iridescence_thickness_map,u,v,2)
    return _stable_lerp(m.iridescence_thickness_min,m.iridescence_thickness,sample)
end

function _apply_pbr_maps(m::MeshPhysicalMaterial, roughness_map, metalness_map, u, v)
    roughness = roughness_map === nothing ? m.roughness :
                m.roughness * _sample_texture_unit_channel(roughness_map, u, v, 2)
    metalness = metalness_map === nothing ? m.metalness :
                m.metalness * _sample_texture_unit_channel(metalness_map, u, v, 3)
    clearcoat = m.clearcoat_map === nothing ? m.clearcoat : m.clearcoat * _sample_texture_unit_channel(m.clearcoat_map, u, v, 1)
    clearcoat_roughness = m.clearcoat_roughness_map === nothing ? m.clearcoat_roughness : m.clearcoat_roughness * _sample_texture_unit_channel(m.clearcoat_roughness_map, u, v, 2)
    transmission = m.transmission_map === nothing ? m.transmission : m.transmission * _sample_texture_unit_channel(m.transmission_map, u, v, 1)
    thickness = m.thickness_map === nothing ? m.thickness : m.thickness * _sample_texture_unit_channel(m.thickness_map, u, v, 2)
    sheen_color = m.sheen_color_map === nothing ? m.sheen_color : begin
        c = sample_texture_linear(m.sheen_color_map, u, v)
        Color3(m.sheen_color.r * c.r, m.sheen_color.g * c.g, m.sheen_color.b * c.b)
    end
    sheen_roughness = m.sheen_roughness_map === nothing ? m.sheen_roughness : m.sheen_roughness * _sample_texture_unit_channel(m.sheen_roughness_map, u, v, 4)
    iridescence = m.iridescence_map === nothing ? m.iridescence : m.iridescence * _sample_texture_unit_channel(m.iridescence_map, u, v, 1)
    iridescence_thickness = _mapped_iridescence_thickness(m,u,v)
    specular_intensity = m.specular_intensity_map === nothing ? m.specular_intensity : m.specular_intensity * _sample_texture_unit_channel(m.specular_intensity_map, u, v, 4)
    specular_color = m.specular_color_map === nothing ? m.specular_color : begin
        c = sample_texture_linear(m.specular_color_map, u, v)
        Color3(m.specular_color.r * c.r, m.specular_color.g * c.g, m.specular_color.b * c.b)
    end
    anisotropy = m.anisotropy_map === nothing ? m.anisotropy : m.anisotropy * _sample_texture_unit_channel(m.anisotropy_map, u, v, 3)
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
                          iridescence_thickness=iridescence_thickness,
                         iridescence_thickness_min=m.iridescence_thickness_min, light_map=m.light_map,
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
    roughness = roughness_map === nothing ? m.roughness :
                m.roughness * _sample_texture_unit_channel(roughness_map, ru, rv, 2)
    metalness = metalness_map === nothing ? m.metalness :
                m.metalness * _sample_texture_unit_channel(metalness_map, mu, mv, 3)
    clearcoat = m.clearcoat_map === nothing ? m.clearcoat : m.clearcoat * _sample_texture_unit_channel(m.clearcoat_map, cu, cv, 1)
    clearcoat_roughness = m.clearcoat_roughness_map === nothing ? m.clearcoat_roughness : m.clearcoat_roughness * _sample_texture_unit_channel(m.clearcoat_roughness_map, cru, crv, 2)
    transmission = m.transmission_map === nothing ? m.transmission : m.transmission * _sample_texture_unit_channel(m.transmission_map, tu, tv, 1)
    thickness = m.thickness_map === nothing ? m.thickness : m.thickness * _sample_texture_unit_channel(m.thickness_map, thu, thv, 2)
    sheen_color = m.sheen_color_map === nothing ? m.sheen_color : begin
        c = sample_texture_linear(m.sheen_color_map, scu, scv)
        Color3(m.sheen_color.r * c.r, m.sheen_color.g * c.g, m.sheen_color.b * c.b)
    end
    sheen_roughness = m.sheen_roughness_map === nothing ? m.sheen_roughness : m.sheen_roughness * _sample_texture_unit_channel(m.sheen_roughness_map, sru, srv, 4)
    iridescence = m.iridescence_map === nothing ? m.iridescence : m.iridescence * _sample_texture_unit_channel(m.iridescence_map, iu, iv, 1)
    iridescence_thickness = _mapped_iridescence_thickness(m,itu,itv)
    specular_intensity = m.specular_intensity_map === nothing ? m.specular_intensity : m.specular_intensity * _sample_texture_unit_channel(m.specular_intensity_map, siu, siv, 4)
    specular_color = m.specular_color_map === nothing ? m.specular_color : begin
        c = sample_texture_linear(m.specular_color_map, spcu, spcv)
        Color3(m.specular_color.r * c.r, m.specular_color.g * c.g, m.specular_color.b * c.b)
    end
    anisotropy = m.anisotropy_map === nothing ? m.anisotropy : m.anisotropy * _sample_texture_unit_channel(m.anisotropy_map, au, av, 3)
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
                         iridescence_thickness=iridescence_thickness,
                         iridescence_thickness_min=m.iridescence_thickness_min, light_map=m.light_map,
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

# MeshPhysicalMaterial scalars after their texture maps (or the material's own
# values, see `_physical_terms`).
struct _PhysicalMappedTerms
    metalness::Float64
    roughness::Float64
    clearcoat::Float64
    clearcoat_roughness::Float64
    transmission::Float64
    thickness::Float64
    sheen_color::Color3{Float64}
    sheen_roughness::Float64
    iridescence::Float64
    iridescence_thickness::Float64
    specular_intensity::Float64
    specular_color::Color3{Float64}
    anisotropy::Float64
end

const _PHYSICAL_MAPPED_TERMS_ZERO =
    _PhysicalMappedTerms(0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                         Color3(0.0, 0.0, 0.0), 0.0, 0.0, 0.0,
                         0.0, Color3(0.0, 0.0, 0.0), 0.0)

function _physical_mapped_terms(m::MeshPhysicalMaterial, roughness_map,
                                metalness_map, u, v, u2, v2)
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
    roughness = roughness_map === nothing ? m.roughness :
                m.roughness * _sample_texture_unit_channel(roughness_map, ru, rv, 2)
    metalness = metalness_map === nothing ? m.metalness :
                m.metalness * _sample_texture_unit_channel(metalness_map, mu, mv, 3)
    clearcoat = m.clearcoat_map === nothing ? m.clearcoat : m.clearcoat * _sample_texture_unit_channel(m.clearcoat_map, cu, cv, 1)
    clearcoat_roughness = m.clearcoat_roughness_map === nothing ? m.clearcoat_roughness : m.clearcoat_roughness * _sample_texture_unit_channel(m.clearcoat_roughness_map, cru, crv, 2)
    transmission = m.transmission_map === nothing ? m.transmission : m.transmission * _sample_texture_unit_channel(m.transmission_map, tu, tv, 1)
    thickness = m.thickness_map === nothing ? m.thickness : m.thickness * _sample_texture_unit_channel(m.thickness_map, thu, thv, 2)
    sheen_color = m.sheen_color_map === nothing ? m.sheen_color : begin
        c = sample_texture_linear(m.sheen_color_map, scu, scv)
        Color3(m.sheen_color.r * c.r, m.sheen_color.g * c.g, m.sheen_color.b * c.b)
    end
    sheen_roughness = m.sheen_roughness_map === nothing ? m.sheen_roughness : m.sheen_roughness * _sample_texture_unit_channel(m.sheen_roughness_map, sru, srv, 4)
    iridescence = m.iridescence_map === nothing ? m.iridescence : m.iridescence * _sample_texture_unit_channel(m.iridescence_map, iu, iv, 1)
    iridescence_thickness = _mapped_iridescence_thickness(m,itu,itv)
    specular_intensity = m.specular_intensity_map === nothing ? m.specular_intensity : m.specular_intensity * _sample_texture_unit_channel(m.specular_intensity_map, siu, siv, 4)
    specular_color = m.specular_color_map === nothing ? m.specular_color : begin
        c = sample_texture_linear(m.specular_color_map, spcu, spcv)
        Color3(m.specular_color.r * c.r, m.specular_color.g * c.g, m.specular_color.b * c.b)
    end
    anisotropy = m.anisotropy_map === nothing ? m.anisotropy : m.anisotropy * _sample_texture_unit_channel(m.anisotropy_map, au, av, 3)
    return _PhysicalMappedTerms(Float64(metalness), Float64(roughness),
                                Float64(clearcoat), Float64(clearcoat_roughness),
                                Float64(transmission), Float64(thickness),
                                sheen_color, Float64(sheen_roughness),
                                Float64(iridescence),
                                Float64(iridescence_thickness),
                                Float64(specular_intensity), specular_color,
                                Float64(anisotropy))
end
_apply_pbr_maps(m::AbstractMaterial, roughness_map, metalness_map, u, v) = m
_apply_pbr_maps(m::AbstractMaterial, roughness_map, metalness_map, u, v, u2, v2) = m
_apply_roughness_map(m::AbstractMaterial, rmap, u, v) = _apply_pbr_maps(m, rmap, nothing, u, v)

struct _DirectLightView{L}
    lights::L
end

function Base.iterate(view::_DirectLightView, state::Int=1)
    while state <= length(view.lights)
        light = @inbounds view.lights[state]
        state += 1
        _is_fill_light(light) || return light, state
    end
    return nothing
end

@inline function _apply_indirect_ao(total::Color3, direct::Color3, ao)
    return Color3(
        direct.r + (total.r - direct.r) * ao,
        direct.g + (total.g - direct.g) * ao,
        direct.b + (total.b - direct.b) * ao,
    )
end

@inline function _shade_face_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material, lights, camera_view, shadow_fn)
    return shade_face(
        normal, view_dir, position, material, lights;
        shadow_fn=shadow_fn)
end

@inline function _shade_face_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshMatcapMaterial, lights, camera_view, shadow_fn)
    return _shade_matcap_face(
        normal, view_dir, material, camera_view)
end

@inline function _shade_face_vertex_color_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material, lights, vertex_color::Color3, camera_view, shadow_fn)
    return _shade_face_vertex_color(
        normal, view_dir, position, material, lights, vertex_color;
        shadow_fn=shadow_fn)
end

# Forms taking three.js `clearcoatNormal` `ccn`, which only a
# MeshPhysicalMaterial reads (its clearcoat lobe and layering).
@inline _shade_face_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material, lights, camera_view, shadow_fn, ccn::Vec3) =
    _shade_face_with_camera_view(normal, view_dir, position, material, lights,
                                 camera_view, shadow_fn)
@inline _shade_face_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshPhysicalMaterial, lights, camera_view, shadow_fn,
        ccn::Vec3) =
    _shade_lit(material, normal, view_dir, position, lights, shadow_fn, ccn)
@inline _shade_face_vertex_color_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material, lights, vertex_color::Color3, camera_view, shadow_fn,
        ccn::Vec3) =
    _shade_face_vertex_color_with_camera_view(normal, view_dir, position,
                                              material, lights, vertex_color,
                                              camera_view, shadow_fn)
@inline _shade_face_vertex_color_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshPhysicalMaterial, lights, vertex_color::Color3,
        camera_view, shadow_fn, ccn::Vec3) =
    _shade_lit_vertex_color(material, normal, view_dir, position, lights,
                            shadow_fn, vertex_color, ccn)

@inline function _shade_face_vertex_color_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshMatcapMaterial, lights, vertex_color::Color3,
        camera_view, shadow_fn)
    return _shade_matcap_face(
        normal, view_dir, material, camera_view)
end

function _shade_mapped_lighting(
        face_n, view_dir, center, material, lights, shadow_fn,
        mapped_kind::Int, use_surface_color::Bool, surface_color,
        eff_mat, phong_specular, phong_shininess,
        standard_metalness, standard_roughness, physical_terms,
        camera_view, ccn::Vec3=face_n)
    if mapped_kind == 1
        return use_surface_color ?
            _shade_phong_mapped_vertex_color(
                face_n, view_dir, center, material, lights, shadow_fn,
                phong_specular, phong_shininess, surface_color) :
            _shade_phong_mapped(
                face_n, view_dir, center, material, lights, shadow_fn,
                phong_specular, phong_shininess)
    elseif mapped_kind == 2
        return use_surface_color ?
            _shade_standard_mapped_vertex_color(
                face_n, view_dir, center, material, lights, shadow_fn,
                standard_metalness, standard_roughness, surface_color) :
            _shade_standard_mapped(
                face_n, view_dir, center, material, lights, shadow_fn,
                standard_metalness, standard_roughness)
    elseif mapped_kind == 3
        return use_surface_color ?
            _shade_physical_mapped_vertex_color(
                face_n, view_dir, center, material, lights, shadow_fn,
                physical_terms, surface_color, ccn) :
            _shade_physical_mapped(
                face_n, view_dir, center, material, lights, shadow_fn,
                physical_terms, ccn)
    elseif use_surface_color
        return _shade_face_vertex_color_with_camera_view(
            face_n, view_dir, center, eff_mat, lights, surface_color,
            camera_view, shadow_fn, ccn)
    end
    return _shade_face_with_camera_view(
        face_n, view_dir, center, eff_mat, lights,
        camera_view, shadow_fn, ccn)
end

# The clearcoat layering factor `_PBRSurface.layer` the emission of `material`
# receives, for its (possibly mapped) clearcoat weight `clearcoat`.
@inline _emission_layer(material, clearcoat, ccn::Vec3, view_dir::Vec3) = 1.0
@inline _emission_layer(material::MeshPhysicalMaterial, clearcoat, ccn::Vec3,
                        view_dir::Vec3) =
    _clearcoat_layer(clearcoat, _saturate(dot(ccn, view_dir)))

# A MeshPhysicalMaterial's clearcoat normal map, when one applies.
@inline _clearcoat_normal_map(material) = nothing
@inline _clearcoat_normal_map(material::MeshPhysicalMaterial) =
    material.clearcoat > 0 && material.clearcoat_normal_map isa Texture ?
        material.clearcoat_normal_map : nothing

function _mapped_environment_contribution(
        env_map, normal, view_dir, material, eff_mat,
        mapped_kind::Int, use_surface_color::Bool, surface_color,
        standard_metalness, standard_roughness, physical_terms)
    env_map === nothing && return Color3(0.0, 0.0, 0.0)
    env_albedo = use_surface_color ?
        _modulate(material.color, surface_color) : eff_mat.color
    if mapped_kind == 2
        return _envmap_reflection(
            env_map, normal, view_dir, env_albedo,
            standard_metalness, standard_roughness) *
            material.env_map_intensity
    elseif mapped_kind == 3
        return _envmap_reflection(
            env_map, normal, view_dir, env_albedo,
            physical_terms.metalness,
            _physical_mapped_roughness(physical_terms)) *
            material.env_map_intensity
    end
    return _envmap_reflection(
        env_map, normal, view_dir, env_albedo,
        eff_mat.metalness, eff_mat.roughness) *
        _material_scalar(eff_mat, :env_map_intensity)
end

function _shade_depth_faces!(colors::Vector{Color3{Float64}},
                             geo::BufferGeometry, modelview::Mat4,
                             material::MeshDepthMaterial)
    _validate_depth_material(material)
    length(colors) == geo.n_faces || resize!(colors, geo.n_faces)
    inverse_range = 1.0 / (material.far - material.near)
    @inbounds for face in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, face)
        v1 = mat4_transform_point(modelview, get_vertex(geo, i1))
        v2 = mat4_transform_point(modelview, get_vertex(geo, i2))
        v3 = mat4_transform_point(modelview, get_vertex(geo, i3))
        view_depth = -_mean3_scaled(v1.z, v2.z, v3.z)
        depth = clamp(
            (view_depth - material.near) * inverse_range, 0.0, 1.0)
        colors[face] = _depth_material_color(material, depth)
    end
    return colors
end

@inline function _depth_face_modelview(world_mat::Mat4, cam_pos::Vec3,
                                       camera_view)
    view = camera_view === nothing ?
           mat4_translation(-cam_pos.x, -cam_pos.y, -cam_pos.z) :
           camera_view
    return view * world_mat
end

# Face visibility follows transformed geometric winding, while lighting keeps
# authored (or fallback) normals. The winding result is shared by culling and by
# two-sided normal orientation so the two policies cannot drift apart.
@inline function _face_front_facing(v1::Vec3, v2::Vec3, v3::Vec3,
                                    center::Vec3, cam_pos::Vec3, ortho_dir)
    geometric_normal = triangle_normal(Triangle(v1, v2, v3))
    view_direction = ortho_dir === nothing ?
        _direction_between(center, cam_pos) : ortho_dir
    return dot(geometric_normal, view_direction) > 0
end

@inline function _side_oriented_normal(normal::Vec3, side::Symbol,
                                       front_facing::Bool)
    return !front_facing && side !== :front ? -normal : normal
end

function shade_mesh_faces(geo::BufferGeometry, world_mat::Mat4,
                          material::AbstractMaterial,
                          lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                          shadow_fn=nothing,
                          camera_view::Union{Nothing,Mat4}=nothing,
                          ortho_dir=nothing)
    # Validate before allocating; malformed counts or backing buffers must not
    # drive an oversized result allocation.
    _validate_triangle_geometry_indices(geo, "shade_mesh_faces")
    _validate_depth_material(material)
    _validate_material_parameters(material)
    return _shade_mesh_faces_dispatch!(
        Vector{Color3{Float64}}(undef, geo.n_faces), geo, world_mat,
                                       material, lights, cam_pos;
                                       shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir)
end

function shade_mesh_faces(geo::BufferGeometry, world_mat::Mat4,
                          material::MeshDepthMaterial,
                          lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                          shadow_fn=nothing,
                          camera_view::Union{Nothing,Mat4}=nothing,
                          ortho_dir=nothing)
    _validate_triangle_geometry_indices(geo, "shade_mesh_faces")
    _validate_depth_material(material)
    _validate_material_parameters(material)
    return _shade_depth_faces!(
        Vector{Color3{Float64}}(undef, geo.n_faces), geo,
        _depth_face_modelview(world_mat, cam_pos, camera_view), material)
end

function _shade_mesh_faces_fast!(colors::Vector{Color3{Float64}},
                                 geo::BufferGeometry, world_mat::Mat4, material,
                                 lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                                 normal_mat::Mat4, has_normals::Bool,
                                 side::Symbol, face_flip::Bool; shadow_fn=nothing,
                                 camera_view=nothing,
                                 ortho_dir=nothing)
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
        v2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
        v3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
        center = _mean3_vec3(v1, v2, v3)

        if material isa MeshDepthMaterial
            d = norm(cam_pos - center)
            depth = clamp((d - material.near) / max(material.far - material.near, 1e-9), 0.0, 1.0)
            colors[fi] = _depth_material_color(material, depth)
            continue
        end

        face_n = _flat_face_normal(
            geo, i1, i2, i3, v1, v2, v3, normal_mat, has_normals)
        if side !== :front
            front_facing = _face_front_facing(
                v1, v2, v3, center, cam_pos, ortho_dir) != face_flip
            face_n = _side_oriented_normal(face_n, side, front_facing)
        end
        view_dir = _direction_between(center, cam_pos)
        color = _shade_face_with_camera_view(
            face_n, view_dir, center, material, lights,
            camera_view, shadow_fn)
        colors[fi] = clamp_color(color)
    end
    return colors
end

# In-place variant: writes one colour per face into `colors` (resized to fit),
# so a caller can reuse the buffer across frames/meshes (bounded allocation).
const _EMPTY_SCENE_LIGHTS = SceneLight[]

function _builtin_scene_lights_or_nothing(lights::Vector{AbstractLight})
    @inbounds for i in eachindex(lights)
        lights[i] isa SceneLight || return nothing
    end
    scene_lights = Vector{SceneLight}(undef, length(lights))
    @inbounds for i in eachindex(lights)
        scene_lights[i] = lights[i]::SceneLight
    end
    return scene_lights
end

_single_light_vector(light::T) where {T<:AbstractLight} = T[light]

function _shade_mesh_faces_dispatch!(colors::Vector{Color3{Float64}},
                                     geo::BufferGeometry, world_mat::Mat4,
                                     material::AbstractMaterial,
                                     lights::Vector{AbstractLight}, cam_pos::Vec3;
                                     shadow_fn=nothing, camera_view=nothing,
                                     ortho_dir=nothing,
                                     face_flip::Union{Nothing,Bool}=nothing)
    if !(material isa LitMaterial)
        return _shade_mesh_faces_impl!(colors, geo, world_mat, material, lights,
                                       cam_pos; shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir, face_flip=face_flip)
    end
    length(lights) == 0 &&
        return _shade_mesh_faces_impl!(colors, geo, world_mat, material, _EMPTY_SCENE_LIGHTS,
                                       cam_pos; shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir, face_flip=face_flip)
    length(lights) == 1 && !(lights[1] isa SceneLight) &&
        return _shade_mesh_faces_impl!(colors, geo, world_mat, material,
                                       _single_light_vector(lights[1]),
                                       cam_pos; shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir, face_flip=face_flip)
    scene_lights = _builtin_scene_lights_or_nothing(lights)
    scene_lights === nothing ||
        return _shade_mesh_faces_impl!(colors, geo, world_mat, material, scene_lights,
                                       cam_pos; shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir, face_flip=face_flip)
    return _shade_mesh_faces_impl!(colors, geo, world_mat, material, lights, cam_pos;
                                   shadow_fn=shadow_fn,
                                   camera_view=camera_view,
                                   ortho_dir=ortho_dir, face_flip=face_flip)
end

function _shade_mesh_faces_dispatch!(colors::Vector{Color3{Float64}},
                                     geo::BufferGeometry, world_mat::Mat4,
                                     material::AbstractMaterial,
                                     lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                                     shadow_fn=nothing, camera_view=nothing,
                                     ortho_dir=nothing,
                                     face_flip::Union{Nothing,Bool}=nothing)
    return _shade_mesh_faces_impl!(colors, geo, world_mat, material, lights, cam_pos;
                                   shadow_fn=shadow_fn,
                                   camera_view=camera_view,
                                   ortho_dir=ortho_dir, face_flip=face_flip)
end

function shade_mesh_faces!(colors::Vector{Color3{Float64}},
                           geo::BufferGeometry, world_mat::Mat4,
                           material::AbstractMaterial,
                           lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                           shadow_fn=nothing,
                           camera_view::Union{Nothing,Mat4}=nothing,
                           ortho_dir=nothing)
    _validate_triangle_geometry_indices(geo, "shade_mesh_faces")
    _validate_depth_material(material)
    _validate_material_parameters(material)
    return _shade_mesh_faces_dispatch!(colors, geo, world_mat,
                                       material, lights, cam_pos;
                                       shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir)
end


function shade_mesh_faces!(colors::Vector{Color3{Float64}},
                           geo::BufferGeometry, world_mat::Mat4,
                           material::MeshDepthMaterial,
                           lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                           shadow_fn=nothing,
                           camera_view::Union{Nothing,Mat4}=nothing,
                           ortho_dir=nothing)
    _validate_triangle_geometry_indices(geo, "shade_mesh_faces")
    _validate_depth_material(material)
    _validate_material_parameters(material)
    return _shade_depth_faces!(
        colors, geo,
        _depth_face_modelview(world_mat, cam_pos, camera_view), material)
end

# `shade_mesh_faces!` with the front-face flip of the object matrix supplied by
# the caller. The renderers use it for InstancedMesh draws, where `world_mat`
# includes an instance matrix but three.js flips front faces only for a mirrored
# object matrix (WebGLRenderer.js `frontFaceCW`).
function _shade_mesh_faces_flip!(colors::Vector{Color3{Float64}},
                                 geo::BufferGeometry, world_mat::Mat4,
                                 material::AbstractMaterial,
                                 lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                                 face_flip::Bool; shadow_fn=nothing,
                                 camera_view::Union{Nothing,Mat4}=nothing,
                                 ortho_dir=nothing)
    _validate_triangle_geometry_indices(geo, "shade_mesh_faces")
    _validate_depth_material(material)
    _validate_material_parameters(material)
    return _shade_mesh_faces_dispatch!(colors, geo, world_mat,
                                       material, lights, cam_pos;
                                       shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir,
                                       face_flip=face_flip)
end

_shade_mesh_faces_flip!(colors::Vector{Color3{Float64}}, geo::BufferGeometry,
                        world_mat::Mat4, material::MeshDepthMaterial,
                        lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                        ::Bool; shadow_fn=nothing,
                        camera_view::Union{Nothing,Mat4}=nothing,
                        ortho_dir=nothing) =
    shade_mesh_faces!(colors, geo, world_mat, material, lights, cam_pos;
                      shadow_fn=shadow_fn, camera_view=camera_view,
                      ortho_dir=ortho_dir)

function _shade_mesh_faces_impl!(colors::Vector{Color3{Float64}},
                                 geo::BufferGeometry, world_mat::Mat4,
                                 material::AbstractMaterial,
                                 lights::Vector{<:AbstractLight}, cam_pos::Vec3;
                                 shadow_fn=nothing, camera_view=nothing,
                                 ortho_dir=nothing,
                                 face_flip::Union{Nothing,Bool}=nothing)
    n_faces = geo.n_faces
    length(colors) == n_faces || resize!(colors, n_faces)
    # Front faces follow three.js frontFaceCW: flipped when the object matrix
    # mirrors space. Callers drawing an InstancedMesh pass the flip of its
    # object matrix, because instance matrices do not flip the front face.
    flip = face_flip === nothing ? _world_mirrors_faces(world_mat) : face_flip

    # Normal matrix (transpose of inverse) for transforming normals to world space.
    normal_mat = mat4_transpose(mat4_inverse(world_mat))
    side = material_side(material)
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
    clearcoat_normal_map = _clearcoat_normal_map(material)
    use_maps = has_uvs && (albedo_map !== nothing || ao_map !== nothing || emissive_map !== nothing ||
                           normal_map !== nothing || roughness_map !== nothing || metalness_map !== nothing ||
                           specular_map !== nothing || glossiness_map !== nothing ||
                           physical_pbr_map !== nothing || light_map !== nothing ||
                           clearcoat_normal_map !== nothing)
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
                                       normal_mat, has_normals, side, flip;
                                       shadow_fn=shadow_fn,
                                       camera_view=camera_view,
                                       ortho_dir=ortho_dir)
    end

    if use_maps && albedo_map isa Texture && ao_map === nothing &&
       emissive_map === nothing && normal_map === nothing &&
       roughness_map === nothing && metalness_map === nothing &&
       specular_map === nothing && glossiness_map === nothing &&
       physical_pbr_map === nothing && light_map === nothing &&
       clearcoat_normal_map === nothing &&
       !use_vertex_colors && env_map === nothing
        return _shade_mesh_faces_mapped!(colors, geo, world_mat, material, lights, cam_pos,
                                         normal_mat, has_normals, side, flip, true,
                                         albedo_map, nothing, nothing, nothing,
                                         normal_scale, nothing, nothing, nothing,
                                         nothing, nothing, nothing, uv2_attr,
                                         nothing, false, nothing;
                                         shadow_fn=shadow_fn,
                                         camera_view=camera_view,
                                         ortho_dir=ortho_dir)
    end

    return _shade_mesh_faces_mapped!(colors, geo, world_mat, material, lights, cam_pos,
                                     normal_mat, has_normals, side, flip, use_maps,
                                     albedo_map, ao_map, emissive_map, normal_map,
                                     normal_scale, roughness_map, metalness_map,
                                     specular_map, glossiness_map, physical_pbr_map,
                                     light_map, uv2_attr, color_attr,
                                     use_vertex_colors, env_map;
                                     shadow_fn=shadow_fn,
                                     camera_view=camera_view,
                                     ortho_dir=ortho_dir)
end

function _shade_mesh_faces_mapped!(colors::Vector{Color3{Float64}},
                                   geo::BufferGeometry, world_mat::Mat4,
                                   material::AbstractMaterial,
                                   lights::Vector{<:AbstractLight}, cam_pos::Vec3,
                                   normal_mat::Mat4, has_normals::Bool,
                                   side::Symbol, face_flip::Bool,
                                   use_maps::Bool, albedo_map, ao_map,
                                   emissive_map, normal_map,
                                   normal_scale::Float64, roughness_map,
                                   metalness_map, specular_map, glossiness_map,
                                   physical_pbr_map, light_map, uv2_attr,
                                   color_attr, use_vertex_colors::Bool,
                                   env_map; shadow_fn=nothing,
                                   camera_view=nothing,
                                   ortho_dir=nothing)
    n_faces = geo.n_faces
    for fi in 1:n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
        v2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
        v3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
        center = _mean3_vec3(v1, v2, v3)

        if material isa MeshDepthMaterial
            d = norm(cam_pos - center)
            depth = clamp((d - material.near) / max(material.far - material.near, 1e-9), 0.0, 1.0)
            colors[fi] = _depth_material_color(material, depth)
            continue
        end

        face_n = _flat_face_normal(
            geo, i1, i2, i3, v1, v2, v3, normal_mat, has_normals)
        if side !== :front
            front_facing = _face_front_facing(
                v1, v2, v3, center, cam_pos, ortho_dir) != face_flip
            face_n = _side_oriented_normal(face_n, side, front_facing)
        end
        view_dir = _direction_between(center, cam_pos)
        eff_mat = material
        mapped_kind = 0
        phong_specular = Color3(0.0, 0.0, 0.0)
        phong_shininess = 0.0
        standard_metalness = 0.0
        standard_roughness = 0.0
        physical_terms = _PHYSICAL_MAPPED_TERMS_ZERO
        vertex_color = Color3(1.0, 1.0, 1.0)
        use_vertex_colors &&
            (vertex_color = _face_vertex_color(color_attr, i1, i2, i3))
        surface_color = vertex_color
        base_albedo_map = false
        # three.js clearcoatNormal: the normal before normalMap perturbation,
        # replaced by the clearcoatNormalMap one when that map is set.
        clearcoat_n = face_n

        # normalMap perturbs the shading normal and roughnessMap overrides the
        # material roughness before shading. Phong/PBR albedo also belongs in
        # the base-color input so it does not erase independently-owned
        # specular response.
        if use_maps
            u, v = _face_centroid_uv(geo, i1, i2, i3)
            u2, v2uv = uv2_attr === nothing ? (u, v) : _face_centroid_uv_attr(uv2_attr, i1, i2, i3)
            base_albedo_map = albedo_map !== nothing &&
                              _albedo_map_before_lighting(material)
            if base_albedo_map
                au, av = _map_uv(albedo_map, u, v, u2, v2uv)
                surface_color = _modulate(
                    surface_color,
                    sample_texture_linear(albedo_map, au, av))
            end
            if normal_map !== nothing
                nu, nv = _map_uv(normal_map, u, v, u2, v2uv)
                normal_uvs = _texture_uv_set(normal_map) == 1 && uv2_attr !== nothing ?
                    (_vertex_uv_attr(uv2_attr, i1), _vertex_uv_attr(uv2_attr, i2), _vertex_uv_attr(uv2_attr, i3)) :
                    (_vertex_uv(geo, i1), _vertex_uv(geo, i2), _vertex_uv(geo, i3))
                face_n = _apply_normal_map(face_n, normal_map, nu, nv, v1, v2, v3,
                                           normal_uvs[1], normal_uvs[2], normal_uvs[3],
                                           normal_scale)
            end
            clearcoat_map = _clearcoat_normal_map(material)
            if clearcoat_map !== nothing
                cu, cv = _map_uv(clearcoat_map, u, v, u2, v2uv)
                clearcoat_uvs = _texture_uv_set(clearcoat_map) == 1 && uv2_attr !== nothing ?
                    (_vertex_uv_attr(uv2_attr, i1), _vertex_uv_attr(uv2_attr, i2), _vertex_uv_attr(uv2_attr, i3)) :
                    (_vertex_uv(geo, i1), _vertex_uv(geo, i2), _vertex_uv(geo, i3))
                clearcoat_n = _apply_normal_map(clearcoat_n, clearcoat_map, cu, cv,
                                                v1, v2, v3, clearcoat_uvs[1],
                                                clearcoat_uvs[2], clearcoat_uvs[3],
                                                material.clearcoat_normal_scale)
            end
            if material isa MeshPhongMaterial &&
               (specular_map !== nothing || glossiness_map !== nothing)
                phong_specular, phong_shininess =
                    _phong_mapped_terms(material, specular_map, glossiness_map,
                                        u, v, u2, v2uv)
                mapped_kind = 1
            elseif material isa MeshStandardMaterial &&
                   (roughness_map !== nothing || metalness_map !== nothing)
                standard_metalness, standard_roughness =
                    _standard_mapped_terms(material, roughness_map, metalness_map,
                                           u, v, u2, v2uv)
                mapped_kind = 2
            elseif material isa MeshPhysicalMaterial &&
                   (roughness_map !== nothing || metalness_map !== nothing ||
                    physical_pbr_map !== nothing)
                physical_terms = _physical_mapped_terms(material, roughness_map,
                                                        metalness_map, u, v, u2, v2uv)
                mapped_kind = 3
            elseif roughness_map !== nothing || metalness_map !== nothing || physical_pbr_map !== nothing
                eff_mat = _apply_pbr_maps(material, roughness_map, metalness_map, u, v, u2, v2uv)
            end
        end

        use_surface_color = use_vertex_colors || base_albedo_map
        color = _shade_mapped_lighting(
            face_n, view_dir, center, material, lights, shadow_fn,
            mapped_kind, use_surface_color, surface_color, eff_mat,
            phong_specular, phong_shininess, standard_metalness,
            standard_roughness, physical_terms, camera_view, clearcoat_n)
        direct_color = ao_map !== nothing && material isa LitMaterial ?
            _shade_mapped_lighting(
                face_n, view_dir, center, material,
                _DirectLightView(lights), shadow_fn,
                mapped_kind, use_surface_color, surface_color, eff_mat,
                phong_specular, phong_shininess, standard_metalness,
                standard_roughness, physical_terms, camera_view, clearcoat_n) :
            Color3(0.0, 0.0, 0.0)
        ao_factor = 1.0

        if use_maps
            u, v = _face_centroid_uv(geo, i1, i2, i3)
            u2, v2 = uv2_attr === nothing ? (u, v) : _face_centroid_uv_attr(uv2_attr, i1, i2, i3)
            # three.js keeps emission OUT of the diffuse map chain: remove the
            # base `emissive · intensity` added by `shade_face` before the
            # multiplicative maps below, and add the modulated form
            # `emissive · emissiveMap texel · intensity` back afterwards.
            em = _material_field(material, :emissive)
            emi = em === nothing ? 0.0 : _material_scalar(material, :emissive_intensity)
            # Emission sits under the clearcoat layer (meshphysical.glsl.js), as
            # `_emitted(::_PBRSurface, m)` added it.
            layer = _emission_layer(material,
                                    mapped_kind == 3 ? physical_terms.clearcoat :
                                    _material_scalar(material, :clearcoat, 0.0),
                                    clearcoat_n, view_dir)
            if em !== nothing
                color = Color3(color.r - em.r * emi * layer, color.g - em.g * emi * layer,
                               color.b - em.b * emi * layer)
                direct_color = Color3(
                    direct_color.r - em.r * emi * layer,
                    direct_color.g - em.g * emi * layer,
                    direct_color.b - em.b * emi * layer)
            end
            if albedo_map !== nothing && !base_albedo_map
                tu, tv = _map_uv(albedo_map, u, v, u2, v2)
                albedo = sample_texture_linear(albedo_map, tu, tv)
                color = color * albedo
                direct_color = direct_color * albedo
            end
            if ao_map !== nothing
                tu, tv = _map_uv(ao_map, u, v, u2, v2; default_uv2=true)
                aoi = _material_scalar(material, :ao_map_intensity)
                ao = _ambient_occlusion_factor(ao_map, tu, tv, aoi)
                ao_factor = ao
                color = _apply_indirect_ao(color, direct_color, ao)
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
                color = color + Color3(em.r * t.r * emi * layer, em.g * t.g * emi * layer,
                                       em.b * t.b * emi * layer)
            end
        end

        # Environment reflection is indirect, so AO attenuates it while direct
        # lighting and emission remain untouched.
        color = color + _mapped_environment_contribution(
            env_map, face_n, view_dir, material, eff_mat,
            mapped_kind, use_surface_color, surface_color,
            standard_metalness, standard_roughness, physical_terms) *
            ao_factor

        colors[fi] = clamp_color(color)
    end
    return colors
end

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshBasicMaterial, lights; shadow_fn=nothing)
    _validate_material_parameters(material)
    return material.color
end

# --------------------------------------------------------------------------
# Ambient / hemisphere lights are view-independent fill, not directional. They
# add uniform (hemisphere: normal-weighted) irradiance rather than an N·L term.
# `_is_fill_light` selects them; `_fill_color` returns the effective irradiance.
# --------------------------------------------------------------------------
@inline _is_fill_light(l::AbstractLight) =
    (l isa AmbientLight) || (l isa HemisphereLight) || (l isa LightProbe)

# Julia 1.9 does not reliably union-split iteration over the seven-member
# `SceneLight` union. Explicitly narrow each built-in light before entering a
# shading operation so its return value stays unboxed in per-fragment loops.
@inline function _dispatch_scene_light(f, light::SceneLight, args...)
    if light isa AmbientLight
        return f(light, args...)
    elseif light isa DirectionalLight
        return f(light, args...)
    elseif light isa PointLight
        return f(light, args...)
    elseif light isa SpotLight
        return f(light, args...)
    elseif light isa HemisphereLight
        return f(light, args...)
    elseif light isa RectAreaLight
        return f(light, args...)
    else
        return f(light::LightProbe, args...)
    end
end

function _fill_color(normal::Vec3, light::AmbientLight)
    _validate_light_parameters(light)
    return light.color * light.intensity
end
# three.js aims the sky hemisphere along the light's normalized world position.
@inline _hemisphere_direction(light::HemisphereLight) =
    normalize(_light_world_position(light))

function _fill_color(normal::Vec3, light::HemisphereLight)
    _validate_light_parameters(light)
    up = _hemisphere_direction(light)
    normal_up = dot(normal, up)
    w = clamp(normal_up * 0.5 + 0.5, zero(normal_up), one(normal_up))
    blended = Color3(light.color.r * w + light.ground_color.r * (1 - w),
                     light.color.g * w + light.ground_color.g * (1 - w),
                     light.color.b * w + light.ground_color.b * (1 - w))
    return blended * light.intensity
end

@inline function _light_probe_channel(
        dc::Float64, x::Float64, y::Float64, z::Float64,
        normal::Vec3{Float64})
    if !(isfinite(dc) && isfinite(x) && isfinite(y) && isfinite(z) &&
         isfinite(normal.x) && isfinite(normal.y) && isfinite(normal.z))
        value = dc + x * normal.x + y * normal.y + z * normal.z
        return max(value, 0.0)
    end
    result = _float_representation_sum4(
        _float_value_representation(dc),
        _float_representation_multiply(
            _float_value_representation(x),
            _float_value_representation(normal.x)),
        _float_representation_multiply(
            _float_value_representation(y),
            _float_value_representation(normal.y)),
        _float_representation_multiply(
            _float_value_representation(z),
            _float_value_representation(normal.z)),
    )
    return max(_float_representation_value(result), 0.0)
end

@inline function _light_probe_channel(
        dc::Float64, x::Float64, y::Float64, z::Float64,
        normal::Vec3)
    scale = max(max(abs(dc), abs(x)), max(abs(y), abs(z)))
    iszero(scale) &&
        return zero(normal.x + normal.y + normal.z)
    value = dc / scale +
            (x / scale) * normal.x +
            (y / scale) * normal.y +
            (z / scale) * normal.z
    return max(value, zero(value)) * scale
end

# Order-1 SH irradiance, clamped to non-negative per channel.
function _fill_color(normal::Vec3, light::LightProbe)
    _validate_light_parameters(light)
    c = light.coeffs
    Color3(
        _light_probe_channel(
            c[1].r, c[2].r, c[3].r, c[4].r, normal),
        _light_probe_channel(
            c[1].g, c[2].g, c[3].g, c[4].g, normal),
        _light_probe_channel(
            c[1].b, c[2].b, c[3].b, c[4].b, normal),
    ) * light.intensity
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

# --------------------------------------------------------------------------
# three.js r186 physically based direct lighting for MeshStandardMaterial and
# MeshPhysicalMaterial. The functions below mirror the GLSL in
# ShaderChunk/{common,lights_physical_pars_fragment,lights_physical_fragment,
# lights_fragment_begin,iridescence_fragment}.glsl.js and the clearcoat/sheen
# composition in ShaderLib/meshphysical.glsl.js.
# --------------------------------------------------------------------------

# three.js DFGLUTData.js: 16x16 RG half-float table of the split-sum scale and
# bias, indexed by (roughness, N·V), sampled with LinearFilter/ClampToEdge.
const _DFG_LUT_BITS = UInt16[
    0x30b5, 0x3ad1, 0x314c, 0x3a4d, 0x33d2, 0x391c, 0x35ef, 0x3828, 0x37f3, 0x36a6, 0x38d1, 0x3539, 0x3979, 0x3410, 0x39f8, 0x3252,
    0x3a53, 0x30f0, 0x3a94, 0x2fc9, 0x3abf, 0x2e35, 0x3ada, 0x2d05, 0x3ae8, 0x2c1f, 0x3aed, 0x2ae0, 0x3aea, 0x29d1, 0x3ae1, 0x28ff,
    0x3638, 0x38e4, 0x364a, 0x38ce, 0x3699, 0x385e, 0x374e, 0x372c, 0x3839, 0x35a4, 0x38dc, 0x3462, 0x396e, 0x32c4, 0x39de, 0x3134,
    0x3a2b, 0x3003, 0x3a59, 0x2e3a, 0x3a6d, 0x2ce1, 0x3a6e, 0x2bba, 0x3a5f, 0x2a33, 0x3a49, 0x290a, 0x3a2d, 0x2826, 0x3a0a, 0x26e8,
    0x3894, 0x36d7, 0x3897, 0x36c9, 0x38a3, 0x3675, 0x38bc, 0x35ac, 0x38ee, 0x349c, 0x393e, 0x3332, 0x3997, 0x3186, 0x39e2, 0x3038,
    0x3a13, 0x2e75, 0x3a29, 0x2cf5, 0x3a2d, 0x2bac, 0x3a21, 0x29ff, 0x3a04, 0x28bc, 0x39dc, 0x2790, 0x39ad, 0x261a, 0x3978, 0x24fa,
    0x39ac, 0x34a8, 0x39ac, 0x34a3, 0x39ae, 0x3480, 0x39ae, 0x3423, 0x39b1, 0x330e, 0x39c2, 0x31a9, 0x39e0, 0x3063, 0x39fc, 0x2eb5,
    0x3a0c, 0x2d1d, 0x3a14, 0x2bcf, 0x3a07, 0x29ff, 0x39e9, 0x28a3, 0x39be, 0x273c, 0x3989, 0x25b3, 0x394a, 0x2488, 0x3907, 0x2345,
    0x3a77, 0x3223, 0x3a76, 0x321f, 0x3a73, 0x3204, 0x3a6a, 0x31b3, 0x3a58, 0x3114, 0x3a45, 0x303b, 0x3a34, 0x2eb6, 0x3a26, 0x2d31,
    0x3a1e, 0x2bef, 0x3a0b, 0x2a0d, 0x39ec, 0x28a1, 0x39c0, 0x271b, 0x3987, 0x2580, 0x3944, 0x2449, 0x38fa, 0x22bd, 0x38ac, 0x2155,
    0x3b07, 0x2fca, 0x3b06, 0x2fca, 0x3b00, 0x2fb8, 0x3af4, 0x2f7c, 0x3adb, 0x2eea, 0x3ab4, 0x2e00, 0x3a85, 0x2cec, 0x3a5e, 0x2bc5,
    0x3a36, 0x2a00, 0x3a0d, 0x2899, 0x39dc, 0x2707, 0x39a0, 0x2562, 0x395a, 0x2424, 0x390b, 0x2268, 0x38b7, 0x20fd, 0x385f, 0x1fd1,
    0x3b69, 0x2cb9, 0x3b68, 0x2cbb, 0x3b62, 0x2cbb, 0x3b56, 0x2cae, 0x3b3b, 0x2c78, 0x3b0d, 0x2c0a, 0x3acf, 0x2ae3, 0x3a92, 0x2998,
    0x3a54, 0x2867, 0x3a17, 0x26d0, 0x39d3, 0x253c, 0x3989, 0x2402, 0x3935, 0x2226, 0x38dc, 0x20bd, 0x387d, 0x1f54, 0x381d, 0x1db3,
    0x3ba9, 0x296b, 0x3ba8, 0x296f, 0x3ba3, 0x297b, 0x3b98, 0x2987, 0x3b7f, 0x2976, 0x3b4e, 0x2927, 0x3b0e, 0x2895, 0x3ac2, 0x27b7,
    0x3a73, 0x263b, 0x3a23, 0x24e7, 0x39d0, 0x239b, 0x3976, 0x21d9, 0x3917, 0x207e, 0x38b2, 0x1ee7, 0x384b, 0x1d53, 0x37c7, 0x1c1e,
    0x3bd2, 0x25cb, 0x3bd1, 0x25d3, 0x3bcd, 0x25f0, 0x3bc2, 0x261f, 0x3bad, 0x2645, 0x3b7d, 0x262d, 0x3b3e, 0x25c4, 0x3aec, 0x250f,
    0x3a93, 0x243a, 0x3a32, 0x22ce, 0x39d0, 0x215b, 0x3969, 0x202a, 0x38fe, 0x1e6e, 0x388f, 0x1cf1, 0x381f, 0x1b9b, 0x3762, 0x19dd,
    0x3be9, 0x21ab, 0x3be9, 0x21b7, 0x3be5, 0x21e5, 0x3bdd, 0x2241, 0x3bc9, 0x22a7, 0x3ba0, 0x22ec, 0x3b62, 0x22cd, 0x3b0f, 0x2247,
    0x3aae, 0x2175, 0x3a44, 0x2088, 0x39d4, 0x1f49, 0x3960, 0x1dbe, 0x38e9, 0x1c77, 0x3870, 0x1ae8, 0x37f1, 0x1953, 0x3708, 0x181b,
    0x3bf6, 0x1cea, 0x3bf6, 0x1cfb, 0x3bf3, 0x1d38, 0x3bec, 0x1dbd, 0x3bda, 0x1e7c, 0x3bb7, 0x1f25, 0x3b7d, 0x1f79, 0x3b2c, 0x1f4c,
    0x3ac6, 0x1ea6, 0x3a55, 0x1dbb, 0x39da, 0x1cbd, 0x395a, 0x1b9d, 0x38d8, 0x1a00, 0x3855, 0x18ac, 0x37ab, 0x173c, 0x36b7, 0x1598,
    0x3bfc, 0x1736, 0x3bfc, 0x1759, 0x3bf9, 0x17e7, 0x3bf4, 0x1896, 0x3be4, 0x1997, 0x3bc6, 0x1aa8, 0x3b91, 0x1b84, 0x3b43, 0x1bd2,
    0x3ade, 0x1b8a, 0x3a65, 0x1acd, 0x39e2, 0x19d3, 0x3957, 0x18cd, 0x38ca, 0x17b3, 0x383e, 0x1613, 0x376d, 0x14bf, 0x366f, 0x135e,
    0x3bff, 0x101b, 0x3bff, 0x1039, 0x3bfc, 0x10c8, 0x3bf9, 0x1226, 0x3bea, 0x1428, 0x3bcf, 0x1584, 0x3b9f, 0x16c5, 0x3b54, 0x179a,
    0x3af0, 0x17ce, 0x3a76, 0x1771, 0x39ea, 0x16a4, 0x3956, 0x15a7, 0x38bf, 0x14a7, 0x3829, 0x1379, 0x3735, 0x11ea, 0x362d, 0x10a1,
    0x3c00, 0x061b, 0x3c00, 0x066a, 0x3bfe, 0x081c, 0x3bfa, 0x0a4c, 0x3bed, 0x0d16, 0x3bd5, 0x0fb3, 0x3ba9, 0x114d, 0x3b63, 0x127c,
    0x3b01, 0x132f, 0x3a85, 0x1344, 0x39f4, 0x12d2, 0x3957, 0x120d, 0x38b5, 0x1122, 0x3817, 0x103c, 0x3703, 0x0ed3, 0x35f0, 0x0d6d,
    0x3c00, 0x007a, 0x3c00, 0x0089, 0x3bfe, 0x011d, 0x3bfb, 0x027c, 0x3bf0, 0x04fa, 0x3bda, 0x0881, 0x3bb1, 0x0acd, 0x3b6f, 0x0c97,
    0x3b10, 0x0d7b, 0x3a93, 0x0df1, 0x39fe, 0x0def, 0x3959, 0x0d8a, 0x38af, 0x0ce9, 0x3808, 0x0c31, 0x36d5, 0x0af0, 0x35b9, 0x09a3,
    0x3c00, 0x0000, 0x3c00, 0x0001, 0x3bff, 0x0015, 0x3bfb, 0x0059, 0x3bf2, 0x00fd, 0x3bdd, 0x01df, 0x3bb7, 0x031c, 0x3b79, 0x047c,
    0x3b1d, 0x05d4, 0x3aa0, 0x06d5, 0x3a08, 0x075a, 0x395d, 0x075e, 0x38aa, 0x06f7, 0x37f4, 0x0648, 0x36ac, 0x0576, 0x3586, 0x049f,
]
const _DFG_LUT = Float64.(reinterpret(Float16, _DFG_LUT_BITS))

@inline _saturate(x) = clamp(x, zero(x), one(x))

# Bilinear clamp-to-edge texel coordinate of a 16-texel axis: the lower texel
# index (0-based) and the interpolation weight. A NaN coordinate selects texel 0
# and keeps propagating through the weight.
@inline function _dfg_lut_axis(t)
    x = t * 16 - 0.5
    x = clamp(x, zero(x), 15 * one(x))
    p = _primal_value(x)
    i = p >= 15 ? 15 : p >= 0 ? trunc(Int, p) : 0
    return i, x - i
end

# `texture2D(dfgLUT, vec2(roughness, dotNV)).rg`.
@inline function _dfg_lut(roughness, dot_nv)
    ix, fx = _dfg_lut_axis(roughness)
    iy, fy = _dfg_lut_axis(dot_nv)
    ix1 = min(ix + 1, 15)
    iy1 = min(iy + 1, 15)
    lut = _DFG_LUT
    @inbounds begin
        b00 = (iy * 16 + ix) * 2
        b10 = (iy * 16 + ix1) * 2
        b01 = (iy1 * 16 + ix) * 2
        b11 = (iy1 * 16 + ix1) * 2
        x0 = lut[b00 + 1] * (1 - fx) + lut[b10 + 1] * fx
        x1 = lut[b01 + 1] * (1 - fx) + lut[b11 + 1] * fx
        y0 = lut[b00 + 2] * (1 - fx) + lut[b10 + 2] * fx
        y1 = lut[b01 + 2] * (1 - fx) + lut[b11 + 2] * fx
    end
    return x0 * (1 - fy) + x1 * fy, y0 * (1 - fy) + y1 * fy
end

# common.glsl.js F_Schlick: the spherical-Gaussian Schlick weight and its blend.
@inline _schlick_weight(dot_vh) = exp2((-5.55473 * dot_vh - 6.98316) * dot_vh)
@inline _f_schlick(f0::Color3, f90, w) =
    Color3(f0.r * (1 - w) + f90 * w, f0.g * (1 - w) + f90 * w,
           f0.b * (1 - w) + f90 * w)

# lights_physical_pars_fragment.glsl.js V_GGX_SmithCorrelated and D_GGX.
@inline function _v_ggx_smith_correlated(alpha, dot_nl, dot_nv)
    a2 = alpha * alpha
    gv = dot_nl * sqrt(a2 + (1 - a2) * (dot_nv * dot_nv))
    gl = dot_nv * sqrt(a2 + (1 - a2) * (dot_nl * dot_nl))
    return 0.5 / max(gv + gl, 1e-6)
end

@inline function _d_ggx(alpha, dot_nh)
    a2 = alpha * alpha
    denom = dot_nh * dot_nh * (a2 - 1) + 1
    return a2 / (π * denom * denom)
end

# Estevez-Kulla "Charlie" sheen distribution and Neubelt visibility
# (lights_physical_pars_fragment.glsl.js D_Charlie / V_Neubelt).
@inline function _d_charlie(roughness, dot_nh)
    alpha = roughness * roughness
    inv_alpha = 1 / alpha
    sin2h = max(1 - dot_nh * dot_nh, 0.0078125)
    return (2 + inv_alpha) * sin2h^(inv_alpha * 0.5) / (2 * π)
end

@inline _v_neubelt(dot_nv, dot_nl) =
    _saturate(1 / (4 * (dot_nl + dot_nv - dot_nl * dot_nv)))

# IBLSheenBRDF: directional albedo fit of the Charlie sheen lobe.
@inline function _ibl_sheen_brdf(dot_nv, roughness)
    r2 = roughness * roughness
    r_inv = 1 / (roughness + 0.1)
    a = -1.9362 + 1.0678 * roughness + 0.4573 * r2 - 0.8469 * r_inv
    b = -0.6014 + 0.5538 * roughness - 0.4670 * r2 - 0.1255 * r_inv
    return _saturate(exp(a * dot_nv + b))
end

@inline _max3(c::Color3) = max(max(c.r, c.g), c.b)

# Sheen roughness of the (material roughness × map texel) product. three.js
# clamps the material value to [1e-4, 1] before the map multiplies it, which a
# zero texel would turn into D_Charlie's `∞·0`; flooring the product at 1e-4
# equals `max(clamp(roughness, 1e-4, 1) · texel, 1e-4)` for the validated
# roughness and texel ranges [0, 1].
@inline _sheen_roughness(product) = max(product, 1e-4)

# iridescence_fragment.glsl.js evalSensitivity with a zero phase shift: the
# Fourier-space XYZ response of the optical path difference `opd` (nm).
@inline function _iridescence_sensitivity_xyz(opd)
    phase = 2 * π * opd * 1.0e-9
    p2 = phase * phase
    x = 5.4856e-13 * sqrt(2 * π * 4.3278e9) * cos(1.6810e6 * phase) *
        exp(-p2 * 4.3278e9) +
        9.7470e-14 * sqrt(2 * π * 4.5282e9) * cos(2.2399e6 * phase) *
        exp(-4.5282e9 * p2)
    y = 4.4201e-13 * sqrt(2 * π * 9.3046e9) * cos(1.7953e6 * phase) *
        exp(-p2 * 9.3046e9)
    z = 5.2481e-13 * sqrt(2 * π * 6.6121e9) * cos(2.2084e6 * phase) *
        exp(-p2 * 6.6121e9)
    return x / 1.0685e-7, y / 1.0685e-7, z / 1.0685e-7
end

# evalSensitivity(opd, shift) for shifts that are whole multiples of π, which
# are the only ones evalIridescence produces (φ12, φ21 and φ23 are each 0 or
# π): `cos(a + kπ) = ±cos(a)`, so each XYZ component of the unshifted response
# flips sign with its channel's shift (x, y, z take the r, g, b shifts as in
# three.js). The result is XYZ_TO_REC709 · xyz.
@inline function _iridescence_sensitivity(xyz, flip_r::Bool, flip_g::Bool,
                                          flip_b::Bool)
    x, y, z = xyz
    x = flip_r ? -x : x
    y = flip_g ? -y : y
    z = flip_b ? -z : z
    return Color3(3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
                  -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
                  0.0556434 * x - 0.2040259 * y + 1.0572252 * z)
end

# The base-independent part of evalIridescence(outsideIOR = 1): the film's
# index, refraction cosine and first-interface reflectance, and the sensitivity
# at one and two optical path differences. `tir` marks total internal
# reflection inside the film, where three.js returns a reflectance of 1.
struct _IridescenceFilm{T<:Real}
    tir::Bool
    film_ior::T
    cos_theta2::T
    r12::T
    t121::T
    phi21_is_pi::Bool
    s1::NTuple{3,T}
    s2::NTuple{3,T}
end

@inline function _iridescence_film(eta2, cos_theta1, thickness)
    outside_ior = 1.0
    t = clamp(thickness / 0.03, zero(thickness), one(thickness))
    film_ior = outside_ior * (1 - t * t * (3 - 2 * t)) + eta2 * (t * t * (3 - 2 * t))
    sin_theta2_sq = (outside_ior / film_ior)^2 * (1 - cos_theta1 * cos_theta1)
    cos_theta2_sq = 1 - sin_theta2_sq
    tir = cos_theta2_sq < 0
    cos_theta2 = sqrt(max(cos_theta2_sq, zero(cos_theta2_sq)))
    r0 = ((film_ior - outside_ior) / (film_ior + outside_ior))^2
    w1 = _schlick_weight(cos_theta1)
    r12 = r0 * (1 - w1) + w1
    # φ12 = π for film_ior < outsideIOR, and φ21 = π - φ12.
    phi21_is_pi = !(film_ior < outside_ior)
    opd = 2 * film_ior * thickness * cos_theta2
    s1 = _iridescence_sensitivity_xyz(opd)
    s2 = _iridescence_sensitivity_xyz(2 * opd)
    T = promote_type(typeof(film_ior), typeof(cos_theta2), typeof(r12),
                     typeof(s1[1]), typeof(s2[1]))
    return _IridescenceFilm{T}(
        tir, film_ior, cos_theta2, r12, 1 - r12, phi21_is_pi,
        (convert(T, s1[1]), convert(T, s1[2]), convert(T, s1[3])),
        (convert(T, s2[1]), convert(T, s2[2]), convert(T, s2[3])))
end

# Second-interface reflectance of one base-layer channel (iridescence_fragment
# Fresnel0ToIor / IorToFresnel0 / F_Schlick) and whether its phase φ23 is π.
@inline function _iridescence_base_channel(base_f0, film_ior, cos_theta2)
    f0 = clamp(base_f0, zero(base_f0), 0.9999 * one(base_f0))
    s = sqrt(f0)
    base_ior = (1 + s) / (1 - s)
    r1 = ((base_ior - film_ior) / (base_ior + film_ior))^2
    w = _schlick_weight(cos_theta2)
    r23 = r1 * (1 - w) + w
    return r23, base_ior < film_ior
end

# Airy reflectance of the film over a base of Fresnel reflectance `base_f0`.
@inline function _iridescence_reflectance(film::_IridescenceFilm, base_f0::Color3)
    if film.tir
        o = one(film.r12)
        return Color3(o, o, o)
    end
    r12, t121 = film.r12, film.t121
    r23r, p23r = _iridescence_base_channel(base_f0.r, film.film_ior, film.cos_theta2)
    r23g, p23g = _iridescence_base_channel(base_f0.g, film.film_ior, film.cos_theta2)
    r23b, p23b = _iridescence_base_channel(base_f0.b, film.film_ior, film.cos_theta2)
    r123r = clamp(r12 * r23r, 1e-5, 0.9999)
    r123g = clamp(r12 * r23g, 1e-5, 0.9999)
    r123b = clamp(r12 * r23b, 1e-5, 0.9999)
    sr, sg, sb = sqrt(r123r), sqrt(r123g), sqrt(r123b)
    rsr = t121 * t121 * r23r / (1 - r123r)
    rsg = t121 * t121 * r23g / (1 - r123g)
    rsb = t121 * t121 * r23b / (1 - r123b)
    ir, ig, ib = r12 + rsr, r12 + rsg, r12 + rsb
    cr, cg, cb = rsr - t121, rsg - t121, rsb - t121
    # Reflectance terms m = 1, 2 (pairs of Diracs). The phase φ = φ21 + φ23 is
    # 0, π or 2π; the second order's 2φ is a multiple of 2π.
    cr *= sr; cg *= sg; cb *= sb
    s1 = _iridescence_sensitivity(film.s1, film.phi21_is_pi ⊻ p23r,
                                  film.phi21_is_pi ⊻ p23g, film.phi21_is_pi ⊻ p23b)
    ir += cr * 2 * s1.r; ig += cg * 2 * s1.g; ib += cb * 2 * s1.b
    cr *= sr; cg *= sg; cb *= sb
    s2 = _iridescence_sensitivity(film.s2, false, false, false)
    ir += cr * 2 * s2.r; ig += cg * 2 * s2.g; ib += cb * 2 * s2.b
    return Color3(max(ir, zero(ir)), max(ig, zero(ig)), max(ib, zero(ib)))
end

# evalIridescence(outsideIOR = 1): Belcour-Barla thin-film Airy reflectance of
# a film of index `eta2` and thickness `thickness` (nm) over a base with
# Fresnel reflectance `base_f0`, seen at `cos_theta1 = N·V`.
@inline _eval_iridescence(eta2, cos_theta1, thickness, base_f0::Color3) =
    _iridescence_reflectance(_iridescence_film(eta2, cos_theta1, thickness), base_f0)

# Lit materials share one accumulation loop so direct lighting can be modulated
# by a per-light shadow visibility (`shadow_fn(light, position) ∈ [0,1]`). Each
# material supplies its fill response and its per-light direct response.
const LitMaterial = Union{MeshLambertMaterial, MeshPhongMaterial, MeshStandardMaterial,
                          MeshPhysicalMaterial, MeshToonMaterial}

@inline function _anisotropic_effective_roughness(roughness, anisotropy)
    strength = clamp(anisotropy, 0.0, 1.0)
    alpha = clamp(roughness * roughness, 0.0, 1.0)
    return sqrt(alpha + (1.0 - alpha) * strength * strength)
end

# KHR_materials_anisotropy is reduced to an isotropic lobe whose roughness is
# the broadened tangent roughness `sqrt(alphaT)` of three.js'
# `material.alphaT = mix(roughness², 1, anisotropy²)`.
@inline _physical_roughness(m::MeshPhysicalMaterial) =
    _anisotropic_effective_roughness(m.roughness, m.anisotropy)

# Per-fragment PBR surface: the three.js `PhysicalMaterial` struct
# (lights_physical_fragment.glsl.js) after lights_fragment_begin, with every
# view-dependent quantity resolved once so each light only evaluates its own
# half-vector terms. `fill_*` fields carry the package's fill-light response.
struct _PBRSurface{T<:Real}
    diffuse_contribution::Color3{T}  # diffuseColor · (1 - metalness)
    specular_color::Color3{T}        # dielectric F0
    specular_blended::Color3{T}      # mix(F0, diffuseColor, metalness)
    specular_f90::T
    alpha::T                         # roughness², roughness clamped to [0.0525, 1]
    multiscatter::Color3{T}          # direct multi-scattering compensation
    diffuse_weight::T                # 1 - transmission
    clearcoat::T
    clearcoat_alpha::T
    layer::T                         # 1 - clearcoat · Fcc(Ncc·V)
    clearcoat_normal::Vec3{T}        # clearcoatNormal: unperturbed or clearcoat-mapped
    sheen_color::Color3{T}           # sheenColor · sheen
    sheen_roughness::T
    sheen_albedo_v::T                # IBLSheenBRDF(N·V)
    iridescence::T
    iridescence_fresnel::Color3{T}
    fill_albedo::Color3{T}
    fill_metalness::T
    fill_roughness::T
    transmitted::Color3{T}           # transmitted fill radiance per unit irradiance
end

@inline _color_as(::Type{T}, c::Color3) where {T} =
    Color3(convert(T, c.r), convert(T, c.g), convert(T, c.b))

@inline function _pbr_roughness(roughness)
    return min(max(roughness, 0.0525), one(roughness))
end

# meshphysical.glsl.js: the outgoing light, emission included, is scaled by
# `1 - clearcoat · Fcc` with Fcc = F_Schlick(0.04, 1, saturate(clearcoatNormal·V)).
@inline function _clearcoat_layer(clearcoat, dot_nv_cc)
    cc = _saturate(clearcoat)
    cc > 0 || return one(cc)
    w = _schlick_weight(dot_nv_cc)
    return 1 - cc * (0.04 * (1 - w) + w)
end

# Shared constructor. `specular_color` is the dielectric F0 and `specular_f90`
# its grazing reflectance (`lights_physical_fragment`'s `specularColor` and
# `specularF90`).
@inline function _pbr_surface(::Type{T}, dot_nv, albedo::Color3, metalness,
                              roughness, specular_color::Color3, specular_f90,
                              clearcoat, clearcoat_roughness, sheen_color::Color3,
                              sheen_roughness, iridescence, iridescence_fresnel::Color3,
                              transmission, fill_roughness,
                              transmitted::Color3, clearcoat_normal::Vec3,
                              dot_nv_cc) where {T}
    r = _pbr_roughness(roughness)
    blended = Color3(specular_color.r + (albedo.r - specular_color.r) * metalness,
                     specular_color.g + (albedo.g - specular_color.g) * metalness,
                     specular_color.b + (albedo.b - specular_color.b) * metalness)
    # lights_fragment_begin.glsl.js: multi-scattering energy compensation
    # `1 + specularColorBlended · (1/Ess - 1)` with Ess = dfg.x + dfg.y.
    dfg_x, dfg_y = _dfg_lut(r, dot_nv)
    gain = 1 / (dfg_x + dfg_y) - 1
    ms = Color3(1 + blended.r * gain, 1 + blended.g * gain, 1 + blended.b * gain)
    kd = 1 - metalness
    cc = _saturate(clearcoat)
    layer = _clearcoat_layer(clearcoat, dot_nv_cc)
    sheen_albedo = _max3(sheen_color) > 0 ?
        _ibl_sheen_brdf(dot_nv, sheen_roughness) : zero(sheen_roughness)
    return _PBRSurface{T}(
        _color_as(T, Color3(albedo.r * kd, albedo.g * kd, albedo.b * kd)),
        _color_as(T, specular_color), _color_as(T, blended),
        convert(T, specular_f90), convert(T, r * r), _color_as(T, ms),
        convert(T, 1 - transmission), convert(T, cc),
        convert(T, _pbr_roughness(clearcoat_roughness)^2), convert(T, layer),
        Vec3{T}(clearcoat_normal.x, clearcoat_normal.y, clearcoat_normal.z),
        _color_as(T, sheen_color), convert(T, sheen_roughness),
        convert(T, sheen_albedo), convert(T, iridescence),
        _color_as(T, iridescence_fresnel), _color_as(T, albedo),
        convert(T, metalness), convert(T, fill_roughness),
        _color_as(T, transmitted))
end

@inline _pbr_scalar_type(n::Vec3, v::Vec3, values...) =
    promote_type(typeof(n.x), typeof(v.x), map(typeof, values)..., Float64)

# MeshStandardMaterial (`specularColor = 0.04`, `specularF90 = 1`) and the
# `KHR_materials_specular` form used by `shade_pbr`.
@inline function _standard_surface(n::Vec3, v::Vec3, albedo::Color3, metalness,
                                   roughness, specular_intensity=1.0,
                                   specular_color::Color3=Color3(1.0, 1.0, 1.0))
    T = _pbr_scalar_type(n, v, albedo.r, metalness, roughness,
                         specular_intensity, specular_color.r)
    dot_nv = _saturate(dot(n, v))
    f0 = Color3(min(0.04 * specular_color.r, 1.0) * specular_intensity,
                min(0.04 * specular_color.g, 1.0) * specular_intensity,
                min(0.04 * specular_color.b, 1.0) * specular_intensity)
    f90 = specular_intensity + (1 - specular_intensity) * metalness
    z = zero(T)
    zc = Color3(z, z, z)
    return _pbr_surface(T, dot_nv, albedo, metalness, roughness, f0, f90,
                        z, z, zc, one(T), z, zc, z, roughness, zc, n, dot_nv)
end

# Physical terms of a material without texture maps.
@inline _physical_terms(m::MeshPhysicalMaterial) =
    _PhysicalMappedTerms(m.metalness, m.roughness, m.clearcoat,
                         m.clearcoat_roughness, m.transmission, m.thickness,
                         m.sheen_color, m.sheen_roughness,
                         m.iridescence, m.iridescence_thickness,
                         m.specular_intensity, m.specular_color, m.anisotropy)

@inline _physical_mapped_roughness(t::_PhysicalMappedTerms) =
    _anisotropic_effective_roughness(t.roughness, t.anisotropy)

# Transmission fill. A CPU rasterizer has no transmission render target to
# refract through, so the fill irradiance stands in for the background the
# refracted ray would reveal (its radiance is `background/π`). The transmitted
# radiance is attenuated by the surface colour (a single-sample Beer-Lambert
# tint along the view path, treating `color` as per-unit transmittance), by the
# optional attenuation colour over `thickness`, and weighted by
# transmission·(1 - Schlick reflectance). three.js replaces the diffuse lobe by
# this transmitted light (`totalDiffuse = mix(totalDiffuse, transmitted,
# transmission)`); the `1 - transmission` diffuse weight lives in `_PBRSurface`.
@inline function _transmission_factor(ior, transmission, thickness,
                                      attenuation_distance,
                                      attenuation_color::Color3,
                                      albedo::Color3, normal::Vec3,
                                      view_dir::Vec3)
    ndotv = clamp(dot(normal, view_dir), 0.0, 1.0)
    r0 = ((ior - 1) / (ior + 1))^2
    refl = r0 + (1 - r0) * (1 - ndotv)^5
    transmit = (1 - refl) * transmission
    path = 1.0 / max(ndotv, 1e-3)
    att = Color3(albedo.r^path, albedo.g^path, albedo.b^path)
    if thickness > 0.0 && attenuation_distance > 0.0
        volume_path = path * thickness / attenuation_distance
        att = att * Color3(attenuation_color.r^volume_path,
                           attenuation_color.g^volume_path,
                           attenuation_color.b^volume_path)
    end
    return att * (transmit / π)
end

@inline function _transmission_fill(m::MeshPhysicalMaterial, normal::Vec3,
                                    view_dir::Vec3, background::Color3)
    m.transmission <= 0.0 && return Color3(0.0, 0.0, 0.0)
    return background * _transmission_factor(
        m.ior, m.transmission, m.thickness, m.attenuation_distance,
        m.attenuation_color, m.color, normal, view_dir)
end

@inline _transmission_response(m, n::Vec3, v::Vec3, fc::Color3) = Color3(0.0, 0.0, 0.0)
@inline _transmission_response(m::MeshPhysicalMaterial, n::Vec3, v::Vec3, fc::Color3) =
    m.transmission > 0.0 ? _transmission_fill(m, n, v, fc) : Color3(0.0, 0.0, 0.0)

# MeshPhysicalMaterial surface from resolved (possibly texture-mapped) terms.
# `ccn` is three.js `clearcoatNormal` (clearcoat_normal_fragment_begin/maps):
# the shading normal before normal mapping, or the clearcoat-normal-mapped one.
function _physical_surface(m::MeshPhysicalMaterial, t::_PhysicalMappedTerms,
                           n::Vec3, v::Vec3, albedo::Color3, ccn::Vec3=n)
    T = _pbr_scalar_type(n, v, albedo.r, ccn.x)
    dot_nv = _saturate(dot(n, v))
    metalness = t.metalness
    # lights_physical_fragment.glsl.js (IOR, USE_SPECULAR):
    # specularF90 = mix(specularIntensity, 1, metalness) and
    # specularColor = min(((ior-1)/(ior+1))² · specularColor, 1) · intensity.
    si = t.specular_intensity
    f0_ior = ((m.ior - 1) / (m.ior + 1))^2
    sc = t.specular_color
    f0 = Color3(min(f0_ior * sc.r, 1.0) * si, min(f0_ior * sc.g, 1.0) * si,
                min(f0_ior * sc.b, 1.0) * si)
    f90 = si + (1 - si) * metalness
    roughness = t.anisotropy > 0 ?
        _anisotropic_effective_roughness(_pbr_roughness(t.roughness), t.anisotropy) :
        t.roughness
    # WebGLMaterials.js: the sheen uniform is sheenColor · sheen, and USE_SHEEN
    # is only defined for sheen > 0.
    sheen_color = m.sheen > 0 ? t.sheen_color * m.sheen : Color3(0.0, 0.0, 0.0)
    # lights_fragment_begin.glsl.js: a zero film thickness disables iridescence;
    # the Fresnel term mixes the dielectric and metallic film responses.
    iridescence = t.iridescence_thickness == 0 ? 0.0 : _saturate(t.iridescence)
    irid_fresnel = if iridescence > 0
        film = _iridescence_film(m.iridescence_ior, dot_nv, t.iridescence_thickness)
        d = _iridescence_reflectance(film, f0)
        mm = _iridescence_reflectance(film, albedo)
        Color3(d.r + (mm.r - d.r) * metalness, d.g + (mm.g - d.g) * metalness,
               d.b + (mm.b - d.b) * metalness)
    else
        z = zero(dot_nv)
        Color3(z, z, z)
    end
    transmitted = t.transmission > 0 ?
        _transmission_factor(m.ior, t.transmission, t.thickness,
                             m.attenuation_distance, m.attenuation_color,
                             albedo, n, v) :
        Color3(0.0, 0.0, 0.0)
    return _pbr_surface(T, dot_nv, albedo, metalness, roughness, f0, f90,
                        t.clearcoat, t.clearcoat_roughness, sheen_color,
                        _sheen_roughness(t.sheen_roughness), iridescence, irid_fresnel,
                        t.transmission, _physical_mapped_roughness(t),
                        transmitted, ccn, ccn === n ? dot_nv : _saturate(dot(ccn, v)))
end

@inline _lit_surface(m::MeshStandardMaterial, n::Vec3, v::Vec3, albedo::Color3) =
    _standard_surface(n, v, albedo, m.metalness, m.roughness)
@inline _lit_surface(m::MeshPhysicalMaterial, n::Vec3, v::Vec3, albedo::Color3,
                     ccn::Vec3=n) =
    _physical_surface(m, _physical_terms(m), n, v, albedo, ccn)
@inline _lit_surface(m::MeshStandardMaterial, n::Vec3, v::Vec3, albedo::Color3,
                     ccn::Vec3) = _lit_surface(m, n, v, albedo)
@inline _lit_surface(m, n::Vec3, v::Vec3, albedo::Color3) = m

# RE_Direct_Physical with the clearcoat, sheen and iridescence lobes and the
# meshphysical.glsl.js clearcoat layering, for one light of colour `lc`,
# intensity `li` and unit direction `ldir` (surface → light).
@inline function _direct_response(s::_PBRSurface, n::Vec3, v::Vec3,
                                  lc::Color3, li, ldir::Vec3)
    dot_nl = _saturate(dot(n, ldir))
    coated = s.clearcoat > 0
    ccn = s.clearcoat_normal
    dot_nl_cc = coated ? _saturate(dot(ccn, ldir)) : zero(dot_nl)
    if !(dot_nl > 0) && !(dot_nl_cc > 0)
        # Every base lobe is scaled by the irradiance N·L and the clearcoat
        # lobe by its own Ncc·L (lights_physical_pars_fragment RE_Direct_Physical).
        z = zero(dot_nl * li * s.alpha * lc.r)
        return Color3(z, z, z)
    end
    h = _half_vec(ldir, v)
    w = _schlick_weight(_saturate(dot(v, h)))
    r = g = b = zero(dot_nl * li * s.alpha * lc.r)
    if dot_nl > 0
        r, g, b = _direct_base_response(s, n, v, li, ldir, h, w, dot_nl)
    end
    if coated && dot_nl_cc > 0
        # BRDF_GGX_Clearcoat (F0 = 0.04, F90 = 1) on clearcoatNormal, weighted
        # by clearcoat.
        dot_nv_cc = _saturate(dot(ccn, v))
        dot_nh_cc = _saturate(dot(ccn, h))
        coat = (0.04 * (1 - w) + w) *
               _v_ggx_smith_correlated(s.clearcoat_alpha, dot_nl_cc, dot_nv_cc) *
               _d_ggx(s.clearcoat_alpha, dot_nh_cc) * (dot_nl_cc * li) * s.clearcoat
        r += coat; g += coat; b += coat
    end
    return Color3(r * lc.r, g * lc.g, b * lc.b)
end

# Specular, diffuse and sheen lobes of RE_Direct_Physical under the clearcoat
# layering, for a light with N·L = `dot_nl` > 0 and Schlick weight `w`.
@inline function _direct_base_response(s::_PBRSurface, n::Vec3, v::Vec3, li,
                                       ldir::Vec3, h::Vec3, w, dot_nl)
    dot_nv = _saturate(dot(n, v))
    dot_nh = _saturate(dot(n, h))
    irradiance = dot_nl * li
    sheen = Color3(zero(irradiance), zero(irradiance), zero(irradiance))
    base_irradiance = irradiance
    sheen_peak = _max3(s.sheen_color)
    if sheen_peak > 0
        sheen = s.sheen_color * (irradiance * _d_charlie(s.sheen_roughness, dot_nh) *
                                 _v_neubelt(dot_nv, dot_nl))
        albedo_l = _ibl_sheen_brdf(dot_nl, s.sheen_roughness)
        base_irradiance = irradiance * (1 - sheen_peak * max(s.sheen_albedo_v, albedo_l))
    end
    F = _f_schlick(s.specular_blended, s.specular_f90, w)
    if s.iridescence > 0
        k = s.iridescence
        F = Color3(F.r + (s.iridescence_fresnel.r - F.r) * k,
                   F.g + (s.iridescence_fresnel.g - F.g) * k,
                   F.b + (s.iridescence_fresnel.b - F.b) * k)
    end
    lobe = _v_ggx_smith_correlated(s.alpha, dot_nl, dot_nv) * _d_ggx(s.alpha, dot_nh)
    spec_scale = base_irradiance * lobe
    Fd = _f_schlick(s.specular_color, s.specular_f90, w)
    diffuse_scale = base_irradiance * s.diffuse_weight / π
    dc = s.diffuse_contribution
    ms = s.multiscatter
    r = (F.r * ms.r * spec_scale + dc.r * (1 - Fd.r) * diffuse_scale + sheen.r) * s.layer
    g = (F.g * ms.g * spec_scale + dc.g * (1 - Fd.g) * diffuse_scale + sheen.g) * s.layer
    b = (F.b * ms.b * spec_scale + dc.b * (1 - Fd.b) * diffuse_scale + sheen.b) * s.layer
    return r, g, b
end

# Fill (ambient/hemisphere/probe) response of a PBR surface: the package's
# metallic-roughness fill model, reduced by the sheen energy compensation of
# RE_IndirectDiffuse/IndirectSpecular_Physical, with three.js' indirect sheen
# lobe, the transmission mix of the diffuse part, and the clearcoat layering.
@inline function _fill_response(s::_PBRSurface, n::Vec3, fc::Color3)
    diffuse, specular = _pbr_ambient_terms(s.fill_albedo, s.fill_metalness,
                                           s.fill_roughness, fc)
    sheen_peak = _max3(s.sheen_color)
    sheen = Color3(zero(s.layer), zero(s.layer), zero(s.layer))
    if sheen_peak > 0
        comp = 1 - sheen_peak * s.sheen_albedo_v
        diffuse = diffuse * comp
        specular = specular * comp
        sheen = s.sheen_color * fc * (s.sheen_albedo_v / π)
    end
    return (diffuse * s.diffuse_weight + fc * s.transmitted + specular + sheen) *
           s.layer
end

# Environment (ambient/IBL) response of a metallic-roughness surface. Without
# this term metals (low diffuse, narrow specular) render black under fill light
# alone, which three.js only avoids with an environment map. Diffuse scales by
# (1-metalness); specular uses Schlick F0 (≈albedo for metals) attenuated by
# roughness. Fill irradiance is reflected through the same 1/π
# (`BRDF_Lambert`/cosine-weighted irradiance) as three.js.
@inline function _pbr_ambient_terms(albedo::Color3, metalness, roughness, fill::Color3)
    kd = one(metalness) - metalness
    F0r = lerp_scalar(0.04, albedo.r, metalness)
    F0g = lerp_scalar(0.04, albedo.g, metalness)
    F0b = lerp_scalar(0.04, albedo.b, metalness)
    spec_scale = one(roughness) - roughness * 0.7
    return Color3(albedo.r * kd * fill.r / π, albedo.g * kd * fill.g / π,
                  albedo.b * kd * fill.b / π),
           Color3(F0r * spec_scale * fill.r / π, F0g * spec_scale * fill.g / π,
                  F0b * spec_scale * fill.b / π)
end

_fill_response(m::MeshLambertMaterial,  n, fc) = _brdf_lambert(m.color * fc)
_fill_response(m::MeshPhongMaterial,    n, fc) = _brdf_lambert(m.color * fc)
_fill_response(m::MeshToonMaterial,     n, fc) = _brdf_lambert(m.color * fc)

_direct_response(m::MeshLambertMaterial, n, v, lc, li, ldir) =
    shade_lambert(n, ldir, lc, li, m.color)
_direct_response(m::MeshPhongMaterial, n, v, lc, li, ldir) =
    shade_phong(n, ldir, v, lc, li, m.color, m.specular, m.shininess)
_direct_response(m::Union{MeshStandardMaterial,MeshPhysicalMaterial}, n, v, lc, li, ldir) =
    _direct_response(_lit_surface(m, n, v, m.color), n, v, lc, li, ldir)
function _direct_response(m::MeshToonMaterial, n, v, lc, li, ldir)
    dotnl = dot(n, ldir)
    irradiance = if m.gradient_map isa Texture
        coord = clamp(dotnl * 0.5 + 0.5, 0.0, 1.0)
        sample_texture(m.gradient_map, coord, 0.0).r
    else
        ndotl = max(dotnl, 0.0)
        ceil(ndotl * m.gradient_steps) / m.gradient_steps
    end
    m.color * lc * (irradiance * li / π)
end

# three.js BRDF_Sheen scaled by the irradiance N·L for a material's own sheen
# parameters (sheenColor · sheen, clamped sheen roughness).
@inline function _sheen_lobe(m::MeshPhysicalMaterial, normal::Vec3, light_dir::Vec3,
                             view_dir::Vec3)
    dot_nl = _saturate(dot(normal, light_dir))
    (m.sheen > 0 && dot_nl > 0) || return Color3(0.0, 0.0, 0.0)
    h = _half_vec(light_dir, view_dir)
    dot_nv = _saturate(dot(normal, view_dir))
    dot_nh = _saturate(dot(normal, h))
    d = _d_charlie(_sheen_roughness(m.sheen_roughness), dot_nh)
    return m.sheen_color * (m.sheen * d * _v_neubelt(dot_nv, dot_nl) * dot_nl)
end

_fill_response_vertex_color(m::MeshLambertMaterial,  n, fc, albedo::Color3) =
    _brdf_lambert(albedo * fc)
_fill_response_vertex_color(m::MeshPhongMaterial,    n, fc, albedo::Color3) =
    _brdf_lambert(albedo * fc)
_fill_response_vertex_color(m::MeshToonMaterial,     n, fc, albedo::Color3) =
    _brdf_lambert(albedo * fc)

_direct_response_vertex_color(m::MeshLambertMaterial, n, v, lc, li, ldir,
                              albedo::Color3) =
    shade_lambert(n, ldir, lc, li, albedo)
_direct_response_vertex_color(m::MeshPhongMaterial, n, v, lc, li, ldir,
                              albedo::Color3) =
    shade_phong(n, ldir, v, lc, li, albedo, m.specular, m.shininess)
function _direct_response_vertex_color(m::MeshToonMaterial, n, v, lc, li, ldir,
                                       albedo::Color3)
    dotnl = dot(n, ldir)
    irradiance = if m.gradient_map isa Texture
        coord = clamp(dotnl * 0.5 + 0.5, 0.0, 1.0)
        sample_texture(m.gradient_map, coord, 0.0).r
    else
        ndotl = max(dotnl, 0.0)
        ceil(ndotl * m.gradient_steps) / m.gradient_steps
    end
    albedo * lc * (irradiance * li / π)
end

@inline function _rect_area_frame(light::RectAreaLight)
    _validate_light_parameters(light)
    position = _light_world_position(light)
    f = _direction_between(position, light.target)
    ref = abs(f.y) < 0.95 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    u = normalize(cross(ref, f))
    v = cross(f, u)
    return f, u, v, position
end

@inline function _rect_area_basis(light::RectAreaLight)
    forward, right, up, _ = _rect_area_frame(light)
    return forward, right, up
end

@inline function _rect_area_sample_direction(
    position::Vec3, sample_position::Vec3,
)
    displacement = sample_position - position
    distance_squared = dot(displacement, displacement)
    if _finite_light_vec3(displacement)
        bounded_distance_squared = max(distance_squared, 1e-10)
        # The near-field attenuation floor must not shorten the unit direction
        # used by the surface and emitter cosine terms.
        return isfinite(distance_squared) && distance_squared >= 1e-10 ?
            (displacement / sqrt(distance_squared),
             bounded_distance_squared) :
            (normalize(displacement), bounded_distance_squared)
    end

    if _finite_light_vec3(position) &&
       _finite_light_vec3(sample_position)
        direction, distance =
            _light_direction_and_distance(position, sample_position)
        return direction, max(distance * distance, 1e-10)
    end

    bounded_distance_squared = max(distance_squared, 1e-10)
    return displacement / sqrt(bounded_distance_squared),
           bounded_distance_squared
end

function _rect_area_response(m, normal::Vec3, view_dir::Vec3, position::Vec3,
                             light::RectAreaLight)
    f, u, v, light_position = _rect_area_frame(light)
    hx = max(light.width, 0.0) * 0.5
    hy = max(light.height, 0.0) * 0.5
    (hx <= 0.0 || hy <= 0.0) && return Color3(0.0, 0.0, 0.0)
    nodes = (-0.7745966692414834, 0.0, 0.7745966692414834)
    weights = (0.5555555555555556, 0.8888888888888888, 0.5555555555555556)
    area_scale = hx * hy
    result = Color3(0.0, 0.0, 0.0)
    @inbounds for ix in 1:3, iy in 1:3
        sample_pos = light_position + u * (hx * nodes[ix]) + v * (hy * nodes[iy])
        ldir, dist2 =
            _rect_area_sample_direction(position, sample_pos)
        emit = max(dot(-ldir, f), 0.0)
        emit <= 0.0 && continue
        li = light.intensity * area_scale * weights[ix] * weights[iy] * emit / dist2
        result = result + _direct_response(m, normal, view_dir, light.color, li, ldir)
    end
    return result
end

# A lit material whose base colour is replaced per fragment (vertex colours or
# a base-colour map) for the Lambert, Phong and Toon models.
struct _AlbedoOverride{M,C<:Color3}
    material::M
    albedo::C
end

@inline _fill_response(o::_AlbedoOverride, n, fc) =
    _fill_response_vertex_color(o.material, n, fc, o.albedo)
@inline _direct_response(o::_AlbedoOverride, n, v, lc, li, ldir) =
    _direct_response_vertex_color(o.material, n, v, lc, li, ldir, o.albedo)

# Blinn-Phong with texture-resolved specular colour and shininess.
struct _PhongMapped{C<:Color3,S<:Color3}
    albedo::C
    specular::S
    shininess::Float64
end

@inline _fill_response(p::_PhongMapped, n, fc) = _brdf_lambert(p.albedo * fc)
@inline _direct_response(p::_PhongMapped, n, v, lc, li, ldir) =
    shade_phong(n, ldir, v, lc, li, p.albedo, p.specular, p.shininess)

function _accumulate_light(result, m, normal::Vec3, view_dir::Vec3,
                           position::Vec3, light::RectAreaLight, shadow_fn)
    vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
    vis <= 0.0 && return result
    return result + _rect_area_response(m, normal, view_dir, position, light) * vis
end

function _accumulate_light(result, m, normal::Vec3, view_dir::Vec3,
                           position::Vec3, light, shadow_fn)
    if _is_fill_light(light)
        return result + _fill_response(m, normal, _fill_color(normal, light))
    else
        lc, li, ldir = light_contribution(light, position)
        vis = shadow_fn === nothing ? 1.0 : shadow_fn(light, position)
        vis <= 0.0 && return result
        return result + _direct_response(m, normal, view_dir, lc, li, ldir) * vis
    end
end

@inline _dispatch_accumulate_light(light, result, m, normal, view_dir, position,
                                   shadow_fn) =
    _accumulate_light(result, m, normal, view_dir, position, light, shadow_fn)

# Light loop of a prepared lit model (a material, `_AlbedoOverride`,
# `_PhongMapped` or `_PBRSurface`) starting from the emitted radiance `result`.
# Built-in scene-light vectors are narrowed per light so the accumulation stays
# unboxed; `_DirectLightView` skips fill lights.
@inline function _shade_model(model, result, normal::Vec3, view_dir::Vec3, position::Vec3,
                              lights::Vector{SceneLight}, shadow_fn)
    @inbounds for i in eachindex(lights)
        result = _dispatch_scene_light(_dispatch_accumulate_light, lights[i], result,
                                       model, normal, view_dir, position, shadow_fn)
    end
    return result
end

@inline function _shade_model(model, result, normal::Vec3, view_dir::Vec3, position::Vec3,
                              lights::_DirectLightView{Vector{SceneLight}}, shadow_fn)
    source = lights.lights
    @inbounds for i in eachindex(source)
        light = source[i]
        _is_fill_light(light) && continue
        result = _dispatch_scene_light(_dispatch_accumulate_light, light, result,
                                       model, normal, view_dir, position, shadow_fn)
    end
    return result
end

@inline function _shade_model(model, result, normal::Vec3, view_dir::Vec3, position::Vec3,
                              lights, shadow_fn)
    for light in lights
        result = _accumulate_light(result, model, normal, view_dir, position, light,
                                   shadow_fn)
    end
    return result
end

@inline _emitted(m) = m.emissive * _material_scalar(m, :emissive_intensity)
# meshphysical.glsl.js applies the clearcoat layering to totalEmissiveRadiance
# as well (outgoingLight includes it before `· (1 - clearcoat · Fcc)`).
@inline _emitted(s::_PBRSurface{T}, m) where {T} = _color_as(T, _emitted(m)) * s.layer

function _shade_phong_mapped_color(normal::Vec3, view_dir::Vec3,
                                   position::Vec3,
                                   material::MeshPhongMaterial, lights, shadow_fn,
                                   specular::Color3, shininess::Float64,
                                   albedo::Color3)
    return _shade_model(_PhongMapped(albedo, specular, shininess), _emitted(material),
                        normal, view_dir, position, lights, shadow_fn)
end

function _shade_phong_mapped(normal::Vec3, view_dir::Vec3, position::Vec3,
                             material::MeshPhongMaterial, lights, shadow_fn,
                             specular::Color3, shininess::Float64)
    _shade_phong_mapped_color(normal, view_dir, position, material, lights,
                              shadow_fn, specular, shininess, material.color)
end

function _shade_phong_mapped_vertex_color(normal::Vec3, view_dir::Vec3,
                                          position::Vec3,
                                          material::MeshPhongMaterial,
                                          lights, shadow_fn,
                                          specular::Color3,
                                          shininess::Float64,
                                          vertex_color::Color3)
    albedo = _modulate(material.color, vertex_color)
    _shade_phong_mapped_color(normal, view_dir, position, material, lights,
                              shadow_fn, specular, shininess, albedo)
end

function _shade_physical_mapped_color(normal::Vec3, view_dir::Vec3,
                                      position::Vec3,
                                      material::MeshPhysicalMaterial,
                                      lights, shadow_fn,
                                      terms::_PhysicalMappedTerms,
                                      albedo::Color3, ccn::Vec3=normal)
    s = _physical_surface(material, terms, normal, view_dir, albedo, ccn)
    return _shade_model(s, _emitted(s, material), normal, view_dir, position,
                        lights, shadow_fn)
end

function _shade_physical_mapped(normal::Vec3, view_dir::Vec3, position::Vec3,
                                material::MeshPhysicalMaterial, lights,
                                shadow_fn, terms::_PhysicalMappedTerms,
                                ccn::Vec3=normal)
    _shade_physical_mapped_color(normal, view_dir, position, material, lights,
                                 shadow_fn, terms, material.color, ccn)
end

function _shade_physical_mapped_vertex_color(normal::Vec3, view_dir::Vec3,
                                             position::Vec3,
                                             material::MeshPhysicalMaterial,
                                             lights, shadow_fn,
                                             terms::_PhysicalMappedTerms,
                                             vertex_color::Color3,
                                             ccn::Vec3=normal)
    albedo = _modulate(material.color, vertex_color)
    _shade_physical_mapped_color(normal, view_dir, position, material, lights,
                                 shadow_fn, terms, albedo, ccn)
end

function _shade_standard_mapped(normal::Vec3, view_dir::Vec3, position::Vec3,
                                material::MeshStandardMaterial, lights, shadow_fn,
                                metalness::Float64, roughness::Float64)
    s = _standard_surface(normal, view_dir, material.color, metalness, roughness)
    return _shade_model(s, _emitted(s, material), normal, view_dir, position,
                        lights, shadow_fn)
end

function _shade_standard_mapped_vertex_color(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshStandardMaterial, lights, shadow_fn,
        metalness::Float64, roughness::Float64, vertex_color::Color3)
    albedo = _modulate(material.color, vertex_color)
    s = _standard_surface(normal, view_dir, albedo, metalness, roughness)
    return _shade_model(s, _emitted(s, material), normal, view_dir, position,
                        lights, shadow_fn)
end

function _shade_lit(m, normal::Vec3, view_dir::Vec3, position::Vec3, lights,
                    shadow_fn)
    _validate_material_parameters(m)
    return _shade_model(m, _emitted(m), normal, view_dir, position, lights,
                        shadow_fn)
end

function _shade_lit(m::Union{MeshStandardMaterial,MeshPhysicalMaterial},
                    normal::Vec3, view_dir::Vec3, position::Vec3, lights,
                    shadow_fn, ccn::Vec3=normal)
    _validate_material_parameters(m)
    s = _lit_surface(m, normal, view_dir, m.color, ccn)
    return _shade_model(s, _emitted(s, m), normal, view_dir, position, lights,
                        shadow_fn)
end

shade_face(normal::Vec3, view_dir::Vec3, position::Vec3, material::LitMaterial, lights;
           shadow_fn=nothing) = _shade_lit(material, normal, view_dir, position, lights, shadow_fn)

function _shade_lit_vertex_color(m, normal::Vec3, view_dir::Vec3, position::Vec3,
                                 lights, shadow_fn, vertex_color::Color3)
    _validate_material_parameters(m)
    return _shade_model(_AlbedoOverride(m, _modulate(m.color, vertex_color)),
                        _emitted(m), normal, view_dir, position, lights, shadow_fn)
end

function _shade_lit_vertex_color(m::Union{MeshStandardMaterial,MeshPhysicalMaterial},
                                 normal::Vec3, view_dir::Vec3, position::Vec3,
                                 lights, shadow_fn, vertex_color::Color3,
                                 ccn::Vec3=normal)
    _validate_material_parameters(m)
    s = _lit_surface(m, normal, view_dir, _modulate(m.color, vertex_color), ccn)
    return _shade_model(s, _emitted(s, m), normal, view_dir, position, lights,
                        shadow_fn)
end

@inline function _shade_face_vertex_color(normal::Vec3, view_dir::Vec3,
                                          position::Vec3,
                                          material::MeshBasicMaterial, lights,
                                          vertex_color::Color3; shadow_fn=nothing)
    _validate_material_parameters(material)
    return _modulate(material.color, vertex_color)
end

@inline function _shade_face_vertex_color(normal::Vec3, view_dir::Vec3,
                                          position::Vec3,
                                          material::LitMaterial, lights,
                                          vertex_color::Color3; shadow_fn=nothing)
    _shade_lit_vertex_color(material, normal, view_dir, position, lights,
                            shadow_fn, vertex_color)
end

@inline function _shade_face_vertex_color(normal::Vec3, view_dir::Vec3,
                                          position::Vec3,
                                          material::AbstractMaterial, lights,
                                          vertex_color::Color3; shadow_fn=nothing)
    shade_face(normal, view_dir, position, _with_vertex_color(material, vertex_color),
               lights; shadow_fn=shadow_fn)
end

# three.js encodes the view-space normal; without a camera view the world-space
# normal is used.
@inline _normal_material_normal(normal::Vec3, ::Nothing) = normal
@inline _normal_material_normal(normal::Vec3, camera_view::Mat4) =
    normalize(mat4_transform_direction(camera_view, normal))

@inline function _shade_normal_face(normal::Vec3, camera_view)
    n = _normal_material_normal(normal, camera_view)
    Color3((n.x + 1) / 2, (n.y + 1) / 2, (n.z + 1) / 2)
end

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshNormalMaterial, lights; shadow_fn=nothing,
                    camera_view::Union{Nothing,Mat4}=nothing)
    return _shade_normal_face(normal, camera_view)
end

@inline _shade_face_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshNormalMaterial, lights, camera_view, shadow_fn) =
    _shade_normal_face(normal, camera_view)

@inline _shade_face_vertex_color_with_camera_view(
        normal::Vec3, view_dir::Vec3, position::Vec3,
        material::MeshNormalMaterial, lights, vertex_color::Color3,
        camera_view, shadow_fn) =
    _shade_normal_face(normal, camera_view)

@inline _matcap_view_vectors(normal::Vec3, view_dir::Vec3, ::Nothing) =
    (normal, view_dir)

@inline function _matcap_view_vectors(normal::Vec3, view_dir::Vec3,
                                      camera_view::Mat4)
    return normalize(mat4_transform_direction(camera_view, normal)),
           normalize(mat4_transform_direction(camera_view, view_dir))
end

@inline function _shade_matcap_face(normal::Vec3, view_dir::Vec3,
                                    material::MeshMatcapMaterial,
                                    camera_view)
    _validate_material_parameters(material)
    if material.matcap isa Texture
        view_normal, matcap_view_dir =
            _matcap_view_vectors(normal, view_dir, camera_view)
        # View-dependent matcap basis (matches the web-export shader / three.js):
        # with a camera view, both inputs are already in view space, so mx/my
        # follow camera roll instead of being glued to world axes.
        s = Vec3(matcap_view_dir.z, 0.0, -matcap_view_dir.x)
        sl = norm(s)
        mx = sl > 1e-6 ? s / sl : Vec3(1.0, 0.0, 0.0)   # fallback when view_dir ≈ ±Y
        my = cross(matcap_view_dir, mx)
        u = clamp(dot(mx, view_normal) * 0.495 + 0.5, 0.0, 1.0)
        v = clamp(dot(my, view_normal) * 0.495 + 0.5, 0.0, 1.0)
        return material.color * sample_texture_linear(material.matcap, u, v)
    end
    # Procedural fallback: brighter where the surface faces the viewer.
    f = max(dot(normal, view_dir), 0.0)
    material.color * (0.35 + 0.65 * f)
end

function shade_face(normal::Vec3, view_dir::Vec3, position::Vec3,
                    material::MeshMatcapMaterial, lights;
                    shadow_fn=nothing,
                    camera_view::Union{Nothing,Mat4}=nothing)
    return _shade_matcap_face(normal, view_dir, material, camera_view)
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

@inline _finite_light_vec3(v::Vec3) =
    isfinite(v.x) && isfinite(v.y) && isfinite(v.z)

@inline function _light_direction_and_distance(from::Vec3, to::Vec3)
    displacement = to - from
    distance = norm(displacement)
    if _finite_light_vec3(displacement)
        return !iszero(_primal_value(distance)) && !_normal_length_needs_scaling(distance) ?
            (displacement / distance, distance) :
            (normalize(displacement), distance)
    end

    # Subtracting finite positions with opposite extreme signs can overflow a
    # component even though their direction remains well-defined. Recover the
    # direction from scaled component differences; the distance may correctly
    # remain infinite when its mathematical value exceeds Float64's range.
    if _finite_light_vec3(from) && _finite_light_vec3(to)
        scaled, _, nonzero =
            _difference_direction_and_logscale(from, to)
        if nonzero
            scaled_norm = norm(scaled)
            direction = scaled / scaled_norm
            return direction, distance
        end
    end

    # Preserve invalid-input propagation for non-finite light or surface data.
    return displacement / max(distance, 1e-10), distance
end

function light_contribution(light::AmbientLight, position::Vec3)
    _validate_light_parameters(light)
    (light.color, light.intensity, Vec3(0.0, 1.0, 0.0))
end

function light_contribution(light::DirectionalLight, position::Vec3)
    _validate_light_parameters(light)
    dir = light.rotation_driven ? -_light_emission_direction(light) :
          _direction_between(light.target, _light_world_position(light))
    (light.color, light.intensity, dir)
end

# three.js `getDistanceAttenuation`: inverse power falloff capped at 100x, with
# the Frostbite window `(1 - (d/cutoff)^4)^2` when a finite cutoff is set.
@inline function _distance_attenuation(dist, cutoff::Float64, decay::Float64)
    falloff = one(dist) / max(dist^decay, 0.01)
    cutoff > 0 || return falloff
    ratio = dist / cutoff
    window = clamp(1 - ratio^4, zero(ratio), one(ratio))
    return falloff * window * window
end

function light_contribution(light::PointLight, position::Vec3)
    _validate_light_parameters(light)
    dir, dist =
        _light_direction_and_distance(position, _light_world_position(light))
    attenuation = _distance_attenuation(dist, light.distance, light.decay)

    # IES photometric distribution (mirrors the SpotLight branch). A PointLight
    # has no target, so the vertical angle θ is measured from the luminaire aim
    # axis per the LM-63 convention (0° = straight down; see IESProfile): -Y,
    # rotated by the light's `rotation` so an oriented luminaire works.
    if light.ies_profile !== nothing
        axis = _light_world_direction(light, Vec3(0.0, -1.0, 0.0))
        θ = acosd(clamp(dot(-dir, axis), -1.0, 1.0))
        attenuation *= ies_intensity(light.ies_profile, θ)
    end

    (light.color, light.intensity * attenuation, dir)
end

function light_contribution(light::SpotLight, position::Vec3)
    _validate_light_parameters(light)
    light_position = _light_world_position(light)
    dir, dist =
        _light_direction_and_distance(position, light_position)

    # Spot cone
    target_dir = _light_emission_direction(light)
    # dir points from surface to light, so -dir points from light to surface.
    cos_angle = dot(-dir, target_dir)
    cos_outer = cos(light.angle)
    cos_inner = cos(light.angle * (1 - light.penumbra))

    # three.js `getSpotAttenuation` = smoothstep(coneCos, penumbraCos, angleCos).
    t = clamp((cos_angle - cos_outer) / max(cos_inner - cos_outer, 1e-10), 0.0, 1.0)
    spot_effect = t * t * (3 - 2t)

    attenuation = spot_effect * _distance_attenuation(dist, light.distance, light.decay)

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
    _validate_light_parameters(light)
    # Blend between sky and ground based on normal direction
    # We return the sky color; the shade function should handle hemisphere blending
    (light.color, light.intensity, Vec3(0.0, 1.0, 0.0))
end

function light_contribution(light::RectAreaLight, position::Vec3)
    _validate_light_parameters(light)
    dir, _ =
        _light_direction_and_distance(position, _light_world_position(light))
    (light.color, light.intensity, dir)
end

# Special handling for ambient in shade functions
function shade_face_with_ambient(normal, view_dir, position, material, lights)
    _validate_material_parameters(material)
    result = Color3(0.0, 0.0, 0.0)
    for light in lights
        _validate_light_parameters(light)
        if light isa AmbientLight
            mc = _material_color(material)
            result = result + mc * light.color * light.intensity
        elseif light isa HemisphereLight
            mc = _material_color(material)
            weight = dot(normal, _hemisphere_direction(light)) * 0.5 + 0.5
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

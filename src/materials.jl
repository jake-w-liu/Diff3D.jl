# --------------------------------------------------------------------------
# Material types mirroring three.js material hierarchy.
# --------------------------------------------------------------------------

abstract type AbstractMaterial end

@noinline function _throw_material_unit_interval(name::Symbol)
    throw(ArgumentError("material $name must be finite and between 0 and 1"))
end

@inline function _validated_material_unit_interval(value, name::Symbol)
    value isa Bool && _throw_material_unit_interval(name)
    result = Float64(value)
    isfinite(result) && 0.0 <= result <= 1.0 ||
        _throw_material_unit_interval(name)
    return result
end

@inline function _validated_material_side(side)
    (side === :front || side === :back || side === :double) ||
        throw(ArgumentError("material side must be one of :front, :back, or :double"))
    return side
end

@inline _validated_material_opacity(value) =
    _validated_material_unit_interval(value, :opacity)
@inline _validated_material_alpha_test(value) =
    _validated_material_unit_interval(value, :alpha_test)
@inline _validated_material_metalness(value) =
    _validated_material_unit_interval(value, :metalness)
@inline _validated_material_roughness(value) =
    _validated_material_unit_interval(value, :roughness)

@inline _validate_material_parameters(::AbstractMaterial) = nothing

# ========================== MeshBasicMaterial ==========================
# Unlit, flat color

struct MeshBasicMaterial <: AbstractMaterial
    color::Color3{Float64}
    opacity::Float64
    transparent::Bool
    wireframe::Bool
    side::Symbol  # :front, :back, :double
    map::Any      # optional albedo Texture
    alpha_map::Any
    ao_map::Any
    light_map::Any
    ao_map_intensity::Float64
    light_map_intensity::Float64
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    alpha_test::Float64
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshBasicMaterial(; color=Color3(1.0, 1.0, 1.0), opacity=1.0,
                           transparent=false, wireframe=false, side=:front, map=nothing,
                           alpha_map=nothing, ao_map=nothing, light_map=nothing,
                           ao_map_intensity=1.0, light_map_intensity=1.0,
                           vertex_colors=false, alpha_test=0.0,
                           depth_test=true, depth_write=true,
                           clipping_planes=Plane{Float64}[])
    MeshBasicMaterial(color, _validated_material_opacity(opacity), transparent, wireframe,
                      _validated_material_side(side), map, alpha_map,
                      ao_map, light_map, Float64(ao_map_intensity),
                      Float64(light_map_intensity), vertex_colors,
                      _validated_material_alpha_test(alpha_test),
                      depth_test, depth_write,
                      _material_clipping_planes(clipping_planes))
end

function MeshBasicMaterial(color::Color3, opacity, transparent::Bool, wireframe::Bool,
                           side::Symbol, map, alpha_map, vertex_colors::Bool,
                           alpha_test, depth_test::Bool, depth_write::Bool)
    MeshBasicMaterial(color, _validated_material_opacity(opacity), transparent, wireframe,
                      _validated_material_side(side), map, alpha_map,
                      nothing, nothing, 1.0, 1.0, vertex_colors,
                      _validated_material_alpha_test(alpha_test),
                      depth_test, depth_write,
                      Plane{Float64}[])
end

MeshBasicMaterial(args::Vararg{Any,15}) =
    MeshBasicMaterial(args..., Plane{Float64}[])

struct SpriteMaterial <: AbstractMaterial
    color::Color3{Float64}
    opacity::Float64
    transparent::Bool
    map::Any
    alpha_map::Any
    rotation::Float64
    size_attenuation::Bool
    alpha_test::Float64
    depth_test::Bool
    depth_write::Bool
end

function SpriteMaterial(color::Color3, opacity, transparent::Bool, map,
                        rotation, size_attenuation::Bool, depth_test::Bool,
                        depth_write::Bool)
    SpriteMaterial(color, _validated_material_opacity(opacity), transparent, map, nothing,
                   Float64(rotation), size_attenuation, 0.0,
                   depth_test, depth_write)
end

function SpriteMaterial(; color=Color3(1.0, 1.0, 1.0), opacity=1.0,
                        transparent=false, map=nothing, alpha_map=nothing,
                        rotation=0.0, size_attenuation=true, alpha_test=0.0,
                        depth_test=true, depth_write=true)
    SpriteMaterial(color, _validated_material_opacity(opacity), transparent, map, alpha_map,
                   Float64(rotation), size_attenuation,
                   _validated_material_alpha_test(alpha_test),
                   depth_test, depth_write)
end

# ========================== MeshLambertMaterial ==========================
# Diffuse-only (Lambertian)

struct MeshLambertMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    opacity::Float64
    transparent::Bool
    wireframe::Bool
    side::Symbol
    map::Any
    normal_map::Any
    normal_scale::Float64
    alpha_map::Any
    ao_map::Any
    emissive_map::Any
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    alpha_test::Float64
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshLambertMaterial(; color=Color3(1.0, 1.0, 1.0),
                              emissive=Color3(0.0, 0.0, 0.0),
                              opacity=1.0, transparent=false, wireframe=false, side=:front,
                              map=nothing, normal_map=nothing, normal_scale=1.0,
                              alpha_map=nothing, ao_map=nothing,
                              emissive_map=nothing, emissive_intensity=1.0,
                              ao_map_intensity=1.0, light_map_intensity=1.0,
                              vertex_colors=false,
                              light_map=nothing, alpha_test=0.0,
                              depth_test=true, depth_write=true,
                              clipping_planes=Plane{Float64}[])
    MeshLambertMaterial(color, emissive, _validated_material_opacity(opacity),
                        transparent, wireframe,
                        _validated_material_side(side), map,
                        normal_map, Float64(normal_scale), alpha_map, ao_map,
                        emissive_map, Float64(emissive_intensity),
                        Float64(ao_map_intensity), Float64(light_map_intensity), vertex_colors,
                        light_map, _validated_material_alpha_test(alpha_test),
                        depth_test, depth_write,
                        _material_clipping_planes(clipping_planes))
end

function MeshLambertMaterial(color::Color3, emissive::Color3, opacity, transparent::Bool,
                             wireframe::Bool, side::Symbol, map, alpha_map, ao_map,
                             emissive_map, emissive_intensity, vertex_colors::Bool,
                             light_map, alpha_test, depth_test::Bool, depth_write::Bool)
    MeshLambertMaterial(color, emissive, opacity, transparent, wireframe, side, map,
                        nothing, 1.0, alpha_map, ao_map, emissive_map,
                        emissive_intensity, 1.0, 1.0, vertex_colors, light_map,
                        alpha_test, depth_test, depth_write)
end

function MeshLambertMaterial(color::Color3, emissive::Color3, opacity, transparent::Bool,
                             wireframe::Bool, side::Symbol, map, normal_map,
                             normal_scale, alpha_map, ao_map, emissive_map,
                             emissive_intensity, vertex_colors::Bool, light_map,
                             alpha_test, depth_test::Bool, depth_write::Bool)
    MeshLambertMaterial(color, emissive, opacity, transparent, wireframe, side, map,
                        normal_map, Float64(normal_scale), alpha_map, ao_map,
                        emissive_map, Float64(emissive_intensity), 1.0, 1.0, vertex_colors,
                        light_map, Float64(alpha_test), depth_test, depth_write)
end

function MeshLambertMaterial(color::Color3, emissive::Color3, opacity, transparent::Bool,
                             wireframe::Bool, side::Symbol, map, normal_map,
                             normal_scale, alpha_map, ao_map, emissive_map,
                             emissive_intensity, ao_map_intensity, light_map_intensity,
                             vertex_colors::Bool, light_map, alpha_test,
                             depth_test::Bool, depth_write::Bool)
    MeshLambertMaterial(color, emissive, _validated_material_opacity(opacity),
                        transparent, wireframe,
                        _validated_material_side(side), map,
                        normal_map, Float64(normal_scale), alpha_map, ao_map,
                        emissive_map, Float64(emissive_intensity),
                        Float64(ao_map_intensity), Float64(light_map_intensity), vertex_colors,
                        light_map, _validated_material_alpha_test(alpha_test),
                        depth_test, depth_write,
                        Plane{Float64}[])
end

function MeshLambertMaterial(color::Color3, emissive::Color3, opacity, transparent::Bool,
                             wireframe::Bool, side::Symbol, map, alpha_map, ao_map,
                             emissive_map, vertex_colors::Bool, light_map, alpha_test,
                             depth_test::Bool, depth_write::Bool)
    MeshLambertMaterial(color, emissive, opacity, transparent, wireframe, side, map,
                        nothing, 1.0, alpha_map, ao_map, emissive_map, 1.0,
                        1.0, 1.0, vertex_colors, light_map, alpha_test,
                        depth_test, depth_write)
end

function MeshLambertMaterial(color::Color3, emissive::Color3, opacity, transparent::Bool,
                             wireframe::Bool, side::Symbol, map, ao_map, emissive_map,
                             vertex_colors::Bool, light_map, depth_test::Bool,
                             depth_write::Bool)
    MeshLambertMaterial(color, emissive, opacity, transparent, wireframe, side, map,
                        nothing, 1.0, nothing, ao_map, emissive_map, 1.0,
                        1.0, 1.0, vertex_colors, light_map, 0.0,
                        depth_test, depth_write)
end

# ========================== MeshPhongMaterial ==========================
# Blinn-Phong shading

const _PHONG_GLOSSINESS_EPS = 1e-4

@inline function _phong_shininess_from_glossiness(glossiness)
    g = clamp(Float64(glossiness), 0.0, 1.0)
    rough = 1.0 - g
    # glTF spec-gloss defines microfacet alpha as (1 - glossiness)^2; the
    # Blinn exponent relation alpha ~= sqrt(2 / (n + 2)) gives n below.
    return max(2.0 / max(rough^4, _PHONG_GLOSSINESS_EPS) - 2.0, 0.0001)
end

@inline function _phong_glossiness_from_shininess(shininess)
    n = max(Float64(shininess), 0.0001)
    return clamp(1.0 - (2.0 / (n + 2.0))^0.25, 0.0, 1.0)
end

struct MeshPhongMaterial <: AbstractMaterial
    color::Color3{Float64}
    specular::Color3{Float64}
    emissive::Color3{Float64}
    shininess::Float64
    glossiness::Float64
    opacity::Float64
    transparent::Bool
    wireframe::Bool
    side::Symbol
    map::Any
    specular_map::Any
    glossiness_map::Any
    normal_map::Any
    normal_scale::Float64
    alpha_map::Any
    ao_map::Any
    emissive_map::Any
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    alpha_test::Float64
    clipping_planes::Vector{Plane{Float64}}
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    depth_test::Bool
    depth_write::Bool
end

function MeshPhongMaterial(; color=Color3(1.0, 1.0, 1.0),
                            specular=Color3(0.066, 0.066, 0.066),
                            emissive=Color3(0.0, 0.0, 0.0),
                            shininess=nothing,
                            glossiness=nothing,
                            opacity=1.0,
                            transparent=false, wireframe=false, side=:front, map=nothing,
                            specular_map=nothing, glossiness_map=nothing,
                            normal_map=nothing, normal_scale=1.0, alpha_map=nothing,
                            ao_map=nothing, emissive_map=nothing, light_map=nothing,
                            vertex_colors=false, alpha_test=0.0, emissive_intensity=1.0,
                            ao_map_intensity=1.0, light_map_intensity=1.0,
                            clipping_planes=Plane{Float64}[],
                            depth_test=true, depth_write=true)
    resolved_shininess = shininess === nothing ?
                         (glossiness === nothing ? 30.0 :
                          _phong_shininess_from_glossiness(glossiness)) :
                         Float64(shininess)
    resolved_glossiness = glossiness === nothing ?
                          _phong_glossiness_from_shininess(resolved_shininess) :
                          Float64(glossiness)
    MeshPhongMaterial(color, specular, emissive, resolved_shininess,
                      resolved_glossiness, _validated_material_opacity(opacity),
                      transparent, wireframe,
                      _validated_material_side(side), map,
                      specular_map, glossiness_map, normal_map,
                      Float64(normal_scale), alpha_map, ao_map, emissive_map,
                      light_map, vertex_colors,
                      _validated_material_alpha_test(alpha_test),
                      _material_clipping_planes(clipping_planes),
                      Float64(emissive_intensity), Float64(ao_map_intensity),
                      Float64(light_map_intensity), depth_test, depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, wireframe::Bool, side::Symbol,
                           map, alpha_map, emissive_map, light_map, vertex_colors::Bool,
                           alpha_test, clipping_planes::Vector{Plane{Float64}},
                           emissive_intensity, depth_test::Bool, depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, wireframe=wireframe, side=side,
                      map=map, alpha_map=alpha_map, emissive_map=emissive_map,
                      light_map=light_map, vertex_colors=vertex_colors,
                      alpha_test=alpha_test, clipping_planes=clipping_planes,
                      emissive_intensity=emissive_intensity,
                      depth_test=depth_test, depth_write=depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, side::Symbol, map, alpha_map,
                           emissive_map, light_map, vertex_colors::Bool, alpha_test,
                           clipping_planes::Vector{Plane{Float64}},
                           emissive_intensity, depth_test::Bool, depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, side=side, map=map,
                      alpha_map=alpha_map, emissive_map=emissive_map,
                      light_map=light_map, vertex_colors=vertex_colors,
                      alpha_test=alpha_test, clipping_planes=clipping_planes,
                      emissive_intensity=emissive_intensity,
                      depth_test=depth_test, depth_write=depth_write)
end

@noinline function _throw_material_clipping_plane(index::Int, suffix::String)
    throw(ArgumentError("material clipping plane $index $suffix"))
end

@inline function _validate_material_clipping_planes(clipping_planes)
    for (index, plane) in enumerate(clipping_planes)
        plane isa Plane || _throw_material_clipping_plane(index, "must be a Plane")
        normal = plane.normal
        nx = Float64(normal.x)
        ny = Float64(normal.y)
        nz = Float64(normal.z)
        constant = Float64(plane.constant)
        isfinite(nx) && isfinite(ny) && isfinite(nz) && isfinite(constant) ||
            _throw_material_clipping_plane(index, "must be finite")
    end
    return nothing
end

function _material_clipping_planes(clipping_planes)
    _validate_material_clipping_planes(clipping_planes)
    return [Plane(Vec3(Float64(p.normal.x), Float64(p.normal.y), Float64(p.normal.z)),
                  Float64(p.constant)) for p in clipping_planes]
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, side::Symbol, map, alpha_map,
                           light_map, vertex_colors::Bool, alpha_test, depth_test::Bool,
                           depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, side=side, map=map,
                      alpha_map=alpha_map, light_map=light_map,
                      vertex_colors=vertex_colors, alpha_test=alpha_test,
                      depth_test=depth_test, depth_write=depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, side::Symbol, map, alpha_map,
                           light_map, vertex_colors::Bool, alpha_test,
                           clipping_planes::Vector{Plane{Float64}},
                           depth_test::Bool, depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, side=side, map=map,
                      alpha_map=alpha_map, light_map=light_map,
                      vertex_colors=vertex_colors, alpha_test=alpha_test,
                      clipping_planes=clipping_planes,
                      depth_test=depth_test, depth_write=depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, side::Symbol, map, alpha_map,
                           light_map, alpha_test, depth_test::Bool, depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, side=side, map=map,
                      alpha_map=alpha_map, light_map=light_map,
                      alpha_test=alpha_test, depth_test=depth_test,
                      depth_write=depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3, shininess,
                           opacity, transparent::Bool, side::Symbol, map, light_map,
                           depth_test::Bool, depth_write::Bool)
    MeshPhongMaterial(color=color, specular=specular, emissive=emissive,
                      shininess=shininess, opacity=opacity,
                      transparent=transparent, side=side, map=map,
                      light_map=light_map, depth_test=depth_test,
                      depth_write=depth_write)
end

function MeshPhongMaterial(color::Color3, specular::Color3, emissive::Color3,
                           shininess, glossiness, opacity, transparent::Bool,
                           wireframe::Bool, side::Symbol, map, specular_map,
                           glossiness_map, normal_map, normal_scale, alpha_map,
                           ao_map, emissive_map, light_map, vertex_colors::Bool,
                           alpha_test, emissive_intensity, ao_map_intensity,
                           light_map_intensity, depth_test::Bool,
                           depth_write::Bool)
    MeshPhongMaterial(color, specular, emissive, shininess, glossiness,
                      _validated_material_opacity(opacity),
                      transparent, wireframe, _validated_material_side(side), map,
                      specular_map, glossiness_map, normal_map, normal_scale, alpha_map,
                      ao_map, emissive_map, light_map, vertex_colors,
                      _validated_material_alpha_test(alpha_test),
                      Plane{Float64}[], emissive_intensity, ao_map_intensity,
                      light_map_intensity, depth_test, depth_write)
end

# ========================== MeshStandardMaterial ==========================
# PBR (metallic-roughness workflow)

struct MeshStandardMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    metalness::Float64
    roughness::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    map::Any
    normal_map::Any
    normal_scale::Float64
    roughness_map::Any
    metalness_map::Any
    alpha_map::Any
    ao_map::Any
    emissive_map::Any
    vertex_colors::Bool   # modulate by geometry :color attribute when true
    alpha_test::Float64
    envmap::Any           # optional CubeTexture for reflection (IBL specular)
    light_map::Any        # baked indirect-lighting texture (multiplied in, like aoMap)
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    env_map_intensity::Float64
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshStandardMaterial(; color=Color3(1.0, 1.0, 1.0),
                               emissive=Color3(0.0, 0.0, 0.0),
                               metalness=0.0, roughness=1.0,
                               opacity=1.0, transparent=false, side=:front,
                               map=nothing, normal_map=nothing, normal_scale=1.0,
                               roughness_map=nothing, metalness_map=nothing, alpha_map=nothing,
                               ao_map=nothing, emissive_map=nothing,
                               vertex_colors=false, alpha_test=0.0,
                               envmap=nothing, light_map=nothing,
                               emissive_intensity=1.0, ao_map_intensity=1.0,
                               light_map_intensity=1.0, env_map_intensity=1.0,
                               depth_test=true, depth_write=true,
                               clipping_planes=Plane{Float64}[])
    MeshStandardMaterial(color, emissive,
                         _validated_material_metalness(metalness),
                         _validated_material_roughness(roughness),
                         _validated_material_opacity(opacity), transparent,
                         _validated_material_side(side),
                         map, normal_map, Float64(normal_scale), roughness_map, metalness_map, alpha_map,
                         ao_map, emissive_map, vertex_colors,
                         _validated_material_alpha_test(alpha_test), envmap, light_map,
                         emissive_intensity, ao_map_intensity, light_map_intensity,
                         env_map_intensity, depth_test, depth_write,
                         _material_clipping_planes(clipping_planes))
end

MeshStandardMaterial(args::Vararg{Any,25}) =
    MeshStandardMaterial(args..., Plane{Float64}[])

@inline function _validate_material_parameters(material::MeshStandardMaterial)
    _validated_material_metalness(material.metalness)
    _validated_material_roughness(material.roughness)
    return nothing
end

# ========================== MeshNormalMaterial ==========================
# Maps normals to RGB

struct MeshNormalMaterial <: AbstractMaterial
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshNormalMaterial(; opacity=1.0, transparent=false, side=:front,
                            depth_test=true, depth_write=true,
                            clipping_planes=Plane{Float64}[])
    MeshNormalMaterial(_validated_material_opacity(opacity), transparent,
                       _validated_material_side(side),
                       depth_test, depth_write,
                       _material_clipping_planes(clipping_planes))
end

MeshNormalMaterial(args::Vararg{Any,5}) =
    MeshNormalMaterial(args..., Plane{Float64}[])

# ========================== LineBasicMaterial ==========================

struct LineBasicMaterial <: AbstractMaterial
    color::Color3{Float64}
    linewidth::Float64
    opacity::Float64
    depth_test::Bool
    depth_write::Bool
end

function LineBasicMaterial(; color=Color3(1.0, 1.0, 1.0), linewidth=1.0, opacity=1.0,
                           depth_test=true, depth_write=true)
    LineBasicMaterial(color, _line_material_width(linewidth),
                      _validated_material_opacity(opacity),
                      depth_test, depth_write)
end

function _line_material_positive(name::Symbol, value)
    value isa Bool &&
        throw(ArgumentError("$(name) must be a finite positive value"))
    x = Float64(value)
    isfinite(x) && x > 0.0 ||
        throw(ArgumentError("$(name) must be a finite positive value"))
    return x
end

function _line_material_width(value)
    width = _line_material_positive(:linewidth, value)
    width <= Float64(typemax(Int) ÷ 4) ||
        throw(ArgumentError("linewidth is too large"))
    return width
end

function _line_material_nonnegative(name::Symbol, value)
    value isa Bool &&
        throw(ArgumentError("$(name) must be a finite non-negative value"))
    x = Float64(value)
    isfinite(x) && x >= 0.0 ||
        throw(ArgumentError("$(name) must be a finite non-negative value"))
    return x
end

function _line_material_alias(primary, alias, default, primary_name::Symbol, alias_name::Symbol)
    if primary !== nothing && alias !== nothing
        throw(ArgumentError("pass only one of $(primary_name) or $(alias_name)"))
    end
    return primary !== nothing ? primary : alias !== nothing ? alias : default
end

# ========================== LineDashedMaterial ==========================

struct LineDashedMaterial <: AbstractMaterial
    color::Color3{Float64}
    linewidth::Float64
    scale::Float64
    dash_size::Float64
    gap_size::Float64
    opacity::Float64
    depth_test::Bool
    depth_write::Bool
end

function LineDashedMaterial(; color=Color3(1.0, 1.0, 1.0), linewidth=1.0,
                            scale=1.0, dash_size=nothing, gap_size=nothing,
                            dashSize=nothing, gapSize=nothing, opacity=1.0,
                            depth_test=true, depth_write=true)
    dash = _line_material_nonnegative(:dash_size,
        _line_material_alias(dash_size, dashSize, 3.0, :dash_size, :dashSize))
    gap = _line_material_nonnegative(:gap_size,
        _line_material_alias(gap_size, gapSize, 1.0, :gap_size, :gapSize))
    dash + gap > 0.0 ||
        throw(ArgumentError("dash_size and gap_size cannot both be zero"))
    LineDashedMaterial(convert(Color3{Float64}, color),
                       _line_material_width(linewidth),
                       _line_material_positive(:scale, scale),
                       dash, gap, _validated_material_opacity(opacity),
                       depth_test, depth_write)
end

# ========================== PointsMaterial ==========================

struct PointsMaterial <: AbstractMaterial
    color::Color3{Float64}
    size::Float64
    opacity::Float64
    transparent::Bool
    map::Any
    alpha_map::Any
    alpha_test::Float64
    size_attenuation::Bool
    depth_test::Bool
    depth_write::Bool
end

function PointsMaterial(; color=Color3(1.0, 1.0, 1.0), size=1.0, opacity=1.0,
                        transparent=false, map=nothing, alpha_map=nothing,
                        alpha_test=0.0, size_attenuation=true,
                        depth_test=true, depth_write=true)
    PointsMaterial(color, _point_material_size(size),
                   _validated_material_opacity(opacity), transparent,
                   map, alpha_map, _validated_material_alpha_test(alpha_test), size_attenuation,
                   depth_test, depth_write)
end

function PointsMaterial(color::Color3, size, opacity, transparent::Bool, map,
                        alpha_map, alpha_test, depth_test::Bool,
                        depth_write::Bool)
    PointsMaterial(color, _point_material_size(size),
                   _validated_material_opacity(opacity), transparent,
                   map, alpha_map, _validated_material_alpha_test(alpha_test), true,
                   depth_test, depth_write)
end

function PointsMaterial(color::Color3, size, opacity, transparent::Bool, map,
                        depth_test::Bool, depth_write::Bool)
    PointsMaterial(color, _point_material_size(size),
                   _validated_material_opacity(opacity), transparent,
                   map, nothing, 0.0, true, depth_test, depth_write)
end

function _point_material_size(value)
    value isa Bool &&
        throw(ArgumentError("point size must be finite and non-negative"))
    size = Float64(value)
    isfinite(size) && size >= 0.0 ||
        throw(ArgumentError("point size must be finite and non-negative"))
    size <= Float64(typemax(Int) ÷ 4) ||
        throw(ArgumentError("point size is too large"))
    return size
end

# ========================== MeshPhysicalMaterial ==========================
# PBR extended with a dielectric clearcoat lobe, transmission and IOR.

struct MeshPhysicalMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    metalness::Float64
    roughness::Float64
    clearcoat::Float64
    clearcoat_roughness::Float64
    transmission::Float64
    ior::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    envmap::Any           # optional CubeTexture for reflection (IBL specular)
    map::Any
    normal_map::Any
    normal_scale::Float64
    roughness_map::Any
    metalness_map::Any
    ao_map::Any
    emissive_map::Any
    alpha_map::Any
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    env_map_intensity::Float64
    alpha_test::Float64
    # --- three.js MeshPhysicalMaterial extensions (added last, keyword defaults) ---
    sheen::Float64                 # retroreflective sheen strength (0 = off)
    sheen_color::Color3{Float64}   # tint of the sheen lobe
    sheen_roughness::Float64       # Charlie-distribution roughness (1 = broad)
    iridescence::Float64           # thin-film interference blend (0 = off)
    iridescence_ior::Float64       # refractive index of the thin film
    iridescence_thickness::Float64 # film thickness in nanometres
    light_map::Any                 # baked indirect-lighting texture (multiplied in)
    clearcoat_map::Any
    clearcoat_roughness_map::Any
    transmission_map::Any
    thickness::Float64
    thickness_map::Any
    attenuation_distance::Float64
    attenuation_color::Color3{Float64}
    sheen_color_map::Any
    sheen_roughness_map::Any
    iridescence_map::Any
    iridescence_thickness_map::Any
    specular_intensity::Float64
    specular_color::Color3{Float64}
    specular_intensity_map::Any
    specular_color_map::Any
    vertex_colors::Bool
    clearcoat_normal_map::Any
    clearcoat_normal_scale::Float64
    dispersion::Float64
    anisotropy::Float64
    anisotropy_rotation::Float64
    anisotropy_map::Any
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshPhysicalMaterial(; color=Color3(1.0,1.0,1.0), emissive=Color3(0.0,0.0,0.0),
                               metalness=0.0, roughness=1.0, clearcoat=0.0,
                               clearcoat_roughness=0.0, transmission=0.0, ior=1.5,
                               opacity=1.0, transparent=false, side=:front, envmap=nothing,
                                map=nothing, normal_map=nothing, normal_scale=1.0,
                               roughness_map=nothing, metalness_map=nothing, ao_map=nothing, emissive_map=nothing,
                               alpha_map=nothing, emissive_intensity=1.0, ao_map_intensity=1.0,
                               light_map_intensity=1.0, env_map_intensity=1.0,
                               alpha_test=0.0,
                               sheen=0.0, sheen_color=Color3(1.0,1.0,1.0), sheen_roughness=1.0,
                               iridescence=0.0, iridescence_ior=1.3, iridescence_thickness=400.0,
                               light_map=nothing,
                               clearcoat_map=nothing, clearcoat_roughness_map=nothing,
                               transmission_map=nothing, thickness=0.0, thickness_map=nothing,
                               attenuation_distance=0.0,
                               attenuation_color=Color3(1.0,1.0,1.0),
                               sheen_color_map=nothing,
                               sheen_roughness_map=nothing, iridescence_map=nothing,
                               iridescence_thickness_map=nothing,
                               specular_intensity=1.0, specular_color=Color3(1.0,1.0,1.0),
                               specular_intensity_map=nothing, specular_color_map=nothing,
                               vertex_colors=false, clearcoat_normal_map=nothing,
                               clearcoat_normal_scale=1.0, dispersion=0.0,
                               anisotropy=0.0, anisotropy_rotation=0.0,
                               anisotropy_map=nothing,
                               depth_test=true, depth_write=true,
                               clipping_planes=Plane{Float64}[])
    MeshPhysicalMaterial(color, emissive,
                         _validated_material_metalness(metalness),
                         _validated_material_roughness(roughness), clearcoat,
                         clearcoat_roughness, transmission, ior,
                         _validated_material_opacity(opacity), transparent,
                         _validated_material_side(side),
                          envmap, map, normal_map, Float64(normal_scale), roughness_map, metalness_map, ao_map,
                          emissive_map, alpha_map, emissive_intensity, ao_map_intensity,
                          light_map_intensity, env_map_intensity,
                          _validated_material_alpha_test(alpha_test),
                         sheen, sheen_color, sheen_roughness,
                         iridescence, iridescence_ior, iridescence_thickness, light_map,
                         clearcoat_map, clearcoat_roughness_map, transmission_map,
                         Float64(thickness), thickness_map, Float64(attenuation_distance),
                         attenuation_color,
                         sheen_color_map, sheen_roughness_map, iridescence_map,
                         iridescence_thickness_map, specular_intensity, specular_color,
                         specular_intensity_map, specular_color_map, vertex_colors,
                         clearcoat_normal_map, Float64(clearcoat_normal_scale),
                         Float64(dispersion), Float64(anisotropy),
                         Float64(anisotropy_rotation), anisotropy_map,
                         depth_test, depth_write,
                         _material_clipping_planes(clipping_planes))
end

MeshPhysicalMaterial(args::Vararg{Any,56}) =
    MeshPhysicalMaterial(args..., Plane{Float64}[])

@inline function _validate_material_parameters(material::MeshPhysicalMaterial)
    _validated_material_metalness(material.metalness)
    _validated_material_roughness(material.roughness)
    return nothing
end

# ========================== MeshToonMaterial ==========================
# Quantized (cel-shaded) diffuse, optionally sampled from a toon gradient map.

function _toon_gradient_steps(gradient_steps)
    steps = Int(gradient_steps)
    steps > 0 || throw(ArgumentError("gradient_steps must be positive"))
    return steps
end

function _toon_gradient_map(gradient_map)
    gradient_map === nothing && return nothing
    gradient_map isa Texture && return gradient_map
    throw(ArgumentError("gradient_map must be a Texture or nothing"))
end

struct MeshToonMaterial <: AbstractMaterial
    color::Color3{Float64}
    emissive::Color3{Float64}
    gradient_steps::Int
    gradient_map::Any
    map::Any
    normal_map::Any
    normal_scale::Float64
    alpha_map::Any
    ao_map::Any
    light_map::Any
    emissive_map::Any
    emissive_intensity::Float64
    ao_map_intensity::Float64
    light_map_intensity::Float64
    alpha_test::Float64
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}

    function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                              gradient_map, map, normal_map, normal_scale,
                              alpha_map, ao_map, light_map, emissive_map,
                              emissive_intensity, ao_map_intensity,
                              light_map_intensity, alpha_test, opacity,
                              transparent::Bool, side::Symbol, depth_test::Bool,
                              depth_write::Bool, clipping_planes)
        new(convert(Color3{Float64}, color), convert(Color3{Float64}, emissive),
            _toon_gradient_steps(gradient_steps), _toon_gradient_map(gradient_map),
            map, normal_map, Float64(normal_scale), alpha_map, ao_map, light_map,
            emissive_map, Float64(emissive_intensity), Float64(ao_map_intensity),
            Float64(light_map_intensity), _validated_material_alpha_test(alpha_test),
            _validated_material_opacity(opacity),
            transparent, _validated_material_side(side), depth_test, depth_write,
            _material_clipping_planes(clipping_planes))
    end
end

function MeshToonMaterial(; color=Color3(1.0,1.0,1.0), emissive=Color3(0.0,0.0,0.0),
                           gradient_steps=3, gradient_map=nothing, map=nothing,
                           normal_map=nothing, normal_scale=1.0,
                           alpha_map=nothing, ao_map=nothing, light_map=nothing,
                           emissive_map=nothing, emissive_intensity=1.0,
                           ao_map_intensity=1.0, light_map_intensity=1.0,
                           alpha_test=0.0, opacity=1.0,
                           transparent=false, side=:front,
                           depth_test=true, depth_write=true,
                           clipping_planes=Plane{Float64}[])
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, map, normal_map,
                     normal_scale, alpha_map, ao_map, light_map, emissive_map,
                     emissive_intensity, ao_map_intensity, light_map_intensity,
                     alpha_test, opacity, transparent, side, depth_test, depth_write,
                     clipping_planes)
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          gradient_map, map, normal_map, normal_scale,
                          alpha_map, ao_map, light_map, emissive_map,
                          emissive_intensity, ao_map_intensity,
                          light_map_intensity, alpha_test, opacity,
                          transparent::Bool, side::Symbol, depth_test::Bool,
                          depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, map, normal_map,
                     normal_scale, alpha_map, ao_map, light_map, emissive_map,
                     emissive_intensity, ao_map_intensity, light_map_intensity,
                     alpha_test, opacity, transparent, side, depth_test, depth_write,
                     Plane{Float64}[])
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          gradient_map, map, alpha_map, emissive_map,
                          emissive_intensity, alpha_test, opacity,
                          transparent::Bool, side::Symbol, depth_test::Bool,
                          depth_write::Bool, clipping_planes)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, map, nothing,
                     1.0, alpha_map, nothing, nothing, emissive_map,
                     emissive_intensity, 1.0, 1.0, alpha_test, opacity,
                     transparent, side, depth_test, depth_write, clipping_planes)
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          gradient_map, map, alpha_map, emissive_map,
                          emissive_intensity, alpha_test, opacity,
                          transparent::Bool, side::Symbol, depth_test::Bool,
                          depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, map, alpha_map,
                     emissive_map, emissive_intensity, alpha_test, opacity, transparent,
                     side, depth_test, depth_write, Plane{Float64}[])
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          gradient_map, map, alpha_map, alpha_test, opacity,
                          transparent::Bool, side::Symbol, depth_test::Bool,
                          depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, map, alpha_map,
                     nothing, 1.0, alpha_test, opacity, transparent, side,
                     depth_test, depth_write)
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          gradient_map, opacity, transparent::Bool,
                          side::Symbol, depth_test::Bool, depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, gradient_map, nothing, nothing,
                     nothing, 1.0, 0.0, opacity, transparent, side, depth_test,
                     depth_write)
end

function MeshToonMaterial(color::Color3, emissive::Color3, gradient_steps,
                          opacity, transparent::Bool, side::Symbol,
                          depth_test::Bool, depth_write::Bool)
    MeshToonMaterial(color, emissive, gradient_steps, nothing, nothing, nothing,
                     nothing, 1.0, 0.0, opacity, transparent, side, depth_test,
                     depth_write)
end

# ========================== MeshMatcapMaterial ==========================
# Material-capture shading: appearance baked into a sphere image indexed by the
# view-space normal. `matcap` is an optional texture; without one a procedural
# view-facing falloff is used.

struct MeshMatcapMaterial <: AbstractMaterial
    color::Color3{Float64}
    matcap::Any
    map::Any
    normal_map::Any
    normal_scale::Float64
    alpha_map::Any
    alpha_test::Float64
    wireframe::Bool
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshMatcapMaterial(; color=Color3(1.0,1.0,1.0), matcap=nothing,
                             map=nothing, normal_map=nothing, normal_scale=1.0,
                             alpha_map=nothing, alpha_test=0.0, wireframe=false,
                             opacity=1.0, transparent=false, side=:front,
                             depth_test=true, depth_write=true,
                             clipping_planes=Plane{Float64}[])
    MeshMatcapMaterial(convert(Color3{Float64}, color), matcap, map, normal_map,
                       Float64(normal_scale), alpha_map,
                       _validated_material_alpha_test(alpha_test),
                       wireframe, _validated_material_opacity(opacity), transparent,
                       _validated_material_side(side), depth_test, depth_write,
                       _material_clipping_planes(clipping_planes))
end

function MeshMatcapMaterial(color::Color3, matcap, map, normal_map, normal_scale,
                            alpha_map, alpha_test, wireframe::Bool, opacity,
                            transparent::Bool, side::Symbol, depth_test::Bool,
                            depth_write::Bool)
    MeshMatcapMaterial(convert(Color3{Float64}, color), matcap, map, normal_map,
                       Float64(normal_scale), alpha_map,
                       _validated_material_alpha_test(alpha_test),
                       wireframe, _validated_material_opacity(opacity), transparent,
                       _validated_material_side(side), depth_test, depth_write,
                       Plane{Float64}[])
end

function MeshMatcapMaterial(color::Color3, matcap, opacity, transparent::Bool,
                            side::Symbol, depth_test::Bool, depth_write::Bool,
                            clipping_planes)
    MeshMatcapMaterial(convert(Color3{Float64}, color), matcap, nothing, nothing,
                       1.0, nothing, 0.0, false,
                       _validated_material_opacity(opacity), transparent,
                       _validated_material_side(side), depth_test, depth_write,
                       _material_clipping_planes(clipping_planes))
end

MeshMatcapMaterial(args::Vararg{Any,7}) =
    MeshMatcapMaterial(args..., Plane{Float64}[])

MeshMatcapMaterial(args::Vararg{Any,13}) =
    MeshMatcapMaterial(args..., Plane{Float64}[])

# ========================== MeshDepthMaterial ==========================
# Renders normalized camera-space depth. `:basic` displays near → bright;
# packed modes encode depth into color channels for depth-texture style output.

function _depth_packing_symbol(depth_packing)
    (depth_packing === :basic ||
     (depth_packing isa AbstractString && depth_packing == "basic")) &&
        return :basic
    (depth_packing === :rgba ||
     (depth_packing isa AbstractString && depth_packing == "rgba")) &&
        return :rgba
    (depth_packing === :rgb ||
     (depth_packing isa AbstractString && depth_packing == "rgb")) &&
        return :rgb
    (depth_packing === :rg ||
     (depth_packing isa AbstractString && depth_packing == "rg")) &&
        return :rg
    throw(ArgumentError("depth_packing must be one of :basic, :rgba, :rgb, or :rg"))
end

function _validated_depth_material_params(near, far)
    near isa Bool &&
        throw(ArgumentError("MeshDepthMaterial near must be finite and non-negative"))
    far isa Bool &&
        throw(ArgumentError("MeshDepthMaterial far must be finite and greater than near"))
    n = Float64(near)
    fr = Float64(far)
    isfinite(n) && n >= 0.0 ||
        throw(ArgumentError("MeshDepthMaterial near must be finite and non-negative"))
    isfinite(fr) && fr > n ||
        throw(ArgumentError("MeshDepthMaterial far must be finite and greater than near"))
    return n, fr
end

struct MeshDepthMaterial <: AbstractMaterial
    near::Float64
    far::Float64
    depth_packing::Symbol
    map::Any
    alpha_map::Any
    alpha_test::Float64
    wireframe::Bool
    opacity::Float64
    transparent::Bool
    side::Symbol
    depth_test::Bool
    depth_write::Bool
    clipping_planes::Vector{Plane{Float64}}
end

function MeshDepthMaterial(near::Real, far::Real, opacity::Real, transparent::Bool,
                           side::Symbol, depth_test::Bool, depth_write::Bool)
    n, fr = _validated_depth_material_params(near, far)
    MeshDepthMaterial(n, fr, :basic, nothing, nothing, 0.0,
                      false, _validated_material_opacity(opacity), transparent,
                      _validated_material_side(side), depth_test,
                      depth_write, Plane{Float64}[])
end

function MeshDepthMaterial(near::Real, far::Real, depth_packing, opacity::Real,
                           transparent::Bool, side::Symbol, depth_test::Bool,
                           depth_write::Bool)
    n, fr = _validated_depth_material_params(near, far)
    MeshDepthMaterial(n, fr, _depth_packing_symbol(depth_packing),
                      nothing, nothing, 0.0, false,
                      _validated_material_opacity(opacity), transparent,
                      _validated_material_side(side), depth_test, depth_write,
                      Plane{Float64}[])
end

function MeshDepthMaterial(; near=0.1, far=100.0, depth_packing=:basic,
                           map=nothing, alpha_map=nothing, alpha_test=0.0,
                           wireframe=false,
                           opacity=1.0, transparent=false, side=:front,
                           depth_test=true, depth_write=true,
                           clipping_planes=Plane{Float64}[])
    n, fr = _validated_depth_material_params(near, far)
    MeshDepthMaterial(n, fr, _depth_packing_symbol(depth_packing),
                      map, alpha_map, _validated_material_alpha_test(alpha_test), wireframe,
                      _validated_material_opacity(opacity), transparent,
                      _validated_material_side(side),
                      depth_test, depth_write,
                      _material_clipping_planes(clipping_planes))
end

MeshDepthMaterial(args::Vararg{Any,12}) =
    MeshDepthMaterial(args..., Plane{Float64}[])

@inline _validate_depth_material(_) = nothing

@inline function _validate_depth_material(material::MeshDepthMaterial)
    _validated_depth_material_params(material.near, material.far)
    return nothing
end

# ========================== ShaderMaterial ==========================
# Placeholder for custom GLSL

struct ShaderMaterial <: AbstractMaterial
    vertex_shader::String
    fragment_shader::String
    uniforms::Dict{String, Any}
    program::Any   # optional CPU fragment program: (normal, view_dir, position, uniforms) -> Color3
    side::Symbol
    depth_test::Bool
    depth_write::Bool
end

function ShaderMaterial(; vertex_shader="", fragment_shader="", uniforms=Dict{String,Any}(),
                         program=nothing, side=:front, depth_test=true, depth_write=true)
    ShaderMaterial(vertex_shader, fragment_shader, uniforms, program,
                   _validated_material_side(side),
                   depth_test, depth_write)
end

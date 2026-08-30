# --------------------------------------------------------------------------
# Light types mirroring three.js light hierarchy.
# --------------------------------------------------------------------------

abstract type AbstractLight <: AbstractObject3D end

@noinline function _throw_light_color(name::Symbol)
    throw(ArgumentError("light $name must be a Color3 with finite components"))
end

@inline function _validated_light_color(value, name::Symbol)
    value isa Color3 || _throw_light_color(name)
    color = convert(Color3{Float64}, value)
    isfinite(color.r) && isfinite(color.g) && isfinite(color.b) ||
        _throw_light_color(name)
    return color
end

@noinline function _throw_light_finite(name::Symbol)
    throw(ArgumentError("light $name must be finite"))
end

@inline function _validated_light_finite(value, name::Symbol)
    value isa Real && !(value isa Bool) || _throw_light_finite(name)
    result = Float64(value)
    isfinite(result) || _throw_light_finite(name)
    return result
end

@inline _validated_light_intensity(value) =
    _validated_light_finite(value, :intensity)

@noinline function _throw_light_vec3(name::Symbol)
    throw(ArgumentError("light $name must be a Vec3 with finite components"))
end

@inline function _validated_light_vec3(value, name::Symbol)
    value isa Vec3 || _throw_light_vec3(name)
    result = convert(Vec3{Float64}, value)
    isfinite(result.x) && isfinite(result.y) && isfinite(result.z) ||
        _throw_light_vec3(name)
    return result
end

@noinline function _throw_light_probe_coeffs()
    throw(ArgumentError(
        "light coeffs must be a tuple of four Color3 values with finite components"))
end

@inline function _validated_light_probe_coeffs(coeffs)
    coeffs isa Tuple && length(coeffs) == 4 || _throw_light_probe_coeffs()
    return (
        _validated_light_color(coeffs[1], :coeffs),
        _validated_light_color(coeffs[2], :coeffs),
        _validated_light_color(coeffs[3], :coeffs),
        _validated_light_color(coeffs[4], :coeffs),
    )
end

@inline _validate_light_parameters(::AbstractLight) = nothing

# ========================== IESProfile ==========================
# Photometric profile for real-world luminaires (IESNA LM-63). A measured
# luminaire is described by its luminous intensity (candela) as a function of the
# vertical angle θ (degrees from the downward/aim axis: 0° = straight down the
# beam axis, 90° = perpendicular, up to 180°). Azimuthal (horizontal) variation
# is collapsed: this single-plane representation uses one candela value per
# vertical angle (the common rotationally symmetric case for spotlights). The
# stored angles are assumed sorted ascending; lookups linearly interpolate and
# clamp outside the tabulated range.

struct IESProfile
    angles::Vector{Float64}    # vertical angles in degrees, ascending
    candela::Vector{Float64}   # luminous intensity (cd) at each angle
    max_candela::Float64       # peak candela, for normalization to [0,1]
end

@noinline function _throw_light_ies_profile()
    throw(ArgumentError("light ies_profile must be an IESProfile or nothing"))
end

@inline function _validated_light_ies_profile(profile)
    profile === nothing || profile isa IESProfile ||
        _throw_light_ies_profile()
    return profile
end

"""
    IESProfile(angles, candela)

Build a photometric profile from vertical `angles` (degrees) and matching
`candela` values. The peak candela is recorded so lookups can return a
normalized [0,1] multiplier.
"""
function IESProfile(angles::AbstractVector{<:Real}, candela::AbstractVector{<:Real})
    length(angles) == length(candela) ||
        throw(ArgumentError("IESProfile: angles and candela must have equal length"))
    length(angles) >= 1 || throw(ArgumentError("IESProfile: need at least one sample"))
    a = collect(Float64, angles)
    c = collect(Float64, candela)
    return _ies_profile_checked(a, c)
end

function _ies_profile_checked(a::Vector{Float64}, c::Vector{Float64})
    all(isfinite, a) || throw(ArgumentError("IESProfile: angles must be finite"))
    all(isfinite, c) || throw(ArgumentError("IESProfile: candela values must be finite"))
    all(x -> x >= 0.0, c) ||
        throw(ArgumentError("IESProfile: candela values must be non-negative"))
    @inbounds for i in 2:length(a)
        a[i] > a[i - 1] ||
            throw(ArgumentError("IESProfile: angles must be strictly increasing"))
    end
    mx = maximum(c)
    IESProfile(a, c, mx)
end

"""
    ies_candela(profile, angle_deg) -> Float64

Linearly interpolate the candela value at a vertical angle (degrees), clamping
to the tabulated endpoints outside `[angles[1], angles[end]]`.
"""
function ies_candela(profile::IESProfile, angle_deg::Real)
    a = profile.angles
    c = profile.candela
    n = length(a)
    n == 1 && return c[1]
    θ = Float64(angle_deg)
    θ <= a[1] && return c[1]
    θ >= a[n] && return c[n]
    isnan(θ) && return c[n]
    # Angles are strictly ascending; binary search keeps per-shading IES lookups
    # logarithmic for dense measured profiles.
    i = searchsortedfirst(a, θ)
    @inbounds begin
        t = (θ - a[i-1]) / (a[i] - a[i-1])
        return c[i-1] + (c[i] - c[i-1]) * t
    end
end

"""
    ies_intensity(profile, angle_deg) -> Float64

Normalized luminous-intensity multiplier in `[0,1]` (candela divided by the
profile peak) at a vertical angle in degrees. Used to modulate a light's
intensity by its measured photometric distribution.
"""
function ies_intensity(profile::IESProfile, angle_deg::Real)
    profile.max_candela <= 0 && return 0.0
    return ies_candela(profile, angle_deg) / profile.max_candela
end

"""
    parse_ies(text) -> IESProfile

Parse an IESNA LM-63 photometric data file (the `.ies` format emitted by lamp
manufacturers and supported by three.js' IESLoader). The parser reads the
`TILT=` line, the two numeric control lines, then the vertical-angle vector and
the candela values, supporting the common single-horizontal-plane (rotationally
symmetric) case. Multi-plane files are collapsed to their first horizontal
plane. Keyword/label lines beginning with `[` are ignored.

The numeric layout after `TILT=NONE` is:

    <num_lamps> <lumens_per_lamp> <candela_multiplier> <num_vertical> <num_horizontal>
    <ballast_factor> <future_use> <input_watts>
    <vertical_angles...>      (num_vertical values)
    <horizontal_angles...>    (num_horizontal values)
    <candela values...>       (num_vertical × num_horizontal, plane-major)
"""
function _ies_parse_numeric_token(tok::AbstractString, line_no::Int)
    value = tryparse(Float64, tok)
    value === nothing &&
        throw(ArgumentError("parse_ies: invalid numeric token $(repr(String(tok))) on line $line_no"))
    isfinite(value) ||
        throw(ArgumentError("parse_ies: numeric token $(repr(String(tok))) on line $line_no must be finite"))
    return value
end

function _ies_positive_integer_count(value::Real, label::String)
    f = Float64(value)
    (f >= 1.0 && f == floor(f) && f <= Float64(typemax(Int))) ||
        throw(ArgumentError("parse_ies: $label count must be a positive integer"))
    return Int(f)
end

function _ies_line_bounds(s::String, i::Int)
    n = lastindex(s)
    j = i
    while j <= n && s[j] != '\n'
        j = nextind(s, j)
    end
    stop = j <= n ? prevind(s, j) : n
    stop >= i && s[stop] == '\r' && (stop = prevind(s, stop))
    next_i = j <= n ? nextind(s, j) : nextind(s, n)
    return i, stop, next_i
end

function _ies_trim_bounds(s::String, first::Int, last::Int)
    while first <= last && isspace(s[first])
        first = nextind(s, first)
    end
    while first <= last && isspace(s[last])
        last = prevind(s, last)
    end
    return first, last
end

function _ies_line_contains_tilt(s::String, first::Int, last::Int)
    pattern = ('T', 'I', 'L', 'T', '=')
    p = first
    while p <= last
        q = p
        matched = true
        for expected in pattern
            if q > last || uppercase(s[q]) != expected
                matched = false
                break
            end
            q = nextind(s, q)
        end
        matched && return true
        p = nextind(s, p)
    end
    return false
end

mutable struct _IESNumericScanner
    s::String
    pos::Int
    line_start::Int
    line_stop::Int
    next_line::Int
    line_no::Int
end

function _ies_numeric_scanner(s::String, pos::Int, line_no::Int)
    n = lastindex(s)
    if pos > n
        return _IESNumericScanner(s, pos, pos, prevind(s, pos), pos, line_no)
    end
    line_start, line_stop, next_line = _ies_line_bounds(s, pos)
    return _IESNumericScanner(s, pos, line_start, line_stop, next_line, line_no)
end

function _ies_advance_line!(scanner::_IESNumericScanner)
    scanner.pos = scanner.next_line
    scanner.line_no += 1
    n = lastindex(scanner.s)
    scanner.pos > n && return false
    scanner.line_start, scanner.line_stop, scanner.next_line =
        _ies_line_bounds(scanner.s, scanner.pos)
    return true
end

@inline _ies_numeric_delim(ch::Char) = isspace(ch) || ch == ','

function _ies_next_number!(scanner::_IESNumericScanner)
    s = scanner.s
    n = lastindex(s)
    while scanner.pos <= n
        if scanner.pos == scanner.line_start
            first, last = _ies_trim_bounds(s, scanner.line_start, scanner.line_stop)
            (first > last || s[first] == '[') && (_ies_advance_line!(scanner); continue)
        end
        while scanner.pos <= scanner.line_stop && _ies_numeric_delim(s[scanner.pos])
            scanner.pos = nextind(s, scanner.pos)
        end
        scanner.pos > scanner.line_stop && (_ies_advance_line!(scanner); continue)
        first = scanner.pos
        while scanner.pos <= scanner.line_stop && !_ies_numeric_delim(s[scanner.pos])
            scanner.pos = nextind(s, scanner.pos)
        end
        last = prevind(s, scanner.pos)
        return _ies_parse_numeric_token(SubString(s, first, last), scanner.line_no)
    end
    return nothing
end

function _ies_find_payload_start(s::String)
    i = firstindex(s)
    n = lastindex(s)
    line_no = 1
    while i <= n
        first, last, next_i = _ies_line_bounds(s, i)
        trimmed_first, trimmed_last = _ies_trim_bounds(s, first, last)
        if trimmed_first <= trimmed_last && _ies_line_contains_tilt(s, trimmed_first, trimmed_last)
            tilt_line = uppercase(String(SubString(s, trimmed_first, trimmed_last)))
            payload_i = next_i
            payload_line_no = line_no + 1
            if endswith(tilt_line, "INCLUDE") || occursin("TILT=INCLUDE", tilt_line)
                for _ in 1:4
                    payload_i > n && break
                    _, _, payload_i = _ies_line_bounds(s, payload_i)
                    payload_line_no += 1
                end
            end
            return payload_i, payload_line_no
        end
        i = next_i
        line_no += 1
    end
    throw(ArgumentError("parse_ies: no TILT= line found"))
end

function parse_ies(text::AbstractString)
    s = text isa String ? text : String(text)
    payload_start, payload_line_no = _ies_find_payload_start(s)
    scanner = _ies_numeric_scanner(s, payload_start, payload_line_no)
    control = Vector{Float64}(undef, 13)
    for i in 1:13
        value = _ies_next_number!(scanner)
        value === nothing && throw(ArgumentError("parse_ies: truncated photometric data"))
        control[i] = value
    end
    # The LM-63 control block is 13 numeric values (the standard splits them as a
    # 10-value first line and a 3-value second line, but token order is fixed
    # regardless of line wrapping):
    #   1: num_lamps          2: lumens_per_lamp   3: candela_multiplier
    #   4: num_vertical_angles 5: num_horizontal_angles
    #   6: photometric_type   7: units_type        8: width
    #   9: length            10: height
    #  11: ballast_factor    12: future_use       13: input_watts
    # The vertical-angle vector starts at token 14.
    cand_mult = control[3]
    num_vert = _ies_positive_integer_count(control[4], "vertical-angle")
    num_horiz = _ies_positive_integer_count(control[5], "horizontal-angle")
    vangles = Vector{Float64}(undef, num_vert)
    for i in 1:num_vert
        value = _ies_next_number!(scanner)
        value === nothing && throw(ArgumentError("parse_ies: missing vertical angles"))
        vangles[i] = value
    end
    for _ in 1:num_horiz
        _ies_next_number!(scanner) === nothing &&
            throw(ArgumentError("parse_ies: missing horizontal angles"))
    end
    cand = Vector{Float64}(undef, num_vert)
    scale = cand_mult > 0 ? cand_mult : 1.0
    for i in 1:num_vert
        value = _ies_next_number!(scanner)
        value === nothing && throw(ArgumentError("parse_ies: missing candela values"))
        cand[i] = value * scale
    end
    return _ies_profile_checked(vangles, cand)
end

# ========================== AmbientLight ==========================

mutable struct AmbientLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}
    intensity::Float64
end

function AmbientLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0, name="AmbientLight")
    AmbientLight(Vec3(), Euler(), Vec3(1.0,1.0,1.0),
                 nothing, AbstractObject3D[], true, name, _next_id(),
                 _validated_light_color(color, :color),
                 _validated_light_intensity(intensity))
end

get_position(o::AmbientLight) = o.position
get_rotation(o::AmbientLight) = o.rotation
get_scale(o::AmbientLight) = o.scale
get_children(o::AmbientLight) = o.children
get_parent(o::AmbientLight) = o.parent
is_visible(o::AmbientLight) = o.visible
set_parent!(o::AmbientLight, p) = (o.parent = p)

function _validated_shadow_bias(v)
    v === nothing && return nothing
    v isa Real && !(v isa Bool) ||
        throw(ArgumentError("shadow_bias must be finite"))
    b = Float64(v)
    isfinite(b) || throw(ArgumentError("shadow_bias must be finite"))
    return b
end

function _validated_shadow_pcf_radius(v)
    v === nothing && return nothing
    v isa Integer && !(v isa Bool) ||
        throw(ArgumentError("shadow_pcf_radius must be an integer or nothing"))
    v >= 0 || throw(ArgumentError("shadow_pcf_radius must be >= 0, got $v"))
    v <= typemax(Int) ||
        throw(ArgumentError("shadow_pcf_radius must fit in Int"))
    return Int(v)
end

@inline function _validated_light_cast_shadow(value)
    value isa Bool || throw(ArgumentError("light cast_shadow must be Bool"))
    return value
end

_light_shadow_bias(light, fallback::Real=3e-3) =
    hasproperty(light, :shadow_bias) && getproperty(light, :shadow_bias) !== nothing ?
    Float64(getproperty(light, :shadow_bias)) : Float64(fallback)

_light_shadow_pcf_radius(light, fallback::Integer=0) =
    hasproperty(light, :shadow_pcf_radius) && getproperty(light, :shadow_pcf_radius) !== nothing ?
    Int(getproperty(light, :shadow_pcf_radius)) : Int(fallback)

# ========================== DirectionalLight ==========================

mutable struct DirectionalLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}
    intensity::Float64
    target::Vec3{Float64}
    cast_shadow::Bool
    shadow_bias::Union{Nothing, Float64}
    shadow_pcf_radius::Union{Nothing, Int}
end

DirectionalLight(position, rotation, scale, parent, children, visible, name, id,
                 color, intensity, target, cast_shadow) =
    DirectionalLight(position, rotation, scale, parent, children, visible, name, id,
                     color, intensity, target,
                     _validated_light_cast_shadow(cast_shadow), nothing, nothing)

function DirectionalLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                           position=Vec3(0.0, 1.0, 0.0), name="DirectionalLight",
                           cast_shadow=false, shadow_bias=nothing,
                           shadow_pcf_radius=nothing)
    DirectionalLight(_validated_light_vec3(position, :position),
                     Euler(), Vec3(1.0,1.0,1.0),
                     nothing, AbstractObject3D[], true, name, _next_id(),
                     _validated_light_color(color, :color),
                     _validated_light_intensity(intensity), Vec3(),
                     _validated_light_cast_shadow(cast_shadow),
                     _validated_shadow_bias(shadow_bias),
                     _validated_shadow_pcf_radius(shadow_pcf_radius))
end

get_position(o::DirectionalLight) = o.position
get_rotation(o::DirectionalLight) = o.rotation
get_scale(o::DirectionalLight) = o.scale
get_children(o::DirectionalLight) = o.children
get_parent(o::DirectionalLight) = o.parent
is_visible(o::DirectionalLight) = o.visible
set_parent!(o::DirectionalLight, p) = (o.parent = p)

# ========================== PointLight ==========================

mutable struct PointLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}
    intensity::Float64
    distance::Float64
    decay::Float64
    cast_shadow::Bool
    shadow_bias::Union{Nothing, Float64}
    shadow_pcf_radius::Union{Nothing, Int}
    ies_profile::Union{Nothing, IESProfile}   # nothing = isotropic
end

PointLight(position, rotation, scale, parent, children, visible, name, id,
           color, intensity, distance, decay, cast_shadow, ies_profile) =
    PointLight(position, rotation, scale, parent, children, visible, name, id,
               color, intensity, distance, decay,
               _validated_light_cast_shadow(cast_shadow), nothing, nothing, ies_profile)

function PointLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                    distance=0.0, decay=2.0, position=Vec3(),
                    name="PointLight", cast_shadow=false, shadow_bias=nothing,
                    shadow_pcf_radius=nothing, ies_profile=nothing)
    PointLight(_validated_light_vec3(position, :position),
               Euler(), Vec3(1.0,1.0,1.0),
               nothing, AbstractObject3D[], true, name, _next_id(),
               _validated_light_color(color, :color),
               _validated_light_intensity(intensity),
               _validated_light_finite(distance, :distance),
               _validated_light_finite(decay, :decay),
               _validated_light_cast_shadow(cast_shadow),
               _validated_shadow_bias(shadow_bias),
               _validated_shadow_pcf_radius(shadow_pcf_radius),
               _validated_light_ies_profile(ies_profile))
end

get_position(o::PointLight) = o.position
get_rotation(o::PointLight) = o.rotation
get_scale(o::PointLight) = o.scale
get_children(o::PointLight) = o.children
get_parent(o::PointLight) = o.parent
is_visible(o::PointLight) = o.visible
set_parent!(o::PointLight, p) = (o.parent = p)

# ========================== SpotLight ==========================

mutable struct SpotLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}
    intensity::Float64
    distance::Float64
    angle::Float64
    penumbra::Float64
    decay::Float64
    target::Vec3{Float64}
    cast_shadow::Bool
    shadow_bias::Union{Nothing, Float64}
    shadow_pcf_radius::Union{Nothing, Int}
    ies_profile::Union{Nothing, IESProfile}   # nothing = analytic cone
end

SpotLight(position, rotation, scale, parent, children, visible, name, id,
          color, intensity, distance, angle, penumbra, decay, target, cast_shadow,
          ies_profile) =
    SpotLight(position, rotation, scale, parent, children, visible, name, id,
              color, intensity, distance, angle, penumbra, decay, target,
              _validated_light_cast_shadow(cast_shadow), nothing, nothing, ies_profile)

function SpotLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                   distance=0.0, angle=π/3, penumbra=0.0, decay=2.0,
                   position=Vec3(0.0, 1.0, 0.0), name="SpotLight",
                   target=Vec3(), cast_shadow=false, shadow_bias=nothing,
                   shadow_pcf_radius=nothing, ies_profile=nothing)
    SpotLight(_validated_light_vec3(position, :position),
              Euler(), Vec3(1.0,1.0,1.0),
              nothing, AbstractObject3D[], true, name, _next_id(),
              _validated_light_color(color, :color),
              _validated_light_intensity(intensity),
              _validated_light_finite(distance, :distance),
              _validated_light_finite(angle, :angle),
              _validated_light_finite(penumbra, :penumbra),
              _validated_light_finite(decay, :decay),
              _validated_light_vec3(target, :target),
              _validated_light_cast_shadow(cast_shadow),
              _validated_shadow_bias(shadow_bias),
              _validated_shadow_pcf_radius(shadow_pcf_radius),
              _validated_light_ies_profile(ies_profile))
end

get_position(o::SpotLight) = o.position
get_rotation(o::SpotLight) = o.rotation
get_scale(o::SpotLight) = o.scale
get_children(o::SpotLight) = o.children
get_parent(o::SpotLight) = o.parent
is_visible(o::SpotLight) = o.visible
set_parent!(o::SpotLight, p) = (o.parent = p)

# ========================== HemisphereLight ==========================

mutable struct HemisphereLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}        # sky color
    ground_color::Color3{Float64}  # ground color
    intensity::Float64
end

function HemisphereLight(; color=Color3(1.0, 1.0, 1.0),
                          ground_color=Color3(0.0, 0.0, 0.0),
                          intensity=1.0, name="HemisphereLight")
    HemisphereLight(Vec3(), Euler(), Vec3(1.0,1.0,1.0),
                    nothing, AbstractObject3D[], true, name, _next_id(),
                    _validated_light_color(color, :color),
                    _validated_light_color(ground_color, :ground_color),
                    _validated_light_intensity(intensity))
end

get_position(o::HemisphereLight) = o.position
get_rotation(o::HemisphereLight) = o.rotation
get_scale(o::HemisphereLight) = o.scale
get_children(o::HemisphereLight) = o.children
get_parent(o::HemisphereLight) = o.parent
is_visible(o::HemisphereLight) = o.visible
set_parent!(o::HemisphereLight, p) = (o.parent = p)

# ========================== RectAreaLight ==========================
# A single-sided rectangular emitter. Lit paths integrate a small finite
# quadrature over the target-facing plane with inverse-square falloff.

mutable struct RectAreaLight <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    color::Color3{Float64}
    intensity::Float64
    width::Float64
    height::Float64
    target::Vec3{Float64}
end

function RectAreaLight(; color=Color3(1.0,1.0,1.0), intensity=1.0, width=1.0, height=1.0,
                        position=Vec3(0.0,1.0,0.0), name="RectAreaLight")
    RectAreaLight(_validated_light_vec3(position, :position),
                  Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                  true, name, _next_id(), _validated_light_color(color, :color),
                  _validated_light_intensity(intensity),
                  _validated_light_finite(width, :width),
                  _validated_light_finite(height, :height), Vec3())
end

get_position(o::RectAreaLight) = o.position
get_rotation(o::RectAreaLight) = o.rotation
get_scale(o::RectAreaLight) = o.scale
get_children(o::RectAreaLight) = o.children
get_parent(o::RectAreaLight) = o.parent
is_visible(o::RectAreaLight) = o.visible
set_parent!(o::RectAreaLight, p) = (o.parent = p)

# ========================== LightProbe ==========================
# Order-1 spherical-harmonics ambient probe: irradiance varies linearly with the
# surface normal. `coeffs` = (DC, x-grad, y-grad, z-grad).

mutable struct LightProbe <: AbstractLight
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    coeffs::NTuple{4, Color3{Float64}}
    intensity::Float64
end

function LightProbe(; coeffs=(Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0),
                              Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0)),
                     intensity=1.0, name="LightProbe")
    LightProbe(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
               true, name, _next_id(), _validated_light_probe_coeffs(coeffs),
               _validated_light_intensity(intensity))
end

"""Build a uniform (DC-only) light probe from an ambient colour."""
LightProbe(ambient::Color3; intensity=1.0) =
    LightProbe(coeffs=(ambient, Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0)),
               intensity=intensity)

get_position(o::LightProbe) = o.position
get_rotation(o::LightProbe) = o.rotation
get_scale(o::LightProbe) = o.scale
get_children(o::LightProbe) = o.children
get_parent(o::LightProbe) = o.parent
is_visible(o::LightProbe) = o.visible
set_parent!(o::LightProbe, p) = (o.parent = p)

@inline function _validate_light_parameters(light::AmbientLight)
    _validated_light_color(light.color, :color)
    _validated_light_intensity(light.intensity)
    return nothing
end

@inline function _validate_light_parameters(light::DirectionalLight)
    _validated_light_color(light.color, :color)
    _validated_light_intensity(light.intensity)
    _validated_light_vec3(light.position, :position)
    _validated_light_vec3(light.target, :target)
    return nothing
end

@inline function _validate_light_parameters(light::PointLight)
    _validated_light_color(light.color, :color)
    _validated_light_intensity(light.intensity)
    _validated_light_finite(light.distance, :distance)
    _validated_light_finite(light.decay, :decay)
    _validated_light_ies_profile(light.ies_profile)
    _validated_light_vec3(light.position, :position)
    return nothing
end

@inline function _validate_light_parameters(light::SpotLight)
    _validated_light_color(light.color, :color)
    _validated_light_intensity(light.intensity)
    _validated_light_finite(light.distance, :distance)
    _validated_light_finite(light.angle, :angle)
    _validated_light_finite(light.penumbra, :penumbra)
    _validated_light_finite(light.decay, :decay)
    _validated_light_ies_profile(light.ies_profile)
    _validated_light_vec3(light.position, :position)
    _validated_light_vec3(light.target, :target)
    return nothing
end

@inline function _validate_light_parameters(light::HemisphereLight)
    _validated_light_color(light.color, :color)
    _validated_light_color(light.ground_color, :ground_color)
    _validated_light_intensity(light.intensity)
    return nothing
end

@inline function _validate_light_parameters(light::RectAreaLight)
    _validated_light_color(light.color, :color)
    _validated_light_intensity(light.intensity)
    _validated_light_finite(light.width, :width)
    _validated_light_finite(light.height, :height)
    _validated_light_vec3(light.position, :position)
    _validated_light_vec3(light.target, :target)
    return nothing
end

@inline function _validate_light_parameters(light::LightProbe)
    _validated_light_probe_coeffs(light.coeffs)
    _validated_light_intensity(light.intensity)
    return nothing
end

@inline _validate_light_shadow_parameters(::AbstractLight) = nothing

@inline _validate_light_object_spatial_parameters(::AbstractLight) = nothing

@inline function _validate_light_object_spatial_parameters(
        light::Union{AmbientLight, HemisphereLight, LightProbe})
    _validated_light_vec3(light.position, :position)
    return nothing
end

@inline function _validate_light_shadow_parameters(
        light::Union{DirectionalLight, PointLight, SpotLight})
    _validated_shadow_bias(light.shadow_bias)
    _validated_shadow_pcf_radius(light.shadow_pcf_radius)
    return nothing
end

@inline function _validate_light_object(light::AbstractLight)
    _validate_light_parameters(light)
    _validate_light_object_spatial_parameters(light)
    _validate_light_shadow_parameters(light)
    return nothing
end

@inline function _light_world_position(
        light::AbstractLight)::Vec3{Float64}
    position = get_position(light)::Vec3{Float64}
    parent = get_parent(light)
    parent === nothing && return position
    return mat4_transform_point(compute_world_matrix(parent), position)
end

@inline function _light_world_direction(
        light::AbstractLight, direction::Vec3)::Vec3{Float64}
    parent = get_parent(light)
    rotation = get_rotation(light)::Euler{Float64}
    if parent === nothing && rotation.x == 0.0 && rotation.y == 0.0 &&
       rotation.z == 0.0
        return normalize(direction)
    end
    return normalize(mat4_transform_direction(
        compute_world_matrix(light), direction))
end

@_compute_world_matrix_method(AmbientLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(DirectionalLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(PointLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(SpotLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(HemisphereLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(RectAreaLight,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)
@_compute_world_matrix_method(LightProbe,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe)

# ========================== Light collection ==========================

# Keep scene light containers concrete so the shading loop can union-split over
# the finite set of supported light types instead of paying abstract-dispatch
# allocation costs on every shaded face.
const SceneLight = Union{
    AmbientLight,
    DirectionalLight,
    PointLight,
    SpotLight,
    HemisphereLight,
    RectAreaLight,
    LightProbe,
}

# Visibility-aware traversal: invisible nodes are skipped along with their
# entire subtree, matching three.js hierarchical visibility semantics.
function _count_lights(obj::AbstractObject3D)
    is_visible(obj) || return 0
    n = obj isa AbstractLight ? 1 : 0
    @inbounds for child in get_children(obj)
        n += _count_lights(child)
    end
    return n
end

function _fill_lights!(lights::Vector{SceneLight}, obj::AbstractObject3D, i::Int)
    is_visible(obj) || return i
    if obj isa AbstractLight
        _validate_light_object(obj)
        lights[i] = obj
        i += 1
    end
    @inbounds for child in get_children(obj)
        i = _fill_lights!(lights, child, i)
    end
    return i
end

function _collect_lights!(lights::Vector{SceneLight}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    if obj isa AbstractLight
        _validate_light_object(obj)
        push!(lights, obj)
    end
    for child in get_children(obj)
        _collect_lights!(lights, child)
    end
    return nothing
end

function collect_lights(scene::AbstractObject3D)
    lights = Vector{SceneLight}(undef, _count_lights(scene))
    _fill_lights!(lights, scene, 1)
    return lights
end

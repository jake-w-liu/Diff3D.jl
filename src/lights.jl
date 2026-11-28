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

    function IESProfile(a::Vector{Float64}, c::Vector{Float64}, ::Val{:owned})
        length(a) == length(c) ||
            throw(ArgumentError(
                "IESProfile: angles and candela must have equal length"))
        length(a) >= 1 ||
            throw(ArgumentError("IESProfile: need at least one sample"))
        all(isfinite, a) ||
            throw(ArgumentError("IESProfile: angles must be finite"))
        all(isfinite, c) ||
            throw(ArgumentError("IESProfile: candela values must be finite"))
        all(value -> value >= 0.0, c) ||
            throw(ArgumentError(
                "IESProfile: candela values must be non-negative"))
        @inbounds for index in 2:length(a)
            a[index] > a[index - 1] ||
                throw(ArgumentError(
                    "IESProfile: angles must be strictly increasing"))
        end
        return new(a, c, maximum(c))
    end
end

function Base.getproperty(profile::IESProfile, name::Symbol)
    if name === :angles || name === :candela
        return copy(getfield(profile, name))
    end
    return getfield(profile, name)
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
normalized [0,1] multiplier. The profile stores immutable snapshots of both
input arrays; accessing `angles` or `candela` returns a copy.
"""
function IESProfile(angles::AbstractVector{<:Real}, candela::AbstractVector{<:Real})
    length(angles) == length(candela) ||
        throw(ArgumentError("IESProfile: angles and candela must have equal length"))
    length(angles) >= 1 || throw(ArgumentError("IESProfile: need at least one sample"))
    a = collect(Float64, angles)
    c = collect(Float64, candela)
    return _ies_profile_from_owned(a, c)
end

# Only freshly allocated, unshared vectors may enter this ownership transfer.
# Validation is shared with public construction, whose conversion above copies inputs.
function _ies_profile_from_owned(a::Vector{Float64}, c::Vector{Float64})
    return IESProfile(a, c, Val(:owned))
end

# Plain real angles are evaluated in Float64. Other `Real` subtypes (ForwardDiff
# duals, reverse-mode `ADVar`) stay in their own type so derivatives with respect
# to the angle flow through the interpolation instead of being truncated by a
# `Float64` conversion.
@inline _ies_angle(x::Union{AbstractFloat,Integer,Rational,AbstractIrrational}) =
    Float64(x)
@inline _ies_angle(x::Real) = x

# Tabulated constants returned for a differentiable angle keep the angle's type
# (with a zero derivative) so callers receive one scalar type on every branch.
@inline _ies_value(::Float64, value::Float64) = value
@inline _ies_value(θ, value::Float64) = value + zero(θ)

"""
    ies_candela(profile, angle_deg)

Linearly interpolate the candela value at a vertical angle (degrees), clamping
to the tabulated endpoints outside `[angles[1], angles[end]]`. Plain real angles
return a `Float64`; differentiable angle types (ForwardDiff duals, `ADVar`)
return a differentiable value carrying the derivative of the interpolation (zero
on the clamped ranges, including the endpoints themselves).
"""
function ies_candela(profile::IESProfile, angle_deg::Real)
    a = getfield(profile, :angles)
    c = getfield(profile, :candela)
    n = length(a)
    θ = _ies_angle(angle_deg)
    # Branch on the primal angle, as reverse-mode `ADVar` comparisons do. Dual
    # comparisons also weigh the partials, so an angle sitting exactly on an
    # endpoint would take the interpolating branch, which turns the infinite
    # partial `acosd` produces for an on-axis shading point into Inf/NaN.
    θp = _primal_value(θ)
    n == 1 && return _ies_value(θ, c[1])
    θp <= a[1] && return _ies_value(θ, c[1])
    θp >= a[n] && return _ies_value(θ, c[n])
    isnan(θp) && return _ies_value(θ, c[n])
    # Angles are strictly ascending; binary search keeps per-shading IES lookups
    # logarithmic for dense measured profiles.
    i = searchsortedfirst(a, θp)
    @inbounds begin
        t = (θ - a[i-1]) / (a[i] - a[i-1])
        return c[i-1] + (c[i] - c[i-1]) * t
    end
end

"""
    ies_intensity(profile, angle_deg)

Normalized luminous-intensity multiplier in `[0,1]` (candela divided by the
profile peak) at a vertical angle in degrees. Used to modulate a light's
intensity by its measured photometric distribution. The result type follows
[`ies_candela`](@ref).
"""
function ies_intensity(profile::IESProfile, angle_deg::Real)
    max_candela = getfield(profile, :max_candela)
    max_candela <= 0 && return _ies_value(_ies_angle(angle_deg), 0.0)
    return ies_candela(profile, angle_deg) / max_candela
end

function _ies_parse_numeric_token(tok::AbstractString, line_no::Int)
    value = tryparse(Float64, tok)
    value === nothing &&
        throw(ArgumentError("parse_ies: invalid numeric token $(repr(String(tok))) on line $line_no"))
    isfinite(value) ||
        throw(ArgumentError("parse_ies: numeric token $(repr(String(tok))) on line $line_no must be finite"))
    return value
end

# Every listed value occupies at least one code unit of the text, so a count
# larger than the text cannot be satisfied; rejecting it up front keeps a
# malformed header from requesting an unbounded buffer.
function _ies_positive_integer_count(value::Real, label::String, text_units::Int)
    f = Float64(value)
    (f >= 1.0 && f == floor(f) && f < 0x1p63) ||
        throw(ArgumentError("parse_ies: $label count must be a positive integer"))
    count = Int(f)
    count <= text_units ||
        throw(ArgumentError("parse_ies: $label count $count exceeds the photometric data"))
    return count
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

# Case-insensitive search for "TILT=" in the bytes first:last of `s`. The
# header is compared as code units: manufacturers' files are often Latin-1,
# and character operations throw on bytes that are not valid UTF-8.
function _ies_line_contains_tilt(s::String, first::Int, last::Int)
    units = codeunits(s)
    last = min(last, length(units))
    @inbounds for p in first:(last - 4)
        (units[p] & 0xdf) == UInt8('T') && (units[p + 1] & 0xdf) == UInt8('I') &&
            (units[p + 2] & 0xdf) == UInt8('L') && (units[p + 3] & 0xdf) == UInt8('T') &&
            units[p + 4] == UInt8('=') && return true
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
            include_tilt = endswith(tilt_line, "INCLUDE") || occursin("TILT=INCLUDE", tilt_line)
            return next_i, line_no + 1, include_tilt
        end
        i = next_i
        line_no += 1
    end
    throw(ArgumentError("parse_ies: no TILT= line found"))
end

# `TILT=INCLUDE` embeds the lamp-tilt table before the control block: the
# lamp-to-luminaire geometry code, the angle count N, then N tilt angles and N
# multiplying factors. Like three.js IESLoader (`readTilt`), the table is read by
# value count rather than by line, since LM-63 lets each vector wrap across lines.
# The factors are not applied (three.js ignores them as well).
function _ies_skip_tilt_data!(scanner::_IESNumericScanner)
    _ies_next_number!(scanner) === nothing &&
        throw(ArgumentError("parse_ies: truncated TILT=INCLUDE data"))
    count = _ies_next_number!(scanner)
    count === nothing && throw(ArgumentError("parse_ies: truncated TILT=INCLUDE data"))
    # Below 2^62 so that the 2N values to skip still fit in Int.
    (count >= 0.0 && count == floor(count) && count < 0x1p62) ||
        throw(ArgumentError("parse_ies: tilt-angle count must be a non-negative integer"))
    for _ in 1:(2 * Int(count))
        _ies_next_number!(scanner) === nothing &&
            throw(ArgumentError("parse_ies: truncated TILT=INCLUDE data"))
    end
    return nothing
end

"""
    parse_ies(text) -> IESProfile

Parse an IESNA LM-63 photometric data file (the `.ies` format emitted by lamp
manufacturers and supported by three.js' IESLoader). The parser reads the
`TILT=` line, any `TILT=INCLUDE` tilt table (skipped, as in three.js), the
13-value control block, then the vertical-angle vector and the candela values,
supporting the common single-horizontal-plane (rotationally symmetric) case.
Multi-plane files are collapsed to their first horizontal plane. Keyword/label
lines beginning with `[` are ignored. Values may be separated by whitespace or
commas and may wrap across lines.

The numeric layout after the `TILT=` data is:

    <num_lamps> <lumens_per_lamp> <candela_multiplier> <num_vertical> <num_horizontal>
        <photometric_type> <units_type> <width> <length> <height>
    <ballast_factor> <future_use> <input_watts>
    <vertical_angles...>      (num_vertical values)
    <horizontal_angles...>    (num_horizontal values)
    <candela values...>       (num_vertical × num_horizontal, plane-major)

Candela values are scaled by `candela_multiplier` when it is positive; a
non-positive multiplier leaves them unscaled.
"""
function parse_ies(text::AbstractString)
    s = text isa String ? text : String(text)
    payload_start, payload_line_no, include_tilt = _ies_find_payload_start(s)
    scanner = _ies_numeric_scanner(s, payload_start, payload_line_no)
    include_tilt && _ies_skip_tilt_data!(scanner)
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
    num_vert = _ies_positive_integer_count(control[4], "vertical-angle", ncodeunits(s))
    num_horiz = _ies_positive_integer_count(control[5], "horizontal-angle", ncodeunits(s))
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
    return _ies_profile_from_owned(vangles, cand)
end

# ========================== Per-frame light world matrices ==========================
# Shading asks for a parented light's world position or direction once per
# shaded fragment and light, and every request walked the parent chain through
# `compute_world_matrix`. A render arms the lights it collected (see
# `_arm_light_world_cache!`), computing each parented light's world matrix once,
# and disarms them when the frame ends, normally or by an exception. While a
# light is armed `_light_world_matrix` returns the stored matrix, which is the
# same `compute_world_matrix` value, so images are bit-identical. The scene
# must not change while a render reads it (see the concurrency notes in the
# manual), which is what makes the stored matrix current for the whole frame.
#
# Renders of one scene may run at the same time in different tasks, so arming
# and disarming take `_LIGHT_WORLD_CACHE_LOCK` and `depth` is atomic: a lost
# update could otherwise leave a light armed after every render ended, with a
# matrix that goes stale when the scene changes. `matrix` is written only while
# `depth` is 0, that is while no render reads it; shading threads read it
# without the lock after an acquire load of `depth`.
mutable struct _LightWorldCache
    # Number of renders in progress that armed this light.
    @atomic depth::Int
    matrix::Mat4{Float64}
end

_LightWorldCache() = _LightWorldCache(0, Mat4{Float64}())

const _LIGHT_WORLD_CACHE_LOCK = ReentrantLock()

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
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
AmbientLight(args::Vararg{Any,10}) = AmbientLight(args..., 0.0, _LightWorldCache())
AmbientLight(args::Vararg{Any,11}) = AmbientLight(args..., _LightWorldCache())

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

# three.js LightShadow.intensity (LightShadow.js:41, default 1): the shadowed
# fraction is mixed back toward lit, `mix(1, shadow, intensity)`
# (shadowmap_pars_fragment.glsl.js:180).
function _validated_shadow_intensity(v)
    v isa Real && !(v isa Bool) ||
        throw(ArgumentError("shadow_intensity must be a real number in [0, 1]"))
    value = Float64(v)
    isfinite(value) && 0.0 <= value <= 1.0 ||
        throw(ArgumentError("shadow_intensity must be finite and in [0, 1]"))
    return value
end

# three.js LightShadow.normalBias (LightShadow.js:74, default 0): world-space
# offset of the shadow lookup along the surface normal (shadowmap_vertex.glsl.js).
function _validated_shadow_normal_bias(v)
    v isa Real && !(v isa Bool) ||
        throw(ArgumentError("shadow_normal_bias must be finite"))
    value = Float64(v)
    isfinite(value) || throw(ArgumentError("shadow_normal_bias must be finite"))
    return value
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

_light_shadow_intensity(light) =
    hasfield(typeof(light), :shadow_intensity) ? getfield(light, :shadow_intensity) : 1.0

_light_shadow_normal_bias(light) =
    hasfield(typeof(light), :shadow_normal_bias) ? getfield(light, :shadow_normal_bias) : 0.0

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
    shadow_intensity::Float64     # three.js light.shadow.intensity
    shadow_normal_bias::Float64   # three.js light.shadow.normalBias
    rotation_driven::Bool
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
DirectionalLight(args::Vararg{Any,17}) = DirectionalLight(args..., 0.0, _LightWorldCache())
DirectionalLight(args::Vararg{Any,18}) = DirectionalLight(args..., _LightWorldCache())

# Positional forms: 14 fields (before rotation_driven existed), 15 (with
# rotation_driven, before the shadow settings), and 16 (all but rotation_driven).
DirectionalLight(args::Vararg{Any,14}) = DirectionalLight(args..., false)
DirectionalLight(args::Vararg{Any,15}) =
    DirectionalLight(args[1:14]..., 1.0, 0.0, args[15])
DirectionalLight(args::Vararg{Any,16}) = DirectionalLight(args..., false)

DirectionalLight(position, rotation, scale, parent, children, visible, name, id,
                 color, intensity, target, cast_shadow) =
    DirectionalLight(position, rotation, scale, parent, children, visible, name, id,
                     color, intensity, target,
                     _validated_light_cast_shadow(cast_shadow), nothing, nothing)

function DirectionalLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                           position=Vec3(0.0, 1.0, 0.0), name="DirectionalLight",
                           cast_shadow=false, shadow_bias=nothing,
                           shadow_pcf_radius=nothing, rotation_driven::Bool=false,
                           shadow_intensity=1.0, shadow_normal_bias=0.0)
    DirectionalLight(_validated_light_vec3(position, :position),
                     Euler(), Vec3(1.0,1.0,1.0),
                     nothing, AbstractObject3D[], true, name, _next_id(),
                     _validated_light_color(color, :color),
                     _validated_light_intensity(intensity), Vec3(),
                     _validated_light_cast_shadow(cast_shadow),
                     _validated_shadow_bias(shadow_bias),
                     _validated_shadow_pcf_radius(shadow_pcf_radius),
                     _validated_shadow_intensity(shadow_intensity),
                     _validated_shadow_normal_bias(shadow_normal_bias), rotation_driven)
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
    shadow_intensity::Float64     # three.js light.shadow.intensity
    shadow_normal_bias::Float64   # three.js light.shadow.normalBias
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
PointLight(args::Vararg{Any,18}) = PointLight(args..., 0.0, _LightWorldCache())
PointLight(args::Vararg{Any,19}) = PointLight(args..., _LightWorldCache())

PointLight(args::Vararg{Any,16}) = PointLight(args..., 1.0, 0.0)

PointLight(position, rotation, scale, parent, children, visible, name, id,
           color, intensity, distance, decay, cast_shadow, ies_profile) =
    PointLight(position, rotation, scale, parent, children, visible, name, id,
               color, intensity, distance, decay,
               _validated_light_cast_shadow(cast_shadow), nothing, nothing, ies_profile)

function PointLight(; color=Color3(1.0, 1.0, 1.0), intensity=1.0,
                    distance=0.0, decay=2.0, position=Vec3(),
                    name="PointLight", cast_shadow=false, shadow_bias=nothing,
                    shadow_pcf_radius=nothing, ies_profile=nothing,
                    shadow_intensity=1.0, shadow_normal_bias=0.0)
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
               _validated_light_ies_profile(ies_profile),
               _validated_shadow_intensity(shadow_intensity),
               _validated_shadow_normal_bias(shadow_normal_bias))
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
    shadow_intensity::Float64     # three.js light.shadow.intensity
    shadow_normal_bias::Float64   # three.js light.shadow.normalBias
    rotation_driven::Bool
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
SpotLight(args::Vararg{Any,22}) = SpotLight(args..., 0.0, _LightWorldCache())
SpotLight(args::Vararg{Any,23}) = SpotLight(args..., _LightWorldCache())

# Positional forms: 19 fields (before rotation_driven existed), 20 (with
# rotation_driven, before the shadow settings), and 21 (all but rotation_driven).
SpotLight(args::Vararg{Any,19}) = SpotLight(args..., false)
SpotLight(args::Vararg{Any,20}) = SpotLight(args[1:19]..., 1.0, 0.0, args[20])
SpotLight(args::Vararg{Any,21}) = SpotLight(args..., false)

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
                   shadow_pcf_radius=nothing, ies_profile=nothing, rotation_driven::Bool=false,
                   shadow_intensity=1.0, shadow_normal_bias=0.0)
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
              _validated_light_ies_profile(ies_profile),
              _validated_shadow_intensity(shadow_intensity),
              _validated_shadow_normal_bias(shadow_normal_bias), rotation_driven)
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
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
HemisphereLight(args::Vararg{Any,11}) = HemisphereLight(args..., 0.0, _LightWorldCache())
HemisphereLight(args::Vararg{Any,12}) = HemisphereLight(args..., _LightWorldCache())

# three.js HemisphereLight.js:50 builds `groundColor` with `new Color(groundColor)`,
# which is white when the argument is omitted.
function HemisphereLight(; color=Color3(1.0, 1.0, 1.0),
                          ground_color=Color3(1.0, 1.0, 1.0),
                          intensity=1.0, position=Vec3(0.0, 1.0, 0.0),
                          name="HemisphereLight")
    HemisphereLight(_validated_light_vec3(position, :position), Euler(), Vec3(1.0,1.0,1.0),
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
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
RectAreaLight(args::Vararg{Any,13}) = RectAreaLight(args..., 0.0, _LightWorldCache())
RectAreaLight(args::Vararg{Any,14}) = RectAreaLight(args..., _LightWorldCache())

# three.js RectAreaLight.js:38: `constructor( color, intensity, width = 10, height = 10 )`.
function RectAreaLight(; color=Color3(1.0,1.0,1.0), intensity=1.0, width=10.0, height=10.0,
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

const _ZERO_SH9 = ntuple(_ -> Color3(0.0, 0.0, 0.0), 9)

@noinline function _throw_light_probe_sh()
    throw(ArgumentError(
        "light sh must be a tuple of nine Color3 values with finite components"))
end

@inline function _validated_light_probe_sh(sh)
    sh isa Tuple && length(sh) == 9 || _throw_light_probe_sh()
    return ntuple(i -> _validated_light_color(sh[i], :sh), 9)
end

"""
    LightProbe(; coeffs=(4 × Color3(0)), sh=(9 × Color3(0)), intensity=1.0, name="LightProbe")
    LightProbe(ambient::Color3; intensity=1.0)

Ambient light probe whose irradiance depends on the surface normal `n` (world
space).

- `sh` holds the nine coefficients of a three.js `SphericalHarmonics3`
  (`LightProbe.sh`, order L00, L1-1, L10, L11, L2-2, L2-1, L20, L21, L22) in
  radiance units. They contribute three.js `shGetIrradianceAt(n)`
  (SphericalHarmonics3.js `getIrradianceAt`, lights_pars_begin.glsl.js). Build
  them from an environment with [`light_probe_from_cube_texture`](@ref).
- `coeffs` is Diff3D's order-1 form `(DC, x, y, z)`, contributing
  `DC + x·n.x + y·n.y + z·n.z` directly as irradiance.

The irradiance is the `coeffs` term clamped to be non-negative per channel plus
the `sh` term, which is not clamped (three.js adds `shGetIrradianceAt` to the
fragment irradiance unclamped, so ringing of a band-limited probe can subtract
light), scaled by `intensity`; it adds to the same ambient irradiance as
[`AmbientLight`](@ref). `LightProbe(ambient)` is a uniform probe with
`coeffs[1] = ambient`. The compact WebGL export supports only `coeffs` and
rejects a probe with non-zero `sh`.
"""
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
    sh::NTuple{9, Color3{Float64}}   # three.js LightProbe.sh coefficients
    render_order::Float64  # three.js Object3D.renderOrder
    _world_cache::_LightWorldCache  # world matrix while a render is in progress
end

# Field layouts before `render_order` (three.js default 0) and the
# per-frame world-matrix cache were added.
LightProbe(args::Vararg{Any,11}) = LightProbe(args..., 0.0, _LightWorldCache())
LightProbe(args::Vararg{Any,12}) = LightProbe(args..., _LightWorldCache())

LightProbe(position, rotation, scale, parent, children, visible, name, id, coeffs,
           intensity) =
    LightProbe(position, rotation, scale, parent, children, visible, name, id, coeffs,
               intensity, _ZERO_SH9)

function LightProbe(; coeffs=(Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0),
                              Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0)),
                     sh=_ZERO_SH9, intensity=1.0, name="LightProbe")
    LightProbe(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
               true, name, _next_id(), _validated_light_probe_coeffs(coeffs),
               _validated_light_intensity(intensity), _validated_light_probe_sh(sh))
end

@inline _light_probe_has_sh(light::LightProbe) = getfield(light, :sh) !== _ZERO_SH9

# three.js SphericalHarmonics3.getIrradianceAt (SphericalHarmonics3.js:119-142),
# the same weights as shGetIrradianceAt in lights_pars_begin.glsl.js, for a unit
# world-space normal.
@inline function _sh9_irradiance_channel(c0, c1, c2, c3, c4, c5, c6, c7, c8, normal::Vec3)
    x = normal.x; y = normal.y; z = normal.z
    result = c0 * 0.886227
    result += c1 * (2.0 * 0.511664 * y)
    result += c2 * (2.0 * 0.511664 * z)
    result += c3 * (2.0 * 0.511664 * x)
    result += c4 * (2.0 * 0.429043 * x * y)
    result += c5 * (2.0 * 0.429043 * y * z)
    result += c6 * (0.743125 * z * z - 0.247708)
    result += c7 * (2.0 * 0.429043 * x * z)
    result += c8 * (0.429043 * (x * x - y * y))
    return result
end

# SH9 irradiance of a probe, not clamped: three.js adds shGetIrradianceAt to the
# fragment irradiance as is (lights_fragment_begin.glsl.js:230,
# WebGLLights.js:283 sums every probe's coefficients first).
function _light_probe_sh_irradiance(sh::NTuple{9,Color3{Float64}}, normal::Vec3)
    r = _sh9_irradiance_channel(sh[1].r, sh[2].r, sh[3].r, sh[4].r, sh[5].r, sh[6].r,
                                sh[7].r, sh[8].r, sh[9].r, normal)
    g = _sh9_irradiance_channel(sh[1].g, sh[2].g, sh[3].g, sh[4].g, sh[5].g, sh[6].g,
                                sh[7].g, sh[8].g, sh[9].g, normal)
    b = _sh9_irradiance_channel(sh[1].b, sh[2].b, sh[3].b, sh[4].b, sh[5].b, sh[6].b,
                                sh[7].b, sh[8].b, sh[9].b, normal)
    return Color3(r, g, b)
end

"""Build a uniform (DC-only) light probe from an ambient colour."""
LightProbe(ambient::Color3; intensity=1.0) =
    LightProbe(coeffs=(ambient, Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0), Color3(0.0,0.0,0.0)),
               intensity=intensity)

# Unit-cube coordinate of the centre of texel (col, row) on a cube face, in the
# GL face convention `sample_cube` uses (`_cube_face_uv`): s = (col - 1/2)/W
# runs along the face's sc axis and the first storage row is t = 0.
@inline function _light_probe_face_coordinate(face::Int, sc::Float64, row::Float64)
    face == 1 && return Vec3(1.0, row, -sc)
    face == 2 && return Vec3(-1.0, row, sc)
    face == 3 && return Vec3(sc, 1.0, -row)
    face == 4 && return Vec3(sc, -1.0, row)
    face == 5 && return Vec3(sc, row, 1.0)
    return Vec3(-sc, row, -1.0)
end

"""
    light_probe_from_cube_texture(cube::CubeTexture; intensity=1.0) -> LightProbe

Project a radiance environment onto nine spherical-harmonic coefficients and
return a [`LightProbe`](@ref) carrying them in `sh`, following three.js
`LightProbeGenerator.fromCubeTexture` (examples/jsm/lights/LightProbeGenerator.js):
every texel is weighted by its solid angle `4 / |c|^3` (`c` the texel centre on
the unit cube), accumulated against the `SphericalHarmonics3.getBasisAt` basis,
and the sum is normalized by `4π / Σweight`. Faces with `colorspace=:srgb` are
decoded to linear first, `:linear` faces are used as stored.

Each face must be square (faces may differ in size). Texel directions follow
[`sample_cube`](@ref), so the probe lights a surface the way the same cube map
reflects onto it. three.js mirrors the x axis for a `CubeTexture` built from
images (`flipEnvMap`), so for the same six images its coefficients `sh[4]`,
`sh[5]` and `sh[8]` (the basis functions odd in x: L11, L2-2, L21) have the
opposite sign;
three.js `fromCubeRenderTarget`, which reads unmirrored faces, agrees with this
function.
"""
function light_probe_from_cube_texture(cube::CubeTexture; intensity=1.0)
    probe_intensity = _validated_light_intensity(intensity)
    acc_r = zeros(9); acc_g = zeros(9); acc_b = zeros(9)
    total_weight = 0.0
    for face in 1:6
        texture = cube.faces[face]
        H, W, _ = _checked_texture_data_size(texture, "light_probe_from_cube_texture")
        H == W || throw(ArgumentError(
            "light_probe_from_cube_texture faces must be square; face $face is $(H)×$(W)"))
        decode = _texture_decodes_srgb(texture)
        data = texture.data
        pixel_size = 2 / W
        @inbounds for row_index in 1:H, col_index in 1:W
            color = _texel_data(data, :clamp, :clamp, col_index - 1, row_index - 1, decode)
            sc = -1 + (col_index - 0.5) * pixel_size
            row = 1 - (row_index - 0.5) * pixel_size
            coord = _light_probe_face_coordinate(face, sc, row)
            length_sq = coord.x * coord.x + coord.y * coord.y + coord.z * coord.z
            weight = 4 / (sqrt(length_sq) * length_sq)
            total_weight += weight
            inv_length = 1 / sqrt(length_sq)
            x = coord.x * inv_length; y = coord.y * inv_length; z = coord.z * inv_length
            # SphericalHarmonics3.getBasisAt (SphericalHarmonics3.js:316-337).
            basis = (0.282095, 0.488603 * y, 0.488603 * z, 0.488603 * x,
                     1.092548 * x * y, 1.092548 * y * z, 0.315392 * (3 * z * z - 1),
                     1.092548 * x * z, 0.546274 * (x * x - y * y))
            for j in 1:9
                acc_r[j] += basis[j] * color.r * weight
                acc_g[j] += basis[j] * color.g * weight
                acc_b[j] += basis[j] * color.b * weight
            end
        end
    end
    norm = (4 * pi) / total_weight
    sh = ntuple(j -> Color3(acc_r[j] * norm, acc_g[j] * norm, acc_b[j] * norm), 9)
    return LightProbe(; sh=sh, intensity=probe_intensity)
end

get_position(o::LightProbe) = o.position
get_rotation(o::LightProbe) = o.rotation
get_scale(o::LightProbe) = o.scale
get_children(o::LightProbe) = o.children
get_parent(o::LightProbe) = o.parent
is_visible(o::LightProbe) = o.visible
set_parent!(o::LightProbe, p) = (o.parent = p)

# ========================== Luminous power ==========================
# three.js `power` accessors: lumens derived from intensity (candela for
# point/spot, nits for rect-area lights). Setting `power` rewrites `intensity`.

const _PowerLight = Union{PointLight, SpotLight, RectAreaLight}

@inline _light_power_scale(::PointLight) = 4π
@inline _light_power_scale(::SpotLight) = Float64(π)
@inline _light_power_scale(light::RectAreaLight) =
    getfield(light, :width) * getfield(light, :height) * π

@inline function Base.getproperty(light::_PowerLight, name::Symbol)
    name === :power &&
        return getfield(light, :intensity) * _light_power_scale(light)
    return getfield(light, name)
end

function Base.setproperty!(light::_PowerLight, name::Symbol, value)
    if name === :power
        power = _validated_light_finite(value, :power)
        scale = _light_power_scale(light)
        isfinite(scale) && scale != 0.0 ||
            throw(ArgumentError("light power requires a finite, nonzero emitter area"))
        return setfield!(light, :intensity, _validated_light_intensity(power / scale))
    end
    return setfield!(light, name, convert(fieldtype(typeof(light), name), value))
end

Base.propertynames(light::_PowerLight, private::Bool=false) =
    (fieldnames(typeof(light))..., :power)

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
    _validated_light_vec3(light.position, :position)
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
    _validated_light_probe_sh(light.sh)
    return nothing
end

@inline _validate_light_shadow_parameters(::AbstractLight) = nothing

@inline _validate_light_object_spatial_parameters(::AbstractLight) = nothing

@inline function _validate_light_object_spatial_parameters(
        light::Union{AmbientLight, LightProbe})
    _validated_light_vec3(light.position, :position)
    return nothing
end

@inline function _validate_light_shadow_parameters(
        light::Union{DirectionalLight, PointLight, SpotLight})
    _validated_shadow_bias(light.shadow_bias)
    _validated_shadow_pcf_radius(light.shadow_pcf_radius)
    _validated_shadow_intensity(light.shadow_intensity)
    _validated_shadow_normal_bias(light.shadow_normal_bias)
    return nothing
end

@inline function _validate_light_object(light::AbstractLight)
    _validate_light_parameters(light)
    _validate_light_object_spatial_parameters(light)
    _validate_light_shadow_parameters(light)
    return nothing
end

# World matrix of `light`: the one stored for the frame while a render that
# armed it is in progress, else computed from the parent chain.
@inline function _light_world_matrix(light::AbstractLight)::Mat4{Float64}
    cache = getfield(light, :_world_cache)::_LightWorldCache
    (@atomic :acquire cache.depth) > 0 && return cache.matrix
    return compute_world_matrix(light)::Mat4{Float64}
end

# Whether `compute_world_matrix(object)` returns without raising: every
# transform on the parent chain is finite (`_validate_object_transform`).
function _world_transform_chain_finite(object::AbstractObject3D)
    node::Union{Nothing, AbstractObject3D} = object
    while node !== nothing
        _object_transform_finite(node) || return false
        node = get_parent(node)
    end
    return true
end

# Arm the parented lights of a frame (see `_LightWorldCache`). A light whose
# transform chain is not finite stays unarmed, so the error it raises keeps
# coming from the first shading query, as before.
function _arm_light_world_cache!(lights::AbstractVector)
    lock(_LIGHT_WORLD_CACHE_LOCK)
    try
        for light in lights
            _arm_light_world!(light)
        end
    finally
        unlock(_LIGHT_WORLD_CACHE_LOCK)
    end
    return lights
end

# Callers hold `_LIGHT_WORLD_CACHE_LOCK`.
@inline function _arm_light_world!(light::AbstractLight)
    get_parent(light) === nothing && return nothing
    cache = getfield(light, :_world_cache)::_LightWorldCache
    depth = @atomic :acquire cache.depth
    if depth == 0
        _world_transform_chain_finite(light) || return nothing
        cache.matrix = compute_world_matrix(light)::Mat4{Float64}
    end
    @atomic :release cache.depth = depth + 1
    return nothing
end

# Undo `_arm_light_world_cache!` for the same lights when the frame ends. A
# light the frame did not arm (its render failed before arming) at worst ends
# another render's use of the stored matrix early, which only makes that render
# recompute the same matrix.
function _disarm_light_world_cache!(lights::AbstractVector)
    lock(_LIGHT_WORLD_CACHE_LOCK)
    try
        for light in lights
            _disarm_light_world!(light)
        end
    finally
        unlock(_LIGHT_WORLD_CACHE_LOCK)
    end
    return lights
end

# Callers hold `_LIGHT_WORLD_CACHE_LOCK`.
@inline function _disarm_light_world!(light::AbstractLight)
    cache = getfield(light, :_world_cache)::_LightWorldCache
    depth = @atomic :acquire cache.depth
    depth > 0 && (@atomic :release cache.depth = depth - 1)
    return nothing
end

@inline function _light_world_position(
        light::AbstractLight)::Vec3{Float64}
    position = get_position(light)::Vec3{Float64}
    parent = get_parent(light)
    parent === nothing && return position
    light_world = _light_world_matrix(light)
    return Vec3(light_world.e[13], light_world.e[14], light_world.e[15])
end

@inline function _light_world_direction(
        light::AbstractLight, direction::Vec3)::Vec3{Float64}
    parent = get_parent(light)
    rotation = get_rotation(light)::Euler{Float64}
    if parent === nothing && rotation.x == 0.0 && rotation.y == 0.0 &&
       rotation.z == 0.0
        return normalize(direction)
    end
    light_world = _light_world_matrix(light)
    return normalize(mat4_transform_direction(light_world, direction))
end

@inline function _light_emission_direction(light::Union{DirectionalLight,SpotLight})
    if light.rotation_driven
        return normalize(mat4_transform_direction(_light_world_matrix(light), Vec3(0.0,0.0,-1.0)))
    end
    return _direction_between(_light_world_position(light), light.target)
end

@inline function _light_world_target(light::Union{DirectionalLight,SpotLight})
    return light.rotation_driven ? _light_world_position(light) + _light_emission_direction(light) : light.target
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

function _collect_lights!(lights::Vector{SceneLight}, obj::AbstractObject3D,
                           layer_mask::Union{Nothing,UInt32}=nothing)
    is_visible(obj) || return nothing
    if obj isa AbstractLight && _object_matches_layer_mask(obj, layer_mask)
        _validate_light_object(obj)
        push!(lights, obj)
    end
    for child in get_children(obj)
        _collect_lights!(lights, child, layer_mask)
    end
    return nothing
end

function collect_lights(scene::AbstractObject3D)
    lights = Vector{SceneLight}(undef, _count_lights(scene))
    _fill_lights!(lights, scene, 1)
    return lights
end

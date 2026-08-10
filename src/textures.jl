# --------------------------------------------------------------------------
# Textures: 2D Texture/DataTexture/CanvasTexture, CubeTexture, DepthTexture,
# UV sampling with wrap modes (repeat/clamp/mirror) and filtering
# (nearest/bilinear), mipmaps, and procedural checker/grid generators.
# Image data is stored row-major H×W×C with row 1 = top; UV (0,0) = bottom-left.
# --------------------------------------------------------------------------

mutable struct Texture
    data::Array{Float64, 3}            # H × W × C
    wrap_s::Symbol                     # :repeat | :clamp | :mirror  (u)
    wrap_t::Symbol                     # :repeat | :clamp | :mirror  (v)
    filter::Symbol                     # :nearest | :bilinear
    min_filter::Symbol                 # WebGL/glTF minification filter metadata
    mag_filter::Symbol                 # WebGL/glTF magnification filter metadata
    mipmaps::Vector{Array{Float64, 3}} # optional pyramid (level 1 = base/2)
    colorspace::Symbol                 # :srgb | :linear  (three.js Texture.colorSpace)
    offset::Vec2{Float64}              # UV offset (three.js Texture.offset)
    repeat::Vec2{Float64}              # UV repeat/scale (three.js Texture.repeat)
    rotation::Float64                  # radians around `center`
    center::Vec2{Float64}              # UV transform pivot
    matrix::Mat3{Float64}              # UV transform matrix
    matrix_auto_update::Bool           # recompute matrix from offset/repeat/rotation/center
    matrix_cache_key::NTuple{7,Float64} # last transform tuple baked into matrix
    tex_coord::Int                     # glTF textureInfo.texCoord / UV set index (0 => uv, 1 => uv2)
    max_anisotropy::Float64            # WebGL anisotropic filtering request (1 = disabled)
    needs_update::Bool                 # browser runtime re-upload marker
end

const _TEXTURE_MATRIX_INVALID_KEY =
    (NaN, NaN, NaN, NaN, NaN, NaN, NaN)

function _texture_wrap_symbol(v)::Symbol
    (v === :repeat || (v isa AbstractString && v == "repeat")) && return :repeat
    (v === :clamp || (v isa AbstractString && v == "clamp")) && return :clamp
    (v === :mirror || (v isa AbstractString && v == "mirror")) && return :mirror
    throw(ArgumentError("unsupported texture wrap mode: $v"))
end

function _texture_filter_symbol(v)::Symbol
    (v === :nearest || (v isa AbstractString && v == "nearest")) && return :nearest
    (v === :linear || v === :bilinear ||
     (v isa AbstractString && (v == "linear" || v == "bilinear"))) &&
        return :bilinear
    throw(ArgumentError("unsupported texture filter: $v"))
end

function _texture_mag_filter_symbol(v)::Symbol
    (v === :nearest || (v isa AbstractString && v == "nearest")) && return :nearest
    (v === :linear || v === :bilinear ||
     (v isa AbstractString && (v == "linear" || v == "bilinear"))) &&
        return :linear
    throw(ArgumentError("unsupported texture mag_filter: $v"))
end

function _texture_min_filter_symbol(v)::Symbol
    (v === :nearest || (v isa AbstractString && v == "nearest")) && return :nearest
    (v === :linear || v === :bilinear ||
     (v isa AbstractString && (v == "linear" || v == "bilinear"))) &&
        return :linear
    (v === :nearest_mipmap_nearest ||
     (v isa AbstractString && v == "nearest_mipmap_nearest")) &&
        return :nearest_mipmap_nearest
    (v === :nearest_mipmap_linear ||
     (v isa AbstractString && v == "nearest_mipmap_linear")) &&
        return :nearest_mipmap_linear
    (v === :linear_mipmap_nearest ||
     (v isa AbstractString && v == "linear_mipmap_nearest")) &&
        return :linear_mipmap_nearest
    (v === :linear_mipmap_linear ||
     (v isa AbstractString && v == "linear_mipmap_linear")) &&
        return :linear_mipmap_linear
    throw(ArgumentError("unsupported texture min_filter: $v"))
end

function _texture_colorspace_symbol(v)::Symbol
    (v === :srgb || (v isa AbstractString && v == "srgb")) && return :srgb
    (v === :linear || (v isa AbstractString && v == "linear")) && return :linear
    throw(ArgumentError("unsupported texture colorspace: $v"))
end

function _texture_max_anisotropy(v)::Float64
    f = try
        Float64(v)
    catch
        throw(ArgumentError("Texture max_anisotropy must be numeric"))
    end
    isfinite(f) || throw(ArgumentError("Texture max_anisotropy must be finite"))
    f >= 1.0 || throw(ArgumentError("Texture max_anisotropy must be at least 1"))
    return f
end

function _texture_finite_float(value, label::String)
    f = try
        Float64(value)
    catch
        throw(ArgumentError("$label must be finite"))
    end
    isfinite(f) || throw(ArgumentError("$label must be finite"))
    return f
end

@inline function _texture_require_finite(value::Float64, label::String)
    isfinite(value) || throw(ArgumentError("$label must be finite"))
    return value
end

function _texture_finite_vec2(value, label::String)
    return Vec2(_texture_finite_float(value.x, "$label.x"),
                _texture_finite_float(value.y, "$label.y"))
end

function _texture_finite_matrix(matrix)
    values = ntuple(
        i -> _texture_finite_float(matrix.e[i], "Texture matrix[$i]"), 9)
    return Mat3{Float64}(values)
end

@noinline _texture_matrix_finite_error(index::Int) =
    throw(ArgumentError("Texture matrix[$index] must be finite"))

@inline function _texture_validate_matrix(matrix::Mat3{Float64})
    @inbounds for i in 1:9
        isfinite(matrix.e[i]) || _texture_matrix_finite_error(i)
    end
    return matrix
end

@inline function _texture_validate_transform_parameters(tex::Texture)
    _texture_require_finite(tex.offset.x, "Texture offset.x")
    _texture_require_finite(tex.offset.y, "Texture offset.y")
    _texture_require_finite(tex.repeat.x, "Texture repeat.x")
    _texture_require_finite(tex.repeat.y, "Texture repeat.y")
    _texture_require_finite(tex.rotation, "Texture rotation")
    _texture_require_finite(tex.center.x, "Texture center.x")
    _texture_require_finite(tex.center.y, "Texture center.y")
    return tex
end

function _texture_tex_coord(value::Integer)
    value isa Bool &&
        throw(ArgumentError("Texture tex_coord must be an integer"))
    tex_coord = try
        Int(value)
    catch
        throw(ArgumentError(
            "Texture tex_coord is outside the supported integer range"))
    end
    tex_coord >= 0 ||
        throw(ArgumentError("Texture tex_coord must be non-negative"))
    tex_coord <= 1 ||
        throw(ArgumentError("Texture tex_coord must be 0 or 1"))
    return tex_coord
end

function _texture_positive_size(value::Integer, label::String)
    value isa Bool && throw(ArgumentError("$label must be a positive integer"))
    size_value = try
        Int(value)
    catch
        throw(ArgumentError("$label is outside the supported integer range"))
    end
    size_value >= 1 || throw(ArgumentError("$label must be positive"))
    return size_value
end
_texture_positive_size(value, label::String) =
    throw(ArgumentError("$label must be a positive integer"))

@inline function _texture_checked_mul(a::Int, b::Int, label::String)
    try
        return Base.checked_mul(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label is too large"))
    end
end

@inline function _texture_checked_mul(a::Int, b::Int, label::String,
                                      context::String)
    try
        return Base.checked_mul(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label $context is too large"))
    end
end

@inline function _texture_check_rgb_square_size(size_value::Int, label::String)
    pixels = _texture_checked_mul(size_value, size_value, label, "pixel count")
    _texture_checked_mul(pixels, 3, label, "element count")
    return size_value
end

@inline function _checked_texture_data_size(tex::Texture, label::String)
    return _checked_texture_data_size(tex.data, label)
end

@inline function _checked_texture_data_size(data::Array{Float64,3}, label::String)
    H, W, C = size(data)
    (H > 0 && W > 0 && C > 0) ||
        throw(ArgumentError("$label texture dimensions must be positive; got $(size(data))"))
    return H, W, C
end

function Texture(data::Array{Float64,3}; wrap_s=:repeat, wrap_t=:repeat, filter=:bilinear,
                 min_filter=nothing, mag_filter=nothing,
                 mipmaps::Vector{Array{Float64,3}}=Array{Float64,3}[], colorspace::Symbol=:srgb,
                 offset=Vec2(0.0, 0.0), repeat=Vec2(1.0, 1.0),
                 rotation::Real=0.0, center=Vec2(0.0, 0.0),
                 matrix=Mat3(), matrix_auto_update::Bool=true, tex_coord::Integer=0,
                 max_anisotropy=1.0, needs_update::Bool=false)
    base_filter = _texture_filter_symbol(filter)
    minf = min_filter === nothing ? _texture_min_filter_symbol(base_filter) :
           _texture_min_filter_symbol(min_filter)
    magf = mag_filter === nothing ? _texture_mag_filter_symbol(base_filter) :
           _texture_mag_filter_symbol(mag_filter)
    offset_value = _texture_finite_vec2(offset, "Texture offset")
    repeat_value = _texture_finite_vec2(repeat, "Texture repeat")
    rotation_value = _texture_finite_float(rotation, "Texture rotation")
    center_value = _texture_finite_vec2(center, "Texture center")
    matrix_value = _texture_finite_matrix(matrix)
    tex_coord_value = _texture_tex_coord(tex_coord)
    tex = Texture(data, _texture_wrap_symbol(wrap_s), _texture_wrap_symbol(wrap_t),
                  base_filter, minf, magf, mipmaps,
                  _texture_colorspace_symbol(colorspace),
                  offset_value, repeat_value, rotation_value, center_value,
                  matrix_value, matrix_auto_update, _TEXTURE_MATRIX_INVALID_KEY,
                  tex_coord_value,
                  _texture_max_anisotropy(max_anisotropy), needs_update)
    matrix_auto_update ? texture_update_matrix!(tex) : tex
end

function Texture(data::Array{Float64,3}, wrap_s::Symbol, wrap_t::Symbol, filter::Symbol,
                 min_filter::Symbol, mag_filter::Symbol,
                 mipmaps::Vector{Array{Float64,3}}, colorspace::Symbol,
                 offset::Vec2{Float64}, repeat::Vec2{Float64}, rotation::Real,
                 center::Vec2{Float64}, matrix::Mat3,
                 matrix_auto_update::Bool, tex_coord::Integer)
    Texture(data, _texture_wrap_symbol(wrap_s), _texture_wrap_symbol(wrap_t),
            _texture_filter_symbol(filter), _texture_min_filter_symbol(min_filter),
            _texture_mag_filter_symbol(mag_filter), mipmaps,
            _texture_colorspace_symbol(colorspace),
            _texture_finite_vec2(offset, "Texture offset"),
            _texture_finite_vec2(repeat, "Texture repeat"),
            _texture_finite_float(rotation, "Texture rotation"),
            _texture_finite_vec2(center, "Texture center"),
            _texture_finite_matrix(matrix), matrix_auto_update,
            _TEXTURE_MATRIX_INVALID_KEY, _texture_tex_coord(tex_coord), 1.0,
            false)
end
function Texture(data::Array{Float64,3}, wrap_s::Symbol, wrap_t::Symbol, filter::Symbol,
                 min_filter::Symbol, mag_filter::Symbol,
                 mipmaps::Vector{Array{Float64,3}}, colorspace::Symbol,
                 offset::Vec2{Float64}, repeat::Vec2{Float64}, rotation::Real,
                 center::Vec2{Float64}, matrix::Mat3,
                 matrix_auto_update::Bool, tex_coord::Integer, max_anisotropy)
    Texture(data, _texture_wrap_symbol(wrap_s), _texture_wrap_symbol(wrap_t),
            _texture_filter_symbol(filter), _texture_min_filter_symbol(min_filter),
            _texture_mag_filter_symbol(mag_filter), mipmaps,
            _texture_colorspace_symbol(colorspace),
            _texture_finite_vec2(offset, "Texture offset"),
            _texture_finite_vec2(repeat, "Texture repeat"),
            _texture_finite_float(rotation, "Texture rotation"),
            _texture_finite_vec2(center, "Texture center"),
            _texture_finite_matrix(matrix), matrix_auto_update,
            _TEXTURE_MATRIX_INVALID_KEY, _texture_tex_coord(tex_coord),
            _texture_max_anisotropy(max_anisotropy), false)
end
DataTexture(data::Array{Float64,3}; kwargs...) = Texture(data; kwargs...)
CanvasTexture(data::Array{Float64,3}; kwargs...) = Texture(data; kwargs...)

# Single-channel depth texture.
DepthTexture(depth::Matrix{Float64}; kwargs...) =
    Texture(reshape(depth, size(depth,1), size(depth,2), 1); kwargs...)

# Wrap a 0-based integer pixel coordinate into [0, n-1] per the mode.
@inline function _wrap_coord(i::Int, n::Int, mode::Symbol)
    if mode === :repeat
        return mod(i, n)
    elseif mode === :clamp
        return clamp(i, 0, n - 1)
    elseif mode === :mirror
        p = mod(i, 2n)
        return p < n ? p : (2n - 1 - p)
    else
        throw(ArgumentError("unsupported texture wrap mode: $mode"))
    end
end

@inline function _texel(tex::Texture, ix::Int, iy::Int)
    H, W, C = size(tex.data)
    x = _wrap_coord(ix, W, tex.wrap_s) + 1
    y = _wrap_coord(iy, H, tex.wrap_t) + 1
    if C == 1
        g = tex.data[y, x, 1]; return Color3(g, g, g)
    elseif C == 2
        g = tex.data[y, x, 1]; return Color3(g, g, g)   # treat channel 1 as luminance
    end
    # C >= 3: RGB
    Color3(tex.data[y, x, 1], tex.data[y, x, 2], tex.data[y, x, 3])
end

@inline function _texel_data(data::Array{Float64,3}, wrap_s::Symbol, wrap_t::Symbol,
                            ix::Int, iy::Int)
    H, W, C = size(data)
    x = _wrap_coord(ix, W, wrap_s) + 1
    y = _wrap_coord(iy, H, wrap_t) + 1
    if C == 1
        g = data[y, x, 1]; return Color3(g, g, g)
    elseif C == 2
        g = data[y, x, 1]; return Color3(g, g, g)
    end
    return Color3(data[y, x, 1], data[y, x, 2], data[y, x, 3])
end

@inline function texture_transform_uv(tex::Texture, u, v)
    if tex.matrix_auto_update
        _texture_update_matrix_if_stale!(tex)
    else
        _texture_validate_matrix(tex.matrix)
    end
    e = tex.matrix.e
    transformed_u = e[1] * u + e[2] * v + e[3]
    transformed_v = e[4] * u + e[5] * v + e[6]
    if transformed_u isa AbstractFloat &&
       isfinite(u) && isfinite(v)
        !isfinite(transformed_u) &&
            (transformed_u = _stable_texture_transform_component(
                e[1], e[2], e[3], u, v))
        !isfinite(transformed_v) &&
            (transformed_v = _stable_texture_transform_component(
                e[4], e[5], e[6], u, v))
    end
    return transformed_u, transformed_v
end

@inline function _stable_texture_transform_component(a, b, c, u, v)
    a, b, c, u, v = promote(a, b, c, u, v)
    au = _float_representation_multiply(
        _float_value_representation(a),
        _float_value_representation(u))
    bv = _float_representation_multiply(
        _float_value_representation(b),
        _float_value_representation(v))
    result = _float_representation_add(
        _float_representation_add(au, bv),
        _float_value_representation(c))
    return _float_representation_value(result)
end

"""
    texture_update_matrix!(tex)

Recompute `tex.matrix` from `offset`, `repeat`, `rotation`, and `center`,
matching three.js `Texture.updateMatrix`/`Matrix3.setUvTransform`.
"""
function texture_update_matrix!(tex::Texture)
    _texture_validate_transform_parameters(tex)
    sx, sy = tex.repeat.x, tex.repeat.y
    tx, ty = tex.offset.x, tex.offset.y
    cx, cy = tex.center.x, tex.center.y
    c = cos(tex.rotation)
    s = sin(tex.rotation)
    offset_x = _stable_texture_matrix_offset(
        sx, -c, cx, -s, cy, cx, tx)
    offset_y = _stable_texture_matrix_offset(
        sy, s, cx, -c, cy, cy, ty)
    matrix = Mat3{Float64}((
        sx * c, sx * s, offset_x,
       -sy * s, sy * c, offset_y,
        0.0,    0.0,     1.0))
    _texture_validate_matrix(matrix)
    tex.matrix = matrix
    tex.matrix_cache_key = _texture_matrix_key(tex)
    return tex
end

@inline function _stable_texture_matrix_offset(
        scale, coefficient_x, x, coefficient_y, y, center, offset)
    scale, coefficient_x, x, coefficient_y, y, center, offset =
        promote(
            scale, coefficient_x, x, coefficient_y, y, center, offset)
    scale_representation = _float_value_representation(scale)
    x_term = _float_representation_multiply(
        _float_representation_multiply(
            scale_representation,
            _float_value_representation(coefficient_x)),
        _float_value_representation(x))
    y_term = _float_representation_multiply(
        _float_representation_multiply(
            scale_representation,
            _float_value_representation(coefficient_y)),
        _float_value_representation(y))
    result = _float_representation_sum4(
        x_term,
        y_term,
        _float_value_representation(center),
        _float_value_representation(offset),
    )
    return _float_representation_value(result)
end

@inline function _texture_matrix_key(tex::Texture)
    return (tex.offset.x, tex.offset.y, tex.repeat.x, tex.repeat.y,
            tex.rotation, tex.center.x, tex.center.y)
end

@inline function _texture_update_matrix_if_stale!(tex::Texture)
    _texture_validate_transform_parameters(tex)
    key = _texture_matrix_key(tex)
    tex.matrix_cache_key == key || texture_update_matrix!(tex)
    return tex
end

"""
    sample_texture(tex, u, v) -> Color3

Sample the texture at UV `(u,v)` ∈ [0,1]² (outside handled by the wrap modes),
using nearest or bilinear filtering. `v=0` is the bottom row.
"""
# Sanitize a non-finite UV from procedural or loaded geometry before sampling.
# Finite coordinates are reduced exactly according to their wrap mode below,
# before any conversion to an integer texel coordinate.
@inline function _sanitize_uv(x)
    isfinite(x) || return zero(x)
    return x
end

@inline function _sampling_uv(x, mode::Symbol)
    x = _sanitize_uv(x)
    if mode === :repeat
        return mod(x, one(x))
    elseif mode === :clamp
        return clamp(x, zero(x), one(x))
    elseif mode === :mirror
        period = one(x) + one(x)
        wrapped = mod(x, period)
        return wrapped <= one(x) ? wrapped : period - wrapped
    end
    throw(ArgumentError("unsupported texture wrap mode: $mode"))
end

@inline function _texture_sample_uv(tex::Texture, u, v)
    u, v = texture_transform_uv(tex, u, v)
    return _sanitize_uv(u), _sanitize_uv(v)
end

@inline function _stable_color_lerp(a::Color3, b::Color3, t)
    return Color3(
        _stable_lerp(a.r, b.r, t),
        _stable_lerp(a.g, b.g, t),
        _stable_lerp(a.b, b.b, t),
    )
end

function _sample_texture_data(data::Array{Float64,3}, wrap_s::Symbol, wrap_t::Symbol,
                              filter::Symbol, u, v, label::String)
    H, W, _ = _checked_texture_data_size(data, label)
    wrap_s = _texture_wrap_symbol(wrap_s)
    wrap_t = _texture_wrap_symbol(wrap_t)
    filter = _texture_filter_symbol(filter)
    u = _sampling_uv(u, wrap_s)
    v = _sampling_uv(v, wrap_t)
    fx = u * W - 0.5
    fy = (1 - v) * H - 0.5                       # flip v so v=0 maps to the bottom row
    if filter === :nearest
        return _texel_data(data, wrap_s, wrap_t, round(Int, fx), round(Int, fy))
    end
    x0 = floor(Int, fx); y0 = floor(Int, fy)
    tx = fx - x0; ty = fy - y0
    c00 = _texel_data(data, wrap_s, wrap_t, x0,   y0)
    c10 = _texel_data(data, wrap_s, wrap_t, x0+1, y0)
    c01 = _texel_data(data, wrap_s, wrap_t, x0,   y0+1)
    c11 = _texel_data(data, wrap_s, wrap_t, x0+1, y0+1)
    top = _stable_color_lerp(c00, c10, tx)
    bottom = _stable_color_lerp(c01, c11, tx)
    return _stable_color_lerp(top, bottom, ty)
end

function sample_texture(tex::Texture, u, v)
    tu, tv = _texture_sample_uv(tex, u, v)
    return _sample_texture_data(tex.data, tex.wrap_s, tex.wrap_t, tex.filter, tu, tv,
                                "sample_texture")
end

@inline function _texel_channel(tex::Texture, ix::Int, iy::Int, channel::Int, default=1.0)
    H, W, C = size(tex.data)
    channel < 1 && return default
    x = _wrap_coord(ix, W, tex.wrap_s) + 1
    y = _wrap_coord(iy, H, tex.wrap_t) + 1
    if channel <= C
        return tex.data[y, x, channel]
    elseif C == 1
        # Single-channel (grayscale / RedFormat) texture: broadcast its lone
        # channel to any requested channel, matching _texel's luminance
        # broadcast and three.js's single-channel sampling. Otherwise a natural
        # grayscale alpha/roughness/etc. map sampled at channel 2/3/4 would be
        # silently ignored in favor of `default`.
        return tex.data[y, x, 1]
    end
    return default
end

@inline _texture_channel_identity(value) = value

# WebGL export uploads texture data as normalized bytes.  Scalar material maps
# use the same per-texel normalization on the CPU so filtering cannot reintroduce
# negative, over-range, or non-finite material factors.
@inline function _texture_unit_interval_value(value)
    result = Float64(value)
    return isfinite(result) ? clamp(result, 0.0, 1.0) : 0.0
end

function _sample_texture_channel(tex::Texture, u, v, channel::Int, default,
                                 transform::F) where {F}
    H, W, _ = _checked_texture_data_size(tex, "sample_texture_channel")
    _texture_wrap_symbol(tex.wrap_s)
    _texture_wrap_symbol(tex.wrap_t)
    filter = _texture_filter_symbol(tex.filter)
    u, v = texture_transform_uv(tex, u, v)
    u = _sampling_uv(u, tex.wrap_s)
    v = _sampling_uv(v, tex.wrap_t)
    fx = u * W - 0.5
    fy = (1 - v) * H - 0.5
    if filter === :nearest
        return transform(
            _texel_channel(tex, round(Int, fx), round(Int, fy), channel, default))
    end
    x0 = floor(Int, fx); y0 = floor(Int, fy)
    tx = fx - x0; ty = fy - y0
    c00 = transform(_texel_channel(tex, x0,   y0,   channel, default))
    c10 = transform(_texel_channel(tex, x0+1, y0,   channel, default))
    c01 = transform(_texel_channel(tex, x0,   y0+1, channel, default))
    c11 = transform(_texel_channel(tex, x0+1, y0+1, channel, default))
    top = _stable_lerp(c00, c10, tx)
    bottom = _stable_lerp(c01, c11, tx)
    return _stable_lerp(top, bottom, ty)
end

function sample_texture_channel(tex::Texture, u, v, channel::Int; default=1.0)
    return _sample_texture_channel(tex, u, v, channel, default,
                                   _texture_channel_identity)
end

@inline function _sample_texture_unit_channel(tex::Texture, u, v, channel::Int;
                                              default=1.0)
    return _sample_texture_channel(tex, u, v, channel, default,
                                   _texture_unit_interval_value)
end

"""
    sample_texture_linear(tex, u, v) -> Color3

Sample the texture and return the color in linear light. When
`tex.colorspace === :srgb` the filtered RGB sample is converted with the
standard sRGB→linear transfer function per channel
(`c ≤ 0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4`), matching three.js's
`SRGBColorSpace` decode for color textures. When `tex.colorspace === :linear`
the raw sample is returned unchanged (for data textures such as normal,
roughness, metalness, AO, or depth maps). `sample_texture` itself is left
untouched and always returns the raw stored values.
"""
function sample_texture_linear(tex::Texture, u, v)
    c = sample_texture(tex, u, v)
    tex.colorspace === :linear && return c
    tex.colorspace === :srgb ||
        throw(ArgumentError("unsupported texture colorspace: $(tex.colorspace)"))
    return Color3(srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b))
end

# ========================== Mipmaps ==========================

function _box_mipmap_even(cur::Array{Float64,3}, nh::Int, nw::Int, C::Int)
    nxt = Array{Float64}(undef, nh, nw, C)
    @inbounds for c in 1:C, j in 1:nw, i in 1:nh
        si = 2i - 1
        sj = 2j - 1
        top = _stable_midpoint(
            cur[si, sj, c], cur[si, sj + 1, c])
        bottom = _stable_midpoint(
            cur[si + 1, sj, c], cur[si + 1, sj + 1, c])
        nxt[i, j, c] = _stable_midpoint(top, bottom)
    end
    return nxt
end

@inline _box_filter_overlap(lo::Float64, hi::Float64, src::Int) =
    min(hi, Float64(src)) - max(lo, Float64(src - 1))

function _box_mipmap_weighted(cur::Array{Float64,3}, nh::Int, nw::Int, C::Int)
    H, W, _ = size(cur)
    row_step = H / nh
    col_step = W / nw
    nxt = Array{Float64}(undef, nh, nw, C)
    @inbounds for c in 1:C, j in 1:nw
        col_lo = (j - 1) * col_step
        col_hi = j * col_step
        sj_first = floor(Int, col_lo) + 1
        sj_last = min(ceil(Int, col_hi), W)
        for i in 1:nh
            row_lo = (i - 1) * row_step
            row_hi = i * row_step
            si_first = floor(Int, row_lo) + 1
            si_last = min(ceil(Int, row_hi), H)
            average = 0.0
            total_weight = 0.0
            for sj in sj_first:sj_last
                wj = _box_filter_overlap(col_lo, col_hi, sj)
                for si in si_first:si_last
                    wi = _box_filter_overlap(row_lo, row_hi, si)
                    weight = wi * wj
                    next_weight = total_weight + weight
                    if total_weight == 0.0
                        average = cur[si, sj, c]
                    else
                        average = _stable_lerp(
                            average, cur[si, sj, c],
                            weight / next_weight)
                    end
                    total_weight = next_weight
                end
            end
            nxt[i, j, c] = average
        end
    end
    return nxt
end

"""Build a box-filtered mipmap pyramid down to 1×1 (three.js `generateMipmaps`)."""
function generate_mipmaps!(tex::Texture)
    _checked_texture_data_size(tex, "generate_mipmaps!")
    empty!(tex.mipmaps)
    cur = tex.data
    while size(cur, 1) > 1 || size(cur, 2) > 1
        H, W, C = size(cur)
        nh = max(H ÷ 2, 1); nw = max(W ÷ 2, 1)
        nxt = if iseven(H) && iseven(W)
            _box_mipmap_even(cur, nh, nw, C)
        else
            # Area-average box filter. Using fractional overlap weights means odd
            # rows/columns contribute instead of being cropped, so the coarsest mip
            # equals the true image average (was biased toward the top-left corner).
            _box_mipmap_weighted(cur, nh, nw, C)
        end
        push!(tex.mipmaps, nxt)
        cur = nxt
    end
    return tex
end

"""Sample a discrete mip level (0 = base). Clamped to the available levels."""
function sample_texture_lod(tex::Texture, u, v, lod::Int)
    _checked_texture_data_size(tex, "sample_texture_lod")
    return _sample_texture_lod_filtered(tex, u, v, lod, tex.filter)
end

@inline _texture_min_filter_uses_mipmaps(filter::Symbol) =
    filter in (:nearest_mipmap_nearest, :nearest_mipmap_linear,
               :linear_mipmap_nearest, :linear_mipmap_linear)
@inline _texture_min_filter_blends_mipmaps(filter::Symbol) =
    filter in (:nearest_mipmap_linear, :linear_mipmap_linear)
@inline _texture_min_filter_texel_filter(filter::Symbol) =
    filter in (:nearest, :nearest_mipmap_nearest, :nearest_mipmap_linear) ? :nearest : :bilinear
@inline _texture_mag_filter_texel_filter(filter::Symbol) =
    filter === :nearest ? :nearest : :bilinear

function _sample_texture_lod_filtered(tex::Texture, u, v, lod::Int, filter::Symbol)
    lod <= 0 && return _sample_texture_filtered(tex, u, v, filter)
    isempty(tex.mipmaps) && return _sample_texture_filtered(tex, u, v, filter)
    lvl = tex.mipmaps[min(lod, length(tex.mipmaps))]
    tu, tv = _texture_sample_uv(tex, u, v)
    return _sample_texture_data(lvl, tex.wrap_s, tex.wrap_t, filter, tu, tv,
                                "sample_texture_lod")
end

function _sample_texture_filtered(tex::Texture, u, v, filter::Symbol)
    _checked_texture_data_size(tex, "sample_texture")
    tu, tv = _texture_sample_uv(tex, u, v)
    return _sample_texture_data(tex.data, tex.wrap_s, tex.wrap_t, filter, tu, tv,
                                "sample_texture")
end

"""
    sample_texture_auto(tex, u, v, duv) -> Color3

Sample with automatic magnification/minification selection from the per-pixel
UV footprint `duv` (the maximum texel span covered by one screen pixel, as a
fraction of the [0,1] UV range). Magnifying footprints use `mag_filter`.
Minifying footprints use the continuous LOD

    lod = clamp(log2(max(duv * size, 1)), 0, length(mipmaps))

with `size = max(W, H)` the base texel dimension, mirroring the GPU mipmap
selection used by three.js. The two bracketing integer levels are sampled
with `sample_texture_lod` and trilinearly blended by the fractional part of
`lod`. When the texture has no mipmaps the call falls back to
the base level using the texture's minification filter. The four mipmap
minification filters are honored: nearest/linear texel filtering is selected
from the filter prefix, and nearest/linear mip-level selection is selected from
the filter suffix. The integer level choice is a discrete decision, but the
linear mip blend weight is carried through unchanged so the result stays smooth
for `ForwardDiff.Dual`/`ADVar` `duv`.
"""
function sample_texture_auto(tex::Texture, u, v, duv)
    # isfinite/comparison work directly on Float64/Dual/ADVar; Float64(::Dual) is
    # undefined and would crash the differentiable path the docstring promises.
    isfinite(duv) ||
        throw(ArgumentError("texture LOD footprint (duv) must be finite"))
    H, W, _ = _checked_texture_data_size(tex, "sample_texture_auto")
    min_filter = _texture_min_filter_symbol(tex.min_filter)
    mag_filter = _texture_mag_filter_symbol(tex.mag_filter)
    sz = max(W, H)
    span_raw = abs(duv) * sz
    if span_raw <= 1.0
        return _sample_texture_filtered(tex, u, v,
                                        _texture_mag_filter_texel_filter(mag_filter))
    end
    filter = _texture_min_filter_texel_filter(min_filter)
    (isempty(tex.mipmaps) || !_texture_min_filter_uses_mipmaps(min_filter)) &&
        return _sample_texture_filtered(tex, u, v, filter)
    nlevels = length(tex.mipmaps)
    # Continuous LOD; clamp to [0, nlevels]. Keep AD type for the blend weight.
    # Use log(x)/log(2) rather than log2 so the reverse-mode `ADVar` path (which
    # defines `log` but not `log2`) keeps its derivative instead of falling back
    # to a value-only `float` conversion.
    span = max(span_raw, one(span_raw))
    lod = clamp(log(span) / log(oftype(float(span), 2)), zero(duv), oftype(float(duv), nlevels))
    # floor(Int, ·) works directly on Float64, ForwardDiff.Dual, and ADVar for the
    # discrete level index — do NOT do Float64(lod) (undefined for Dual, crashes
    # the differentiable path); the AD type stays in `lod`/`frac` for the blend.
    if !_texture_min_filter_blends_mipmaps(min_filter)
        nearest_level = clamp(floor(Int, lod + 0.5), 0, nlevels)
        return _sample_texture_lod_filtered(tex, u, v, nearest_level, filter)
    end
    l0 = floor(Int, lod)
    frac = lod - l0                            # fractional blend weight (AD-stable)
    l1 = min(l0 + 1, nlevels)
    c0 = _sample_texture_lod_filtered(tex, u, v, l0, filter)
    frac <= 0 && return c0                      # exactly on a level
    c1 = _sample_texture_lod_filtered(tex, u, v, l1, filter)
    return _stable_color_lerp(c0, c1, frac)
end

"""
    sample_texture_aniso(tex, u, v, du, dv; max_aniso=8) -> Color3

Anisotropic texture filtering. `(du, dv)` is the per-pixel UV-space footprint
(the texel span one screen pixel covers along the U and V axes, expressed as a
fraction of the [0,1] UV range, exactly the convention used by
`sample_texture_auto`'s `duv`). The footprint is modeled as an axis-aligned
ellipse with half-extents `|du|` and `|dv|`; its major axis is the larger
extent and its minor axis the smaller.

The sample count is `N = clamp(ceil(major/minor), 1, max_aniso)`. `N` probes
are spread evenly along the *major* axis, centred on `(u, v)`, each taken at the
level-of-detail implied by the *minor* axis footprint (via `sample_texture_auto`,
which reuses the existing mipmaps). Averaging these probes integrates the long
direction of the footprint while keeping the short direction sharp, which is
exactly what isotropic bilinear/mip sampling blurs away at grazing angles.

Fallback behaviour:
- If `tex` has no mipmaps, or the footprint is (near-)isotropic
  (`ratio < 1.5`), or `max_aniso <= 1`, a single isotropic sample is returned
  (`sample_texture_auto` when mipmaps exist, else `sample_texture`).

AD tolerance: the discrete decisions (`N`, the per-probe integer mip level) are
made on `Float64` magnitudes, while the probe coordinates, the minor-axis
`duv`, and the averaging weight `1/N` all flow through unchanged, so a
`ForwardDiff.Dual`/`ADVar` `(u, v, du, dv)` keeps a smooth derivative through
the returned color.
"""
function sample_texture_aniso(tex::Texture, u, v, du, dv; max_aniso::Int=8)
    (isfinite(du) && isfinite(dv)) ||
        throw(ArgumentError("texture anisotropic footprint (du, dv) must be finite"))
    # Footprint extents along each UV axis (keep AD type for the live path).
    adu = abs(du)
    adv = abs(dv)
    # Major/minor extents and the axis the major one lies on.
    major = max(adu, adv)
    minor = min(adu, adv)
    major_is_u = adu >= adv

    # Discrete decisions below use comparisons / ceil(Int,·), which work directly
    # on Float64, ForwardDiff.Dual, and ADVar — do NOT do Float64(major) (undefined
    # for Dual, crashes the differentiable footprint path).

    # No mipmaps: anisotropic LOD selection is meaningless, fall back to bilinear.
    isempty(tex.mipmaps) && return sample_texture(tex, u, v)

    # Near-isotropic footprint, degenerate footprint, or anisotropy disabled:
    # a single isotropic auto-LOD sample is correct and cheapest.
    if max_aniso <= 1 || minor <= 0 || major <= 0
        return sample_texture_auto(tex, u, v, major)
    end
    ratio = major / minor
    if ratio < 1.5
        return sample_texture_auto(tex, u, v, major)
    end

    # Number of probes along the major axis (discrete, value-only).
    N = ratio >= max_aniso ? max_aniso :
        clamp(ceil(Int, ratio), 1, max_aniso)
    if N <= 1
        return sample_texture_auto(tex, u, v, major)
    end

    # The probes share the minor-axis LOD: sampling at the minor footprint keeps
    # the short direction sharp; the spread along the major axis integrates the
    # long direction. (`minor` carries the AD type into sample_texture_auto.)
    duv_minor = minor

    # The probes span the major axis symmetrically about (u,v): the footprint
    # half-extent is `major`, so for N probes at fractional positions
    # t_k = (k + 0.5)/N ∈ (0,1) the signed UV offset is (2 t_k - 1)*major.
    invN = 1.0 / N
    @inline probe(k) = begin
        s = (2 * (k + 0.5) * invN) - 1.0        # Float64 stepping fraction in (-1, 1)
        off = s * major                          # AD-typed signed UV offset
        if major_is_u
            sample_texture_auto(tex, u + off, v, duv_minor)
        else
            sample_texture_auto(tex, u, v + off, duv_minor)
        end
    end
    average = probe(0)                           # seeds the accumulator with the AD type
    @inbounds for k in 1:(N - 1)
        sample = probe(k)
        weight = 1.0 / (k + 1)
        average = _stable_color_lerp(average, sample, weight)
    end
    return average
end

# ========================== CubeTexture ==========================

struct CubeTexture
    faces::NTuple{6, Texture}   # +x, -x, +y, -y, +z, -z
end

function _cube_face_uv(dir::Vec3)
    ax, ay, az = abs(dir.x), abs(dir.y), abs(dir.z)
    ax == 0 && ay == 0 && az == 0 && return 1, 0.5, 0.5
    if ax >= ay && ax >= az
        if dir.x > 0; return 1, 0.5 - (dir.z/dir.x)/2, 0.5 + (dir.y/ax)/2
        else;         return 2, 0.5 - (dir.z/dir.x)/2, 0.5 + (dir.y/ax)/2; end
    elseif ay >= ax && ay >= az
        if dir.y > 0; return 3, 0.5 + (dir.x/ay)/2, 0.5 - (dir.z/ay)/2
        else;         return 4, 0.5 + (dir.x/ay)/2, 0.5 + (dir.z/ay)/2; end
    else
        if dir.z > 0; return 5, 0.5 + (dir.x/dir.z)/2, 0.5 + (dir.y/az)/2
        else;         return 6, 0.5 + (dir.x/dir.z)/2, 0.5 + (dir.y/az)/2; end
    end
end

"""Sample a cube map along direction `dir` (three.js cube-map convention)."""
function sample_cube(ct::CubeTexture, dir::Vec3)
    face, u, v = _cube_face_uv(dir)
    return sample_texture(ct.faces[face], u, v)
end

"""
    sample_cube_lod(ct, dir, lod) -> Color3

Sample a cube map at an explicit mip level. `lod = 0` samples the base face;
positive fractional levels are clamped to the selected face's available mip
chain and blended between neighboring levels. Faces without mipmaps fall back
to `sample_cube`.
"""
function sample_cube_lod(ct::CubeTexture, dir::Vec3, lod)
    lod_f = try
        Float64(lod)
    catch err
        (err isa MethodError || err isa InexactError || err isa OverflowError ||
         err isa DomainError || err isa TypeError || err isa ArgumentError) ||
            rethrow()
        throw(ArgumentError("cubemap lod must be finite"))
    end
    isfinite(lod_f) || throw(ArgumentError("cubemap lod must be finite"))
    face, u, v = _cube_face_uv(dir)
    tex = ct.faces[face]
    isempty(tex.mipmaps) && return sample_texture(tex, u, v)
    lod_f <= 0 && return sample_texture(tex, u, v)
    nlevels = length(tex.mipmaps)
    lod_clamped = clamp(lod_f, 0.0, Float64(nlevels))
    l0 = floor(Int, lod_clamped)
    frac = lod_clamped - l0
    c0 = sample_texture_lod(tex, u, v, l0)
    frac <= 0 && return c0
    c1 = sample_texture_lod(tex, u, v, min(l0 + 1, nlevels))
    return _stable_color_lerp(c0, c1, frac)
end

function _cube_face_direction(face::Int, u::Float64, v::Float64)
    dir = if face == 1       # +X
        Vec3(1.0, 2v - 1, 1 - 2u)
    elseif face == 2         # -X
        Vec3(-1.0, 2v - 1, 2u - 1)
    elseif face == 3         # +Y
        Vec3(2u - 1, 1.0, 1 - 2v)
    elseif face == 4         # -Y
        Vec3(2u - 1, -1.0, 2v - 1)
    elseif face == 5         # +Z
        Vec3(2u - 1, 2v - 1, 1.0)
    elseif face == 6         # -Z
        Vec3(1 - 2u, 2v - 1, -1.0)
    else
        throw(ArgumentError("cube face index must be in 1:6"))
    end
    n = norm(dir)
    n > 0 || return Vec3(1.0, 0.0, 0.0)
    return dir / n
end

function _equirectangular_uv(dir::Vec3)
    n = norm(dir)
    n > 0 || return (0.5, 0.5)
    unit = normalize(dir)
    x, y, z = unit.x, unit.y, unit.z
    u = 0.5 + atan(z, x) / (2pi)
    v = 0.5 + asin(clamp(y, -1.0, 1.0)) / pi
    return (u, v)
end

"""
    equirectangular_to_cubemap(tex; size=max(1, min(H, W ÷ 2)),
                               generate_mipmaps=false) -> CubeTexture

Convert an equirectangular environment texture to a six-face [`CubeTexture`](@ref)
using Diff3D's cube-map face convention (`+x, -x, +y, -y, +z, -z`). The source
texture is sampled as longitude/latitude with horizontal wrap and vertical
top/bottom poles; HDR values are preserved as floating-point data. Set
`generate_mipmaps=true` to build per-face mip chains for roughness-aware
environment sampling.
"""
function equirectangular_to_cubemap(tex::Texture; size::Integer=max(1, min(Base.size(tex.data, 1), Base.size(tex.data, 2) ÷ 2)),
                                    generate_mipmaps::Bool=false)
    face_size = _texture_positive_size(size, "cubemap face size")
    _texture_check_rgb_square_size(face_size, "cubemap face")
    faces = ntuple(face -> begin
        data = Array{Float64}(undef, face_size, face_size, 3)
        @inbounds for row in 1:face_size, col in 1:face_size
            u_face = (col - 0.5) / face_size
            v_face = 1.0 - (row - 0.5) / face_size
            u_env, v_env = _equirectangular_uv(_cube_face_direction(face, u_face, v_face))
            c = sample_texture(tex, u_env, v_env)
            data[row, col, 1] = c.r
            data[row, col, 2] = c.g
            data[row, col, 3] = c.b
        end
        face_tex = Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=tex.filter,
                           colorspace=tex.colorspace,
                           max_anisotropy=tex.max_anisotropy)
        generate_mipmaps && generate_mipmaps!(face_tex)
        face_tex
    end, 6)
    return CubeTexture(faces)
end

# ========================== PMREM (prefiltered environment) ==========================

"""
Prefiltered radiance environment map: a sequence of [`CubeTexture`](@ref) levels
where level `i` (0-based) holds the source convolved with a GGX specular lobe of
roughness `i / (levels-1)`. Level 0 is the mirror (roughness 0) reflection.
Build one with [`generate_pmrem`](@ref) and sample it with [`sample_pmrem`](@ref).
"""
struct PMREM
    levels::Vector{CubeTexture}
end

# Van der Corput radical inverse in base 2 — deterministic low-discrepancy
# sequence (no RNG), matching three.js' Hammersley-based prefilter.
@inline function _radical_inverse_vdc(bits::UInt32)
    bits = (bits << 16) | (bits >> 16)
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1)
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2)
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4)
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8)
    return Float64(bits) * 2.3283064365386963e-10        # bits / 2^32
end

# GGX importance sample direction in world space around normal `N`.
function _importance_sample_ggx(xi1::Float64, xi2::Float64, N::Vec3, roughness::Float64)
    a = roughness * roughness
    phi = 2pi * xi1
    cos_t = sqrt((1.0 - xi2) / (1.0 + (a * a - 1.0) * xi2))
    sin_t = sqrt(max(0.0, 1.0 - cos_t * cos_t))
    hx = sin_t * cos(phi); hy = sin_t * sin(phi); hz = cos_t
    up = abs(N.z) < 0.999 ? Vec3(0.0, 0.0, 1.0) : Vec3(1.0, 0.0, 0.0)
    tangent = normalize(cross(up, N))
    bitangent = cross(N, tangent)
    return normalize(tangent * hx + bitangent * hy + N * hz)
end

# Convolve the source cube map around direction `N` for the given roughness.
function _pmrem_prefilter(ct::CubeTexture, N::Vec3, roughness::Float64, samples::Int)
    roughness <= 0.0 && return sample_cube(ct, N)        # exact mirror reflection
    V = N                                                # split-sum assumes V = N = R
    average = Color3(0.0, 0.0, 0.0)
    total_weight = 0.0
    @inbounds for i in 0:(samples - 1)
        xi1 = i / samples
        xi2 = _radical_inverse_vdc(UInt32(i))
        H = _importance_sample_ggx(xi1, xi2, N, roughness)
        L = normalize(2.0 * dot(V, H) * H - V)           # reflect V about H
        ndl = dot(N, L)
        if ndl > 0.0
            sample = sample_cube(ct, L)
            next_weight = total_weight + ndl
            average = total_weight == 0.0 ? sample :
                _stable_color_lerp(
                    average, sample, ndl / next_weight)
            total_weight = next_weight
        end
    end
    return total_weight > 0.0 ? average : sample_cube(ct, N)
end

"""
    generate_pmrem(ct; levels=5, samples=64, base_size=face size) -> PMREM

Prefilter a [`CubeTexture`](@ref) into a roughness mip chain, mirroring three.js'
`PMREMGenerator`. Level `i` is convolved with a GGX lobe of roughness
`i / (levels-1)` using a deterministic Hammersley sequence (no RNG), and each
level's face resolution halves so rougher levels are cheaper. HDR/linear values
are preserved. Sample the result with [`sample_pmrem`](@ref).
"""
function generate_pmrem(ct::CubeTexture; levels::Integer=5, samples::Integer=64,
                        base_size::Integer=Base.size(ct.faces[1].data, 1))
    nlev = _texture_positive_size(levels, "PMREM levels")
    nsamp = _texture_positive_size(samples, "PMREM samples")
    base_size_value = _texture_positive_size(base_size, "PMREM base_size")
    _texture_check_rgb_square_size(base_size_value, "PMREM base level")
    out = Vector{CubeTexture}(undef, nlev)
    for l in 0:(nlev - 1)
        roughness = nlev == 1 ? 0.0 : l / (nlev - 1)
        sz = max(1, base_size_value >> l)
        faces = ntuple(face -> begin
            data = Array{Float64}(undef, sz, sz, 3)
            @inbounds for row in 1:sz, col in 1:sz
                u = (col - 0.5) / sz
                v = 1.0 - (row - 0.5) / sz
                N = _cube_face_direction(face, u, v)
                c = _pmrem_prefilter(ct, N, roughness, nsamp)
                data[row, col, 1] = c.r
                data[row, col, 2] = c.g
                data[row, col, 3] = c.b
            end
            Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:bilinear,
                    colorspace=ct.faces[face].colorspace)
        end, 6)
        out[l + 1] = CubeTexture(faces)
    end
    return PMREM(out)
end

"""
    sample_pmrem(pmrem, dir, roughness) -> Color3

Sample a [`PMREM`](@ref) along `dir` at a perceptual `roughness` in `[0, 1]`,
linearly blending between the two neighboring prefiltered levels.
"""
function sample_pmrem(pmrem::PMREM, dir::Vec3, roughness)
    n = length(pmrem.levels)
    n >= 1 || throw(ArgumentError("PMREM has no levels"))
    r = try
        Float64(roughness)
    catch err
        (err isa MethodError || err isa InexactError || err isa OverflowError ||
         err isa DomainError || err isa TypeError || err isa ArgumentError) ||
            rethrow()
        throw(ArgumentError("PMREM roughness must be finite"))
    end
    isfinite(r) || throw(ArgumentError("PMREM roughness must be finite"))
    n == 1 && return sample_cube(pmrem.levels[1], dir)
    lod = clamp(r, 0.0, 1.0) * (n - 1)
    l0 = floor(Int, lod)
    frac = lod - l0
    c0 = sample_cube(pmrem.levels[l0 + 1], dir)
    frac <= 0.0 && return c0
    c1 = sample_cube(pmrem.levels[min(l0 + 1, n - 1) + 1], dir)
    return _stable_color_lerp(c0, c1, frac)
end

# ========================== Procedural textures ==========================

"""`n`×`n`-cell checkerboard texture (each cell `cell` pixels) as an H×W×3 Texture."""
function checker_texture(; n::Int=8, cell::Int=8, a=Color3(1.0,1.0,1.0), b=Color3(0.0,0.0,0.0),
                          wrap_s=:repeat, wrap_t=:repeat, filter=:nearest)
    n = max(1, n); cell = max(1, cell)   # avoid a 0-size texture / (i-1)÷0 DivideError
    sz = _texture_checked_mul(n, cell, "checker texture side length")
    _texture_check_rgb_square_size(sz, "checker texture")
    data = Array{Float64}(undef, sz, sz, 3)
    @inbounds for i in 1:sz, j in 1:sz
        ci = (i - 1) ÷ cell; cj = (j - 1) ÷ cell
        col = iseven(ci + cj) ? a : b
        data[i,j,1] = col.r; data[i,j,2] = col.g; data[i,j,3] = col.b
    end
    Texture(data; wrap_s=wrap_s, wrap_t=wrap_t, filter=filter)
end

"""Grid texture: `line` color on grid lines every `cell` pixels, else `bg`."""
function grid_texture(; size_px::Int=64, cell::Int=16, line=Color3(0.0,0.0,0.0),
                       bg=Color3(1.0,1.0,1.0), thickness::Int=1, wrap_s=:repeat, wrap_t=:repeat)
    cell = max(1, cell)            # cell=0 would make (i-1) % cell a DivideError
    size_px = max(1, size_px)
    _texture_check_rgb_square_size(size_px, "grid texture")
    data = Array{Float64}(undef, size_px, size_px, 3)
    @inbounds for i in 1:size_px, j in 1:size_px
        on = ((i-1) % cell < thickness) || ((j-1) % cell < thickness)
        col = on ? line : bg
        data[i,j,1] = col.r; data[i,j,2] = col.g; data[i,j,3] = col.b
    end
    Texture(data; wrap_s=wrap_s, wrap_t=wrap_t, filter=:nearest)
end

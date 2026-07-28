# --------------------------------------------------------------------------
# Math types: Vec2, Vec3, Vec4, Mat3, Mat4, Quaternion, Euler, Color3
# All immutable and parametric for ForwardDiff Dual number compatibility.
# --------------------------------------------------------------------------

# ========================== Vector Types ==========================

struct Vec2{T<:Real}
    x::T
    y::T
end
Vec2(x::Real, y::Real) = Vec2(promote(x, y)...)
Vec2() = Vec2(0.0, 0.0)

struct Vec3{T<:Real}
    x::T
    y::T
    z::T
end
Vec3(x::Real, y::Real, z::Real) = Vec3(promote(x, y, z)...)
Vec3() = Vec3(0.0, 0.0, 0.0)

struct Vec4{T<:Real}
    x::T
    y::T
    z::T
    w::T
end
Vec4(x::Real, y::Real, z::Real, w::Real) = Vec4(promote(x, y, z, w)...)
Vec4() = Vec4(0.0, 0.0, 0.0, 1.0)

Base.convert(::Type{Vec2{T}}, v::Vec2) where {T<:Real} =
    Vec2{T}(convert(T, v.x), convert(T, v.y))
Base.convert(::Type{Vec3{T}}, v::Vec3) where {T<:Real} =
    Vec3{T}(convert(T, v.x), convert(T, v.y), convert(T, v.z))
Base.convert(::Type{Vec4{T}}, v::Vec4) where {T<:Real} =
    Vec4{T}(convert(T, v.x), convert(T, v.y), convert(T, v.z), convert(T, v.w))

# Vec3 arithmetic
Base.:+(a::Vec3, b::Vec3) = Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
Base.:-(a::Vec3, b::Vec3) = Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
Base.:-(a::Vec3) = Vec3(-a.x, -a.y, -a.z)
Base.:*(a::Vec3, s::Real) = Vec3(a.x * s, a.y * s, a.z * s)
Base.:*(s::Real, a::Vec3) = a * s
Base.:/(a::Vec3, s::Real) = Vec3(a.x / s, a.y / s, a.z / s)

function dot(a::Vec3, b::Vec3)
    result = a.x * b.x + a.y * b.y + a.z * b.z
    if result isa AbstractFloat && !isfinite(result) &&
       isfinite(a.x) && isfinite(a.y) && isfinite(a.z) &&
       isfinite(b.x) && isfinite(b.y) && isfinite(b.z)
        return _stable_float_dot(a, b)
    end
    return result
end

function cross(a::Vec3, b::Vec3)
    result = Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    )
    if result.x isa AbstractFloat &&
       !(isfinite(result.x) && isfinite(result.y) && isfinite(result.z)) &&
       isfinite(a.x) && isfinite(a.y) && isfinite(a.z) &&
       isfinite(b.x) && isfinite(b.y) && isfinite(b.z)
        return _stable_float_cross(a, b)
    end
    return result
end
@inline _norm3(x, y, z) = hypot(x, y, z)
@inline _norm4(x, y, z, w) = hypot(x, y, z, w)

norm(a::Vec3) = _norm3(a.x, a.y, a.z)
function normalize(a::Vec3)
    l = norm(a)
    iszero(l) && return Vec3(zero(a.x), zero(a.y), zero(a.z))
    isfinite(l) && return a / l

    # A finite vector can have a mathematical length larger than typemax(T).
    # Scale first in that case so its unit direction remains representable.
    scale = max(max(abs(a.x), abs(a.y)), abs(a.z))
    isfinite(scale) || return a / l
    scaled = a / scale
    return scaled / _norm3(scaled.x, scaled.y, scaled.z)
end

@inline function _stable_lerp(a, b, t)
    iszero(t) && return a
    t == one(t) && return b
    result = if (a >= zero(a) && b >= zero(b)) ||
                (a <= zero(a) && b <= zero(b))
        a + (b - a) * t
    else
        a * (one(t) - t) + b * t
    end
    if result isa AbstractFloat && !isfinite(result) &&
       isfinite(a) && isfinite(b) && isfinite(t)
        return _stable_float_lerp_fallback(a, b, t)
    end
    return result
end

lerp(a::Vec3, b::Vec3, t::Real) = Vec3(
    _stable_lerp(a.x, b.x, t),
    _stable_lerp(a.y, b.y, t),
    _stable_lerp(a.z, b.z, t),
)
distance(a::Vec3, b::Vec3) = norm(a - b)

# Vec2 arithmetic
Base.:+(a::Vec2, b::Vec2) = Vec2(a.x + b.x, a.y + b.y)
Base.:-(a::Vec2, b::Vec2) = Vec2(a.x - b.x, a.y - b.y)
Base.:*(a::Vec2, s::Real) = Vec2(a.x * s, a.y * s)
Base.:*(s::Real, a::Vec2) = a * s
function dot(a::Vec2, b::Vec2)
    result = a.x * b.x + a.y * b.y
    if result isa AbstractFloat && !isfinite(result) &&
       isfinite(a.x) && isfinite(a.y) &&
       isfinite(b.x) && isfinite(b.y)
        return _stable_float_dot(a, b)
    end
    return result
end

# Vec4 arithmetic
Base.:+(a::Vec4, b::Vec4) = Vec4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w)
Base.:-(a::Vec4, b::Vec4) = Vec4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w)
Base.:*(a::Vec4, s::Real) = Vec4(a.x * s, a.y * s, a.z * s, a.w * s)

# ========================== Color ==========================

struct Color3{T<:Real}
    r::T
    g::T
    b::T
end
Color3(r::Real, g::Real, b::Real) = Color3(promote(r, g, b)...)
Color3() = Color3(1.0, 1.0, 1.0)
Color3(hex::UInt32) = Color3(
    ((hex >> 16) & 0xFF) / 255.0,
    ((hex >> 8)  & 0xFF) / 255.0,
    (hex         & 0xFF) / 255.0
)
Base.convert(::Type{Color3{T}}, c::Color3) where {T<:Real} =
    Color3{T}(convert(T, c.r), convert(T, c.g), convert(T, c.b))

Base.:+(a::Color3, b::Color3) = Color3(a.r + b.r, a.g + b.g, a.b + b.b)
Base.:*(a::Color3, s::Real) = Color3(a.r * s, a.g * s, a.b * s)
Base.:*(s::Real, a::Color3) = a * s
Base.:*(a::Color3, b::Color3) = Color3(a.r * b.r, a.g * b.g, a.b * b.b)
clamp_color(c::Color3) = Color3(clamp(c.r, 0, 1), clamp(c.g, 0, 1), clamp(c.b, 0, 1))

# ========================== Mat4 ==========================
# Column-major storage, matching three.js/OpenGL convention.
# elements[col*4 + row + 1] for 0-based, or indexed 1..16 directly.
# Layout: columns stored contiguously.
#   col 0: [n11, n21, n31, n41]  (indices 1-4)
#   col 1: [n12, n22, n32, n42]  (indices 5-8)
#   col 2: [n13, n23, n33, n43]  (indices 9-12)
#   col 3: [n14, n24, n34, n44]  (indices 13-16)

struct Mat4{T<:Real}
    e::NTuple{16, T}
end

function Mat4{T}() where T
    Mat4{T}((one(T), zero(T), zero(T), zero(T),
             zero(T), one(T), zero(T), zero(T),
             zero(T), zero(T), one(T), zero(T),
             zero(T), zero(T), zero(T), one(T)))
end
Mat4() = Mat4{Float64}()

# Access by (row, col) — 1-based
@inline mat4_get(m::Mat4, row::Int, col::Int) = m.e[(col-1)*4 + row]

@inline function _mat4_linear_column_norm(m::Mat4, col::Int)
    return hypot(
        mat4_get(m, 1, col),
        mat4_get(m, 2, col),
        mat4_get(m, 3, col),
    )
end

@inline function _mat4_linear_max_scale(m::Mat4)
    sx = _mat4_linear_column_norm(m, 1)
    sy = _mat4_linear_column_norm(m, 2)
    sz = _mat4_linear_column_norm(m, 3)
    return max(max(sx, sy), sz)
end

function mat4_multiply(a::Mat4, b::Mat4)
    T = promote_type(eltype(a.e), eltype(b.e))
    ae = a.e
    be = b.e
    # Build the product tuple directly so repeated Mat4 multiplies do not pay for
    # the closure allocation inherent in the previous `ntuple` implementation.
    result = Mat4{T}((
        ae[1]*be[1]  + ae[5]*be[2]  + ae[9]*be[3]   + ae[13]*be[4],
        ae[2]*be[1]  + ae[6]*be[2]  + ae[10]*be[3]  + ae[14]*be[4],
        ae[3]*be[1]  + ae[7]*be[2]  + ae[11]*be[3]  + ae[15]*be[4],
        ae[4]*be[1]  + ae[8]*be[2]  + ae[12]*be[3]  + ae[16]*be[4],

        ae[1]*be[5]  + ae[5]*be[6]  + ae[9]*be[7]   + ae[13]*be[8],
        ae[2]*be[5]  + ae[6]*be[6]  + ae[10]*be[7]  + ae[14]*be[8],
        ae[3]*be[5]  + ae[7]*be[6]  + ae[11]*be[7]  + ae[15]*be[8],
        ae[4]*be[5]  + ae[8]*be[6]  + ae[12]*be[7]  + ae[16]*be[8],

        ae[1]*be[9]  + ae[5]*be[10] + ae[9]*be[11]  + ae[13]*be[12],
        ae[2]*be[9]  + ae[6]*be[10] + ae[10]*be[11] + ae[14]*be[12],
        ae[3]*be[9]  + ae[7]*be[10] + ae[11]*be[11] + ae[15]*be[12],
        ae[4]*be[9]  + ae[8]*be[10] + ae[12]*be[11] + ae[16]*be[12],

        ae[1]*be[13] + ae[5]*be[14] + ae[9]*be[15]  + ae[13]*be[16],
        ae[2]*be[13] + ae[6]*be[14] + ae[10]*be[15] + ae[14]*be[16],
        ae[3]*be[13] + ae[7]*be[14] + ae[11]*be[15] + ae[15]*be[16],
        ae[4]*be[13] + ae[8]*be[14] + ae[12]*be[15] + ae[16]*be[16],
    ))
    if result.e[1] isa AbstractFloat &&
       !all(isfinite, result.e) &&
       all(isfinite, ae) && all(isfinite, be)
        return _stable_float_mat4_product(a, b)
    end
    return result
end
Base.:*(a::Mat4, b::Mat4) = mat4_multiply(a, b)

function mat4_transform_vec4(m::Mat4, v::Vec4)
    result = Vec4(
        mat4_get(m, 1, 1)*v.x + mat4_get(m, 1, 2)*v.y + mat4_get(m, 1, 3)*v.z + mat4_get(m, 1, 4)*v.w,
        mat4_get(m, 2, 1)*v.x + mat4_get(m, 2, 2)*v.y + mat4_get(m, 2, 3)*v.z + mat4_get(m, 2, 4)*v.w,
        mat4_get(m, 3, 1)*v.x + mat4_get(m, 3, 2)*v.y + mat4_get(m, 3, 3)*v.z + mat4_get(m, 3, 4)*v.w,
        mat4_get(m, 4, 1)*v.x + mat4_get(m, 4, 2)*v.y + mat4_get(m, 4, 3)*v.z + mat4_get(m, 4, 4)*v.w,
    )
    if result.x isa AbstractFloat &&
       !(isfinite(result.x) && isfinite(result.y) &&
         isfinite(result.z) && isfinite(result.w)) &&
       all(isfinite, m.e) &&
       isfinite(v.x) && isfinite(v.y) && isfinite(v.z) && isfinite(v.w)
        return _stable_float_mat4_transform(m, v)
    end
    return result
end

function mat4_transform_point(m::Mat4, p::Vec3)
    v = mat4_transform_vec4(m, Vec4(p.x, p.y, p.z, one(p.x)))
    result = Vec3(v.x / v.w, v.y / v.w, v.z / v.w)
    if result.x isa AbstractFloat &&
       !(isfinite(result.x) && isfinite(result.y) && isfinite(result.z)) &&
       all(isfinite, m.e) &&
       isfinite(p.x) && isfinite(p.y) && isfinite(p.z)
        stable, valid = _stable_float_mat4_transform_point(m, p)
        valid && return stable
    end
    return result
end

function mat4_transform_direction(m::Mat4, d::Vec3)
    result = Vec3(
        mat4_get(m, 1, 1)*d.x + mat4_get(m, 1, 2)*d.y + mat4_get(m, 1, 3)*d.z,
        mat4_get(m, 2, 1)*d.x + mat4_get(m, 2, 2)*d.y + mat4_get(m, 2, 3)*d.z,
        mat4_get(m, 3, 1)*d.x + mat4_get(m, 3, 2)*d.y + mat4_get(m, 3, 3)*d.z,
    )
    if result.x isa AbstractFloat &&
       !(isfinite(result.x) && isfinite(result.y) && isfinite(result.z)) &&
       all(isfinite, m.e) &&
       isfinite(d.x) && isfinite(d.y) && isfinite(d.z)
        transformed = _stable_float_mat4_transform(
            m, Vec4(d.x, d.y, d.z, zero(d.x)))
        return Vec3(transformed.x, transformed.y, transformed.z)
    end
    return result
end

function mat4_translation(tx, ty, tz)
    T = promote_type(typeof(tx), typeof(ty), typeof(tz), Float64)
    Mat4{T}((one(T), zero(T), zero(T), zero(T),
             zero(T), one(T), zero(T), zero(T),
             zero(T), zero(T), one(T), zero(T),
             T(tx), T(ty), T(tz), one(T)))
end

function mat4_scaling(sx, sy, sz)
    T = promote_type(typeof(sx), typeof(sy), typeof(sz), Float64)
    Mat4{T}((T(sx), zero(T), zero(T), zero(T),
             zero(T), T(sy), zero(T), zero(T),
             zero(T), zero(T), T(sz), zero(T),
             zero(T), zero(T), zero(T), one(T)))
end

function mat4_rotation_x(θ)
    c, s = cos(θ), sin(θ)
    T = typeof(c)
    Mat4{T}((one(T), zero(T), zero(T), zero(T),
             zero(T), c, s, zero(T),
             zero(T), -s, c, zero(T),
             zero(T), zero(T), zero(T), one(T)))
end

function mat4_rotation_y(θ)
    c, s = cos(θ), sin(θ)
    T = typeof(c)
    Mat4{T}((c, zero(T), -s, zero(T),
             zero(T), one(T), zero(T), zero(T),
             s, zero(T), c, zero(T),
             zero(T), zero(T), zero(T), one(T)))
end

function mat4_rotation_z(θ)
    c, s = cos(θ), sin(θ)
    T = typeof(c)
    Mat4{T}((c, s, zero(T), zero(T),
             -s, c, zero(T), zero(T),
             zero(T), zero(T), one(T), zero(T),
             zero(T), zero(T), zero(T), one(T)))
end

function mat4_look_at(eye::Vec3, target::Vec3, up::Vec3)
    d = eye - target
    # Guard the degenerate eye==target case before normalising (three.js lookAt):
    # normalize(0) is NaN and would poison the whole view matrix and its AD gradients.
    z = if isfinite(d.x) && isfinite(d.y) && isfinite(d.z)
        dot(d, d) < 1e-12 ?
            Vec3(zero(d.x), zero(d.y), one(d.z)) : normalize(d)
    else
        # Finite endpoints with opposite extreme signs can overflow during the
        # subtraction even though their direction is well-defined. Recover it
        # from independently scaled component differences.
        scaled, _, nonzero =
            _difference_direction_and_logscale(target, eye)
        nonzero ? normalize(scaled) :
            Vec3(zero(d.x), zero(d.y), one(d.z))
    end
    up_direction = normalize(up)
    xc = cross(up_direction, z)
    if dot(xc, xc) < 1e-12          # up parallel to view dir: perturb z (three.js lookAt)
        if abs(z.z) > one(z.z) - 1e-4
            z = normalize(Vec3(z.x + 1e-4, z.y, z.z))
        else
            z = normalize(Vec3(z.x, z.y, z.z + 1e-4))
        end
        xc = cross(up_direction, z)
    end
    x = normalize(xc)
    y = cross(z, x)
    T = typeof(x.x)
    Mat4{T}((x.x, y.x, z.x, zero(T),
             x.y, y.y, z.y, zero(T),
             x.z, y.z, z.z, zero(T),
             -dot(x, eye), -dot(y, eye), -dot(z, eye), one(T)))
end

@inline function _mat4_divide_product(value, a, b)
    # Divide by the larger factor first. Forming a*b can overflow/underflow,
    # and dividing by a tiny factor first can overflow an intermediate even
    # when value/(a*b) is representable.
    return abs(a) >= abs(b) ? (value / a) / b : (value / b) / a
end

function mat4_perspective(fov, aspect, near, far)
    isfinite(fov) && 0 < fov < Float64(pi) ||
        throw(ArgumentError("mat4_perspective fov must be finite and between 0 and pi radians"))
    isfinite(aspect) && aspect > 0 ||
        throw(ArgumentError("mat4_perspective aspect must be finite and positive"))
    isfinite(near) && near > 0 ||
        throw(ArgumentError("mat4_perspective near must be finite and positive"))
    !isnan(far) || throw(ArgumentError("mat4_perspective far must not be NaN"))
    (isinf(far) && far > 0) || (isfinite(far) && far > near) ||
        throw(ArgumentError("mat4_perspective far must be finite and greater than near, or +Inf"))
    t = tan(fov / 2)
    T = promote_type(typeof(t), typeof(aspect), typeof(near), typeof(far))
    # far == Inf is a supported config (infinite far clip plane, matching three.js
    # makePerspective); the limit of the depth terms is c=-1, d=-2·near. Without
    # this the Inf/Inf forms below are NaN, poisoning the whole projection.
    if isinf(far)
        c = -one(T)
        d = -2 * near
    else
        ratio = near / far
        denominator = one(ratio) - ratio
        c = -(one(ratio) + ratio) / denominator
        d = -2 * (near / denominator)
    end
    xscale = _mat4_divide_product(one(T), aspect, t)
    yscale = one(T) / t
    (isfinite(xscale) && isfinite(yscale) && isfinite(c) && isfinite(d)) ||
        throw(ArgumentError(
            "mat4_perspective parameters produce unrepresentable coefficients"))
    Mat4{T}((convert(T, xscale), zero(T), zero(T), zero(T),
             zero(T), convert(T, yscale), zero(T), zero(T),
             zero(T), zero(T), convert(T, c), -one(T),
             zero(T), zero(T), convert(T, d), zero(T)))
end

function _mat4_orthographic_axis(lo, hi, label::String)
    scale = max(abs(lo), abs(hi))
    iszero(scale) && throw(ArgumentError("$label bounds must differ"))
    lo_scaled = lo / scale
    hi_scaled = hi / scale
    span = hi_scaled - lo_scaled
    coefficient = _mat4_divide_product(one(span) + one(span), scale, span)
    offset = -(hi_scaled + lo_scaled) / span
    (isfinite(coefficient) && isfinite(offset)) ||
        throw(ArgumentError("$label bounds produce unrepresentable coefficients"))
    return coefficient, offset
end

function mat4_orthographic(left, right, bottom, top, near, far)
    isfinite(left) && isfinite(right) ||
        throw(ArgumentError("mat4_orthographic left and right must be finite"))
    isfinite(bottom) && isfinite(top) ||
        throw(ArgumentError("mat4_orthographic bottom and top must be finite"))
    left != right || throw(ArgumentError("mat4_orthographic left and right must differ"))
    bottom != top || throw(ArgumentError("mat4_orthographic bottom and top must differ"))
    isfinite(near) && isfinite(far) ||
        throw(ArgumentError("mat4_orthographic near and far must be finite"))
    far != near || throw(ArgumentError("mat4_orthographic near and far must differ"))
    sx, tx = _mat4_orthographic_axis(
        left, right, "mat4_orthographic left/right")
    sy, ty = _mat4_orthographic_axis(
        bottom, top, "mat4_orthographic bottom/top")
    sz, tz = _mat4_orthographic_axis(
        near, far, "mat4_orthographic near/far")
    T = promote_type(typeof(sx), typeof(tx), typeof(sy), typeof(ty),
                     typeof(sz), typeof(tz), Float64)
    Mat4{T}((convert(T, sx), zero(T), zero(T), zero(T),
             zero(T), convert(T, sy), zero(T), zero(T),
             zero(T), zero(T), convert(T, -sz), zero(T),
             convert(T, tx), convert(T, ty), convert(T, tz), one(T)))
end

@inline function _mat4_inverse_unscale(value, column_scale, row_scale)
    return _mat4_divide_product(value, column_scale, row_scale)
end

@inline _mat4_inverse_scale_value(value) = value
@inline _mat4_inverse_scale_value(value::ForwardDiff.Dual) =
    _mat4_inverse_scale_value(ForwardDiff.value(value))

@inline function _mat4_zero_like(value)
    z = zero(value)
    return Mat4((z, z, z, z,
                 z, z, z, z,
                 z, z, z, z,
                 z, z, z, z))
end

function mat4_inverse(m::Mat4)
    e = m.e
    a00, a10, a20, a30 = e[1], e[2], e[3], e[4]
    a01, a11, a21, a31 = e[5], e[6], e[7], e[8]
    a02, a12, a22, a32 = e[9], e[10], e[11], e[12]
    a03, a13, a23, a33 = e[13], e[14], e[15], e[16]

    # Balance finite matrices by rows and then columns before evaluating the
    # adjugate. The unscaled cofactor formula overflows for large, perfectly
    # invertible transforms (for example scaling(1e308, 1e308, 1e308)) and
    # underflows their small counterparts to a false zero determinant.
    balanced = all(isfinite, e)
    if balanced
        r0 = max(max(abs(_mat4_inverse_scale_value(a00)),
                     abs(_mat4_inverse_scale_value(a01))),
                 max(abs(_mat4_inverse_scale_value(a02)),
                     abs(_mat4_inverse_scale_value(a03))))
        r1 = max(max(abs(_mat4_inverse_scale_value(a10)),
                     abs(_mat4_inverse_scale_value(a11))),
                 max(abs(_mat4_inverse_scale_value(a12)),
                     abs(_mat4_inverse_scale_value(a13))))
        r2 = max(max(abs(_mat4_inverse_scale_value(a20)),
                     abs(_mat4_inverse_scale_value(a21))),
                 max(abs(_mat4_inverse_scale_value(a22)),
                     abs(_mat4_inverse_scale_value(a23))))
        r3 = max(max(abs(_mat4_inverse_scale_value(a30)),
                     abs(_mat4_inverse_scale_value(a31))),
                 max(abs(_mat4_inverse_scale_value(a32)),
                     abs(_mat4_inverse_scale_value(a33))))
        if iszero(r0) || iszero(r1) || iszero(r2) || iszero(r3)
            return _mat4_zero_like(a00)
        end

        a00 /= r0; a01 /= r0; a02 /= r0; a03 /= r0
        a10 /= r1; a11 /= r1; a12 /= r1; a13 /= r1
        a20 /= r2; a21 /= r2; a22 /= r2; a23 /= r2
        a30 /= r3; a31 /= r3; a32 /= r3; a33 /= r3

        c0 = max(max(abs(_mat4_inverse_scale_value(a00)),
                     abs(_mat4_inverse_scale_value(a10))),
                 max(abs(_mat4_inverse_scale_value(a20)),
                     abs(_mat4_inverse_scale_value(a30))))
        c1 = max(max(abs(_mat4_inverse_scale_value(a01)),
                     abs(_mat4_inverse_scale_value(a11))),
                 max(abs(_mat4_inverse_scale_value(a21)),
                     abs(_mat4_inverse_scale_value(a31))))
        c2 = max(max(abs(_mat4_inverse_scale_value(a02)),
                     abs(_mat4_inverse_scale_value(a12))),
                 max(abs(_mat4_inverse_scale_value(a22)),
                     abs(_mat4_inverse_scale_value(a32))))
        c3 = max(max(abs(_mat4_inverse_scale_value(a03)),
                     abs(_mat4_inverse_scale_value(a13))),
                 max(abs(_mat4_inverse_scale_value(a23)),
                     abs(_mat4_inverse_scale_value(a33))))
        if iszero(c0) || iszero(c1) || iszero(c2) || iszero(c3)
            return _mat4_zero_like(a00)
        end

        a00 /= c0; a10 /= c0; a20 /= c0; a30 /= c0
        a01 /= c1; a11 /= c1; a21 /= c1; a31 /= c1
        a02 /= c2; a12 /= c2; a22 /= c2; a32 /= c2
        a03 /= c3; a13 /= c3; a23 /= c3; a33 /= c3
    else
        # Preserve ordinary NaN/Inf propagation for non-finite inputs.
        one_e = one(a00)
        r0 = r1 = r2 = r3 = one_e
        c0 = c1 = c2 = c3 = one_e
    end

    b00 = a00*a11 - a01*a10
    b01 = a00*a12 - a02*a10
    b02 = a00*a13 - a03*a10
    b03 = a01*a12 - a02*a11
    b04 = a01*a13 - a03*a11
    b05 = a02*a13 - a03*a12
    b06 = a20*a31 - a21*a30
    b07 = a20*a32 - a22*a30
    b08 = a20*a33 - a23*a30
    b09 = a21*a32 - a22*a31
    b10 = a21*a33 - a23*a31
    b11 = a22*a33 - a23*a32

    det = b00*b11 - b01*b10 + b02*b09 + b03*b08 - b04*b07 + b05*b06
    if iszero(det)                  # singular matrix: return zero matrix (three.js Matrix4.invert)
        return _mat4_zero_like(a00)
    end
    inv_det = one(det) / det

    i00 = (a11*b11 - a12*b10 + a13*b09)*inv_det
    i10 = (-a10*b11 + a12*b08 - a13*b07)*inv_det
    i20 = (a10*b10 - a11*b08 + a13*b06)*inv_det
    i30 = (-a10*b09 + a11*b07 - a12*b06)*inv_det
    i01 = (-a01*b11 + a02*b10 - a03*b09)*inv_det
    i11 = (a00*b11 - a02*b08 + a03*b07)*inv_det
    i21 = (-a00*b10 + a01*b08 - a03*b06)*inv_det
    i31 = (a00*b09 - a01*b07 + a02*b06)*inv_det
    i02 = (a31*b05 - a32*b04 + a33*b03)*inv_det
    i12 = (-a30*b05 + a32*b02 - a33*b01)*inv_det
    i22 = (a30*b04 - a31*b02 + a33*b00)*inv_det
    i32 = (-a30*b03 + a31*b01 - a32*b00)*inv_det
    i03 = (-a21*b05 + a22*b04 - a23*b03)*inv_det
    i13 = (a20*b05 - a22*b02 + a23*b01)*inv_det
    i23 = (-a20*b04 + a21*b02 - a23*b00)*inv_det
    i33 = (a20*b03 - a21*b01 + a22*b00)*inv_det

    if balanced
        i00 = _mat4_inverse_unscale(i00, c0, r0)
        i10 = _mat4_inverse_unscale(i10, c1, r0)
        i20 = _mat4_inverse_unscale(i20, c2, r0)
        i30 = _mat4_inverse_unscale(i30, c3, r0)
        i01 = _mat4_inverse_unscale(i01, c0, r1)
        i11 = _mat4_inverse_unscale(i11, c1, r1)
        i21 = _mat4_inverse_unscale(i21, c2, r1)
        i31 = _mat4_inverse_unscale(i31, c3, r1)
        i02 = _mat4_inverse_unscale(i02, c0, r2)
        i12 = _mat4_inverse_unscale(i12, c1, r2)
        i22 = _mat4_inverse_unscale(i22, c2, r2)
        i32 = _mat4_inverse_unscale(i32, c3, r2)
        i03 = _mat4_inverse_unscale(i03, c0, r3)
        i13 = _mat4_inverse_unscale(i13, c1, r3)
        i23 = _mat4_inverse_unscale(i23, c2, r3)
        i33 = _mat4_inverse_unscale(i33, c3, r3)
    end

    return Mat4((i00, i10, i20, i30,
                 i01, i11, i21, i31,
                 i02, i12, i22, i32,
                 i03, i13, i23, i33))
end

function mat4_transpose(m::Mat4)
    e = m.e
    Mat4((e[1], e[5], e[9], e[13],
          e[2], e[6], e[10], e[14],
          e[3], e[7], e[11], e[15],
          e[4], e[8], e[12], e[16]))
end

# Normal matrix: transpose of the inverse, so transforming a normal as a
# direction by this matrix keeps it perpendicular under non-uniform scale.
function mat4_normal_matrix(m::Mat4)
    return mat4_transpose(mat4_inverse(m))
end

# ========================== Mat3 ==========================

struct Mat3{T<:Real}
    e::NTuple{9, T}
end
Mat3() = Mat3{Float64}((1.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,1.0))

# ========================== Quaternion ==========================

struct Quaternion{T<:Real}
    x::T
    y::T
    z::T
    w::T
end
Quaternion() = Quaternion(0.0, 0.0, 0.0, 1.0)
Quaternion(x::Real, y::Real, z::Real, w::Real) = Quaternion(promote(x, y, z, w)...)
Base.convert(::Type{Quaternion{T}}, q::Quaternion) where {T<:Real} =
    Quaternion{T}(convert(T, q.x), convert(T, q.y), convert(T, q.z), convert(T, q.w))

quat_multiply(a::Quaternion, b::Quaternion) = Quaternion(
    a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
    a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
    a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
    a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z
)

# Euler → quaternion for all six three.js intrinsic orders. Formulas match
# three.js `Quaternion.setFromEuler`; c1/s1 use the half-angle of x, c2/s2 of y,
# c3/s3 of z, regardless of order.
function quat_from_euler(x, y, z; order=:XYZ)
    c1, s1 = cos(x/2), sin(x/2)
    c2, s2 = cos(y/2), sin(y/2)
    c3, s3 = cos(z/2), sin(z/2)
    if order == :XYZ
        Quaternion(s1*c2*c3 + c1*s2*s3,
                   c1*s2*c3 - s1*c2*s3,
                   c1*c2*s3 + s1*s2*c3,
                   c1*c2*c3 - s1*s2*s3)
    elseif order == :YXZ
        Quaternion(s1*c2*c3 + c1*s2*s3,
                   c1*s2*c3 - s1*c2*s3,
                   c1*c2*s3 - s1*s2*c3,
                   c1*c2*c3 + s1*s2*s3)
    elseif order == :ZXY
        Quaternion(s1*c2*c3 - c1*s2*s3,
                   c1*s2*c3 + s1*c2*s3,
                   c1*c2*s3 + s1*s2*c3,
                   c1*c2*c3 - s1*s2*s3)
    elseif order == :ZYX
        Quaternion(s1*c2*c3 - c1*s2*s3,
                   c1*s2*c3 + s1*c2*s3,
                   c1*c2*s3 - s1*s2*c3,
                   c1*c2*c3 + s1*s2*s3)
    elseif order == :YZX
        Quaternion(s1*c2*c3 + c1*s2*s3,
                   c1*s2*c3 + s1*c2*s3,
                   c1*c2*s3 - s1*s2*c3,
                   c1*c2*c3 - s1*s2*s3)
    elseif order == :XZY
        Quaternion(s1*c2*c3 - c1*s2*s3,
                   c1*s2*c3 - s1*c2*s3,
                   c1*c2*s3 + s1*s2*c3,
                   c1*c2*c3 + s1*s2*s3)
    else
        throw(ArgumentError("unknown Euler order :$order"))
    end
end

function quat_to_mat4(q::Quaternion)
    x, y, z, w = q.x, q.y, q.z, q.w
    x2, y2, z2 = x+x, y+y, z+z
    xx, xy, xz = x*x2, x*y2, x*z2
    yy, yz, zz = y*y2, y*z2, z*z2
    wx, wy, wz = w*x2, w*y2, w*z2
    T = typeof(x)
    Mat4{T}((one(T)-yy-zz, xy+wz, xz-wy, zero(T),
             xy-wz, one(T)-xx-zz, yz+wx, zero(T),
             xz+wy, yz-wx, one(T)-xx-yy, zero(T),
             zero(T), zero(T), zero(T), one(T)))
end

function quat_normalize(q::Quaternion)
    l = _norm4(q.x, q.y, q.z, q.w)
    if l == zero(l)    # zero quaternion: return identity (three.js Quaternion.normalize)
        return Quaternion(zero(q.x), zero(q.y), zero(q.z), one(q.w))
    end
    isfinite(l) && return Quaternion(q.x/l, q.y/l, q.z/l, q.w/l)

    # Preserve the direction of finite components even when their true
    # four-dimensional length exceeds the floating-point range.
    scale = max(max(abs(q.x), abs(q.y)), max(abs(q.z), abs(q.w)))
    if isfinite(scale) && scale > zero(scale)
        x, y, z, w = q.x/scale, q.y/scale, q.z/scale, q.w/scale
        sl = _norm4(x, y, z, w)
        return Quaternion(x/sl, y/sl, z/sl, w/sl)
    end
    return Quaternion(q.x/l, q.y/l, q.z/l, q.w/l)
end

# ========================== Euler ==========================

struct Euler{T<:Real}
    x::T
    y::T
    z::T
    order::Symbol
end
Euler() = Euler(0.0, 0.0, 0.0, :XYZ)
Euler(x, y, z) = Euler(promote(x, y, z)..., :XYZ)
Base.convert(::Type{Euler{T}}, e::Euler) where {T<:Real} =
    Euler{T}(convert(T, e.x), convert(T, e.y), convert(T, e.z), e.order)

# ========================== Bounding volumes ==========================

struct Box3{T<:Real}
    min::Vec3{T}
    max::Vec3{T}
end
Box3() = Box3(Vec3(Inf, Inf, Inf), Vec3(-Inf, -Inf, -Inf))

function box3_expand_by_point(box::Box3, p::Vec3)
    Box3(
        Vec3(min(box.min.x, p.x), min(box.min.y, p.y), min(box.min.z, p.z)),
        Vec3(max(box.max.x, p.x), max(box.max.y, p.y), max(box.max.z, p.z))
    )
end

struct BoundingSphere{T<:Real}
    center::Vec3{T}
    radius::T
end

struct Ray{T<:Real}
    origin::Vec3{T}
    direction::Vec3{T}
end
Ray(origin::Vec3, direction::Vec3) =
    Ray(Vec3(promote(origin.x, direction.x)[1],
             promote(origin.y, direction.y)[1],
             promote(origin.z, direction.z)[1]),
        Vec3(promote(origin.x, direction.x)[2],
             promote(origin.y, direction.y)[2],
             promote(origin.z, direction.z)[2]))

struct Plane{T<:Real}
    normal::Vec3{T}
    constant::T
end

# Signed distance from a plane (a·x + d = 0) to a point; >0 on the normal side.
function plane_distance_to_point(p::Plane, pt::Vec3)
    result = dot(p.normal, pt) + p.constant
    if result isa AbstractFloat && !isfinite(result) &&
       isfinite(p.normal.x) && isfinite(p.normal.y) &&
       isfinite(p.normal.z) && isfinite(p.constant) &&
       isfinite(pt.x) && isfinite(pt.y) && isfinite(pt.z)
        return _stable_float_plane_distance(p, pt)
    end
    return result
end

# ========================== Quaternion slerp / setFromUnitVectors ==========================

quat_dot(a::Quaternion, b::Quaternion) = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w

"""
    quat_slerp(a, b, t)

Spherical linear interpolation between unit quaternions along the shorter arc
(matches three.js `Quaternion.slerp`). `t=0` gives `a`, `t=1` gives `b`.
"""
function quat_slerp(a::Quaternion, b::Quaternion, t)
    d = quat_dot(a, b)
    if d < 0                       # take the shorter arc
        b = Quaternion(-b.x, -b.y, -b.z, -b.w); d = -d
    end
    if d > 0.9995                  # nearly parallel: nlerp to avoid division by ~0
        q = Quaternion(a.x + t*(b.x-a.x), a.y + t*(b.y-a.y),
                       a.z + t*(b.z-a.z), a.w + t*(b.w-a.w))
        return quat_normalize(q)
    end
    θ0 = acos(clamp(d, -one(d), one(d)))
    sinθ0 = sin(θ0)
    θ = θ0 * t
    s0 = sin(θ0 - θ) / sinθ0
    s1 = sin(θ) / sinθ0
    Quaternion(s0*a.x + s1*b.x, s0*a.y + s1*b.y, s0*a.z + s1*b.z, s0*a.w + s1*b.w)
end

"""
    quat_from_unit_vectors(from, to)

Quaternion rotating unit vector `from` onto unit vector `to`
(three.js `Quaternion.setFromUnitVectors`). Handles the antiparallel case.
"""
function quat_from_unit_vectors(from::Vec3, to::Vec3)
    f = normalize(from); t = normalize(to)
    r = dot(f, t) + 1
    if r < 1e-8                    # opposite vectors: rotate π about an axis ⟂ f
        if abs(f.x) > abs(f.z)
            q = Quaternion(-f.y, f.x, zero(f.x), zero(f.x))
        else
            q = Quaternion(zero(f.x), -f.z, f.y, zero(f.x))
        end
    else
        c = cross(f, t)
        q = Quaternion(c.x, c.y, c.z, r)
    end
    quat_normalize(q)
end

# ========================== Triangle ==========================

struct Triangle{T<:Real}
    a::Vec3{T}
    b::Vec3{T}
    c::Vec3{T}
end

@inline _vec3_max_abs(v::Vec3) =
    max(max(abs(v.x), abs(v.y)), abs(v.z))

@inline function _triangle_axis_edges(a, b, c)
    scale = max(max(abs(a), abs(b)), abs(c))
    if iszero(scale)
        z = zero(a)
        return z, z, scale
    end
    a_scaled = a / scale
    return b / scale - a_scaled, c / scale - a_scaled, scale
end

@inline function _triangle_scaled_cross(tri::Triangle)
    abx, acx, sx = _triangle_axis_edges(tri.a.x, tri.b.x, tri.c.x)
    aby, acy, sy = _triangle_axis_edges(tri.a.y, tri.b.y, tri.c.y)
    abz, acz, sz = _triangle_axis_edges(tri.a.z, tri.b.z, tri.c.z)
    # Each minor is computed after scaling its two coordinate axes
    # independently. This preserves thin triangles whose axes differ by
    # hundreds of orders of magnitude.
    nx = aby * acz - abz * acy
    ny = abz * acx - abx * acz
    nz = abx * acy - aby * acx
    return nx, ny, nz, sx, sy, sz
end

@inline _triangle_cross_logmag(minor, scale1, scale2) =
    log(abs(minor)) + log(scale1) + log(scale2)

function _triangle_cross_direction_and_logscale(tri::Triangle)
    nx, ny, nz, sx, sy, sz = _triangle_scaled_cross(tri)
    has_x = !iszero(nx) && !iszero(sy) && !iszero(sz)
    has_y = !iszero(ny) && !iszero(sx) && !iszero(sz)
    has_z = !iszero(nz) && !iszero(sx) && !iszero(sy)
    if !(has_x || has_y || has_z)
        z = zero(nx + ny + nz)
        return Vec3(z, z, z), z, false
    end

    if has_x
        logscale = _triangle_cross_logmag(nx, sy, sz)
    elseif has_y
        logscale = _triangle_cross_logmag(ny, sx, sz)
    else
        logscale = _triangle_cross_logmag(nz, sx, sy)
    end
    if has_y
        ly = _triangle_cross_logmag(ny, sx, sz)
        ly > logscale && (logscale = ly)
    end
    if has_z
        lz = _triangle_cross_logmag(nz, sx, sy)
        lz > logscale && (logscale = lz)
    end

    cx = has_x ? (nx / abs(nx)) *
         exp(_triangle_cross_logmag(nx, sy, sz) - logscale) : zero(nx)
    cy = has_y ? (ny / abs(ny)) *
         exp(_triangle_cross_logmag(ny, sx, sz) - logscale) : zero(ny)
    cz = has_z ? (nz / abs(nz)) *
         exp(_triangle_cross_logmag(nz, sx, sy) - logscale) : zero(nz)
    return Vec3(cx, cy, cz), logscale, true
end

function triangle_normal(tri::Triangle)
    direction, _, nondegenerate =
        _triangle_cross_direction_and_logscale(tri)
    nondegenerate || return direction
    return normalize(direction)
end

@inline function _float_product_representation(a::T, b::T) where {T<:AbstractFloat}
    (iszero(a) || iszero(b)) && return zero(T), 0, false
    ma, ea = frexp(a)
    mb, eb = frexp(b)
    m, correction = frexp(ma * mb)
    return m, ea + eb + correction, true
end

struct _FloatRepresentation{T<:AbstractFloat}
    mantissa::T
    exponent::Int
    nonzero::Bool
end

@inline _float_zero_representation(::Type{T}) where {T<:AbstractFloat} =
    _FloatRepresentation(zero(T), 0, false)

@inline function _float_value_representation(value::T) where {T<:AbstractFloat}
    iszero(value) && return _float_zero_representation(T)
    mantissa, exponent = frexp(value)
    return _FloatRepresentation(mantissa, exponent, true)
end

@inline function _float_difference_representation(
        value1::T, value2::T) where {T<:AbstractFloat}
    difference, scale, nonzero = _axis_difference(value1, value2)
    nonzero || return _float_zero_representation(T)
    mantissa, exponent, nonzero =
        _float_product_representation(difference, scale)
    return _FloatRepresentation(mantissa, exponent, nonzero)
end

@inline function _float_representation_add(
        a::_FloatRepresentation{T},
        b::_FloatRepresentation{T}) where {T<:AbstractFloat}
    a.nonzero || return b
    b.nonzero || return a
    exponent = max(a.exponent, b.exponent)
    value = ldexp(a.mantissa, a.exponent - exponent) +
            ldexp(b.mantissa, b.exponent - exponent)
    iszero(value) && return _float_zero_representation(T)
    mantissa, correction = frexp(value)
    return _FloatRepresentation(mantissa, exponent + correction, true)
end

@inline _float_representation_negate(a::_FloatRepresentation{T}) where
        {T<:AbstractFloat} =
    _FloatRepresentation(-a.mantissa, a.exponent, a.nonzero)

@inline function _float_representation_multiply(
        a::_FloatRepresentation{T},
        b::_FloatRepresentation{T}) where {T<:AbstractFloat}
    (a.nonzero && b.nonzero) || return _float_zero_representation(T)
    mantissa, correction = frexp(a.mantissa * b.mantissa)
    return _FloatRepresentation(
        mantissa, a.exponent + b.exponent + correction, true)
end

@inline function _float_representation_value(
        value::_FloatRepresentation{T}) where {T<:AbstractFloat}
    value.nonzero || return zero(T)
    return ldexp(value.mantissa, value.exponent)
end

@inline function _stable_float_lerp_fallback(
        a::AbstractFloat, b::AbstractFloat, t::Real)
    a, b, t = promote(a, b, t)
    return muladd(t, b - a, a)
end

@inline function _float_representation_cross(a, b)
    return (
        _float_representation_add(
            _float_representation_multiply(a[2], b[3]),
            _float_representation_negate(
                _float_representation_multiply(a[3], b[2]))),
        _float_representation_add(
            _float_representation_multiply(a[3], b[1]),
            _float_representation_negate(
                _float_representation_multiply(a[1], b[3]))),
        _float_representation_add(
            _float_representation_multiply(a[1], b[2]),
            _float_representation_negate(
                _float_representation_multiply(a[2], b[1]))),
    )
end

@inline function _float_representation_dot(a, b)
    xy = _float_representation_add(
        _float_representation_multiply(a[1], b[1]),
        _float_representation_multiply(a[2], b[2]),
    )
    return _float_representation_add(
        xy, _float_representation_multiply(a[3], b[3]))
end

@inline function _float_representation_dot4(a, b)
    xy = _float_representation_add(
        _float_representation_multiply(a[1], b[1]),
        _float_representation_multiply(a[2], b[2]),
    )
    zw = _float_representation_add(
        _float_representation_multiply(a[3], b[3]),
        _float_representation_multiply(a[4], b[4]),
    )
    return _float_representation_add(xy, zw)
end

@inline function _stable_float_components(a::Vec3, b::Vec3)
    ax, ay, az, bx, by, bz = promote(
        a.x, a.y, a.z, b.x, b.y, b.z)
    return (
        (
            _float_value_representation(ax),
            _float_value_representation(ay),
            _float_value_representation(az),
        ),
        (
            _float_value_representation(bx),
            _float_value_representation(by),
            _float_value_representation(bz),
        ),
    )
end

@inline function _stable_float_dot(a::Vec3, b::Vec3)
    a_representation, b_representation =
        _stable_float_components(a, b)
    return _float_representation_value(
        _float_representation_dot(
            a_representation, b_representation))
end

@inline function _stable_float_dot(a::Vec2, b::Vec2)
    ax, ay, bx, by = promote(a.x, a.y, b.x, b.y)
    return _float_representation_value(
        _float_representation_add(
            _float_representation_multiply(
                _float_value_representation(ax),
                _float_value_representation(bx)),
            _float_representation_multiply(
                _float_value_representation(ay),
                _float_value_representation(by)),
        ),
    )
end

@inline function _stable_float_cross(a::Vec3, b::Vec3)
    a_representation, b_representation =
        _stable_float_components(a, b)
    result = _float_representation_cross(
        a_representation, b_representation)
    return Vec3(
        _float_representation_value(result[1]),
        _float_representation_value(result[2]),
        _float_representation_value(result[3]),
    )
end

@inline function _stable_float_mat4_row_representation(
        m::Mat4, row::Int, v::Vec4)
    m1, m2, m3, m4, x, y, z, w = promote(
        mat4_get(m, row, 1), mat4_get(m, row, 2),
        mat4_get(m, row, 3), mat4_get(m, row, 4),
        v.x, v.y, v.z, v.w,
    )
    matrix_row = (
        _float_value_representation(m1),
        _float_value_representation(m2),
        _float_value_representation(m3),
        _float_value_representation(m4),
    )
    vector = (
        _float_value_representation(x),
        _float_value_representation(y),
        _float_value_representation(z),
        _float_value_representation(w),
    )
    return _float_representation_dot4(matrix_row, vector)
end

@inline function _stable_float_mat4_row(m::Mat4, row::Int, v::Vec4)
    return _float_representation_value(
        _stable_float_mat4_row_representation(m, row, v))
end

@inline function _stable_float_mat4_transform(m::Mat4, v::Vec4)
    return Vec4(
        _stable_float_mat4_row(m, 1, v),
        _stable_float_mat4_row(m, 2, v),
        _stable_float_mat4_row(m, 3, v),
        _stable_float_mat4_row(m, 4, v),
    )
end

@inline function _stable_float_mat4_transform_point(m::Mat4, p::Vec3)
    homogeneous = Vec4(p.x, p.y, p.z, one(p.x))
    x = _stable_float_mat4_row_representation(m, 1, homogeneous)
    y = _stable_float_mat4_row_representation(m, 2, homogeneous)
    z = _stable_float_mat4_row_representation(m, 3, homogeneous)
    w = _stable_float_mat4_row_representation(m, 4, homogeneous)
    result = Vec3(
        _float_representation_ratio(x, w),
        _float_representation_ratio(y, w),
        _float_representation_ratio(z, w),
    )
    return result, w.nonzero
end

@inline function _stable_float_mat4_product(a::Mat4, b::Mat4)
    be = b.e
    column1 = Vec4(be[1], be[2], be[3], be[4])
    column2 = Vec4(be[5], be[6], be[7], be[8])
    column3 = Vec4(be[9], be[10], be[11], be[12])
    column4 = Vec4(be[13], be[14], be[15], be[16])
    return Mat4((
        _stable_float_mat4_row(a, 1, column1),
        _stable_float_mat4_row(a, 2, column1),
        _stable_float_mat4_row(a, 3, column1),
        _stable_float_mat4_row(a, 4, column1),
        _stable_float_mat4_row(a, 1, column2),
        _stable_float_mat4_row(a, 2, column2),
        _stable_float_mat4_row(a, 3, column2),
        _stable_float_mat4_row(a, 4, column2),
        _stable_float_mat4_row(a, 1, column3),
        _stable_float_mat4_row(a, 2, column3),
        _stable_float_mat4_row(a, 3, column3),
        _stable_float_mat4_row(a, 4, column3),
        _stable_float_mat4_row(a, 1, column4),
        _stable_float_mat4_row(a, 2, column4),
        _stable_float_mat4_row(a, 3, column4),
        _stable_float_mat4_row(a, 4, column4),
    ))
end

@inline function _stable_float_plane_distance(p::Plane, pt::Vec3)
    nx, ny, nz, constant, x, y, z = promote(
        p.normal.x, p.normal.y, p.normal.z, p.constant,
        pt.x, pt.y, pt.z,
    )
    normal = (
        _float_value_representation(nx),
        _float_value_representation(ny),
        _float_value_representation(nz),
    )
    point = (
        _float_value_representation(x),
        _float_value_representation(y),
        _float_value_representation(z),
    )
    result = _float_representation_add(
        _float_representation_dot(normal, point),
        _float_value_representation(constant),
    )
    return _float_representation_value(result)
end

@inline _float_vector_difference(a::Vec3{T}, b::Vec3{T}) where
        {T<:AbstractFloat} = (
    _float_difference_representation(a.x, b.x),
    _float_difference_representation(a.y, b.y),
    _float_difference_representation(a.z, b.z),
)

@inline function _float_representation_ratio(
        numerator::_FloatRepresentation{T},
        denominator::_FloatRepresentation{T}) where {T<:AbstractFloat}
    numerator.nonzero || return zero(T)
    denominator.nonzero || return T(NaN)
    return ldexp(
        numerator.mantissa / denominator.mantissa,
        numerator.exponent - denominator.exponent,
    )
end

function triangle_normal(tri::Triangle{T}) where {T<:AbstractFloat}
    normal = _float_representation_cross(
        _float_vector_difference(tri.a, tri.b),
        _float_vector_difference(tri.a, tri.c),
    )
    has_x = normal[1].nonzero
    has_y = normal[2].nonzero
    has_z = normal[3].nonzero
    if !(has_x || has_y || has_z)
        return Vec3(zero(T), zero(T), zero(T))
    end
    exponent = has_x ? normal[1].exponent :
               (has_y ? normal[2].exponent : normal[3].exponent)
    has_y && normal[2].exponent > exponent &&
        (exponent = normal[2].exponent)
    has_z && normal[3].exponent > exponent &&
        (exponent = normal[3].exponent)
    direction = Vec3(
        has_x ? ldexp(
            normal[1].mantissa, normal[1].exponent - exponent) : zero(T),
        has_y ? ldexp(
            normal[2].mantissa, normal[2].exponent - exponent) : zero(T),
        has_z ? ldexp(
            normal[3].mantissa, normal[3].exponent - exponent) : zero(T),
    )
    return normalize(direction)
end

function triangle_area(tri::Triangle)
    direction, logscale, nondegenerate =
        _triangle_cross_direction_and_logscale(tri)
    nondegenerate || return zero(logscale)
    # `direction` is the true cross product divided by `exp(logscale)`.
    # Keeping the scale logarithmic prevents premature overflow/underflow when
    # different coordinate axes have radically different magnitudes.
    return exp(logscale + log(norm(direction)) - log(2))
end

function triangle_area(tri::Triangle{T}) where {T<:AbstractFloat}
    normal = _float_representation_cross(
        _float_vector_difference(tri.a, tri.b),
        _float_vector_difference(tri.a, tri.c),
    )
    squared_norm = _float_representation_dot(normal, normal)
    squared_norm.nonzero || return zero(T)
    mantissa = squared_norm.mantissa
    exponent = squared_norm.exponent
    if isodd(exponent)
        mantissa *= 2
        exponent -= 1
    end
    # sqrt(m * 2^e) / 2 = sqrt(m) * 2^(e/2 - 1), with the
    # exponent kept integral so no intermediate cross component must fit in T.
    return ldexp(sqrt(mantissa), div(exponent, 2) - 1)
end

@inline function _mean3_scaled(a, b, c)
    scale = max(max(abs(a), abs(b)), abs(c))
    iszero(scale) && return zero(a)
    return ((a / scale + b / scale + c / scale) / 3) * scale
end

triangle_centroid(tri::Triangle) = Vec3(
    _mean3_scaled(tri.a.x, tri.b.x, tri.c.x),
    _mean3_scaled(tri.a.y, tri.b.y, tri.c.y),
    _mean3_scaled(tri.a.z, tri.b.z, tri.c.z),
)

"""Barycentric coordinates `(u,v,w)` of `p` relative to the triangle plane."""
function triangle_barycentric(tri::Triangle, p::Vec3)
    scale = max(
        max(_vec3_max_abs(tri.a), _vec3_max_abs(tri.b)),
        _vec3_max_abs(tri.c),
    )
    if iszero(scale)
        z = zero(tri.a.x + p.x)
        return Vec3(z, z, z)
    end
    a = tri.a / scale
    v0 = tri.b / scale - a
    v1 = tri.c / scale - a
    v2 = p / scale - a
    d00 = dot(v0, v0)
    d01 = dot(v0, v1)
    d11 = dot(v1, v1)
    d20 = dot(v2, v0)
    d21 = dot(v2, v1)
    denominator = d00 * d11 - d01 * d01
    if iszero(denominator)
        z = zero(denominator)
        return Vec3(z, z, z)
    end
    v = (d11 * d20 - d01 * d21) / denominator
    w = (d00 * d21 - d01 * d20) / denominator
    Vec3(one(v) - v - w, v, w)
end

function triangle_barycentric(
        tri::Triangle{T}, p::Vec3{T}) where {T<:AbstractFloat}
    edge_b = _float_vector_difference(tri.a, tri.b)
    edge_c = _float_vector_difference(tri.a, tri.c)
    offset = _float_vector_difference(tri.a, p)
    normal = _float_representation_cross(edge_b, edge_c)
    denominator = _float_representation_dot(normal, normal)
    if !denominator.nonzero
        return Vec3(zero(T), zero(T), zero(T))
    end
    numerator_v = _float_representation_dot(
        _float_representation_cross(offset, edge_c), normal)
    numerator_w = _float_representation_dot(
        _float_representation_cross(edge_b, offset), normal)
    v = _float_representation_ratio(numerator_v, denominator)
    w = _float_representation_ratio(numerator_w, denominator)
    return Vec3(one(T) - v - w, v, w)
end

function triangle_contains_point(tri::Triangle, p::Vec3; atol=1e-9)
    bc = triangle_barycentric(tri, p)
    bc.x >= -atol && bc.y >= -atol && bc.z >= -atol
end

# ========================== Line3 ==========================
# `finish` denotes the segment end (`end` is a reserved word in Julia).

struct Line3{T<:Real}
    start::Vec3{T}
    finish::Vec3{T}
end

line3_delta(l::Line3)  = l.finish - l.start
line3_length(l::Line3) = norm(line3_delta(l))

@inline function _stable_midpoint(a, b)
    if (a >= zero(a) && b >= zero(b)) ||
       (a <= zero(a) && b <= zero(b))
        return a + (b - a) / 2
    end
    return a / 2 + b / 2
end

line3_center(l::Line3) = Vec3(
    _stable_midpoint(l.start.x, l.finish.x),
    _stable_midpoint(l.start.y, l.finish.y),
    _stable_midpoint(l.start.z, l.finish.z),
)

line3_at(l::Line3, t) = Vec3(
    _stable_lerp(l.start.x, l.finish.x, t),
    _stable_lerp(l.start.y, l.finish.y, t),
    _stable_lerp(l.start.z, l.finish.z, t),
)

@inline function _axis_difference(value1, value2)
    scale = max(abs(value1), abs(value2))
    iszero(scale) && return zero(value1), scale, false
    difference = value2 / scale - value1 / scale
    iszero(difference) && return difference, scale, false
    return difference, scale, true
end

function _difference_direction_and_logscale(a::Vec3, b::Vec3)
    dx, sx, has_x = _axis_difference(a.x, b.x)
    dy, sy, has_y = _axis_difference(a.y, b.y)
    dz, sz, has_z = _axis_difference(a.z, b.z)
    if !(has_x || has_y || has_z)
        z = zero(dx + dy + dz)
        return Vec3(z, z, z), z, false
    end

    if has_x
        logscale = log(abs(dx)) + log(sx)
    elseif has_y
        logscale = log(abs(dy)) + log(sy)
    else
        logscale = log(abs(dz)) + log(sz)
    end
    if has_y
        ly = log(abs(dy)) + log(sy)
        ly > logscale && (logscale = ly)
    end
    if has_z
        lz = log(abs(dz)) + log(sz)
        lz > logscale && (logscale = lz)
    end

    x = has_x ? (dx / abs(dx)) *
        exp(log(abs(dx)) + log(sx) - logscale) : zero(dx)
    y = has_y ? (dy / abs(dy)) *
        exp(log(abs(dy)) + log(sy) - logscale) : zero(dy)
    z = has_z ? (dz / abs(dz)) *
        exp(log(abs(dz)) + log(sz) - logscale) : zero(dz)
    return Vec3(x, y, z), logscale, true
end

"""Parameter `t` of the point on the line/segment closest to `p`."""
function line3_closest_point_parameter(l::Line3, p::Vec3; clamp_to_segment=true)
    direction, direction_logscale, nondegenerate =
        _difference_direction_and_logscale(l.start, l.finish)
    nondegenerate || return zero(direction_logscale)
    offset, offset_logscale, nonzero_offset =
        _difference_direction_and_logscale(l.start, p)
    nonzero_offset || return zero(offset_logscale)

    denominator = dot(direction, direction)
    ratio = dot(offset, direction) / denominator
    iszero(ratio) && return zero(ratio)
    if clamp_to_segment && ratio < zero(ratio)
        return zero(ratio)
    end
    log_parameter =
        offset_logscale - direction_logscale + log(abs(ratio))
    if clamp_to_segment && log_parameter >= zero(log_parameter)
        return one(ratio)
    end
    parameter = (ratio / abs(ratio)) * exp(log_parameter)
    return clamp_to_segment ?
           clamp(parameter, zero(parameter), one(parameter)) : parameter
end

function line3_closest_point_parameter(
        l::Line3{T}, p::Vec3{T}; clamp_to_segment=true) where {T<:AbstractFloat}
    direction = _float_vector_difference(l.start, l.finish)
    denominator = _float_representation_dot(direction, direction)
    denominator.nonzero || return zero(T)
    offset = _float_vector_difference(l.start, p)
    numerator = _float_representation_dot(offset, direction)
    parameter = _float_representation_ratio(numerator, denominator)
    return clamp_to_segment ? clamp(parameter, zero(T), one(T)) : parameter
end
line3_closest_point(l::Line3, p::Vec3; clamp_to_segment=true) =
    line3_at(l, line3_closest_point_parameter(l, p; clamp_to_segment=clamp_to_segment))

# ========================== Spherical / Cylindrical ==========================
# three.js convention: phi = polar angle measured from +Y, theta = azimuth in xz.

struct Spherical{T<:Real}
    radius::T
    phi::T
    theta::T
end

function spherical_to_cartesian(s::Spherical)
    sinphi_r = sin(s.phi) * s.radius
    Vec3(sinphi_r * sin(s.theta), cos(s.phi) * s.radius, sinphi_r * cos(s.theta))
end

function cartesian_to_spherical(v::Vec3)
    r = norm(v)
    r == 0 && return Spherical(zero(r), zero(r), zero(r))
    phi = if isfinite(r)
        acos(clamp(v.y / r, -one(r), one(r)))
    else
        # The radius itself may be unrepresentable even though every component
        # is finite. Scale only for the angular calculation in that case.
        scale = max(max(abs(v.x), abs(v.y)), abs(v.z))
        if isfinite(scale) && scale > zero(scale)
            sx, sy, sz = v.x/scale, v.y/scale, v.z/scale
            atan(hypot(sx, sz), sy)
        else
            acos(clamp(v.y / r, -one(r), one(r)))
        end
    end
    Spherical(r, phi, atan(v.x, v.z))
end

struct Cylindrical{T<:Real}
    radius::T
    theta::T
    y::T
end

cylindrical_to_cartesian(c::Cylindrical) =
    Vec3(c.radius * sin(c.theta), c.y, c.radius * cos(c.theta))
cartesian_to_cylindrical(v::Vec3) =
    Cylindrical(hypot(v.x, v.z), atan(v.x, v.z), v.y)

# ========================== Interpolant ==========================

function _validate_interpolant_inputs(kind::AbstractString, times::AbstractVector,
                                      values::AbstractVector)
    length(times) == length(values) ||
        throw(ArgumentError("$kind times and values must have the same length"))
    isempty(times) && throw(ArgumentError("$kind requires at least one keyframe"))
    for i in 2:length(times)
        times[i] > times[i - 1] ||
            throw(ArgumentError("$kind times must be strictly increasing"))
    end
    return length(times)
end

"""
    interpolate_linear(times, values, t)

Piecewise-linear interpolation of `values` sampled at sorted `times`, evaluated
at `t`, clamped to the endpoints. `values` may be reals or `Vec3`.
"""
function interpolate_linear(times::AbstractVector, values::AbstractVector, t)
    n = _validate_interpolant_inputs("interpolate_linear", times, values)
    isnan(t) && throw(ArgumentError("interpolate_linear: query time t must not be NaN"))
    t <= times[1] && return values[1]
    t >= times[n] && return values[n]
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    α = (t - times[lo]) / (times[hi] - times[lo])
    return _lerp_value(values[lo], values[hi], α)
end
_lerp_value(a::Real, b::Real, α) = _stable_lerp(a, b, α)
_lerp_value(a::Vec3, b::Vec3, α) = lerp(a, b, α)

# ========================== Frustum (+ culling) ==========================

struct Frustum{T<:Real}
    planes::NTuple{6, Plane{T}}
end

@inline function _make_plane(a, b, c, d)
    n = _norm3(a, b, c)
    if isfinite(n)
        inv = n > zero(n) ? one(n)/n : one(n)
        return Plane(Vec3(a*inv, b*inv, c*inv), d*inv)
    end

    # Keep finite plane coefficients normalizable when their mathematical norm
    # exceeds the scalar range. Dividing d by the same scale preserves a·x+d=0.
    scale = max(max(abs(a), abs(b)), abs(c))
    if isfinite(scale) && scale > zero(scale)
        sa, sb, sc = a/scale, b/scale, c/scale
        inv = one(n) / _norm3(sa, sb, sc)
        return Plane(Vec3(sa*inv, sb*inv, sc*inv), (d/scale)*inv)
    end

    # Preserve the previous propagation behavior for non-finite coefficients.
    inv = n > zero(n) ? one(n)/n : one(n)
    return Plane(Vec3(a*inv, b*inv, c*inv), d*inv)
end

"""
    frustum_from_matrix(m)

Extract the six clip planes (right, left, bottom, top, far, near) from a
view-projection matrix via the Gribb–Hartmann method (three.js
`Frustum.setFromProjectionMatrix`). Plane normals point inward.
"""
function frustum_from_matrix(m::Mat4)
    e = m.e
    scale = maximum(abs, e)
    divisor = isfinite(scale) && scale > zero(scale) ? scale : one(scale)
    # A homogeneous view-projection matrix may be multiplied by any non-zero
    # scalar without changing its frustum. Normalize before adding/subtracting
    # rows so two finite coefficients cannot overflow before plane normalization.
    me0, me1, me2, me3 = (
        e[1] / divisor, e[2] / divisor,
        e[3] / divisor, e[4] / divisor)
    me4, me5, me6, me7 = (
        e[5] / divisor, e[6] / divisor,
        e[7] / divisor, e[8] / divisor)
    me8, me9, me10, me11 = (
        e[9] / divisor, e[10] / divisor,
        e[11] / divisor, e[12] / divisor)
    me12, me13, me14, me15 = (
        e[13] / divisor, e[14] / divisor,
        e[15] / divisor, e[16] / divisor)
    planes = (
        _make_plane(me3-me0, me7-me4, me11-me8,  me15-me12),
        _make_plane(me3+me0, me7+me4, me11+me8,  me15+me12),
        _make_plane(me3+me1, me7+me5, me11+me9,  me15+me13),
        _make_plane(me3-me1, me7-me5, me11-me9,  me15-me13),
        _make_plane(me3-me2, me7-me6, me11-me10, me15-me14),
        _make_plane(me3+me2, me7+me6, me11+me10, me15+me14),
    )
    Frustum(planes)
end

function frustum_contains_point(f::Frustum, p::Vec3)
    for pl in f.planes
        plane_distance_to_point(pl, p) < 0 && return false
    end
    return true
end

function frustum_intersects_sphere(f::Frustum, s::BoundingSphere)
    for pl in f.planes
        plane_distance_to_point(pl, s.center) < -s.radius && return false
    end
    return true
end

function frustum_intersects_box(f::Frustum, b::Box3)
    for pl in f.planes
        n = pl.normal
        px = n.x > 0 ? b.max.x : b.min.x
        py = n.y > 0 ? b.max.y : b.min.y
        pz = n.z > 0 ? b.max.z : b.min.z
        plane_distance_to_point(pl, Vec3(px, py, pz)) < 0 && return false
    end
    return true
end

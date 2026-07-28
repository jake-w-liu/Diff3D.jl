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

dot(a::Vec3, b::Vec3) = a.x * b.x + a.y * b.y + a.z * b.z
cross(a::Vec3, b::Vec3) = Vec3(
    a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x
)
@inline _norm3(x, y, z) = hypot(x, y, z)
@inline _norm4(x, y, z, w) = hypot(x, y, z, w)

norm(a::Vec3) = _norm3(a.x, a.y, a.z)
function normalize(a::Vec3)
    l = norm(a)
    l > zero(l) || return Vec3(zero(a.x), zero(a.y), zero(a.z))
    isfinite(l) && return a / l

    # A finite vector can have a mathematical length larger than typemax(T).
    # Scale first in that case so its unit direction remains representable.
    scale = max(max(abs(a.x), abs(a.y)), abs(a.z))
    isfinite(scale) || return a / l
    scaled = a / scale
    return scaled / _norm3(scaled.x, scaled.y, scaled.z)
end
lerp(a::Vec3, b::Vec3, t::Real) = a * (1 - t) + b * t
distance(a::Vec3, b::Vec3) = norm(a - b)

# Vec2 arithmetic
Base.:+(a::Vec2, b::Vec2) = Vec2(a.x + b.x, a.y + b.y)
Base.:-(a::Vec2, b::Vec2) = Vec2(a.x - b.x, a.y - b.y)
Base.:*(a::Vec2, s::Real) = Vec2(a.x * s, a.y * s)
Base.:*(s::Real, a::Vec2) = a * s
dot(a::Vec2, b::Vec2) = a.x * b.x + a.y * b.y

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
    Mat4{T}((
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
end
Base.:*(a::Mat4, b::Mat4) = mat4_multiply(a, b)

function mat4_transform_vec4(m::Mat4, v::Vec4)
    Vec4(
        mat4_get(m, 1, 1)*v.x + mat4_get(m, 1, 2)*v.y + mat4_get(m, 1, 3)*v.z + mat4_get(m, 1, 4)*v.w,
        mat4_get(m, 2, 1)*v.x + mat4_get(m, 2, 2)*v.y + mat4_get(m, 2, 3)*v.z + mat4_get(m, 2, 4)*v.w,
        mat4_get(m, 3, 1)*v.x + mat4_get(m, 3, 2)*v.y + mat4_get(m, 3, 3)*v.z + mat4_get(m, 3, 4)*v.w,
        mat4_get(m, 4, 1)*v.x + mat4_get(m, 4, 2)*v.y + mat4_get(m, 4, 3)*v.z + mat4_get(m, 4, 4)*v.w
    )
end

function mat4_transform_point(m::Mat4, p::Vec3)
    v = mat4_transform_vec4(m, Vec4(p.x, p.y, p.z, one(p.x)))
    Vec3(v.x / v.w, v.y / v.w, v.z / v.w)
end

function mat4_transform_direction(m::Mat4, d::Vec3)
    Vec3(
        mat4_get(m, 1, 1)*d.x + mat4_get(m, 1, 2)*d.y + mat4_get(m, 1, 3)*d.z,
        mat4_get(m, 2, 1)*d.x + mat4_get(m, 2, 2)*d.y + mat4_get(m, 2, 3)*d.z,
        mat4_get(m, 3, 1)*d.x + mat4_get(m, 3, 2)*d.y + mat4_get(m, 3, 3)*d.z
    )
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
    z = dot(d, d) < 1e-12 ? Vec3(zero(d.x), zero(d.y), one(d.z)) : normalize(d)
    xc = cross(up, z)
    if dot(xc, xc) < 1e-12          # up parallel to view dir: perturb z (three.js lookAt)
        if abs(z.z) > one(z.z) - 1e-4
            z = normalize(Vec3(z.x + 1e-4, z.y, z.z))
        else
            z = normalize(Vec3(z.x, z.y, z.z + 1e-4))
        end
        xc = cross(up, z)
    end
    x = normalize(xc)
    y = cross(z, x)
    T = typeof(x.x)
    Mat4{T}((x.x, y.x, z.x, zero(T),
             x.y, y.y, z.y, zero(T),
             x.z, y.z, z.z, zero(T),
             -dot(x, eye), -dot(y, eye), -dot(z, eye), one(T)))
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
    c = isinf(far) ? -one(T) : -(far + near) / (far - near)
    d = isinf(far) ? -2 * near : -2 * far * near / (far - near)
    Mat4{T}((one(T)/(aspect*t), zero(T), zero(T), zero(T),
             zero(T), one(T)/t, zero(T), zero(T),
             zero(T), zero(T), T(c), -one(T),
             zero(T), zero(T), T(d), zero(T)))
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
    T = promote_type(typeof(left), typeof(right), typeof(bottom), typeof(top),
                     typeof(near), typeof(far), Float64)
    rl = T(right - left)
    tb = T(top - bottom)
    fn = T(far - near)
    Mat4{T}((2/rl, zero(T), zero(T), zero(T),
             zero(T), 2/tb, zero(T), zero(T),
             zero(T), zero(T), -2/fn, zero(T),
             -(T(right)+T(left))/rl, -(T(top)+T(bottom))/tb, -(T(far)+T(near))/fn, one(T)))
end

@inline function _mat4_inverse_unscale(value, column_scale, row_scale)
    # Divide by the larger scale first. Multiplying the scales can overflow or
    # underflow, while dividing by a tiny scale first can overflow an
    # intermediate even when the final quotient is representable.
    return abs(column_scale) >= abs(row_scale) ?
           (value / column_scale) / row_scale :
           (value / row_scale) / column_scale
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
plane_distance_to_point(p::Plane, pt::Vec3) = dot(p.normal, pt) + p.constant

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

triangle_normal(tri::Triangle)   = normalize(cross(tri.b - tri.a, tri.c - tri.a))
triangle_area(tri::Triangle)     = 0.5 * norm(cross(tri.b - tri.a, tri.c - tri.a))
triangle_centroid(tri::Triangle) = (tri.a + tri.b + tri.c) / 3

"""Barycentric coordinates `(u,v,w)` of `p` relative to the triangle plane."""
function triangle_barycentric(tri::Triangle, p::Vec3)
    v0 = tri.b - tri.a; v1 = tri.c - tri.a; v2 = p - tri.a
    d00 = dot(v0, v0); d01 = dot(v0, v1); d11 = dot(v1, v1)
    d20 = dot(v2, v0); d21 = dot(v2, v1)
    denom = d00*d11 - d01*d01
    if iszero(denom)                # degenerate (collinear/zero-area) triangle (three.js getBarycoord)
        z = zero(denom)
        return Vec3(z, z, z)
    end
    v = (d11*d20 - d01*d21) / denom
    w = (d00*d21 - d01*d20) / denom
    Vec3(one(v) - v - w, v, w)
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
line3_center(l::Line3) = (l.start + l.finish) * 0.5
line3_at(l::Line3, t)  = l.start + line3_delta(l) * t

"""Parameter `t` of the point on the line/segment closest to `p`."""
function line3_closest_point_parameter(l::Line3, p::Vec3; clamp_to_segment=true)
    d = line3_delta(l)
    denom = dot(d, d)
    t = denom > 0 ? dot(p - l.start, d) / denom : zero(d.x)
    clamp_to_segment ? clamp(t, zero(t), one(t)) : t
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
_lerp_value(a::Real, b::Real, α) = a + (b - a) * α
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
    me0, me1, me2, me3     = e[1],  e[2],  e[3],  e[4]
    me4, me5, me6, me7     = e[5],  e[6],  e[7],  e[8]
    me8, me9, me10, me11   = e[9],  e[10], e[11], e[12]
    me12, me13, me14, me15 = e[13], e[14], e[15], e[16]
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

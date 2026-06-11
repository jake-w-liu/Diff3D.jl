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
norm(a::Vec3) = sqrt(dot(a, a))
function normalize(a::Vec3)
    l = norm(a)
    l > 1e-20 || return Vec3(zero(a.x), zero(a.y), zero(a.z))
    return a / l
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

function mat4_multiply(a::Mat4, b::Mat4)
    T = promote_type(eltype(a.e), eltype(b.e))
    e = ntuple(16) do idx
        col = (idx - 1) ÷ 4 + 1
        row = (idx - 1) % 4 + 1
        mat4_get(a, row, 1) * mat4_get(b, 1, col) +
        mat4_get(a, row, 2) * mat4_get(b, 2, col) +
        mat4_get(a, row, 3) * mat4_get(b, 3, col) +
        mat4_get(a, row, 4) * mat4_get(b, 4, col)
    end
    Mat4{T}(e)
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
    t = tan(fov / 2)
    T = promote_type(typeof(t), typeof(aspect), typeof(near), typeof(far))
    Mat4{T}((one(T)/(aspect*t), zero(T), zero(T), zero(T),
             zero(T), one(T)/t, zero(T), zero(T),
             zero(T), zero(T), -(far+near)/(far-near), -one(T),
             zero(T), zero(T), -2*far*near/(far-near), zero(T)))
end

function mat4_orthographic(left, right, bottom, top, near, far)
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

function mat4_inverse(m::Mat4)
    e = m.e
    a00, a10, a20, a30 = e[1], e[2], e[3], e[4]
    a01, a11, a21, a31 = e[5], e[6], e[7], e[8]
    a02, a12, a22, a32 = e[9], e[10], e[11], e[12]
    a03, a13, a23, a33 = e[13], e[14], e[15], e[16]

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
        T = eltype(e)
        return Mat4{T}(ntuple(_ -> zero(T), 16))
    end
    inv_det = one(det) / det

    Mat4(( (a11*b11 - a12*b10 + a13*b09)*inv_det,
           (-a10*b11 + a12*b08 - a13*b07)*inv_det,
           (a10*b10 - a11*b08 + a13*b06)*inv_det,
           (-a10*b09 + a11*b07 - a12*b06)*inv_det,
           (-a01*b11 + a02*b10 - a03*b09)*inv_det,
           (a00*b11 - a02*b08 + a03*b07)*inv_det,
           (-a00*b10 + a01*b08 - a03*b06)*inv_det,
           (a00*b09 - a01*b07 + a02*b06)*inv_det,
           (a31*b05 - a32*b04 + a33*b03)*inv_det,
           (-a30*b05 + a32*b02 - a33*b01)*inv_det,
           (a30*b04 - a31*b02 + a33*b00)*inv_det,
           (-a30*b03 + a31*b01 - a32*b00)*inv_det,
           (-a21*b05 + a22*b04 - a23*b03)*inv_det,
           (a20*b05 - a22*b02 + a23*b01)*inv_det,
           (-a20*b04 + a21*b02 - a23*b00)*inv_det,
           (a20*b03 - a21*b01 + a22*b00)*inv_det ))
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
    l = sqrt(q.x^2 + q.y^2 + q.z^2 + q.w^2)
    if l < 1e-20    # zero quaternion: return identity (three.js Quaternion.normalize)
        return Quaternion(zero(q.x), zero(q.y), zero(q.z), one(q.w))
    end
    Quaternion(q.x/l, q.y/l, q.z/l, q.w/l)
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
    Spherical(r, acos(clamp(v.y / r, -one(r), one(r))), atan(v.x, v.z))
end

struct Cylindrical{T<:Real}
    radius::T
    theta::T
    y::T
end

cylindrical_to_cartesian(c::Cylindrical) =
    Vec3(c.radius * sin(c.theta), c.y, c.radius * cos(c.theta))
cartesian_to_cylindrical(v::Vec3) =
    Cylindrical(sqrt(v.x^2 + v.z^2), atan(v.x, v.z), v.y)

# ========================== Interpolant ==========================

"""
    interpolate_linear(times, values, t)

Piecewise-linear interpolation of `values` sampled at sorted `times`, evaluated
at `t`, clamped to the endpoints. `values` may be reals or `Vec3`.
"""
function interpolate_linear(times::AbstractVector, values::AbstractVector, t)
    n = length(times)
    @assert n == length(values) && n >= 1 "times and values must align and be non-empty"
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
    n = sqrt(a*a + b*b + c*c)
    inv = n > 0 ? one(n)/n : one(n)
    Plane(Vec3(a*inv, b*inv, c*inv), d*inv)
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

# --------------------------------------------------------------------------
# Cameras: PerspectiveCamera, OrthographicCamera
# --------------------------------------------------------------------------

abstract type AbstractCamera <: AbstractObject3D end

mutable struct PerspectiveCamera <: AbstractCamera
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    fov::Float64       # vertical field of view in radians
    aspect::Float64
    near::Float64
    far::Float64
    zoom::Float64
    target::Vec3{Float64}  # look-at target
    up::Vec3{Float64}
end

function PerspectiveCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                           scale::Vec3{Float64},
                           parent::Union{Nothing, AbstractObject3D},
                           children::Vector{AbstractObject3D}, visible::Bool,
                           name::String, id::Int, fov, aspect, near, far,
                           target::Vec3{Float64}, up::Vec3{Float64})
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(position, rotation, scale, parent, children, visible,
                      name, id, f, a, n, fr, 1.0, target, up)
end

function _validated_camera_zoom(zoom)
    z = Float64(zoom)
    (isfinite(z) && z > 0.0) || throw(ArgumentError("camera zoom must be positive and finite"))
    return z
end

function _validated_perspective_params(fov, aspect, near, far)
    f = Float64(fov)
    a = Float64(aspect)
    n = Float64(near)
    fr = Float64(far)
    isfinite(f) && 0.0 < f < Float64(pi) ||
        throw(ArgumentError("PerspectiveCamera fov must be finite and between 0 and pi radians"))
    isfinite(a) && a > 0.0 ||
        throw(ArgumentError("PerspectiveCamera aspect must be finite and positive"))
    isfinite(n) && n > 0.0 ||
        throw(ArgumentError("PerspectiveCamera near must be finite and positive"))
    !isnan(fr) || throw(ArgumentError("PerspectiveCamera far must not be NaN"))
    (isinf(fr) && fr > 0.0) || (isfinite(fr) && fr > n) ||
        throw(ArgumentError("PerspectiveCamera far must be finite and greater than near, or +Inf"))
    return f, a, n, fr
end

function _validated_orthographic_params(left, right, bottom, top, near, far)
    l = Float64(left)
    r = Float64(right)
    b = Float64(bottom)
    t = Float64(top)
    n = Float64(near)
    fr = Float64(far)
    isfinite(l) && isfinite(r) ||
        throw(ArgumentError("OrthographicCamera left and right must be finite"))
    isfinite(b) && isfinite(t) ||
        throw(ArgumentError("OrthographicCamera bottom and top must be finite"))
    l != r || throw(ArgumentError("OrthographicCamera left and right must differ"))
    b != t || throw(ArgumentError("OrthographicCamera bottom and top must differ"))
    isfinite(n) && n >= 0.0 ||
        throw(ArgumentError("OrthographicCamera near must be finite and non-negative"))
    isfinite(fr) && fr > n ||
        throw(ArgumentError("OrthographicCamera far must be finite and greater than near"))
    return l, r, b, t, n, fr
end

function PerspectiveCamera(; fov=π/4, aspect=1.0, near=0.1, far=1000.0,
                           zoom=1.0, name="PerspectiveCamera")
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        f, a, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0)
    )
end

get_position(c::PerspectiveCamera) = c.position
get_rotation(c::PerspectiveCamera) = c.rotation
get_scale(c::PerspectiveCamera) = c.scale
get_children(c::PerspectiveCamera) = c.children
get_parent(c::PerspectiveCamera) = c.parent
is_visible(c::PerspectiveCamera) = c.visible
set_parent!(c::PerspectiveCamera, p) = (c.parent = p)

function projection_matrix(c::PerspectiveCamera)
    zoom = _validated_camera_zoom(c.zoom)
    f, a, n, fr = _validated_perspective_params(c.fov, c.aspect, c.near, c.far)
    fov = 2.0 * atan(tan(f / 2.0) / zoom)
    mat4_perspective(fov, a, n, fr)
end

function view_matrix(c::PerspectiveCamera)
    mat4_look_at(c.position, c.target, c.up)
end

mutable struct OrthographicCamera <: AbstractCamera
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    left::Float64
    right::Float64
    bottom::Float64
    top::Float64
    near::Float64
    far::Float64
    zoom::Float64
    target::Vec3{Float64}
    up::Vec3{Float64}
end

function OrthographicCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                            scale::Vec3{Float64},
                            parent::Union{Nothing, AbstractObject3D},
                            children::Vector{AbstractObject3D}, visible::Bool,
                            name::String, id::Int, left, right, bottom, top,
                            near, far, target::Vec3{Float64}, up::Vec3{Float64})
    l, r, b, t, n, fr = _validated_orthographic_params(left, right, bottom, top, near, far)
    OrthographicCamera(position, rotation, scale, parent, children, visible,
                       name, id, l, r, b, t, n, fr, 1.0, target, up)
end

function OrthographicCamera(; left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                             near=0.1, far=1000.0, zoom=1.0,
                             name="OrthographicCamera")
    l, r, b, t, n, fr = _validated_orthographic_params(left, right, bottom, top, near, far)
    OrthographicCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        l, r, b, t, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0)
    )
end

get_position(c::OrthographicCamera) = c.position
get_rotation(c::OrthographicCamera) = c.rotation
get_scale(c::OrthographicCamera) = c.scale
get_children(c::OrthographicCamera) = c.children
get_parent(c::OrthographicCamera) = c.parent
is_visible(c::OrthographicCamera) = c.visible
set_parent!(c::OrthographicCamera, p) = (c.parent = p)

function projection_matrix(c::OrthographicCamera)
    zoom = _validated_camera_zoom(c.zoom)
    l, r, b, t, n, fr = _validated_orthographic_params(
        c.left, c.right, c.bottom, c.top, c.near, c.far)
    cx = (l + r) * 0.5
    cy = (b + t) * 0.5
    hx = (r - l) * 0.5 / zoom
    hy = (t - b) * 0.5 / zoom
    mat4_orthographic(cx - hx, cx + hx, cy - hy, cy + hy, n, fr)
end

function view_matrix(c::OrthographicCamera)
    mat4_look_at(c.position, c.target, c.up)
end

# ========================== StereoCamera ==========================
# Produces a left/right eye camera pair for stereo rendering.

mutable struct StereoCamera
    eye_sep::Float64
    cameraL::PerspectiveCamera
    cameraR::PerspectiveCamera
end

function StereoCamera(; eye_sep=0.064, aspect=1.0)
    StereoCamera(eye_sep, PerspectiveCamera(aspect=aspect), PerspectiveCamera(aspect=aspect))
end

"""
Update the left/right eye cameras from a base camera: each eye is the base
camera shifted by ∓`eye_sep`/2 along the camera's world right axis.
"""
function stereo_update!(s::StereoCamera, cam::PerspectiveCamera)
    z = normalize(cam.position - cam.target)
    right = normalize(cross(cam.up, z))
    half = s.eye_sep / 2
    for (sub, sign) in ((s.cameraL, -1.0), (s.cameraR, 1.0))
        off = right * (sign * half)
        sub.fov = cam.fov; sub.aspect = cam.aspect
        sub.near = cam.near; sub.far = cam.far; sub.zoom = cam.zoom; sub.up = cam.up
        sub.position = cam.position + off
        sub.target = cam.target + off
    end
    return s
end

# ========================== CubeCamera ==========================
# Six 90°-fov cameras facing the principal axes, for cube-map capture.

struct CubeCamera
    cameras::Vector{PerspectiveCamera}   # order: +x, -x, +y, -y, +z, -z
end

function CubeCamera(; near=0.1, far=1000.0, position=Vec3())
    faces = ((Vec3( 1.0,0,0), Vec3(0.0,-1,0)),
             (Vec3(-1.0,0,0), Vec3(0.0,-1,0)),
             (Vec3(0.0, 1,0), Vec3(0.0,0, 1)),
             (Vec3(0.0,-1,0), Vec3(0.0,0,-1)),
             (Vec3(0.0,0, 1), Vec3(0.0,-1,0)),
             (Vec3(0.0,0,-1), Vec3(0.0,-1,0)))
    cams = PerspectiveCamera[]
    for (dir, up) in faces
        c = PerspectiveCamera(fov=π/2, aspect=1.0, near=near, far=far)
        c.position = position
        c.target = position + dir
        c.up = up
        push!(cams, c)
    end
    CubeCamera(cams)
end

# ========================== ArrayCamera ==========================
# A set of sub-cameras, each owning a screen viewport (x, y, width, height).

struct ArrayCamera
    cameras::Vector{PerspectiveCamera}
    viewports::Vector{NTuple{4,Int}}
end
ArrayCamera(cameras::Vector{PerspectiveCamera}) =
    ArrayCamera(cameras, [(0, 0, 0, 0) for _ in cameras])

# Parametric view/projection for AD — takes raw camera parameters
function view_matrix_from_params(eye_x, eye_y, eye_z, target_x, target_y, target_z,
                                  up_x, up_y, up_z)
    eye = Vec3(eye_x, eye_y, eye_z)
    target = Vec3(target_x, target_y, target_z)
    up = Vec3(up_x, up_y, up_z)
    mat4_look_at(eye, target, up)
end

function projection_matrix_from_params(fov, aspect, near, far)
    mat4_perspective(fov, aspect, near, far)
end

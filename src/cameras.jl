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
    PerspectiveCamera(position, rotation, scale, parent, children, visible,
                      name, id, Float64(fov), Float64(aspect), Float64(near),
                      Float64(far), 1.0, target, up)
end

function _validated_camera_zoom(zoom)
    z = Float64(zoom)
    (isfinite(z) && z > 0.0) || throw(ArgumentError("camera zoom must be positive and finite"))
    return z
end

function PerspectiveCamera(; fov=π/4, aspect=1.0, near=0.1, far=1000.0,
                           zoom=1.0, name="PerspectiveCamera")
    PerspectiveCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        fov, aspect, near, far, _validated_camera_zoom(zoom),
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
    fov = 2.0 * atan(tan(c.fov / 2.0) / zoom)
    mat4_perspective(fov, c.aspect, c.near, c.far)
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
    OrthographicCamera(position, rotation, scale, parent, children, visible,
                       name, id, Float64(left), Float64(right),
                       Float64(bottom), Float64(top), Float64(near),
                       Float64(far), 1.0, target, up)
end

function OrthographicCamera(; left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                             near=0.1, far=1000.0, zoom=1.0,
                             name="OrthographicCamera")
    OrthographicCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        left, right, bottom, top, near, far, _validated_camera_zoom(zoom),
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
    cx = (c.left + c.right) * 0.5
    cy = (c.bottom + c.top) * 0.5
    hx = (c.right - c.left) * 0.5 / zoom
    hy = (c.top - c.bottom) * 0.5 / zoom
    mat4_orthographic(cx - hx, cx + hx, cy - hy, cy + hy, c.near, c.far)
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

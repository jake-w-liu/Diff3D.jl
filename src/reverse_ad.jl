# --------------------------------------------------------------------------
# Minimal reverse-mode automatic differentiation (a Wengert-list / tape engine),
# pure Julia, no external dependencies. `ADVar <: Real` flows through the same
# generic math used by the soft rasterizer, so a scalar loss over high-dimensional
# parameters (vertex positions, per-face colours) gets its full gradient in a
# single backward pass — O(1) in output dimension, unlike ForwardDiff's O(n).
#
# This is the engine's own reverse mode; it intentionally avoids heavy external
# AD packages (Enzyme/Zygote) that cannot be installed under the §14 disk
# constraint. Correctness is validated against ForwardDiff in the test suite.
# --------------------------------------------------------------------------

mutable struct ADVar <: Real
    val::Float64
    adj::Float64                 # accumulated adjoint (∂output/∂this)
    args::Union{Tuple{},Tuple{ADVar},Tuple{ADVar,ADVar}}
    partials::Union{Tuple{},Tuple{Float64},Tuple{Float64,Float64}}
end

@inline _mat4_inverse_scale_value(value::ADVar) = value.val

# Per-task stack of active tapes (operations recorded in creation = topological
# order). Task-local so concurrent reverse_gradient calls (e.g. Threads.@threads
# over independent gradients) never corrupt each other's tape, and a STACK so a
# nested reverse_gradient records onto its own tape without wiping the enclosing
# pass's graph. ADVars reference their parents directly via `args`, so the tape
# is only an ordering for the backward pass — a fresh per-call tape is sufficient.
function _ad_tape_stack()
    tls = task_local_storage()
    stack = get(tls, :diff3d_ad_tape_stack, nothing)
    if stack === nothing
        stack = Vector{ADVar}[]
        tls[:diff3d_ad_tape_stack] = stack
    end
    return stack::Vector{Vector{ADVar}}
end

function _ad_record(val::Float64, args::Tuple, partials::Tuple)
    v = ADVar(val, 0.0, args, partials)
    stack = _ad_tape_stack()
    isempty(stack) || push!(stack[end], v)   # record only while a gradient pass is active
    return v
end

_ad_constant(x::Real) = ADVar(Float64(x), 0.0, (), ())

ADVar(x::Real) = _ad_record(Float64(x), (), ())     # leaf / constant
ADVar(x::ADVar) = x

Base.convert(::Type{ADVar}, x::Real) = x isa ADVar ? x : ADVar(x)
Base.convert(::Type{ADVar}, x::ADVar) = x
Base.promote_rule(::Type{ADVar}, ::Type{<:Real}) = ADVar
Base.promote_rule(
    ::Type{ADVar},
    ::Type{ForwardDiff.Dual{Tag,V,N}},
) where {Tag,V,N} =
    ForwardDiff.Dual{Tag,promote_type(ADVar, V),N}
Base.promote_rule(
    ::Type{ForwardDiff.Dual{Tag,V,N}},
    ::Type{ADVar},
) where {Tag,V,N} =
    ForwardDiff.Dual{Tag,promote_type(V, ADVar),N}

Base.Float64(x::ADVar) = x.val
# `float` must preserve the ADVar (ForwardDiff.Dual convention): Base's generic
# `f(x::Real) = f(float(x))` fallbacks then fail loudly for any function without
# an explicit overload instead of silently severing the gradient.
Base.float(x::ADVar) = x
Base.float(::Type{ADVar}) = ADVar
(::Type{T})(x::ADVar) where {T<:Integer} = T(x.val)
(::Type{T})(x::ADVar) where {T<:AbstractFloat} = convert(T, x.val)
Base.convert(::Type{T}, x::ADVar) where {T<:AbstractFloat} = convert(T, x.val)
Base.Bool(x::ADVar) = Bool(x.val)
Base.hash(x::ADVar, h::UInt) = hash(x.val, h)

# ForwardDiff defines each of these operations for `(Real, Dual)` and
# `(Dual, Real)`, while reverse mode defines the corresponding broad
# `(ADVar, Real)` methods below. Without an explicit intersection, combining
# the two AD modes raises an ambiguous-method error. Delegate the intersection
# to ForwardDiff's generic rule: it promotes the Dual's value and partials to
# ADVar, preserving both the forward partial and the reverse tape.
for op in (:+, :-, :*, :/, :^, :(==), :<, :<=, :>, :>=,
           :isless, :min, :max, :hypot, :mod, :rem)
    @eval begin
        Base.$op(a::ADVar, b::ForwardDiff.Dual) =
            invoke(Base.$op, Tuple{Real,ForwardDiff.Dual}, a, b)
        Base.$op(a::ForwardDiff.Dual, b::ADVar) =
            invoke(Base.$op, Tuple{ForwardDiff.Dual,Real}, a, b)
    end
end

# ---- arithmetic ----
Base.:+(a::ADVar, b::ADVar) = _ad_record(a.val + b.val, (a, b), (1.0, 1.0))
Base.:+(a::ADVar, b::Real)  = _ad_record(a.val + Float64(b), (a,), (1.0,))
Base.:+(a::Real, b::ADVar)  = _ad_record(Float64(a) + b.val, (b,), (1.0,))
Base.:-(a::ADVar, b::ADVar) = _ad_record(a.val - b.val, (a, b), (1.0, -1.0))
Base.:-(a::ADVar, b::Real)  = _ad_record(a.val - Float64(b), (a,), (1.0,))
Base.:-(a::Real, b::ADVar)  = _ad_record(Float64(a) - b.val, (b,), (-1.0,))
Base.:-(a::ADVar)           = _ad_record(-a.val, (a,), (-1.0,))
Base.:*(a::ADVar, b::ADVar) = _ad_record(a.val * b.val, (a, b), (b.val, a.val))
Base.:*(a::ADVar, b::Real)  = (bf = Float64(b); _ad_record(a.val * bf, (a,), (bf,)))
Base.:*(a::Real, b::ADVar)  = (af = Float64(a); _ad_record(af * b.val, (b,), (af,)))
function Base.:/(a::ADVar, b::ADVar)
    quotient = a.val / b.val
    inv_b = 1.0 / b.val
    # Form ∂(a/b)/∂b as -(a/b)/b.  Computing -a/(b*b) first can
    # overflow or underflow `b*b` even when the derivative is representable.
    _ad_record(quotient, (a, b), (inv_b, -quotient * inv_b))
end
function Base.:/(a::ADVar, b::Real)
    bf = Float64(b)
    _ad_record(a.val / bf, (a,), (1.0 / bf,))
end
function Base.:/(a::Real, b::ADVar)
    af = Float64(a)
    quotient = af / b.val
    inv_b = 1.0 / b.val
    _ad_record(quotient, (b,), (-quotient * inv_b,))
end

# ---- powers ----
function Base.:^(a::ADVar, p::Integer)
    # At a.val==0 the formula p·0^(p-1) is correct for p≥1 (gives 1 for p=1, 0
    # for p≥2) but yields 0·0^(-1)=0·Inf=NaN for p=0 and ±Inf for p<0 (a pole).
    # Guard those non-positive exponents to 0, matching the ^(::Real) sibling and
    # ForwardDiff (d/dx of the constant x^0≡1 is 0); without this the NaN adjoint
    # poisons the whole reverse-mode gradient.
    d = (a.val == 0 && p <= 0) ? 0.0 : Float64(p) * a.val^(p - 1)
    _ad_record(a.val^p, (a,), (d,))
end
function Base.:^(a::ADVar, p::Real)
    v = a.val^p
    # Only the non-positive exponents are singular at base 0 (p=0 ⇒ 0·Inf=NaN,
    # p<0 ⇒ pole). p=1 is the smooth identity (derivative 1) and p>1 gives 0, so
    # the guard must NOT zero those — over-broad `a.val==0 ? 0.0` dropped d/dx x=1.
    d = (a.val == 0 && p <= 0) ? 0.0 : p * a.val^(p - 1)
    _ad_record(v, (a,), (d,))
end
function Base.:^(a::Real, b::ADVar)
    af = Float64(a)
    v = af^b.val
    db = af > 0 ? v * log(af) : 0.0
    _ad_record(v, (b,), (db,))
end
Base.:^(a::Irrational{:ℯ}, b::ADVar) = Float64(a)^b
# Resolve the dispatch ambiguity between ^(::ADVar, ::Real) above and Base's
# ^(::Number, ::Rational): a rational exponent (e.g. x^(1//3)) is ordinary input.
Base.:^(a::ADVar, p::Rational) = a^float(p)
function Base.:^(a::ADVar, b::ADVar)   # ADVar exponent (also reached by x::Real ^ ADVar via promotion)
    v = a.val^b.val
    da = (a.val == 0 && b.val <= 0) ? 0.0 : b.val * a.val^(b.val - 1)
    db = a.val > 0 ? v * log(a.val) : 0.0
    _ad_record(v, (a, b), (da, db))
end
Base.literal_pow(::typeof(^), a::ADVar, ::Val{p}) where {p} = a^p

# ---- elementary functions ----
Base.exp(a::ADVar)  = (e = exp(a.val); _ad_record(e, (a,), (e,)))
Base.log(a::ADVar)  = _ad_record(log(a.val), (a,), (1.0 / a.val,))
Base.sqrt(a::ADVar) = (s = sqrt(a.val); _ad_record(s, (a,), (s == 0 ? 0.0 : 0.5 / s,)))
Base.abs(a::ADVar)  = _ad_record(abs(a.val), (a,), (a.val < 0 ? -1.0 : 1.0,))
Base.sin(a::ADVar)  = _ad_record(sin(a.val), (a,), (cos(a.val),))
Base.cos(a::ADVar)  = _ad_record(cos(a.val), (a,), (-sin(a.val),))
Base.tan(a::ADVar)  = (t = tan(a.val); _ad_record(t, (a,), (1.0 + t * t,)))
Base.sinh(a::ADVar) = _ad_record(sinh(a.val), (a,), (cosh(a.val),))
Base.cosh(a::ADVar) = _ad_record(cosh(a.val), (a,), (sinh(a.val),))
@inline function _tanh_derivative(x::Float64, value::Float64)
    # `1 - tanh(x)^2` has better absolute accuracy near zero, but loses the
    # entire representable derivative once tanh rounds to ±1. The exponential
    # sech² form has no subtractive cancellation in the tails.
    abs(x) < 1.0 && return 1.0 - value * value
    exponent = -2.0 * abs(x)
    tail = exp(exponent)
    numerator = (iszero(tail) || issubnormal(tail)) ?
                exp(log(4.0) + exponent) : 4.0 * tail
    denominator = 1.0 + tail
    return numerator / (denominator * denominator)
end
function Base.tanh(a::ADVar)
    value = tanh(a.val)
    return _ad_record(
        value, (a,), (_tanh_derivative(a.val, value),))
end
Base.asin(a::ADVar) = _ad_record(asin(a.val), (a,), (1.0 / sqrt(1.0 - a.val * a.val),))
Base.acos(a::ADVar) = _ad_record(acos(a.val), (a,), (-1.0 / sqrt(1.0 - a.val * a.val),))
@inline function _atan_derivative(x::Float64)
    if abs(x) > 1.0
        reciprocal = inv(x)
        squared = reciprocal * reciprocal
        return squared / (1.0 + squared)
    end
    return 1.0 / (1.0 + x * x)
end
Base.atan(a::ADVar) = _ad_record(atan(a.val), (a,), (_atan_derivative(a.val),))

function _atan2_partials(y::Float64, x::Float64)
    scale = max(abs(x), abs(y))
    iszero(scale) && return (NaN, NaN)
    scaled_x = x / scale
    scaled_y = y / scale
    denominator = scaled_x * scaled_x + scaled_y * scaled_y
    return (scaled_x / denominator / scale,
            -scaled_y / denominator / scale)
end

function Base.atan(y::ADVar, x::ADVar)
    dy, dx = _atan2_partials(y.val, x.val)
    _ad_record(atan(y.val, x.val), (y, x), (dy, dx))
end
Base.exp2(a::ADVar)  = (e = exp2(a.val); _ad_record(e, (a,), (e * log(2.0),)))
Base.exp10(a::ADVar) = (e = exp10(a.val); _ad_record(e, (a,), (e * log(10.0),)))
Base.expm1(a::ADVar) = _ad_record(expm1(a.val), (a,), (exp(a.val),))
@inline function _log_base_derivative(x::Float64, log_base::Float64)
    return abs(x) >= 1.0 ? inv(x) / log_base : inv(x * log_base)
end
Base.log2(a::ADVar)  = _ad_record(
    log2(a.val), (a,), (_log_base_derivative(a.val, log(2.0)),))
Base.log10(a::ADVar) = _ad_record(
    log10(a.val), (a,), (_log_base_derivative(a.val, log(10.0)),))
Base.log1p(a::ADVar) = _ad_record(log1p(a.val), (a,), (1.0 / (1.0 + a.val),))
Base.cbrt(a::ADVar)  = (c = cbrt(a.val); _ad_record(c, (a,), (c == 0 ? 0.0 : 1.0 / (3.0 * c * c),)))
function Base.hypot(a::ADVar, b::ADVar)
    h = hypot(a.val, b.val)
    _ad_record(h, (a, b), (h == 0 ? 0.0 : a.val / h, h == 0 ? 0.0 : b.val / h))
end
function Base.hypot(a::ADVar, b::Real)
    bf = Float64(b)
    h = hypot(a.val, bf)
    _ad_record(h, (a,), (h == 0 ? 0.0 : a.val / h,))
end
function Base.hypot(a::Real, b::ADVar)
    af = Float64(a)
    h = hypot(af, b.val)
    _ad_record(h, (b,), (h == 0 ? 0.0 : b.val / h,))
end

# ---- min/max (gradient flows to the selected argument) ----
Base.max(a::ADVar, b::ADVar) = a.val >= b.val ? _ad_record(a.val, (a, b), (1.0, 0.0)) :
                                                _ad_record(b.val, (a, b), (0.0, 1.0))
Base.min(a::ADVar, b::ADVar) = a.val <= b.val ? _ad_record(a.val, (a, b), (1.0, 0.0)) :
                                                _ad_record(b.val, (a, b), (0.0, 1.0))
Base.max(a::ADVar, b::Real) = (bf = Float64(b); a.val >= bf ? _ad_record(a.val, (a,), (1.0,)) : _ad_constant(bf))
Base.max(a::Real, b::ADVar) = (af = Float64(a); af >= b.val ? _ad_constant(af) : _ad_record(b.val, (b,), (1.0,)))
Base.min(a::ADVar, b::Real) = (bf = Float64(b); a.val <= bf ? _ad_record(a.val, (a,), (1.0,)) : _ad_constant(bf))
Base.min(a::Real, b::ADVar) = (af = Float64(a); af <= b.val ? _ad_constant(af) : _ad_record(b.val, (b,), (1.0,)))

# ---- comparisons (decided by the value; no gradient) ----
Base.:<(a::ADVar, b::ADVar)  = a.val < b.val
Base.:<=(a::ADVar, b::ADVar) = a.val <= b.val
Base.:>(a::ADVar, b::ADVar)  = a.val > b.val
Base.:>=(a::ADVar, b::ADVar) = a.val >= b.val
Base.:(==)(a::ADVar, b::ADVar) = a.val == b.val
Base.:<(a::ADVar, b::Real)  = a.val < Float64(b)
Base.:<=(a::ADVar, b::Real) = a.val <= Float64(b)
Base.:>(a::ADVar, b::Real)  = a.val > Float64(b)
Base.:>=(a::ADVar, b::Real) = a.val >= Float64(b)
Base.:(==)(a::ADVar, b::Real) = a.val == Float64(b)
Base.:(==)(a::ADVar, b::AbstractIrrational) = a.val == Float64(b)
Base.:<(a::Real, b::ADVar)  = Float64(a) < b.val
Base.:<=(a::Real, b::ADVar) = Float64(a) <= b.val
Base.:>(a::Real, b::ADVar)  = Float64(a) > b.val
Base.:>=(a::Real, b::ADVar) = Float64(a) >= b.val
Base.:(==)(a::Real, b::ADVar) = Float64(a) == b.val
Base.:(==)(a::AbstractIrrational, b::ADVar) = Float64(a) == b.val
Base.isless(a::ADVar, b::ADVar) = a.val < b.val
Base.isless(a::ADVar, b::Real) = a.val < Float64(b)
Base.isless(a::Real, b::ADVar) = Float64(a) < b.val
Base.isless(a::ADVar, b::AbstractFloat) = isless(a.val, Float64(b))
Base.isless(a::AbstractFloat, b::ADVar) = isless(Float64(a), b.val)
Base.isfinite(a::ADVar) = isfinite(a.val)
Base.isnan(a::ADVar) = isnan(a.val)

# ---- identities / rounding (discrete results carry no gradient) ----
Base.zero(::Type{ADVar}) = _ad_constant(0.0)
Base.one(::Type{ADVar})  = _ad_constant(1.0)
Base.zero(::ADVar) = _ad_constant(0.0)
Base.one(::ADVar)  = _ad_constant(1.0)
Base.floor(::Type{T}, a::ADVar) where {T<:Integer} = floor(T, a.val)
Base.ceil(::Type{T}, a::ADVar) where {T<:Integer}  = ceil(T, a.val)
Base.round(::Type{T}, a::ADVar) where {T<:Integer} = round(T, a.val)
Base.trunc(::Type{T}, a::ADVar) where {T<:Integer} = trunc(T, a.val)
# Single-argument floor/ceil/round/trunc(::ADVar) route through this; a rounded
# result is piecewise-constant, so it carries a zero derivative. Without it those
# forms raise MethodError instead of returning the rounded value.
Base.round(a::ADVar, r::RoundingMode) = ADVar(round(a.val, r))
# mod/rem are piecewise-linear away from quotient discontinuities.
Base.mod(a::ADVar, b::Real) =
    (bf = Float64(b); _ad_record(mod(a.val, bf), (a,), (1.0,)))
Base.rem(a::ADVar, b::Real) =
    (bf = Float64(b); _ad_record(rem(a.val, bf), (a,), (1.0,)))
function Base.mod(a::ADVar, b::ADVar)
    q = fld(a.val, b.val)
    _ad_record(mod(a.val, b.val), (a, b), (1.0, -q))
end
function Base.mod(a::Real, b::ADVar)
    af = Float64(a)
    q = fld(af, b.val)
    _ad_record(mod(af, b.val), (b,), (-q,))
end
function Base.rem(a::ADVar, b::ADVar)
    q = trunc(a.val / b.val)
    _ad_record(rem(a.val, b.val), (a, b), (1.0, -q))
end
function Base.rem(a::Real, b::ADVar)
    af = Float64(a)
    q = trunc(af / b.val)
    _ad_record(rem(af, b.val), (b,), (-q,))
end

# Discrete quotient operations carry no derivative, matching ForwardDiff.
Base.div(a::ADVar, b::ADVar, r::RoundingMode) = div(a.val, b.val, r)

function Base.modf(a::ADVar)
    fraction, integral = modf(a.val)
    return (_ad_record(fraction, (a,), (1.0,)), _ad_constant(integral))
end

Base.eps(a::ADVar) = eps(a.val)
Base.nextfloat(a::ADVar, n::Integer=1) =
    _ad_record(nextfloat(a.val, n), (a,), (1.0,))
Base.prevfloat(a::ADVar, n::Integer=1) =
    _ad_record(prevfloat(a.val, n), (a,), (1.0,))
Base.isinteger(a::ADVar) = isinteger(a.val)
Base.issubnormal(a::ADVar) = issubnormal(a.val)
Base.exponent(a::ADVar) = exponent(a.val)
# Angle conversions. Base routes these through `f(x::Real) = f(float(x))`, and
# `float(::ADVar) = ADVar` (above) makes that recurse forever (StackOverflow);
# define them directly via the recorded `*`/sin/cos/tan so the gradient flows.
Base.deg2rad(x::ADVar) = x * (π / 180)
Base.rad2deg(x::ADVar) = x * (180 / π)
Base.sind(x::ADVar) = sin(deg2rad(x))
Base.cosd(x::ADVar) = cos(deg2rad(x))
Base.tand(x::ADVar) = tan(deg2rad(x))

function _reverse_value_gradient(f, x::AbstractVector{<:Real})
    stack = _ad_tape_stack()
    n = length(x)
    tape = ADVar[]
    sizehint!(tape, n <= typemax(Int) ÷ 3 ? max(16, 3n) : n)
    push!(stack, tape)                    # this pass records onto its own tape
    try
        inputs = Vector{ADVar}(undef, n)
        input_index = 1
        @inbounds for i in eachindex(x)
            inputs[input_index] = ADVar(Float64(x[i]))   # leaf (recorded on `tape`)
            input_index += 1
        end
        y = f(inputs)
        y isa ADVar || error("reverse_gradient: f must return a scalar ADVar")
        # Backward pass: tape is in topological order, so iterate in reverse.
        for v in tape
            v.adj = 0.0
        end
        y.adj = 1.0
        @inbounds for k in length(tape):-1:1
            v = tape[k]
            a = v.adj
            a == 0.0 && continue
            for i in 1:length(v.args)
                v.args[i].adj += a * v.partials[i]
            end
        end
        grad = Vector{Float64}(undef, n)
        @inbounds for i in 1:n
            grad[i] = inputs[i].adj
        end
        return (Float64(y.val), grad)
    finally
        pop!(stack)                       # always release this pass's tape
    end
end

"""
    reverse_gradient(f, x::Vector{Float64}) -> Vector{Float64}

Gradient of scalar `f(x)` via one reverse-mode pass. `f` must accept a vector of
`ADVar` and return a single `ADVar`. Validated against ForwardDiff in tests.
"""
function reverse_gradient(f, x::AbstractVector{<:Real})
    return _reverse_value_gradient(f, x)[2]
end

"""Value and gradient of `f` at `x` in one reverse pass."""
function reverse_value_gradient(f, x::AbstractVector{<:Real})
    return _reverse_value_gradient(f, x)
end

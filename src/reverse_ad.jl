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
    args::Tuple                  # parent ADVars
    partials::Tuple              # ∂this/∂parent for each parent (Float64)
end

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

ADVar(x::Real) = _ad_record(Float64(x), (), ())     # leaf / constant

Base.convert(::Type{ADVar}, x::Real) = x isa ADVar ? x : ADVar(x)
Base.convert(::Type{ADVar}, x::ADVar) = x
Base.promote_rule(::Type{ADVar}, ::Type{<:Real}) = ADVar

Base.Float64(x::ADVar) = x.val
# `float` must preserve the ADVar (ForwardDiff.Dual convention): Base's generic
# `f(x::Real) = f(float(x))` fallbacks then fail loudly for any function without
# an explicit overload instead of silently severing the gradient.
Base.float(x::ADVar) = x
Base.float(::Type{ADVar}) = ADVar
(::Type{T})(x::ADVar) where {T<:Integer} = T(x.val)

# ---- arithmetic ----
Base.:+(a::ADVar, b::ADVar) = _ad_record(a.val + b.val, (a, b), (1.0, 1.0))
Base.:-(a::ADVar, b::ADVar) = _ad_record(a.val - b.val, (a, b), (1.0, -1.0))
Base.:-(a::ADVar)           = _ad_record(-a.val, (a,), (-1.0,))
Base.:*(a::ADVar, b::ADVar) = _ad_record(a.val * b.val, (a, b), (b.val, a.val))
function Base.:/(a::ADVar, b::ADVar)
    _ad_record(a.val / b.val, (a, b), (1.0 / b.val, -a.val / (b.val * b.val)))
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
Base.tanh(a::ADVar) = (t = tanh(a.val); _ad_record(t, (a,), (1.0 - t * t,)))
Base.asin(a::ADVar) = _ad_record(asin(a.val), (a,), (1.0 / sqrt(1.0 - a.val * a.val),))
Base.acos(a::ADVar) = _ad_record(acos(a.val), (a,), (-1.0 / sqrt(1.0 - a.val * a.val),))
Base.atan(a::ADVar) = _ad_record(atan(a.val), (a,), (1.0 / (1.0 + a.val * a.val),))
function Base.atan(y::ADVar, x::ADVar)
    d = x.val * x.val + y.val * y.val
    _ad_record(atan(y.val, x.val), (y, x), (x.val / d, -y.val / d))
end
Base.exp2(a::ADVar)  = (e = exp2(a.val); _ad_record(e, (a,), (e * log(2.0),)))
Base.exp10(a::ADVar) = (e = exp10(a.val); _ad_record(e, (a,), (e * log(10.0),)))
Base.expm1(a::ADVar) = _ad_record(expm1(a.val), (a,), (exp(a.val),))
Base.log2(a::ADVar)  = _ad_record(log2(a.val), (a,), (1.0 / (a.val * log(2.0)),))
Base.log10(a::ADVar) = _ad_record(log10(a.val), (a,), (1.0 / (a.val * log(10.0)),))
Base.log1p(a::ADVar) = _ad_record(log1p(a.val), (a,), (1.0 / (1.0 + a.val),))
Base.cbrt(a::ADVar)  = (c = cbrt(a.val); _ad_record(c, (a,), (c == 0 ? 0.0 : 1.0 / (3.0 * c * c),)))
function Base.hypot(a::ADVar, b::ADVar)
    h = hypot(a.val, b.val)
    _ad_record(h, (a, b), (h == 0 ? 0.0 : a.val / h, h == 0 ? 0.0 : b.val / h))
end
Base.hypot(a::ADVar, b::Real) = hypot(a, ADVar(b))
Base.hypot(a::Real, b::ADVar) = hypot(ADVar(a), b)

# ---- min/max (gradient flows to the selected argument) ----
Base.max(a::ADVar, b::ADVar) = a.val >= b.val ? _ad_record(a.val, (a, b), (1.0, 0.0)) :
                                                _ad_record(b.val, (a, b), (0.0, 1.0))
Base.min(a::ADVar, b::ADVar) = a.val <= b.val ? _ad_record(a.val, (a, b), (1.0, 0.0)) :
                                                _ad_record(b.val, (a, b), (0.0, 1.0))

# ---- comparisons (decided by the value; no gradient) ----
Base.:<(a::ADVar, b::ADVar)  = a.val < b.val
Base.:<=(a::ADVar, b::ADVar) = a.val <= b.val
Base.:>(a::ADVar, b::ADVar)  = a.val > b.val
Base.:>=(a::ADVar, b::ADVar) = a.val >= b.val
Base.:(==)(a::ADVar, b::ADVar) = a.val == b.val
Base.isless(a::ADVar, b::ADVar) = a.val < b.val
Base.isfinite(a::ADVar) = isfinite(a.val)
Base.isnan(a::ADVar) = isnan(a.val)

# ---- identities / rounding (discrete results carry no gradient) ----
Base.zero(::Type{ADVar}) = ADVar(0.0)
Base.one(::Type{ADVar})  = ADVar(1.0)
Base.zero(::ADVar) = ADVar(0.0)
Base.one(::ADVar)  = ADVar(1.0)
Base.floor(::Type{T}, a::ADVar) where {T<:Integer} = floor(T, a.val)
Base.ceil(::Type{T}, a::ADVar) where {T<:Integer}  = ceil(T, a.val)
Base.round(::Type{T}, a::ADVar) where {T<:Integer} = round(T, a.val)
Base.trunc(::Type{T}, a::ADVar) where {T<:Integer} = trunc(T, a.val)
# Single-argument floor/ceil/round/trunc(::ADVar) route through this; a rounded
# result is piecewise-constant, so it carries a zero derivative. Without it those
# forms raise MethodError instead of returning the rounded value.
Base.round(a::ADVar, r::RoundingMode) = ADVar(round(a.val, r))
# mod/rem are piecewise-linear with unit slope in the first argument (a.e.).
Base.mod(a::ADVar, b::Real) = _ad_record(mod(a.val, b), (a,), (1.0,))
Base.rem(a::ADVar, b::Real) = _ad_record(rem(a.val, b), (a,), (1.0,))
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

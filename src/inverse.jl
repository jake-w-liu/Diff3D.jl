# --------------------------------------------------------------------------
# Inverse rendering utilities: gradient-based optimization of scene params.
# Uses ForwardDiff for gradient computation.
# --------------------------------------------------------------------------

using ForwardDiff

struct _ForwardDiffValueGradientConfig{N,Tag}
    dual_params::Vector{ForwardDiff.Dual{Tag,Float64,N}}
end

struct _InverseValueGradientConfig{F}
    mode::Symbol
    forward::F
    allow_fallback::Bool
end

const _INVERSE_AUTO_REVERSE_MIN_PARAMS = 16

function _inverse_ad_mode(ad)
    (ad === :auto || (ad isa AbstractString && ad == "auto")) && return :auto
    (ad === :forward || (ad isa AbstractString && ad == "forward")) && return :forward
    (ad === :reverse || (ad isa AbstractString && ad == "reverse")) && return :reverse
    throw(ArgumentError("inverse rendering ad must be :auto, :forward, or :reverse"))
end

function _forwarddiff_value_gradient_config(objective::F,
                                            params::AbstractVector{Float64}) where {F}
    chunk = isempty(params) ? 1 : min(ForwardDiff.pickchunksize(length(params)),
                                      length(params))
    return _forwarddiff_value_gradient_config(objective, params, Val(chunk))
end

function _forwarddiff_value_gradient_config(::F,
                                            params::AbstractVector{Float64},
                                            ::Val{N}) where {F,N}
    Tag = ForwardDiff.Tag{F, Float64}
    dual_params = Vector{ForwardDiff.Dual{Tag,Float64,N}}(undef, length(params))
    return _ForwardDiffValueGradientConfig{N,Tag}(dual_params)
end

function _inverse_value_gradient_config(objective::F,
                                        params::AbstractVector{Float64},
                                        ad) where {F}
    requested = _inverse_ad_mode(ad)
    mode = requested
    allow_fallback = false
    if requested == :auto
        mode = length(params) >= _INVERSE_AUTO_REVERSE_MIN_PARAMS ? :reverse : :forward
        allow_fallback = mode == :reverse
    end
    forward = (mode == :forward || allow_fallback) ?
        _forwarddiff_value_gradient_config(objective, params) : nothing
    return _InverseValueGradientConfig(mode, forward, allow_fallback)
end

_inverse_reverse_autofallback_error(err) =
    err isa MethodError ||
    (err isa ErrorException && occursin("reverse_gradient: f must return",
                                        sprint(showerror, err)))

function _forwarddiff_value_and_gradient!(grad::AbstractVector{Float64},
                                          objective::F,
                                          params::AbstractVector{Float64},
                                          cfg::_ForwardDiffValueGradientConfig{N,Tag}) where {F,N,Tag}
    length(grad) == length(params) ||
        throw(ArgumentError("gradient workspace length must match params"))
    length(cfg.dual_params) == length(params) ||
        throw(ArgumentError("ForwardDiff workspace length must match params"))
    n = length(params)
    if n == 0
        return Float64(objective(params))
    end
    return _forwarddiff_value_and_gradient_chunk!(grad, objective, params, cfg)
end

function _forwarddiff_value_and_gradient_chunk!(grad::AbstractVector{Float64},
                                                objective::F,
                                                params::AbstractVector{Float64},
                                                cfg::_ForwardDiffValueGradientConfig{N,Tag}) where {F,N,Tag}
    dual_params = cfg.dual_params
    value = 0.0
    got_value = false
    @inbounds for first_idx in 1:N:length(params)
        last_idx = min(first_idx + N - 1, length(params))
        for i in eachindex(params)
            lane = i - first_idx + 1
            partials = ForwardDiff.Partials{N,Float64}(
                ntuple(j -> j == lane ? 1.0 : 0.0, Val(N)))
            dual_params[i] = ForwardDiff.Dual{Tag}(params[i], partials)
        end
        y = objective(dual_params)
        if y isa ForwardDiff.Dual
            got_value || (value = Float64(ForwardDiff.value(y)); got_value = true)
            ypartials = ForwardDiff.partials(y)
            for lane in 1:(last_idx - first_idx + 1)
                grad[first_idx + lane - 1] = ypartials[lane]
            end
        else
            # Objective ignored the parameters; ForwardDiff would return a zero
            # gradient, and the first scalar value is the loss for this step.
            fill!(grad, 0.0)
            return Float64(y)
        end
    end
    return value
end

function _inverse_value_and_gradient!(grad::AbstractVector{Float64},
                                      objective::F,
                                      params::AbstractVector{Float64},
                                      cfg::_InverseValueGradientConfig) where {F}
    if cfg.mode == :forward
        return _forwarddiff_value_and_gradient!(grad, objective, params, cfg.forward)
    end
    length(grad) == length(params) ||
        throw(ArgumentError("gradient workspace length must match params"))
    if isempty(params)
        return Float64(objective(params))
    end
    value, reverse_grad = try
        reverse_value_gradient(objective, params)
    catch err
        if cfg.allow_fallback && _inverse_reverse_autofallback_error(err)
            return _forwarddiff_value_and_gradient!(grad, objective, params, cfg.forward)
        end
        rethrow()
    end
    length(reverse_grad) == length(grad) ||
        throw(ArgumentError("reverse-gradient result length must match params"))
    copyto!(grad, reverse_grad)
    return value
end

function _validate_optimizer_common(lr, n_iters, label::String)
    n_iters isa Bool && throw(ArgumentError("$label n_iters must be a non-negative integer"))
    n_iters isa Integer ||
        throw(ArgumentError("$label n_iters must be a non-negative integer"))
    n_iters >= 0 ||
        throw(ArgumentError("$label n_iters must be a non-negative integer"))
    lr isa Bool && throw(ArgumentError("$label lr must be finite and non-negative"))
    (isfinite(lr) && lr >= 0) ||
        throw(ArgumentError("$label lr must be finite and non-negative"))
    return nothing
end

function _validate_adam_hyperparams(β1, β2, ε)
    for (name, value) in ((:β1, β1), (:β2, β2))
        value isa Bool && throw(ArgumentError("inverse_render_adam $name must satisfy 0 <= $name < 1"))
        (isfinite(value) && 0 <= value < 1) ||
            throw(ArgumentError("inverse_render_adam $name must satisfy 0 <= $name < 1"))
    end
    ε isa Bool && throw(ArgumentError("inverse_render_adam ε must be finite and positive"))
    (isfinite(ε) && ε > 0) ||
        throw(ArgumentError("inverse_render_adam ε must be finite and positive"))
    return nothing
end

@inline function _adam_normalized_step(
    first_moment, root_second_moment,
    first_correction, root_second_correction, epsilon,
)
    if iszero(root_second_moment)
        iszero(first_moment) && return zero(first_moment)
        return (first_moment / first_correction) / epsilon
    end

    epsilon_ratio =
        (epsilon / root_second_moment) * root_second_correction
    if epsilon_ratio > one(epsilon_ratio)
        epsilon_limited =
            (first_moment / first_correction) / epsilon
        return epsilon_limited /
               (one(epsilon_ratio) + inv(epsilon_ratio))
    end
    moment_ratio =
        (first_moment / root_second_moment) *
        (root_second_correction / first_correction)
    return moment_ratio / (one(epsilon_ratio) + epsilon_ratio)
end

@inline _optimizer_parameter_step(parameter, rate, update) =
    _float_product_difference(
        one(parameter), parameter, rate, update)

"""
Gradient descent optimizer for inverse rendering.
Optimizes `params` to minimize the loss between rendered image and target.

Arguments:
- initial_params: starting parameter vector
- target_image: goal image (H×W×3 array)
- render_fn: params -> image (must be ForwardDiff-compatible)
- loss_fn: (rendered, target) -> scalar loss
- lr: learning rate
- n_iters: number of optimization steps
- verbose: print progress
- ad: `:auto`, `:forward`, or `:reverse` gradient backend. `:auto` uses the
  single-pass reverse engine for wider parameter vectors and falls back to
  ForwardDiff when the reverse engine reports an unsupported objective.

Returns: (optimized_params, loss_history)
"""
function inverse_render_optimize(initial_params::Vector{Float64},
                                 target_image::Array{Float64, 3},
                                 render_fn::Function,
                                 loss_fn::Function;
                                 lr=0.01,
                                 n_iters=100,
                                 verbose=true,
                                 ad=:auto)
    _validate_optimizer_common(lr, n_iters, "inverse_render_optimize")
    params = copy(initial_params)
    loss_history = Vector{Float64}(undef, n_iters)

    function objective(p)
        img = render_fn(p)
        loss_fn(img, target_image)
    end

    grad = similar(params)
    grad_cfg = _inverse_value_gradient_config(objective, params, ad)

    for iter in 1:n_iters
        current_loss = _inverse_value_and_gradient!(grad, objective, params, grad_cfg)
        loss_history[iter] = current_loss

        # Gradient descent step
        @inbounds for i in eachindex(params, grad)
            params[i] =
                _optimizer_parameter_step(params[i], lr, grad[i])
        end

        if verbose && (iter % 10 == 0 || iter == 1)
            @info "Iter $iter/$n_iters: loss = $(round(current_loss, sigdigits=6))"
        end
    end

    return params, loss_history
end

"""
Adam optimizer for inverse rendering.
Better convergence than vanilla gradient descent.
Accepts the same `ad` gradient-backend keyword as `inverse_render_optimize`.
"""
function inverse_render_adam(initial_params::Vector{Float64},
                            target_image::Array{Float64, 3},
                            render_fn::Function,
                            loss_fn::Function;
                            lr=0.01,
                            β1=0.9, β2=0.999,
                            ε=1e-8,
                            n_iters=100,
                            verbose=true,
                            ad=:auto)
    _validate_optimizer_common(lr, n_iters, "inverse_render_adam")
    _validate_adam_hyperparams(β1, β2, ε)
    params = copy(initial_params)
    n = length(params)
    m = zeros(n)  # first moment
    root_v = zeros(n)  # square root of the second moment
    grad = similar(params)
    loss_history = Vector{Float64}(undef, n_iters)

    function objective(p)
        img = render_fn(p)
        loss_fn(img, target_image)
    end

    one_minus_β1 = 1 - β1
    one_minus_β2 = 1 - β2
    sqrt_β2 = sqrt(β2)
    sqrt_one_minus_β2 = sqrt(one_minus_β2)
    grad_cfg = _inverse_value_gradient_config(objective, params, ad)

    for iter in 1:n_iters
        current_loss = _inverse_value_and_gradient!(grad, objective, params, grad_cfg)
        loss_history[iter] = current_loss

        # Adam update
        first_correction = 1 - β1^iter
        root_second_correction = sqrt(1 - β2^iter)
        @inbounds for i in eachindex(params, grad, m, root_v)
            gi = grad[i]
            mi = _stable_lerp(m[i], gi, one_minus_β1)
            root_vi = hypot(
                sqrt_β2 * root_v[i],
                sqrt_one_minus_β2 * gi,
            )
            m[i] = mi
            root_v[i] = root_vi
            normalized_step = _adam_normalized_step(
                mi, root_vi, first_correction,
                root_second_correction, ε)
            params[i] = _optimizer_parameter_step(
                params[i], lr, normalized_step)
        end

        if verbose && (iter % 10 == 0 || iter == 1)
            @info "Adam iter $iter/$n_iters: loss = $(round(current_loss, sigdigits=6))"
        end
    end

    return params, loss_history
end

"""
Compute numerical (finite difference) gradients for validation.

Uses second-order accurate central differences (O(δ²) error) so that this
serves as a trustworthy oracle for the automatic-differentiation gradients.
"""
function numerical_gradient(f, params::Vector{Float64}; δ=1e-5)
    δ isa Bool && throw(ArgumentError("numerical_gradient δ must be finite and non-zero"))
    (isfinite(δ) && δ != 0) ||
        throw(ArgumentError("numerical_gradient δ must be finite and non-zero"))
    n = length(params)
    grad = Vector{Float64}(undef, n)
    work = copy(params)
    for i in 1:n
        copyto!(work, params)
        work[i] += δ
        f_plus = f(work)
        copyto!(work, params)
        work[i] -= δ
        grad[i] = (f_plus - f(work)) / (2 * δ)
    end
    return grad
end

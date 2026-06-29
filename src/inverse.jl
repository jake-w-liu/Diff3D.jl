# --------------------------------------------------------------------------
# Inverse rendering utilities: gradient-based optimization of scene params.
# Uses ForwardDiff for gradient computation.
# --------------------------------------------------------------------------

using ForwardDiff

struct _ForwardDiffValueGradientConfig{N,Tag}
    dual_params::Vector{ForwardDiff.Dual{Tag,Float64,N}}
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

Returns: (optimized_params, loss_history)
"""
function inverse_render_optimize(initial_params::Vector{Float64},
                                 target_image::Array{Float64, 3},
                                 render_fn::Function,
                                 loss_fn::Function;
                                 lr=0.01,
                                 n_iters=100,
                                 verbose=true)
    n_iters >= 0 || throw(ArgumentError("n_iters must be non-negative"))
    params = copy(initial_params)
    loss_history = Vector{Float64}(undef, n_iters)

    function objective(p)
        img = render_fn(p)
        loss_fn(img, target_image)
    end

    grad = similar(params)
    grad_cfg = _forwarddiff_value_gradient_config(objective, params)

    for iter in 1:n_iters
        current_loss = _forwarddiff_value_and_gradient!(grad, objective, params, grad_cfg)
        loss_history[iter] = current_loss

        # Gradient descent step
        @inbounds for i in eachindex(params, grad)
            params[i] -= lr * grad[i]
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
"""
function inverse_render_adam(initial_params::Vector{Float64},
                            target_image::Array{Float64, 3},
                            render_fn::Function,
                            loss_fn::Function;
                            lr=0.01,
                            β1=0.9, β2=0.999,
                            ε=1e-8,
                            n_iters=100,
                            verbose=true)
    n_iters >= 0 || throw(ArgumentError("n_iters must be non-negative"))
    params = copy(initial_params)
    n = length(params)
    m = zeros(n)  # first moment
    v = zeros(n)  # second moment
    grad = similar(params)
    loss_history = Vector{Float64}(undef, n_iters)

    function objective(p)
        img = render_fn(p)
        loss_fn(img, target_image)
    end

    one_minus_β1 = 1 - β1
    one_minus_β2 = 1 - β2
    grad_cfg = _forwarddiff_value_gradient_config(objective, params)

    for iter in 1:n_iters
        current_loss = _forwarddiff_value_and_gradient!(grad, objective, params, grad_cfg)
        loss_history[iter] = current_loss

        # Adam update
        inv_m_correction = 1 / (1 - β1^iter)
        inv_v_correction = 1 / (1 - β2^iter)
        @inbounds for i in eachindex(params, grad, m, v)
            gi = grad[i]
            mi = β1 * m[i] + one_minus_β1 * gi
            vi = β2 * v[i] + one_minus_β2 * gi * gi
            m[i] = mi
            v[i] = vi
            params[i] -= lr * (mi * inv_m_correction) /
                         (sqrt(vi * inv_v_correction) + ε)
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
    p_plus = copy(params)
    p_minus = copy(params)
    for i in 1:n
        copyto!(p_plus, params)
        copyto!(p_minus, params)
        p_plus[i] += δ
        p_minus[i] -= δ
        grad[i] = (f(p_plus) - f(p_minus)) / (2 * δ)
    end
    return grad
end

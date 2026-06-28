# --------------------------------------------------------------------------
# Inverse rendering utilities: gradient-based optimization of scene params.
# Uses ForwardDiff for gradient computation.
# --------------------------------------------------------------------------

using ForwardDiff

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
    grad_cfg = ForwardDiff.GradientConfig(objective, params)

    for iter in 1:n_iters
        current_loss = objective(params)
        loss_history[iter] = current_loss

        ForwardDiff.gradient!(grad, objective, params, grad_cfg)

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

    grad_cfg = ForwardDiff.GradientConfig(objective, params)
    one_minus_β1 = 1 - β1
    one_minus_β2 = 1 - β2

    for iter in 1:n_iters
        current_loss = objective(params)
        loss_history[iter] = current_loss

        ForwardDiff.gradient!(grad, objective, params, grad_cfg)

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

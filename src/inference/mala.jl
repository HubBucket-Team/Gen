function mala(model::GenerativeFunction{T,U}, selection::AddressSet, trace::U, tau) where {T,U}
    model_args = get_call_record(trace).args
    std = sqrt(2 * tau)

    # forward proposal
    (_, values_trie, gradient_trie) = backprop_trace(model, trace, selection, nothing)
    values = to_array(values_trie, Float64)
    gradient = to_array(gradient_trie, Float64)
    forward_mu = values + tau * gradient
    forward_score = 0.
    proposed_values = Vector{Float64}(undef, length(values))
    for i=1:length(values)
        proposed_values[i] = random(normal, forward_mu[i], std)
        forward_score += logpdf(normal, proposed_values[i], forward_mu[i], std)
    end

    # evaluate model weight
    constraints = from_array(values_trie, proposed_values)
    (new_trace, weight, discard) = force_update(
        model, model_args, noargdiff, trace, constraints)

    # backward proposal
    (_, _, backward_gradient_trie) = backprop_trace(model, new_trace, selection, nothing)
    backward_gradient = to_array(backward_gradient_trie, Float64)
    @assert length(backward_gradient) == length(values)
    backward_score = 0.
    backward_mu  = proposed_values + tau * backward_gradient
    for i=1:length(values)
        backward_score += logpdf(normal, values[i], backward_mu[i], std)
    end

    # accept or reject
    alpha = weight - forward_score + backward_score
    if log(rand()) < alpha
        return new_trace
    else
        return trace
    end
end

export mala

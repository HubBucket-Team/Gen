using Gen
import Random

include("dynamic_model.jl")
include("dataset.jl")

@gen function gibbs_proposal(prev, i::Int)
    prev_args = get_call_record(prev).args
    constraints = DynamicAssignment()
    constraints[:data => i => :z] = false
    (_, weight1) = force_update(model, prev_args, noargdiff, prev, constraints)
    constraints[:data => i => :z] = true
    (_, weight2) = force_update(model, prev_args, noargdiff, prev, constraints)
    prob_true = exp(weight2- logsumexp([weight1, weight2]))
    @addr(bernoulli(prob_true), :data => i => :z)
end

slope_intercept_selection = DynamicAddressSet()
push!(slope_intercept_selection, :slope)
push!(slope_intercept_selection, :intercept)

std_selection = DynamicAddressSet()
push!(std_selection, :log_inlier_std)
push!(std_selection, :log_outlier_std)

function do_inference(xs, ys, num_iters)
    observations = DynamicAssignment()
    for (i, y) in enumerate(ys)
        observations[:data => i => :y] = y
    end
    observations[:log_inlier_std] = 0.
    observations[:log_outlier_std] = 0.
 
    # initial trace
    (trace, _) = initialize(model, (xs,), observations)

    scores = Vector{Float64}(undef, num_iters)
    for i=1:num_iters
        trace = map_optimize(model, slope_intercept_selection, trace, max_step_size=1., min_step_size=1e-10)
        trace = map_optimize(model, std_selection, trace, max_step_size=1., min_step_size=1e-10)
    
        # gibbs step on the outliers
        for j=1:length(xs)
            trace = custom_mh(model, gibbs_proposal, (j,), trace)
        end
    
        score = get_call_record(trace).score
        scores[i] = score
    
        # print
        assignment = get_assignment(trace)
        slope = assignment[:slope]
        intercept = assignment[:intercept]
        inlier_std = exp(assignment[:log_inlier_std])
        outlier_std = exp(assignment[:log_outlier_std])
        println("score: $score, slope: $slope, intercept: $intercept, inlier_std: $inlier_std, outlier_std: $outlier_std")
    end
    return scores
end

(xs, ys) = make_data_set(200)
do_inference(xs, ys, 10)
@time scores = do_inference(xs, ys, 100)
println(scores)

using PyPlot

figure(figsize=(4, 2))
plot(scores)
ylabel("Log probability density")
xlabel("Iterations")
tight_layout()
savefig("dynamic_map_optimize_gibbs_scores.png")

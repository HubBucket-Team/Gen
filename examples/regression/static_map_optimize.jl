using Gen
import Random

include("static_model.jl")
include("dataset.jl")

@staticgen function flip_z(z::Bool)
    @addr(bernoulli(z ? 0.0 : 1.0), :z)
end

data_proposal = at_dynamic(flip_z, Int)

@staticgen function is_outlier_proposal(prev, i::Int)
    prev_z::Bool = get_assignment(prev)[:data => i => :z]
    @addr(data_proposal(i, (prev_z,)), :data) 
end

Gen.load_generated_functions()

slope_intercept_selection = let
    s = DynamicAddressSet()
    push!(s, :slope)
    push!(s, :intercept)
    StaticAddressSet(s)
end

std_selection = let
    s = DynamicAddressSet()
    push!(s, :log_inlier_std)
    push!(s, :log_outlier_std)
    StaticAddressSet(s)
end

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
    
        # step on the outliers
        for j=1:length(xs)
            trace = custom_mh(model, is_outlier_proposal, (j,), trace)
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
@time scores = do_inference(xs, ys, 50)
println(scores)

using PyPlot

figure(figsize=(4, 2))
plot(scores)
ylabel("Log probability density")
xlabel("Iterations")
tight_layout()
savefig("static_map_optimize_scores.png")

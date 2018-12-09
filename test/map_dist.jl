@testset "map_dist combinator" begin

    foo = MapDist(normal)
    mus = [1, 2, 3]
    stds = [0.1, 0.2, 0.3]

    # test initialize
    z1, z3 = 1.1, 3.3
    constraints = DynamicAssignment()
    constraints[1] = z1
    constraints[3] = z3
    (trace, weight) = initialize(foo, (mus, stds), constraints)
    assmt = get_assignment(trace)
    @test assmt[1] == z1
    z2 = assmt[2]
    @test assmt[3] == z3
    @test isapprox(weight, logpdf(normal, z1, 1, 0.1) + logpdf(normal, z3, 3, 0.3))

    # test propose
    # TODO
    #assmt = get_assignment(simulate(foo, (mus, stds)))
    #@test has_leaf_node(assmt, 1)
    #@test has_leaf_node(assmt, 2)
    #@test has_leaf_node(assmt, 3)
    #@test length(collect(get_subassmts_shallow(assmt))) == 0

    # test assess
    # TODO 
    #z1, z2, z3 = 1.1, 2.2, 3.3
    #constraints = DynamicAssignment()
    #constraints[1] = z1
    #constraints[2] = z2
    #constraints[3] = z3
    #trace = assess(foo, (mus, stds), constraints)
    #assmt = get_assignment(trace)
    #@test assmt[1] == z1
    #@test assmt[2] == z2
    #@test assmt[3] == z3
    #score = get_score(trace)
    #@test isapprox(score, logpdf(normal, z1, 1, 0.1) + logpdf(normal, z2, 2, 0.2) + logpdf(normal, z3, 3, 0.3))

    # test force_update
    z2_new = 3.3
    constraints = DynamicAssignment()
    constraints[2] = z2_new
    (trace, weight, discard, retchange) = force_update(foo, (mus, stds), noargdiff, trace, constraints)
    assmt = get_assignment(trace)
    @test assmt[1] == z1
    @test assmt[2] == z2_new
    @test assmt[3] == z3
    @test discard[2] == z2
    @test length(collect(get_values_shallow(discard))) == 1
    @test length(collect(get_subassmts_shallow(discard))) == 0
    @test isapprox(weight, logpdf(normal, z2_new, 2, 0.2) - logpdf(normal, z2, 2, 0.2))

    # test backprop_trace
    # TODO
end

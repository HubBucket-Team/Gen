"""
No change to the arguments for any retained application
"""
function process_all_retained!(gen::Map{T,U}, args::Tuple, argdiff::NoArgDiff,
                               constraints_or_selections::Dict{Int,Any},
                               prev_length::Int, new_length::Int,
                               retained_constrained_or_selected,
                               state) where {T,U}
    # only visit retained applications that were constrained
    for key in retained_constrained_or_selected
        @assert key <= min(new_length, prev_length)
        process_retained!(gen, args, constraints_or_selections, key, noargdiff, state)
    end
end

"""
Unknown change to the arguments for retained applications
"""
function process_all_retained!(gen::Map{T,U}, args::Tuple, argdiff::UnknownArgDiff,
                               constraints_or_selections::Dict{Int,Any},
                               prev_length::Int, new_length::Int,
                               retained_constrained_or_selected,
                               state) where {T,U}
    # visit every retained application
    for key in 1:min(prev_length, new_length)
        @assert key <= min(new_length, prev_length)
        process_retained!(gen, args, constraints_or_selections, key, unknownargdiff, state)
    end
end

"""
Custom argdiffs for some retained applications
"""
function process_all_retained!(gen::Map{T,U}, args::Tuple, argdiff::MapCustomArgDiff{T},
                               constraints_or_selections::Dict{Int,Any},
                               prev_length::Int, new_length::Int,
                               retained_constrained_or_selected,
                               state) where {T,U}
    # visit every retained applications with a custom argdiff or constraints
    for key in union(keys(argdiff.retained_argdiffs), retained_constrained_or_selected)
        @assert key <= min(new_length, prev_length)
        if haskey(argdiff.retained_retdiffs, key)
            subargdiff = retained_retdiffs[key]
        else
            subargdiff = noargdiff
        end
        process_retained!(gen, args, constraints_or_selections, key, subargdiff, state)
    end
end

"""
Process all new applications.
"""
function process_all_new!(gen::Map{T,U}, args::Tuple, constraints_or_selections::Dict{Int,Any},
                          prev_len::Int, new_len::Int,
                          state) where {T,U}
    for key=prev_len+1:new_len
        process_new!(gen, arg, constraints_or_selections, key, state)
    end
end

function get_trace_and_weight(args::Tuple, prev_trace::VectorTrace{T,U}, state) where {T,U}
    call = CallRecord(state.score, state.retvals, args)
    trace = VectorTrace{T,U}(state.subtraces, state.retvals, args, state.score,
                        state.len, state.num_has_choices)
    prev_score = get_call_record(prev_trace).score
    weight = state.score - prev_score
    (trace, weight)
end


################
# force update #
################

mutable struct MapUpdateState{T,U}
    score::Float64
    subtraces::PersistentVector{U}
    retvals::PersistentVector{T}
    discard::DynamicAssignment
    len::Int
    num_has_choices::Int
    isdiff_retdiffs::Dict{Int,Any}
end

function process_retained!(gen::Map{T,U}, args::Tuple,
                           constraints::Dict{Int,Any}, key::Int, kernel_argdiff,
                           state::MapUpdateState{T,U}) where {T,U}
    
    # check for constraint
    if haskey(constraints, key)
        subconstraints = constraints[key]
    else
        subconstraints = EmptyAssignment()
    end

    # arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get new subtrace with recursive call to force_update()
    prev_subtrace = state.subtraces[key]
    prev_call = get_call_record(prev_subtrace)
    (subtrace, _, kernel_discard, subretdiff) = force_update(
        gen.kernel, kernel_args, kernel_argdiff, prev_subtrace, subconstraints)
    if !isnodiff(subretdiff)
        state.isdiff_retdiffs[key] = subretdiff
    end

    # update state
    set_internal_node!(state.discard, key, kernel_discard)
    call = get_call_record(subtrace)
    state.score += (call.score - prev_call.score)
    state.subtraces = assoc(state.subtraces, key, subtrace)
    state.retvals = assoc(state.retvals, key, call.retval::T)
    if has_choices(subtrace) && !has_choices(prev_subtrace)
        state.num_has_choices += 1
    elseif !has_choices(subtrace) && has_choices(prev_subtrace)
        state.num_has_choices -= 1
    end
end

function process_new!(gen::Map{T,U}, args::Tuple, 
                      constraints::Dict{Int,Any}, key::Int,
                      state::MapUpdateState{T,U}) where {T,U}

    # check for constraint
    if haskey(constraints, key)
        subconstraints = constraints[key]
    else
        subconstraints = EmptyAssignment()
    end

    # extract arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get subtrace
    (subtrace::U, _) = initialize(gen.kernel, kernel_args, subconstraints)

    # update state
    call = get_call_record(subtrace)
    state.score += call.score
    retval::T = call.retval
    if key <= length(state.subtraces)
        state.subtraces = assoc(state.subtraces, key, subtrace)
        state.retvals = assoc(state.retvals, key, retval)
    else
        state.subtraces = push(state.subtraces, subtrace)
        state.retvals = push(state.retvals, retval)
        @assert length(state.subtraces) == key
    end
    @assert state.len == key - 1
    state.len = key
    if has_choices(subtrace)
        state.num_has_choices += 1
    end
end

function force_update(gen::Map{T,U}, args::Tuple, argdiff, prev_trace::VectorTrace{T,U},
                constraints::Assignment) where {T,U}
    (new_length, prev_length) = get_prev_and_new_lengths(args, prev_trace)
    (nodes, retained_constrained) = collect_map_constraints(constraints, prev_length, new_length)
    (discard, num_has_choices) = discard_deleted_applications(new_length, prev_length, prev_trace)
    state = MapUpdateState{T,U}(prev_trace.call.score,
                                  prev_trace.subtraces, prev_trace.call.retval,
                                  discard, min(prev_length, new_length), num_has_choices,
                                  Dict{Int,Any}())
    process_all_retained!(gen, args, argdiff, nodes, prev_length, new_length, retained_constrained, state)
    process_all_new!(gen, args, nodes, prev_length, new_length, state)
    (trace, weight) = get_trace_and_weight(args, prev_trace, state)
    retdiff = compute_retdiff(state.isdiff_retdiffs, new_length, prev_length)
    return (trace, weight, discard, retdiff)
end


##########
# extend #
##########

mutable struct MapExtendState{T,U}
    score::Float64
    weight::Float64
    subtraces::PersistentVector{U}
    retvals::PersistentVector{T}
    len::Int
    num_has_choices::Bool
    isdiff_retdiffs::Dict{Int,Any}
end

function process_retained!(gen::Map{T,U}, args::Tuple,
                           constraints::Dict{Int,Any}, key::Int, kernel_argdiff,
                           state::MapExtendState{T,U}) where {T,U}
    
    # check for constraint
    if haskey(constraints, key)
        subconstraints = constraints[key]
    else
        subconstraints = EmptyAssignment()
    end

    # arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get new subtrace with recursive call to extend()
    prev_subtrace = state.subtraces[key]
    prev_call = get_call_record(subtrace)
    (subtrace, _, subretdiff) = extend(
        gen.kernel, kernel_args, kernel_argdiff, prev_subtrace, subconstraints)
    if !isnodiff(subretdiff)
        state.isdiff_retdiffs[key] = subretdiff
    end

    # update state
    call = get_call_record(subtrace)
    state.score += (call.score - prev_call.score)
    state.subtraces = assoc(state.subtraces, key, subtrace)
    state.retvals = assoc(state.retvals, key, call.retval::T)
    if has_choices(subtrace) && !has_choices(prev_subtrace)
        state.num_has_choices += 1
    elseif !has_choices(subtrace) && has_choices(prev_subtrace)
        state.num_has_choices -= 1
    end
end

function process_new!(gen::Map{T,U}, args::Tuple, 
                      constraints::Dict{Int,Any}, key::Int,
                      state::MapExtendState{T,U}) where {T,U}

    # check for constraint
    if haskey(constraints, key)
        subconstraints = constraints[key]
    else
        subconstraints = EmptyAssignment()
    end

    # extract arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get subtrace
    (subtrace, weight) = initialize(gen.kernel, kernel_args, subconstraints)

    # update state
    call = get_call_record(subtrace)
    state.score += call.score
    state.weight += weight
    retval::T = call.retval
    if key <= length(state.subtraces)
        state.subtraces = assoc(state.subtraces, key, subtrace)
        state.retvals = assoc(state.retvals, key, retval)
    else
        state.subtraces = push(state.subtraces, subtrace)
        state.retvals = push(state.retvals, retval)
        @assert length(state.subtraces) == key
    end
    @assert state.len == key - 1
    state.len = key
    if has_choices(subtrace)
        state.num_has_choices += 1
    end
end

function extend(gen::Map{T,U}, args::Tuple, argdiff, prev_trace::VectorTrace{T,U},
                constraints::Assignment) where {T,U}
    (new_length, prev_length) = get_prev_and_new_lengths(args, prev_trace)
    if new_length < prev_length
        error("Extend cannot remove addresses (prev length: $prev_length, new length: $new_length")
    end
    (nodes, retained_constrained) = collect_map_constraints(constraints, prev_length, new_length)
    state = MapExtendState{T,U}(prev_trace.call.score, 0.,
                                  prev_trace.subtraces, prev_trace.call.retval,
                                  prev_length, prev_trace.num_has_choices)
    process_all_retained!(gen, args, argdiff, nodes, prev_length, new_length, retained_constrained, state)
    process_all_new!(gen, args, nodes, prev_length, new_length, state)
    (trace, weight) = get_trace_and_weight(args, prev_trace, state)
    retdiff = compute_retdiff(state.isdiff_retdiffs, new_length, prev_length)
    return (trace, weight, retdiff)
end

##############
# regenerate #
##############

mutable struct MapRegenerateState{T,U}
    score::Float64
    subtraces::PersistentVector{U}
    retvals::PersistentVector{T}
    len::Int
    num_has_choices::Int
    isdiff_retdiffs::Dict{Int,Any}
end

function process_retained!(gen::Map{T,U}, args::Tuple,
                           selections::Dict{Int,Any}, key::Int, kernel_argdiff,
                           state::MapRegenerateState{T,U}) where {T,U}
    
    # check for constraint
    if haskey(selections, key)
        subselection = selections[key]
    else
        subselection = EmptyAddressSet()
    end

    # arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get new subtrace with recursive call to free_update()
    prev_subtrace = state.subtraces[key]
    prev_call = get_call_record(prev_subtrace)
    (subtrace, weight, subretdiff) = free_update(
        gen.kernel, kernel_args, kernel_argdiff, prev_subtrace, subselection)
    if !isnodiff(subretdiff)
        state.isdiff_retdiffs[key] = subretdiff
    end

    # update state
    call = get_call_record(subtrace)
    state.score += (call.score - prev_call.score)
    state.subtraces = assoc(state.subtraces, key, subtrace)
    state.retvals = assoc(state.retvals, key, call.retval::T)
    if has_choices(subtrace) && !has_choices(prev_subtrace)
        state.num_has_choices += 1
    elseif !has_choices(subtrace) && has_choices(prev_subtrace)
        state.num_has_choices -= 1
    end
end

function process_new!(gen::Map{T,U}, args::Tuple, 
                      selections::Dict{Int,Any}, key::Int,
                      state::MapRegenerateState{T,U}) where {T,U}

    # check for subselection (cannot select addresses that do not already exist)
    @assert !haskey(selections, key)

    # extract arguments for this application
    kernel_args = get_args_for_key(args, key)

    # get subtrace
    subtrace::U = simulate(gen.kernel, kernel_args)

    # update state
    call = get_call_record(subtrace)
    state.score += call.score
    retval::T = call.retval
    if key <= length(state.subtraces)
        state.subtraces = assoc(state.subtraces, key, subtrace)
        state.retvals = assoc(state.retvals, key, retval)
    else
        state.subtraces = push(state.subtraces, subtrace)
        state.retvals = push(state.retvals, retval)
        @assert length(state.subtraces) == key
    end
    @assert state.len == key - 1
    state.len = key
    if has_choices(subtrace)
        state.num_has_choices += 1
    end
end

function free_update(gen::Map{T,U}, args::Tuple, argdiff, prev_trace::VectorTrace{T,U},
                     selection::AddressSet) where {T,U}
    (new_length, prev_length) = get_prev_and_new_lengths(args, prev_trace)
    selections = collect_map_selections(selection, prev_length, new_length)
    state = MapRegenerateState{T,U}(prev_trace.call.score,
                                      prev_trace.subtraces, prev_trace.call.retval,
                                      min(prev_length, new_length), prev_trace.num_has_choices,
                                      Dict{Int,Any}())
    process_all_retained!(gen, args, argdiff, selections, prev_length, new_length, keys(selections), state)
    process_all_new!(gen, args, selections, prev_length, new_length, state)
    (trace, weight) = get_trace_and_weight(args, prev_trace, state)
    retdiff = compute_retdiff(state.isdiff_retdiffs, new_length, prev_length)
    return (trace, weight, retdiff)
end

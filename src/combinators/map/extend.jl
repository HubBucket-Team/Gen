mutable struct MapExtendUpdateState{T,U}
    weight::Float64
    score::Float64
    noise::Float64
    subtraces::PersistentVector{U}
    retval::PersistentVector{T}
    len::Int
    num_nonempty::Int
    isdiff_retdiffs::Dict{Int,Any}
end

function process_retained!(gen_fn::Map{T,U}, args::Tuple,
                           assmt::Assignment, key::Int, kernel_argdiff,
                           state::MapExtendUpdateState{T,U}) where {T,U}
    local subtrace::U
    local prev_subtrace::U
    local retval::T

    subassmt = get_subassmt(assmt, key)
    kernel_args = get_args_for_key(args, key)

    # get new subtrace with recursive call to extend()
    prev_subtrace = state.subtraces[key]
    (subtrace, weight, subretdiff) = extend(
        kernel_args, kernel_argdiff, prev_subtrace, subassmt)

    # retrieve retdiff
    if !isnodiff(subretdiff)
        state.isdiff_retdiffs[key] = subretdiff
    end

    # update state
    state.weight += weight
    state.score += (get_score(subtrace) - get_score(prev_subtrace))
    state.noise += (project(subtrace, EmptyAddressSet()) - project(subtrace, EmptyAddressSet()))
    state.subtraces = assoc(state.subtraces, key, subtrace)
    retval = get_retval(subtrace)
    state.retval = assoc(state.retval, key, retval)
    subtrace_empty = isempty(get_assignment(subtrace))
    prev_subtrace_empty = isempty(get_assignment(prev_subtrace))
    @assert !(subtrace_empty && !prev_subtrace_empty)
    if !subtrace_empty && prev_subtrace_empty
        state.num_nonempty += 1
    end
end

function process_new!(gen_fn::Map{T,U}, args::Tuple, assmt, key::Int,
                      state::MapExtendUpdateState{T,U}) where {T,U}
    local subtrace::U
    local retval::T

    subassmt = get_subassmt(assmt, key)
    kernel_args = get_args_for_key(args, key)

    # get subtrace and weight
    (subtrace, weight) = initialize(gen_fn.kernel, kernel_args, subassmt)

    # update state
    state.weight += weight
    state.score += get_score(subtrace)
    retval = get_retval(subtrace)
    if key <= length(state.subtraces)
        state.subtraces = assoc(state.subtraces, key, subtrace)
        state.retval = assoc(state.retval, key, retval)
    else
        state.subtraces = push(state.subtraces, subtrace)
        state.retval = push(state.retval, retval)
        @assert length(state.subtraces) == key
    end
    @assert state.len == key - 1
    state.len = key
    if !isempty(get_assignment(subtrace))
        state.num_nonempty += 1
    end
end


function extend(args::Tuple, argdiff, trace::VectorTrace{MapType,T,U},
                assmt::Assignment) where {T,U}
    gen_fn = trace.gen_fn
    (new_length, prev_length) = get_prev_and_new_lengths(args, trace)
    if new_length < prev_length
        error("Cannot decrease number of applications from $new_length to $prev_length in map extend")
    end
    retained_and_constrained = get_retained_and_constrained(assmt, prev_length, new_length)
    state = MapExtendUpdateState{T,U}(0., trace.score, trace.noise,
        trace.subtraces, trace.retval, min(prev_length, new_length),
        trace.num_nonempty, Dict{Int,Any}())
    process_all_retained!(gen_fn, args, argdiff, assmt, prev_length, new_length, retained_and_constrained, state)
    process_all_new!(gen_fn, args, assmt, prev_length, new_length, state)
    retdiff = compute_retdiff(state.isdiff_retdiffs, new_length, prev_length)
    new_trace = VectorTrace{MapType,T,U}(gen_fn, state.subtraces, state.retval, args,  
        state.score, state.noise, state.len, state.num_nonempty)

    (new_trace, state.weight, retdiff)
end

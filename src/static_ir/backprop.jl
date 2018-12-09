const gradient_prefix = gensym("gradient")
gradient_var(node::RegularNode) = Symbol("$(gradient_prefix)_$(node.name)")

const value_trie_prefix = gensym("value_trie")
value_trie_var(node::GenerativeFunctionCallNode) = Symbol("$(value_trie_prefix)_$(node.addr)")

const gradient_trie_prefix = gensym("gradient_trie")
gradient_trie_var(node::GenerativeFunctionCallNode) = Symbol("$(gradient_trie_prefix)_$(node.addr)")

function fwd_pass!(selected_choices, selected_calls, fwd_marked, node::ArgumentNode)
    if node.compute_grad
        push!(fwd_marked, node)
    end
end

function fwd_pass!(selected_choices, selected_calls, fwd_marked, node::JuliaNode)
    if any(input_node in fwd_marked for input_node in node.inputs)
        push!(fwd_marked, node)
    end
end

function fwd_pass!(selected_choices, selected_calls, fwd_marked, node::RandomChoiceNode)
    if node in selected_choices
        push!(fwd_marked, node)
    end
end

function fwd_pass!(selected_choices, selected_calls, fwd_marked, node::GenerativeFunctionCallNode)
    if node in selected_calls || any(input_node in fwd_marked for input_node in node.inputs)
        push!(fwd_marked, node)
    end
end

function fwd_pass!(selected_choices, selected_calls, fwd_marked, ::DiffNode) end

function back_pass!(back_marked, node::ArgumentNode) end

function back_pass!(back_marked, node::JuliaNode)
    if node in back_marked
        for input_node in node.inputs
            push!(back_marked, input_node)
        end
    end
end

function back_pass!(back_marked, node::RandomChoiceNode)
    # the logpdf of every random choice is a SINK
    for input_node in node.inputs
        push!(back_marked, input_node)
    end
    # the value of every random choice is in back_marked, since it affects its logpdf
    push!(back_marked, node) 
end

function back_pass!(back_marked, node::GenerativeFunctionCallNode)
    # the logpdf of every generative function call is a SINK
    for input_node in node.inputs
        push!(back_marked, input_node)
    end
end

function back_pass!(back_marked, ::DiffNode) end

function fwd_codegen!(stmts, fwd_marked, back_marked, node::ArgumentNode)
    if node in fwd_marked && node in back_marked

        # initialize gradient to zero
        push!(stmts, :($(gradient_var(node)) = zero($(node.name))))
    end
end

function fwd_codegen!(stmts, fwd_marked, back_marked, node::JuliaNode)

    # we need the value for initializing gradient to zero (to get the type and
    # e.g. shape), and for reference by other nodes during back_codegen! we
    # could be more selective about which JuliaNodes need to be evalutaed, that
    # is a performance optimization for the future
    args = map((input_node) -> input_node.name, node.inputs)
    push!(stmts, :($(node.name) = $(QuoteNode(node.fn))($(args...))))

    if node in back_marked && any(input_node in fwd_marked for input_node in node.inputs)

        # initialize gradient to zero
        push!(stmts, :($(gradient_var(node)) = zero($(node.name))))
    end
end

function fwd_codegen!(stmts, fwd_marked, back_marked, node::RandomChoiceNode)
    # for reference by other nodes during back_codegen!
    # could performance optimize this away
    push!(stmts, :($(node.name) = trace.$(get_value_fieldname(node))))

    # every random choice is in back_marked, since it affects it logpdf, but
    # also possibly due to other downstream usage of the value
    @assert node in back_marked 

    if node in fwd_marked
        # the only way we are fwd_marked is if this choice was selected

        # initialize gradient with respect to the value of the random choice to zero
        # it will be a runtime error, thrown here, if there is no zero() method
        push!(stmts, :($(gradient_var(node)) = zero($(node.name))))
    end
end

function fwd_codegen!(stmts, fwd_marked, back_marked, node::GenerativeFunctionCallNode)
    # for reference by other nodes during back_codegen!
    # could performance optimize this away
    subtrace_fieldname = get_subtrace_fieldname(node)
    push!(stmts, :($(node.name) = get_retval(trace.$subtrace_fieldname)))

    # NOTE: we will still potentially run backprop_trace recursively on the generative function,
    # we just might not use its return value gradient.
    if node in fwd_marked && node in back_marked
        # we are fwd_marked if an input was fwd_marked, or if we were selected internally
        push!(stmts, :($(gradient_var(node)) = zero($(node.name))))
    end
end

function fwd_codegen!(stmts, fwd_marked, back_marked, ::DiffNode) end

function back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, node::ArgumentNode)

    # handle case when it is the return node
    if node === ir.return_node && node in fwd_marked
        @assert node in back_marked
        push!(stmts, :($(gradient_var(node)) += retval_grad))
    end
end

function back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, node::JuliaNode)
    # handle case when it is the return node
    if node === ir.return_node && node in fwd_marked
        @assert node in back_marked
        push!(stmts, :($(gradient_var(node)) += retval_grad))
    end
    if node in back_marked && any(input_node in fwd_marked for input_node in node.inputs)

        # compute gradient with respect to parents
        # NOTE: some of the fields in this tuple may be 'nothing'
        input_grads = gensym("input_grads")
        args = map((input_node) -> input_node.name, node.inputs)
        args_tuple = Expr(:tuple, args...)
        push!(stmts, :($input_grads::Tuple = $(QuoteNode(node.grad_fn))($(gradient_var(node)), $(node.name), $args_tuple)))

        # increment gradients of input nodes that are in fwd_marked
        for (i, input_node) in enumerate(node.inputs)
            
            # NOTE: it will be a runtime error if we try to add 'nothing'
            # we could require the JuliaNode to statically report which inputs
            # it takes gradients with respect to, and check this at compile
            # time. TODO future work
            if input_node in fwd_marked
                push!(stmts, :($(gradient_var(input_node)) += $input_grads[$(QuoteNode(i))]))
            end
        end
    end

end

function back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, node::RandomChoiceNode)

    # only evaluate the gradient of the logpdf if we need to
    if any(input_node in fwd_marked for input_node in node.inputs) || node in fwd_marked
        logpdf_grad = gensym("logpdf_grad")
        args = map((input_node) -> input_node.name, node.inputs)
        push!(stmts, :($logpdf_grad = logpdf_grad($(node.dist), $(node.name), $(args...))))
    end

    # increment gradients of input nodes that are in fwd_marked
    for (i, input_node) in enumerate(node.inputs)
        if input_node in fwd_marked
            @assert input_node in back_marked # this ensured its gradient will have been initialized
            if !has_argument_grads(node.dist)[i]
                error("Distribution $dist does not have logpdf gradient for argument $i")
            end
            push!(stmts, :($(gradient_var(input_node)) += $logpdf_grad[$(QuoteNode(i+1))]))
        end
    end

    # handle case when it is the return node
    if node === ir.return_node && node in fwd_marked
        @assert node in back_marked
        push!(stmts, :($(gradient_var(node)) += retval_grad))
    end

    # backpropagate to the value (if it was selected)
    if node in fwd_marked
        if !has_output_grad(node.dist)
            error("Distribution $dist does not logpdf gradient for its output value")
        end
        push!(stmts, :($(gradient_var(node)) += $logpdf_grad[1]))
    end
end

function back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, node::GenerativeFunctionCallNode)

    # handle case when it is the return node
    if node === ir.return_node && node in fwd_marked
        @assert node in back_marked
        push!(stmts, :($(gradient_var(node)) += retval_grad))
    end

    if node in fwd_marked
        input_grads = gensym("call_input_grads")
        value_trie = value_trie_var(node)
        gradient_trie = gradient_trie_var(node)
        subtrace_fieldname = get_subtrace_fieldname(node)
        call_selection = gensym("call_selection")
        if node in selected_calls
            push!(stmts, :($call_selection = static_get_internal_node(selection, $(QuoteNode(Val(node.addr))))))
        else
            push!(stmts, :($call_selection = EmptyAddressSet()))
        end
        if node in back_marked
            retval_grad = gradient_var(node)
        else
            retval_grad = :(nothing)
        end
        push!(stmts, :(($input_grads, $value_trie, $gradient_trie) = backprop_trace(
            $(node.generative_function), trace.$subtrace_fieldname, $call_selection, $retval_grad)))
    end

    # increment gradients of input nodes that are in fwd_marked
    for (i, input_node) in enumerate(node.inputs)
        if input_node in fwd_marked
            @assert input_node in back_marked # this ensured its gradient will have been initialized
            push!(stmts, :($(gradient_var(input_node)) += $input_grads[$(QuoteNode(i))]))
        end
    end

    # NOTE: the value_trie and gradient_trie are dealt with later
end

function back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, ::DiffNode) end

function generate_value_gradient_trie(selected_choices::Set{RandomChoiceNode},
                                      selected_calls::Set{GenerativeFunctionCallNode},
                                      value_trie::Symbol, gradient_trie::Symbol)
    selected_choices_vec = collect(selected_choices)
    quoted_leaf_keys = map((node) -> QuoteNode(node.addr), selected_choices_vec)
    leaf_values = map((node) -> :(trace.$(get_value_fieldname(node))), selected_choices_vec)
    leaf_gradients = map((node) -> gradient_var(node), selected_choices_vec)

    selected_calls_vec = collect(selected_calls)
    quoted_internal_keys = map((node) -> QuoteNode(node.addr), selected_calls_vec)
    internal_values = map((node) -> :(get_assignment(trace.$(get_subtrace_fieldname(node)))),
                          selected_calls_vec)
    internal_gradients = map((node) -> gradient_trie_var(node), selected_calls_vec)

    quote
        $value_trie = StaticAssignment(
            NamedTuple{($(quoted_leaf_keys...),)}(($(leaf_values...),)),
            NamedTuple{($(quoted_internal_keys...),)}(($(internal_values...),)))
        $gradient_trie = StaticAssignment(
            NamedTuple{($(quoted_leaf_keys...),)}(($(leaf_gradients...),)),
            NamedTuple{($(quoted_internal_keys...),)}(($(internal_gradients...),)))
    end
end

function get_selected_choices(::EmptyAddressSchema, ::StaticIR)
    Set{RandomChoiceNode}()
end

function get_selected_choices(schema::StaticAddressSchema, ir::StaticIR)
    selected_choice_addrs = Set(leaf_node_keys(schema))
    selected_choices = Set{RandomChoiceNode}()
    for node in ir.choice_nodes
        if node.addr in selected_choice_addrs
            push!(selected_choices, node)
        end
    end
    selected_choices
end

function get_selected_calls(::EmptyAddressSchema, ::StaticIR)
    Set{GenerativeFunctionCallNode}()
end

function get_selected_calls(schema::StaticAddressSchema, ir::StaticIR)
    selected_call_addrs = Set(internal_node_keys(schema))
    selected_calls = Set{GenerativeFunctionCallNode}()
    for node in ir.call_nodes
        if node.addr in selected_call_addrs
            push!(selected_calls, node)
        end
    end
    selected_calls
end

function codegen_backprop_trace(gen_fn_type::Type{T}, trace_type, selection_type,
                               retval_grad_type) where {T <: StaticIRGenerativeFunction}

    schema = get_address_schema(selection_type)

    # convert the selection to a static address set if it is not already one
    if !(isa(schema, StaticAddressSchema) || isa(schema, EmptyAddressSchema))
        return quote backprop_trace(gen, trace, StaticAddressSet(selection), retval_grad) end
    end

    ir = get_ir(gen_fn_type)
    selected_choices = get_selected_choices(schema, ir)
    selected_calls = get_selected_calls(schema, ir)

    # forward marking pass
    fwd_marked = Set{RegularNode}()
    for node in ir.nodes
        fwd_pass!(selected_choices, selected_calls, fwd_marked, node)
    end

    # backward marking pass
    back_marked = Set{RegularNode}()
    push!(back_marked, ir.return_node)
    for node in reverse(ir.nodes)
        back_pass!(back_marked, node)
    end

    stmts = Expr[]

    # unpack arguments from the trace
    arg_names = Symbol[arg_node.name for arg_node in ir.arg_nodes]
    push!(stmts, :($(Expr(:tuple, arg_names...)) = get_args(trace)))

    # forward code-generation pass (initialize gradients to zero, create needed references)
    for node in ir.nodes
        fwd_codegen!(stmts, fwd_marked, back_marked, node)
    end

    # backward code-generation pass (increment gradients)
    for node in reverse(ir.nodes)
        back_codegen!(stmts, ir, selected_calls, fwd_marked, back_marked, node)
    end

    # assemble value_trie and gradient_trie
    value_trie = gensym("value_trie")
    gradient_trie = gensym("gradient_trie")
    push!(stmts, generate_value_gradient_trie(selected_choices, selected_calls, 
        value_trie, gradient_trie))

    # gradients with respect to inputs
    arg_grad = (node::ArgumentNode) -> node.compute_grad ? gradient_var(node) : :(nothing)
    input_grads = Expr(:tuple, map(arg_grad, ir.arg_nodes)...)

    # return values
    push!(stmts, :(return ($input_grads, $value_trie, $gradient_trie)))
    
    Expr(:block, stmts...)
end

push!(Gen.generated_functions, quote
@generated function Gen.backprop_trace(gen::Gen.StaticIRGenerativeFunction{T,U}, trace::U,
                                       selection, retval_grad) where {T,U}
    Gen.codegen_backprop_trace(gen, trace, selection, retval_grad)
end
end)

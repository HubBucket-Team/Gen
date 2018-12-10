function backprop_trace(trace::VectorTrace{MapType,T,U}, selection::AddressSet,
                        retval_grad) where {T,U}

    args = get_args(trace)
    n_args = length(args)
    len = length(args[1])
    
    has_grads = has_argument_grads(trace.gen_fn.kernel)
    arg_grad = Vector(undef, n_args)
    for (i, has_grad) in enumerate(has_grads)
        if has_grad
            arg_grad[i] = Vector(undef, len)
        else
            arg_grad[i] = nothing
        end
    end
    
    value_trie = DynamicAssignment()
    gradient_trie = DynamicAssignment()
    
    for key=1:len
        subtrace = trace.subtraces[key]
        if has_internal_node(selection, key)
            sub_selection = get_internal_node(selection, key)
        else
            sub_selection = EmptyAddressSet()
        end
        kernel_retval_grad = (retval_grad == nothing) ? nothing : retval_grad[key]
        (kernel_arg_grad::Tuple, kernel_value_trie, kernel_gradient_trie) = backprop_trace(
            subtrace, sub_selection, kernel_retval_grad)
        set_subassmt!(value_trie, key, kernel_value_trie)
        set_subassmt!(gradient_trie, key, kernel_gradient_trie)
        for (i, grad, has_grad) in zip(1:n_args, kernel_arg_grad, has_grads)
            if has_grad
                arg_grad[i][key] = grad
            end
        end
    end
    ((arg_grad...,), value_trie, gradient_trie)
end

function backprop_params(trace::VectorTrace{MapType,T,U}, retval_grad) where {T,U}

    args = get_args(trace)
    n_args = length(args)
    len = length(args[1])
    
    has_grads = has_argument_grads(trace.gen_fn.kernel)
    arg_grad = Vector(undef, n_args)
    for (i, has_grad) in enumerate(has_grads)
        if has_grad
            arg_grad[i] = Vector(undef, len)
        else
            arg_grad[i] = nothing
        end
    end
    
    for key=1:len
        subtrace = trace.subtraces[key]
        kernel_retval_grad = (retval_grad == nothing) ? nothing : retval_grad[key]
        kernel_arg_grad::Tuple = backprop_params(subtrace, kernel_retval_grad)
        for (i, grad, has_grad) in zip(1:n_args, kernel_arg_grad, has_grads)
            if has_grad
                arg_grad[i][key] = grad
            end
        end
    end
    (arg_grad...,)
end

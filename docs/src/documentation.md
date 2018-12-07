# Gen Documentation

## Assignment

### Static Assignment

A `StaticAssignment` contains only symbols as its keys for leaf nodes and for internal nodes.
A `StaticAssignment` has type parameters`R` and `T` that are tuples of `Symbol`s that are the keys of the leaf nodes and internal nodes respectively, so that code can be generated that is specialized to the particular set of keys in the trie:

```julia
struct StaticAssignment{R,S,T,U} <: Assignment
    leaf_nodes::NamedTuple{R,S}
    internal_nodes::NamedTuple{T,U}
end 
```

A `StaticAssignment` with leaf symbols `:a` and `:b` and internal key `:c` can be constructed using syntax like:
```julia
trie = StaticAssignment((a=1, b=2), (c=inner_trie,))
```


## Generative Function Interface

Generative functions implement the *generative function interface*, which is a set of methods that involve the execution traces and probabilistic behavior of generative functions.
In the mathematical description of the interface methods, we denote arguments to a function by ``x``, complete assignments of values to addresses of random choices (containing all the random choices made during some execution) by ``t`` and partial assignments by either ``u`` or ``v``.
We denote a trace of a generative function by the tuple ``(x, t)``.
We say that two assignments ``u`` and ``t`` *agree* when they assign addresses that appear in both assignments to the same values (they can different or even disjoint sets of addresses and still agree).
A generative function is associated with a family of probability distributions ``P(t; x)`` on assignments ``t``, parameterized by arguments ``x``, and a second family of distributions ``Q(t; u, x)`` on assignments ``t`` parameterized by partial assignment ``u`` and arguments ``x``.
``Q`` is called the *internal proposal family* of the generative function, and satisfies that if ``u`` and ``t`` agree then ``P(t; x) > 0`` if and only if ``Q(t; x, u) > 0``, and that ``Q(t; x, u) > 0`` implies that ``u`` and ``t`` agree.
See the [Gen technical report](http://hdl.handle.net/1721.1/119255) for additional details.

Generative functions may also use *non-addressable random choices*, denoted ``r``.
Unlike regular (addressable) random choices, non-addressable random choices do not have addresses, and the value of non-addressable random choices is not exposed through the generative function interface.
However, the state of non-addressable random choices is maintained in the trace.
A trace that contains non-addressable random choices is denoted ``(x, t, r)``.
Non-addressable random choices manifest to the user of the interface as stochasticity in weights returned by generative function interface methods.
The behavior of non-addressable random choices is defined by an additional pair of families of distributions associated with the generative function, denoted ``Q(r; x, t)`` and ``P(r; x, t)``, which are defined for ``P(t; x) > 0``, and which satisfy ``Q(r; x, t) > 0`` if and only if ``P(r; x, t) > 0``.
For each generative function below, we describe its semantics first in the basic setting where there is no non-addressable random choices, and then in the more general setting that may include non-addressable random choices.

```@docs
initialize
project
propose
assess
force_update
fix_update
free_update
extend
backprop_params
backprop_trace
```

## Distributions

Probability distributions are singleton types whose supertype is `Distribution{T}`, where `T` indicates the data type of the random sample.

```julia
abstract type Distribution{T} end
```

By convention, distributions have a global constant lower-case name for the singleton value.
For example:

```julia
struct Bernoulli <: Distribution{Bool} end
const bernoulli = Bernoulli()
```

Distributions must implement two methods, `random` and `logpdf`.

`random` returns a random sample from the distribution:

```julia
x::Bool = random(bernoulli, 0.5)
x::Bool = random(Bernoulli(), 0.5)
```

`logpdf` returns the log probability (density) of the distribution at a given value:

```julia
logpdf(bernoulli, false, 0.5)
logpdf(Bernoulli(), false, 0.5)
```

Distribution values are also callable, which is a syntactic sugar with the same behavior of calling `random`:

```julia
bernoulli(0.5) # identical to random(bernoulli, 0.5) and random(Bernoulli(), 0.5)
```

### Gradients of Distributions

Distributions may also implement `logpdf_grad`, which returns the gradient of the log probability (density) with respect to the random sample and the parameters, as a tuple:

```julia
(grad_sample, grad_mu, grad_std) = logpdf_grad(normal, 1.324, 0.0, 1.0)
```

The partial derivative of the log probability (density) with respect to the random sample, or one of the parameters, might not always exist.
Distributions indicate which partial derivatives exist using the methods `has_output_grad` and `has_argument_grads`:

```julia
has_output_grad(::Normal) = true
has_argument_grads(::Normal) = (true, true)
```

If a particular partial derivative does not exist, that field of the tuple returned by `logpdf_grad` should be `nothing`.


### Built-In Distributions

```@docs
bernoulli
normal
mvnormal
gamma
inv_gamma
beta
categorical
uniform
uniform_discrete
poisson
```

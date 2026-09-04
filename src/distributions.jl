# Workload distributions.
#
# Every distribution is sampled through `sample(rng, d)`, and the `rng` is
# always passed in explicitly — guide section 12: "randomness comes from an
# explicit RNG, never hidden global state". Calling bare `rand()` anywhere in
# this package would make runs irreproducible.

using Random

"""
    Distribution

Abstract supertype for anything the simulator can draw a duration from:
inter-arrival gaps, service times, and later retry backoff delays.

Adding a distribution means adding a subtype here and one `sample` method.
Nothing that calls `sample` needs to change.
"""
abstract type Distribution end

"""
    Constant(value)

Always returns `value`. The degenerate distribution, useful for the
hand-calculated scenarios that the engine tests are built on.
"""
struct Constant <: Distribution
    value::Float64

    function Constant(value::Float64)
        if value < 0
            throw(ArgumentError("Constant distribution must be nonnegative"))
        end
        new(value)
    end
end

"""
    Exponential(rate)

Exponential distribution with the given `rate` (λ). Mean is `1 / rate`.

Used for inter-arrival gaps: exponential gaps are exactly what makes arrivals
a Poisson process. It is memoryless — how long you have already waited says
nothing about how much longer you will wait.
"""
struct Exponential <: Distribution
    rate::Float64

    function Exponential(rate::Float64)
        if rate <= 0
            throw(ArgumentError("Exponential distribution must have positive rate"))
        end
        new(rate)
    end
end

"""
    LogNormal(mu, sigma)

Log-normal distribution: `log(X)` is normal with mean `mu` and standard
deviation `sigma`.

`mu` is the parameter in *log space*, not the mean of the samples, so it is
deliberately allowed to be negative and only `sigma` is validated. The actual
mean is

    E[X] = exp(mu + sigma^2 / 2)

so a scenario file that specifies a real-world mean must invert that when it
builds this type. Setting `mu = log(desired_mean)` overshoots the mean by a
factor of `exp(sigma^2 / 2)` — about 20% at `sigma = 0.6`.

This is the usual shape of service latency: most requests fast, a long right
tail of slow ones.
"""
struct LogNormal <: Distribution
    mu::Float64
    sigma::Float64

    function LogNormal(mu::Float64, sigma::Float64)
        if sigma <= 0
            throw(ArgumentError("LogNormal distribution must have positive sigma"))
        end
        new(mu, sigma)
    end
end

"""
    sample(rng, d::Constant) -> Float64

Return the fixed value. Takes an `rng` it never uses, so that callers can
treat every distribution the same way.

Sampling this through the general inverse-transform route would give
`F^-1(u) = value` for every `u`, since all the probability mass sits on one
point — so the draw is well defined, it just does not depend on the rng.
"""
function sample(rng::AbstractRNG, d::Constant)
    return d.value
end

"""
    sample(rng, d::Exponential) -> Float64

Draw one exponential variate by inverse transform sampling.

Inverting the CDF `F(x) = 1 - exp(-rate * x)` gives `F^-1(u) = -log(1 - u) / rate`,
which at `rate = 1` is exactly what `randexp` returns; dividing by `rate`
rescales `Exponential(1)` to `Exponential(rate)`. `randexp` uses the Ziggurat
algorithm rather than a logarithm, so it draws different numbers from the same
distribution, roughly twice as fast.

Do not hand-roll this as `-log(rand(rng)) / rate`: `rand` can return exactly
`0.0`, and `log(0.0)` is `-Inf`, which would put an event at infinite time.
The `1 - u` form avoids that; `randexp` avoids it too.
"""
function sample(rng::AbstractRNG, d::Exponential)
    # randexp(rng) ~ -log(1 - u): a draw from Exponential(1).
    return randexp(rng) / d.rate
end

"""
    sample(rng, d::LogNormal) -> Float64

Draw one log-normal variate straight from the definition: `log(X)` is normal
with mean `mu` and standard deviation `sigma`, so `X = exp(mu + sigma * Z)`
with `Z` standard normal.

Inverse transform sampling is not used here because the normal CDF has no
closed-form inverse — but `randn` already produces `Z` directly.
"""
function sample(rng::AbstractRNG, d::LogNormal)
    return exp(d.mu + d.sigma * randn(rng))
end

"""
    sample(rng, d::Distribution, n::Int) -> Vector{Float64}

Draw `n` independent variates from `d`.

Dispatches to the single-draw method, so it works for every distribution
without a method per type. `n` must be positive.

"""
function sample(rng::AbstractRNG, d::Distribution, n::Int)
    if n <= 0
        throw(ArgumentError("n must be positive, got $n"))
    end
    return [sample(rng, d) for _ in 1:n]
end

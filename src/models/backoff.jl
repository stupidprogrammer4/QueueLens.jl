"""Convert a duration to finite, nonnegative Float64 seconds."""
function backoff_seconds(value, label::AbstractString)
    value isa Real || throw(ArgumentError("$label must be a real number of seconds"))
    seconds = Float64(value)
    if !isfinite(seconds) || seconds < 0.0
        throw(ArgumentError("$label must be finite and nonnegative"))
    end
    return seconds
end

"""
    FixedBackoff(delay)

Callable fixed delay in seconds: backoff(rng, attempt_id). Requires a positive
attempt number and never consumes RNG state. Zero means no delay.
"""
struct FixedBackoff
    delay::Float64

    # Validate once; each call only needs to validate the attempt number.
    FixedBackoff(delay::Real) = new(backoff_seconds(delay, "fixed backoff delay"))
end

"""Return the fixed delay without sampling randomness."""
function (backoff::FixedBackoff)(rng::AbstractRNG, attempt_id::Int)
    validate_attempt_id(attempt_id)
    return backoff.delay
end

"""
    ExponentialBackoff(base_delay; cap)

Capped doubling delay after failed attempt n: min(cap, base_delay * 2^(n-1)).
Both durations are finite, nonnegative seconds. A base above cap is permitted
and immediately capped. Zero base or cap produces zero delay.
"""
struct ExponentialBackoff
    base_delay::Float64
    cap::Float64

    # Validate configuration once, before the policy enters the event loop.
    function ExponentialBackoff(base_delay::Real; cap::Real)
        new(backoff_seconds(base_delay, "base delay"), backoff_seconds(cap, "backoff cap"))
    end
end

"""
Compute capped exponential delay without RNG draws. Handle zero base and very
large attempt numbers without overflow or a loop proportional to attempt_id.
"""
function (backoff::ExponentialBackoff)(rng::AbstractRNG, attempt_id::Int)
    validate_attempt_id(attempt_id)
    backoff.base_delay == 0.0 && return 0.0
    backoff.cap == 0.0 && return 0.0
    backoff.base_delay >= backoff.cap && return backoff.cap
    # No finite Float64 spans more than 2098 binary exponents, even subnormals.
    exponent = attempt_id - 1
    exponent > 2098 && return backoff.cap
    return min(backoff.cap, ldexp(backoff.base_delay, exponent))
end

"""
    FullJitterBackoff(base_delay; cap)

Full jitter over the capped exponential delay. The envelope owns the validated
configuration so the exponential calculation is not duplicated. Sample uniformly
from zero to that envelope; this is not additive jitter around a fixed delay.
"""
struct FullJitterBackoff
    envelope::ExponentialBackoff

    # Reuse exponential configuration and validation rather than storing copies.
    FullJitterBackoff(base_delay::Real; cap::Real) = new(ExponentialBackoff(base_delay; cap))
end

"""
Return one rand(rng) draw multiplied by the envelope's delay. Consume exactly
one draw for each valid call, including a zero envelope; never use global RNG.
"""
function (backoff::FullJitterBackoff)(rng::AbstractRNG, attempt_id::Int)
    validate_attempt_id(attempt_id)
    return rand(rng) * backoff.envelope(rng, attempt_id)
end

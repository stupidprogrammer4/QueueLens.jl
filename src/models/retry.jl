"""
    RetryPolicy(; max_attempts = 1, backoff = FixedBackoff(0.0))

Retry budget and a callable backoff(rng, attempt_id) returning seconds.
max_attempts includes the original attempt, so one disables retry. Functions,
closures and callable structs are accepted, with their concrete type retained.
The callback signature and returned duration are checked when used, never by
executing user code during construction. Zero delay means immediate retry.

Pass as simulate's retry_policy keyword. Failures and timeouts retry the whole
job from its first step. The policy calculates delays; the engine owns cleanup,
attempt identity and readmission through the bounded worker queue.
"""
struct RetryPolicy{B}
    max_attempts::Int
    backoff::B

    # Do not invoke a callback to validate it: construction must not sample it.
    function RetryPolicy(; max_attempts::Int = 1, backoff = FixedBackoff(0.0))
        if max_attempts < 1
            throw(ArgumentError("max_attempts must be positive and includes the original attempt"))
        end
        new{typeof(backoff)}(max_attempts, backoff)
    end
end

"""
    retry_delay(policy::RetryPolicy, attempt_id::Int, rng::AbstractRNG) -> Union{Nothing,Float64}

After the numbered attempt fails, decide whether another attempt is allowed.
Call backoff(rng, attempt_id) once when budget remains, or return nothing when
exhausted without invoking backoff or consuming randomness. Convert the returned
real duration to Float64 and reject negative or non-finite values.
Positive attempt numbers at or beyond max_attempts have no budget left.
Nonpositive attempt numbers throw ArgumentError. Read only: do not increment
attempts, release ownership or schedule events. Only the caller-supplied RNG
and callback-owned state may be changed by the callback. Invalid attempt ids
are rejected before calling backoff.
"""
function retry_delay(policy::RetryPolicy, attempt_id::Int, rng::AbstractRNG)
    if attempt_id <= 0
        throw(ArgumentError("attempt_id must be positive"))
    end
    result = nothing
    if attempt_id < policy.max_attempts
        if !applicable(policy.backoff, rng, attempt_id)
            throw(ArgumentError("backoff must be callable as backoff(rng, attempt_id)"))
        end
        result = backoff_seconds(policy.backoff(rng, attempt_id), "backoff result")
    end
    return result
end

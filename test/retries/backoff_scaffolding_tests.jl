using Test
using Random
using QueueLens

# A plain named function is also a valid policy callback.
test_linear_backoff(rng, attempt_id) = 2 * attempt_id

@testset "callable backoff infrastructure" begin
    @testset "configuration and fixed callable" begin
        rng = Xoshiro(10)
        reference = copy(rng)
        fixed = QueueLens.FixedBackoff(2)
        @test fixed(rng, 1) === 2.0
        @test fixed(rng, typemax(Int)) === 2.0
        @test QueueLens.FixedBackoff(0)(rng, 1) === 0.0
        @test rand(rng) == rand(reference)
        exponential = QueueLens.ExponentialBackoff(2; cap=10)
        jitter = QueueLens.FullJitterBackoff(2; cap=10)
        @test exponential.base_delay === jitter.envelope.base_delay === 2.0
        @test exponential.cap === jitter.envelope.cap === 10.0
        @test QueueLens.ExponentialBackoff(20; cap=10).base_delay === 20.0
        @test QueueLens.ExponentialBackoff(0; cap=0).cap === 0.0
        for invalid in (-1.0, Inf, -Inf, NaN)
            @test_throws ArgumentError QueueLens.FixedBackoff(invalid)
            @test_throws ArgumentError QueueLens.ExponentialBackoff(invalid; cap=10)
            @test_throws ArgumentError QueueLens.ExponentialBackoff(1; cap=invalid)
            @test_throws ArgumentError QueueLens.FullJitterBackoff(invalid; cap=10)
            @test_throws ArgumentError QueueLens.FullJitterBackoff(1; cap=invalid)
        end
        for backoff in (fixed, exponential, jitter), invalid in (0, -1)
            reference = copy(rng)
            @test_throws ArgumentError backoff(rng, invalid)
            @test rand(rng) == rand(reference)
        end
    end

    @testset "functions, closures and concrete storage" begin
        rng = Xoshiro(42)
        named = QueueLens.RetryPolicy(; max_attempts=3, backoff=test_linear_backoff)
        @test QueueLens.retry_delay(named, 2, rng) === 4.0
        @test fieldtype(typeof(named), :backoff) === typeof(test_linear_backoff)
        calls = Int[]
        callback = (passed_rng, attempt_id) -> begin
            @test passed_rng === rng
            push!(calls, attempt_id)
            return 0.25 * attempt_id
        end
        policy = QueueLens.RetryPolicy(; max_attempts=3, backoff=callback)
        @test isempty(calls)
        @test policy.backoff === callback
        @test fieldtype(typeof(policy), :backoff) === typeof(callback)
        @test QueueLens.retry_delay(policy, 1, rng) === 0.25
        @test QueueLens.retry_delay(policy, 2, rng) === 0.5
        @test calls == [1, 2]
        @test QueueLens.retry_delay(policy, 3, rng) === nothing
        @test QueueLens.retry_delay(policy, typemax(Int), rng) === nothing
        @test_throws ArgumentError QueueLens.retry_delay(policy, 0, rng)
        @test_throws ArgumentError QueueLens.retry_delay(policy, -1, rng)
        @test calls == [1, 2]
    end

    @testset "only the supplied RNG is consumed" begin
        policy = QueueLens.RetryPolicy(; max_attempts=2, backoff=(rng, attempt_id) -> rand(rng))
        for rng in (Xoshiro(32), MersenneTwister(32))
            reference = copy(rng)
            @test QueueLens.retry_delay(policy, 1, rng) === rand(reference)
            @test QueueLens.retry_delay(policy, 2, rng) === nothing
            @test_throws ArgumentError QueueLens.retry_delay(policy, 0, rng)
            @test rand(rng) == rand(reference)
        end
    end

    @testset "callback shape and returned seconds" begin
        rng = Xoshiro(1)
        for bad in (17, nothing, () -> 1.0, attempt_id -> 1.0)
            policy = QueueLens.RetryPolicy(; max_attempts=2, backoff=bad)
            @test_throws ArgumentError QueueLens.retry_delay(policy, 1, rng)
            @test QueueLens.retry_delay(policy, 2, rng) === nothing
        end
        for value in (-1.0, NaN, Inf, -Inf, nothing, "2", 1 + 0im, big(2)^1024)
            policy = QueueLens.RetryPolicy(; max_attempts=2, backoff=(rng, id) -> value)
            @test_throws ArgumentError QueueLens.retry_delay(policy, 1, rng)
        end
        for value in (0, 2, 1//4)
            policy = QueueLens.RetryPolicy(; max_attempts=2, backoff=(rng, id) -> value)
            @test QueueLens.retry_delay(policy, 1, rng) === Float64(value)
        end
        throwing = QueueLens.RetryPolicy(; max_attempts=2, backoff=(rng, id) -> error("callback failure"))
        @test_throws ErrorException QueueLens.retry_delay(throwing, 1, rng)
        @test QueueLens.retry_delay(throwing, 2, rng) === nothing
    end
end

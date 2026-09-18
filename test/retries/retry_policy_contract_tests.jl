# Completed budget behavior, with callable-backoff wiring; also runnable alone.
# Run: julia --project=. test/retries/retry_policy_contract_tests.jl
using Test
using QueueLens
using Random

@testset "retry budget and fixed delay" begin
    rng = Xoshiro(42)
    @testset "budget includes the original attempt" begin
        policy = QueueLens.RetryPolicy(; max_attempts=3, backoff=QueueLens.FixedBackoff(2.0))
        @test QueueLens.retry_delay(policy, 1, rng) === 2.0
        @test QueueLens.retry_delay(policy, 2, rng) === 2.0
        @test QueueLens.retry_delay(policy, 3, rng) === nothing
        @test QueueLens.retry_delay(policy, 4, rng) === nothing
        @test QueueLens.retry_delay(policy, typemax(Int), rng) === nothing
        @test policy.max_attempts == 3
        @test policy.backoff.delay === 2.0
    end
    @testset "zero delay is different from no retry" begin
        immediate = QueueLens.RetryPolicy(; max_attempts=2)
        @test QueueLens.retry_delay(immediate, 1, rng) === 0.0
        @test QueueLens.retry_delay(immediate, 2, rng) === nothing
        @test QueueLens.retry_delay(QueueLens.RetryPolicy(), 1, rng) === nothing
        @test QueueLens.retry_delay(QueueLens.RetryPolicy(; backoff=QueueLens.FixedBackoff(10.0)), 1, rng) === nothing
    end
    @testset "fractional seconds and deterministic decisions" begin
        policy = QueueLens.RetryPolicy(; max_attempts=2, backoff=QueueLens.FixedBackoff(0.125))
        @test QueueLens.retry_delay(policy, 1, rng) === 0.125
        @test QueueLens.retry_delay(policy, 1, rng) === 0.125
    end
    @testset "invalid attempt ids are rejected even when retry is disabled" begin
        for policy in (QueueLens.RetryPolicy(), QueueLens.RetryPolicy(; max_attempts=3)),
            attempt_id in (0, -1, typemin(Int))
            @test_throws ArgumentError QueueLens.retry_delay(policy, attempt_id, rng)
        end
    end
end

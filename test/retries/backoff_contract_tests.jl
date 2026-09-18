# Learner calculations, separate until exponential and full jitter are complete.
# Run: julia --project=. test/retries/backoff_contract_tests.jl
using Test
using Random
using QueueLens

@testset "backoff calculations (learner exercise)" begin
    @testset "capped doubling without consuming randomness" begin
        rng = Xoshiro(7)
        reference = copy(rng)
        backoff = QueueLens.ExponentialBackoff(2; cap=10)
        for (attempt_id, expected) in enumerate((2.0, 4.0, 8.0, 10.0, 10.0))
            @test backoff(rng, attempt_id) === expected
        end
        @test backoff(rng, typemax(Int)) === 10.0
        @test rand(rng) == rand(reference)
        @test QueueLens.ExponentialBackoff(20; cap=10)(rng, 1) === 10.0
        @test QueueLens.ExponentialBackoff(0; cap=10)(rng, typemax(Int)) === 0.0
        @test QueueLens.ExponentialBackoff(2; cap=0)(rng, 1) === 0.0
        @test QueueLens.ExponentialBackoff(0.125; cap=1)(rng, 3) === 0.5
        @test QueueLens.ExponentialBackoff(floatmax(Float64)/2; cap=floatmax(Float64))(rng, 3) === floatmax(Float64)
        policy = QueueLens.RetryPolicy(; max_attempts=4, backoff)
        @test QueueLens.retry_delay(policy, 3, rng) === 8.0
        @test QueueLens.retry_delay(policy, 4, rng) === nothing
    end

    @testset "full jitter reuses the envelope and one draw" begin
        rng = Xoshiro(42)
        reference = copy(rng)
        jitter = QueueLens.FullJitterBackoff(2; cap=10)
        for (attempt_id, ceiling) in enumerate((2.0, 4.0, 8.0, 10.0, 10.0))
            expected = rand(reference) * ceiling
            @test jitter(rng, attempt_id) === expected
        end
        @test rand(rng) == rand(reference)
        @test QueueLens.FullJitterBackoff(0; cap=10)(rng, typemax(Int)) === 0.0
        rand(reference)
        @test rand(rng) == rand(reference)
        @test jitter(rng, typemax(Int)) === rand(reference) * 10.0
        first_rng, second_rng = Xoshiro(19), Xoshiro(19)
        @test [jitter(first_rng, 2) for _ in 1:8] == [jitter(second_rng, 2) for _ in 1:8]
    end

    @testset "invalid and exhausted attempts do not sample" begin
        rng = Xoshiro(14)
        reference = copy(rng)
        backoff = QueueLens.FullJitterBackoff(2; cap=10)
        policy = QueueLens.RetryPolicy(; max_attempts=2, backoff)
        @test_throws ArgumentError backoff(rng, 0)
        @test_throws ArgumentError QueueLens.retry_delay(policy, -1, rng)
        @test QueueLens.retry_delay(policy, 2, rng) === nothing
        @test rand(rng) == rand(reference)
        @test QueueLens.retry_delay(policy, 1, rng) === rand(reference) * 2.0
        @test rand(rng) == rand(reference)
    end
end

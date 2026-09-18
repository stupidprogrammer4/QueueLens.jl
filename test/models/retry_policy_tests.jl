@testset "fixed retry policy configuration" begin
    policy = QueueLens.RetryPolicy()
    @test policy.max_attempts == 1
    @test policy.backoff.delay === 0.0
    @test !ismutabletype(typeof(policy))
    custom = QueueLens.RetryPolicy(; max_attempts=3, backoff=QueueLens.FixedBackoff(2))
    @test custom.max_attempts == 3
    @test custom.backoff.delay === 2.0
    @test QueueLens.FixedBackoff(0.25).delay === 0.25
    for limit in (0, -1)
        @test_throws ArgumentError QueueLens.RetryPolicy(; max_attempts=limit)
    end
    for delay in (-1.0, Inf, -Inf, NaN)
        @test_throws ArgumentError QueueLens.FixedBackoff(delay)
    end
end

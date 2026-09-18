@testset "repeated runs" begin

    @testset "t critical values" begin
        @test QueueLens.t_critical_95(4) ≈ 2.776
        @test QueueLens.t_critical_95(30) ≈ 2.042
        # Above the table, fall back to the normal value.
        @test QueueLens.t_critical_95(31) ≈ 1.96
        @test QueueLens.t_critical_95(10_000) ≈ 1.96
        # Small samples need a much wider multiplier than 1.96.
        @test QueueLens.t_critical_95(1) > 10
    end

    @testset "estimate of identical values has no spread" begin
        e = QueueLens.estimate([5.0, 5.0, 5.0, 5.0])

        @test e.mean ≈ 5.0
        @test e.halfwidth ≈ 0.0
        @test e.num_runs == 4
    end

    @testset "estimate matches a hand-calculated interval" begin
        # values 2, 4, 4, 4, 5, 5, 7, 9: mean 5, sample sd 2.138, n = 8.
        # halfwidth = 2.365 * 2.138 / sqrt(8) = 1.787
        e = QueueLens.estimate([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])

        @test e.mean ≈ 5.0
        @test e.halfwidth ≈ 1.787 rtol = 0.01
    end

    @testset "a single value claims no certainty" begin
        e = QueueLens.estimate([3.0])

        @test e.mean ≈ 3.0
        @test isinf(e.halfwidth)
    end

    @testset "the interval narrows like 1/sqrt(n)" begin
        # Same population, four times as many observations: the half-width
        # should roughly halve.
        rng = Xoshiro(4)
        few  = QueueLens.estimate([randn(rng) for _ in 1:50])
        many = QueueLens.estimate([randn(rng) for _ in 1:200])

        @test many.halfwidth < few.halfwidth
        @test many.halfwidth ≈ few.halfwidth / 2 rtol = 0.35
    end

    @testset "repeated runs are reproducible" begin
        s = Scenario(Exponential(8.0), Constant(0.1), 2_000, 42)

        a = simulate_repeated(s, Dict{Symbol,Int}(), 5)
        b = simulate_repeated(s, Dict{Symbol,Int}(), 5)

        @test a.latency_mean.mean == b.latency_mean.mean
        @test a.latency_mean.halfwidth == b.latency_mean.halfwidth
    end

    @testset "runs actually differ from each other" begin
        # If every run used the same seed the half-width would be exactly zero.
        s = Scenario(Exponential(8.0), LogNormal(log(0.1) - 0.5, 1.0), 2_000, 42)

        @test simulate_repeated(s, Dict{Symbol,Int}(), 5).latency_mean.halfwidth > 0.0
    end

    @testset "omitted capacity preserves single-worker results" begin
        s = Scenario(Exponential(8.0), Constant(0.1), 100, 42)
        default = simulate_repeated(s, Dict{Symbol,Int}(), 4; warmup_fraction = 0.2)
        explicit = simulate_repeated(s, Dict{Symbol,Int}(), 4, 1; warmup_fraction = 0.2)

        for field in (:latency_mean, :latency_p99, :waiting_mean, :throughput)
            @test getfield(default, field) == getfield(explicit, field)
        end
        @test default.num_runs == explicit.num_runs == 4
        @test default.warmup_fraction == explicit.warmup_fraction == 0.2
    end

    @testset "repeated two-worker runs match hand-calculated metrics" begin
        # Arrivals 1/2/3, starts 1/2/4, completions 4/5/7.
        # Constant workloads produce identical metrics under every seed.
        s = Scenario(Constant(1.0), Constant(3.0), 3, 42)
        result = simulate_repeated(s, Dict{Symbol,Int}(), 4, 2)
        @test simulate_repeated(s, Dict{Symbol,Int}(), 4, 1).waiting_mean.mean ≈ 2.0
        @test result.num_runs == 4
        @test result.warmup_fraction == 0.0
        for (field, expected) in ((:waiting_mean, 1 / 3), (:latency_mean, 10 / 3),
                                  (:latency_p99, 4.0), (:throughput, 0.5))
            value = getfield(result, field)
            @test value.mean ≈ expected
            @test value.halfwidth == 0.0
            @test value.num_runs == 4
        end

        # Discard job 1: two retained jobs over the window from 2 to 7.
        warm = simulate_repeated(s, Dict{Symbol,Int}(), 4, 2; warmup_fraction = 1 / 3)
        @test warm.warmup_fraction == 1 / 3
        @test warm.waiting_mean.mean ≈ 0.5
        @test warm.latency_mean.mean ≈ 3.5
        @test warm.latency_p99.mean ≈ 4.0
        @test warm.throughput.mean ≈ 0.4
    end

    @testset "multi-worker estimates match the specified individual runs" begin
        s = Scenario(Exponential(10.0), LogNormal(-0.5, 1.0), 80, 42)
        result = simulate_repeated(s, Dict{Symbol,Int}(), 4, 2; warmup_fraction = 0.2)
        summaries = [summarize(
            simulate(Scenario(s.arrivals, s.service, s.num_jobs, seed), Dict{Symbol,Int}(), 2);
            warmup_fraction = 0.2,
        ) for seed in (42, 43, 44, 45)]

        for (repeated_field, run_field) in ((:latency_mean, :mean_latency),
                                           (:latency_p99, :p99_latency),
                                           (:waiting_mean, :mean_waiting),
                                           (:throughput, :throughput))
            expected = QueueLens.estimate([getfield(s, run_field) for s in summaries])
            actual = getfield(result, repeated_field)
            @test actual.mean ≈ expected.mean
            @test actual.halfwidth ≈ expected.halfwidth
            @test actual.num_runs == expected.num_runs
        end
        @test result.waiting_mean.halfwidth > 0.0
    end

    @testset "invalid capacity is rejected by repeated runs" begin
        s = Scenario(Constant(1.0), Constant(3.0), 3, 42)
        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 4, 0)
        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 4, -1)
        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 1, 2)
        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 4, 2; warmup_fraction = 1.0)
    end

    @testset "fewer than two runs is rejected" begin
        s = Scenario(Exponential(8.0), Constant(0.1), 100, 1)

        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 1)
        @test_throws ArgumentError simulate_repeated(s, Dict{Symbol,Int}(), 0)
    end

    @testset "the warm-up used is recorded with the result" begin
        s = Scenario(Exponential(8.0), Constant(0.1), 2_000, 42)
        r = simulate_repeated(s, Dict{Symbol,Int}(), 4; warmup_fraction = 0.2)

        @test r.num_runs == 4
        @test r.warmup_fraction == 0.2
    end

    @testset "theory falls inside the interval" begin
        # M/G/1 with constant service: W = rho * E[S] / (2 * (1 - rho))
        # at rho = 0.8, E[S] = 0.1 gives W = 0.2.
        #
        # This is the test that would have stopped the single-seed mistake:
        # the point estimate misses 0.2, but the interval covers it.
        s = Scenario(Exponential(8.0), Constant(0.1), 50_000, 42)
        w = simulate_repeated(s, Dict{Symbol,Int}(), 8).waiting_mean

        @test w.mean - w.halfwidth <= 0.2 <= w.mean + w.halfwidth
    end

    @testset "estimates print with their interval" begin
        text = sprint(show, MIME("text/plain"), QueueLens.estimate([1.0, 2.0, 3.0]))

        @test occursin("±", text)
    end

end

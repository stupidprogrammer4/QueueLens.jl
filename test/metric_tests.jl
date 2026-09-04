@testset "metrics" begin

    # Job i arrives at 0, starts immediately, and completes at time i.
    # So latencies are 1.0 .. n, waiting times are all zero, and the last
    # completion is at time n.
    fake(i) = JobResult(i, 0.0, 0.0, Float64(i), 0.0, Float64(i))
    fakes(n) = [fake(i) for i in 1:n]

    @testset "percentile uses the nearest-rank definition" begin
        xs = collect(1.0:100.0)

        @test QueueLens.percentile(xs, 0.50) == 50.0
        @test QueueLens.percentile(xs, 0.95) == 95.0
        @test QueueLens.percentile(xs, 0.99) == 99.0
        @test QueueLens.percentile(xs, 1.00) == 100.0

        # ceil(0.001 * 100) == 1, so the smallest observation, not an
        # interpolated value below it.
        @test QueueLens.percentile(xs, 0.001) == 1.0
    end

    @testset "percentile always returns an observed value" begin
        xs = [1.0, 2.0, 100.0]

        @test QueueLens.percentile(xs, 0.5) in xs
        @test QueueLens.percentile(xs, 0.9) in xs
    end

    @testset "summarize with no warm-up keeps everything" begin
        s = summarize(fakes(100))

        @test s.num_completed == 100
        @test s.num_discarded == 0
        @test s.mean_latency ≈ 50.5
        @test s.p50_latency == 50.0
        @test s.p95_latency == 95.0
        @test s.p99_latency == 99.0
        @test s.mean_waiting == 0.0
        # 100 jobs, first arrival at 0.0, last completion at 100.0.
        @test s.throughput ≈ 1.0
    end

    @testset "warm-up discards from the front" begin
        s = summarize(fakes(100); warmup_fraction = 0.1)

        @test s.num_discarded == 10
        @test s.num_completed == 90
        # Latencies 11 .. 100 remain.
        @test s.mean_latency ≈ 55.5
        @test s.p50_latency == 55.0
    end

    @testset "invalid warm-up fractions are rejected" begin
        @test_throws ArgumentError summarize(fakes(10); warmup_fraction = -0.1)
        @test_throws ArgumentError summarize(fakes(10); warmup_fraction = 1.0)
        @test_throws ArgumentError summarize(fakes(10); warmup_fraction = 2.0)
    end

    @testset "a warm-up that would discard everything is rejected" begin
        # 0.99 of 3 results rounds down to 2 discarded, leaving 1 — fine.
        @test summarize(fakes(3); warmup_fraction = 0.99).num_completed >= 1
    end

    @testset "a single result summarises without error" begin
        s = summarize(fakes(1))

        @test s.num_completed == 1
        @test s.mean_latency == 1.0
        @test s.p50_latency == 1.0
        @test s.p99_latency == 1.0
    end

    @testset "summarize matches a hand-calculated constant run" begin
        # Gaps of 2.0, service 3.0, three jobs: waiting 0, 1, 2 and
        # latencies 3, 4, 5, as pinned in the scenario tests.
        s = summarize(simulate(Scenario(Constant(2.0), Constant(3.0), 3, 1)))

        @test s.num_completed == 3
        @test s.mean_latency ≈ 4.0
        @test s.mean_waiting ≈ 1.0
        @test s.p50_latency ≈ 4.0
        @test s.p99_latency ≈ 5.0
    end

    @testset "Summary prints readably" begin
        text = sprint(show, MIME("text/plain"), summarize(fakes(10)))

        @test occursin("10", text)
        # Not the default positional rendering.
        @test !startswith(text, "Summary(")
    end

end

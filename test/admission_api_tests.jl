@testset "admission API" begin
    jobs = [Job(i, time, 3.0) for (i, time) in enumerate((0.0, 0.5, 1.0, 3.5))]
    resources = Dict{Symbol,Int}()
    scenario = Scenario(Constant(0.5), Constant(3.0), 4, 42)

    @testset "explicit jobs expose both outcomes" begin
        result = simulate(jobs, resources; queue_capacity = 1)
        @test result isa SimulationResult
        @test result.completed == [
            JobResult(1, 0.0, 0.0, 3.0, 0.0, 3.0),
            JobResult(2, 0.5, 3.0, 6.0, 2.5, 5.5),
            JobResult(4, 3.5, 6.0, 9.0, 2.5, 5.5),
        ]
        @test result.rejected == [JobRejection(3, 1.0, 1.0, :queue_full)]
        @test length(result.completed) + length(result.rejected) == length(jobs)
        @test length(simulate(jobs, resources).completed) == 4
        @test isempty(simulate(jobs, resources).rejected)

        again = simulate(jobs, resources; queue_capacity = 1)
        @test again.completed == result.completed
        @test again.rejected == result.rejected
        @test again.completed !== result.completed
        @test again.rejected !== result.rejected
        text = sprint(show, MIME("text/plain"), result)
        @test occursin("completed: 3", text)
        @test occursin("rejected: 1", text)
        @test occursin("rejection_rate: 0.25", text)
        @test rejection_rate(result) == 0.25
    end

    @testset "zero queue limit allows all available workers" begin
        simultaneous = [Job(i, 0.0, 3.0) for i in 1:3]
        result = simulate(simultaneous, resources, 2; queue_capacity = 0)
        @test result.completed == [JobResult(i, 0.0, 0.0, 3.0, 0.0, 3.0) for i in 1:2]
        @test result.rejected == [JobRejection(3, 0.0, 0.0, :queue_full)]
    end

    @testset "scenario arrivals continue after rejection" begin
        result = simulate(scenario, resources; queue_capacity = 0)
        @test result.completed == [JobResult(1, 0.5, 0.5, 3.5, 0.0, 3.0)]
        @test result.rejected == [JobRejection(i, i * 0.5, i * 0.5, :queue_full) for i in 2:4]
        @test length(result.completed) + length(result.rejected) == scenario.num_jobs
    end

    @testset "resource waiting keeps workers occupied" begin
        staged = [Job(i, time, [QueueLens.ServiceStep(:db, 2.0)])
                  for (i, time) in enumerate((0.0, 0.25, 0.5))]
        result = simulate(staged, Dict(:db => 1), 2; queue_capacity = 0)
        @test result.completed == [JobResult(1, 0.0, 0.0, 2.0, 0.0, 2.0),
                                   JobResult(2, 0.25, 0.25, 4.0, 0.0, 3.75)]
        @test result.rejected == [JobRejection(3, 0.5, 0.5, :queue_full)]
    end

    @testset "invalid queue limits reach all entry points" begin
        @test_throws ArgumentError simulate(jobs, resources; queue_capacity = -1)
        @test_throws ArgumentError simulate(scenario, resources; queue_capacity = -1)
        @test_throws ArgumentError simulate_repeated(scenario, resources, 2; queue_capacity = -1)
    end

    @testset "summary ignores rejections, warm-up applies only to completions" begin
        result = simulate(jobs, resources; queue_capacity = 1)
        for warmup in (0.0, 1 / 3)
            summary = summarize(result; warmup_fraction = warmup)
            expected = summarize(result.completed; warmup_fraction = warmup)
            @test summary == expected
        end
        @test length(result.rejected) == 1
        @test rejection_rate(result) == 0.25
        @test_throws ArgumentError summarize(result; warmup_fraction = 1.0)
        @test_throws ArgumentError summarize(SimulationResult(JobResult[], JobRejection[]))
        @test_throws ArgumentError summarize(SimulationResult(JobResult[], [JobRejection(1, 0.0, 0.0, :queue_full)]))
    end

    @testset "repeated runs report full-run rejection counts" begin
        result = simulate_repeated(scenario, resources, 3; queue_capacity = 1, warmup_fraction = 0.5)
        @test result.num_rejected.mean == 2.0
        @test result.num_rejected.halfwidth == 0.0
        @test result.num_rejected.num_runs == 3
        @test result.rejection_rate.mean == 0.5
        @test result.rejection_rate.halfwidth == 0.0
        @test result.rejection_rate.num_runs == 3
        @test result.latency_mean.mean == 5.5
        @test result.waiting_mean.mean == 2.5
        @test result.warmup_fraction == 0.5
        baseline = simulate_repeated(scenario, resources, 3)
        @test baseline.num_rejected.mean == 0.0
        @test baseline.num_rejected.halfwidth == 0.0
        @test baseline.rejection_rate.mean == 0.0
        @test baseline.rejection_rate.halfwidth == 0.0
        @test occursin("num_rejected (full run)", sprint(show, MIME("text/plain"), result))
        @test occursin("rejection_rate (full run)", sprint(show, MIME("text/plain"), result))
    end

    @testset "rejection estimate matches the specified independent seeds" begin
        workload = Scenario(Exponential(10.0), Constant(1.0), 60, 5)
        repeated = simulate_repeated(workload, resources, 4, 2; queue_capacity = 1)
        counts = [Float64(length(simulate(
            Scenario(workload.arrivals, workload.service, workload.num_jobs, seed),
            resources, 2; queue_capacity = 1,
        ).rejected)) for seed in 5:8]
        expected = QueueLens.estimate(counts)
        @test repeated.num_rejected.mean == expected.mean
        @test repeated.num_rejected.halfwidth == expected.halfwidth
        @test repeated.num_rejected.num_runs == expected.num_runs
        expected_rate = QueueLens.estimate(counts ./ workload.num_jobs)
        @test repeated.rejection_rate.mean == expected_rate.mean
        @test repeated.rejection_rate.halfwidth == expected_rate.halfwidth
        @test repeated.rejection_rate.num_runs == expected_rate.num_runs
    end

    @testset "one outcome per generated job (seed $seed, workers $capacity, limit $limit)" for seed in (5, 6), (capacity, limit) in ((1, 0), (2, 1), (3, 2))
        workload = Scenario(Exponential(10.0), Constant(1.0), 60, seed)
        result = simulate(workload, resources, capacity; queue_capacity = limit)
        completed_ids = [r.id for r in result.completed]
        rejected_ids = [r.id for r in result.rejected]
        @test sort(vcat(completed_ids, rejected_ids)) == collect(1:60)
        @test isempty(intersect(completed_ids, rejected_ids))
        @test !isempty(rejected_ids)
        @test all(r -> r.reason == :queue_full && r.rejection_time == r.arrival_time, result.rejected)
        again = simulate(workload, resources, capacity; queue_capacity = limit)
        @test result.completed == again.completed
        @test result.rejected == again.rejected
    end
end

@testset "monitoring reports" begin
    @testset "both entry points match hand calculations" begin
        for (input, capacity, duration, queue_mean, worker_util) in (
            ([Job(1, 1.0, 3.0)], 1, 4.0, 0.0, 0.75),
            (Scenario(Constant(1.0), Constant(3.0), 1, 42), 1, 4.0, 0.0, 0.75),
            ([Job(1, 1.0, 3.0), Job(2, 2.0, 3.0)], 1, 7.0, 2/7, 6/7),
            (Scenario(Constant(1.0), Constant(3.0), 2, 42), 1, 7.0, 2/7, 6/7),
            ([Job(1, 1.0, 3.0), Job(2, 2.0, 3.0)], 2, 5.0, 0.0, 0.6),
            (Scenario(Constant(1.0), Constant(3.0), 2, 42), 2, 5.0, 0.0, 0.6),
            ([Job(1, 0.0, 3.0), Job(2, 0.0, 3.0)], 1, 6.0, 0.5, 1.0),
            (Scenario(Constant(0.0), Constant(3.0), 2, 42), 1, 6.0, 0.5, 1.0),
            ([Job(1, 0.0, 0.0)], 1, 0.0, 0.0, 0.0),
            (Scenario(Constant(0.0), Constant(0.0), 2, 42), 1, 0.0, 0.0, 0.0),
            ([Job(1, 5.0, 0.0)], 1, 5.0, 0.0, 0.0),
        )
            result = simulate(input, Dict{Symbol,Int}(), capacity)
            stats = result.monitoring
            @test stats isa MonitoringSummary
            @test stats.duration == duration
            @test stats.worker_capacity == capacity
            @test stats.mean_queue_length ≈ queue_mean
            @test stats.worker_utilization ≈ worker_util
            @test isempty(stats.resources)
        end
    end

    @testset "resource contention, unused pools and idle tail" begin
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 3.0)]),
                Job(2, 0.0, [QueueLens.ServiceStep(:db, 3.0),
                             QueueLens.ServiceStep(nothing, 2.0)])]
        config = Dict(:db => 1, :cache => 2)
        result = simulate(jobs, config, 2)
        stats = result.monitoring
        @test stats.duration == 8.0
        @test stats.worker_utilization == 11/16
        @test stats.mean_queue_length == 0.0
        @test stats.resources[:db] == ResourceSummary(1, 3/8, 0.75)
        @test stats.resources[:cache] == ResourceSummary(2, 0.0, 0.0)
        @test config == Dict(:db => 1, :cache => 2)
        again = simulate(jobs, config, 2).monitoring
        @test again.resources !== stats.resources
        @test again.resources == stats.resources
        empty!(stats.resources)
        @test length(again.resources) == 2
        @test length(config) == 2
    end

    @testset "multiple occupied resource slots are normalized by capacity" begin
        jobs = [Job(i, 0.0, [QueueLens.ServiceStep(:db, 3.0)]) for i in 1:3]
        stats = simulate(jobs, Dict(:db => 2), 3).monitoring
        @test stats.duration == 6.0
        @test stats.worker_utilization ≈ 2/3
        @test stats.resources[:db] == ResourceSummary(2, 0.5, 0.75)
    end

    @testset "bounded queue and no-wait admission" begin
        jobs = [Job(i, t, 3.0) for (i, t) in enumerate((0.0, 0.5, 1.0, 3.5))]
        result = simulate(jobs, Dict{Symbol,Int}(); queue_capacity = 1)
        @test [r.id for r in result.rejected] == [3]
        @test result.monitoring.duration == 9.0
        @test result.monitoring.mean_queue_length ≈ 5/9
        @test result.monitoring.worker_utilization == 1.0
        no_wait = simulate(jobs, Dict{Symbol,Int}(); queue_capacity = 0)
        @test length(no_wait.rejected) == 2
        @test no_wait.monitoring.mean_queue_length == 0.0
        @test no_wait.monitoring.worker_utilization ≈ 6/6.5
    end

    @testset "snapshots do not retain or mutate run state" begin
        state = QueueLens.SimState(Scenario(Constant(1.0), Constant(3.0), 2, 42),
                                   Dict(:db => 2), 4)
        state.in_use = 2
        state.resources[:db].in_use = 1
        QueueLens.observe_state!(state)
        state.now = 5.0
        QueueLens.observe_state!(state)
        rng_before = copy(state.rng)
        before = (state.worker_busy_stat.area, state.worker_busy_stat.last_time,
                  state.worker_busy_stat.last_value)
        snapshot = QueueLens.summarize_monitoring(state)
        second = QueueLens.summarize_monitoring(state)
        @test snapshot.worker_utilization == 0.5
        @test snapshot.resources[:db] == ResourceSummary(2, 0.0, 0.5)
        @test snapshot.resources !== second.resources
        @test before == (state.worker_busy_stat.area, state.worker_busy_stat.last_time,
                         state.worker_busy_stat.last_value)
        @test rand(copy(state.rng)) == rand(rng_before)
        state.res_busy_stat[:db].area = 0.0
        state.resources[:db].capacity = 10
        empty!(state.res_queue_stat)
        @test snapshot.resources[:db] == ResourceSummary(2, 0.0, 0.5)
        @test state.now == 5.0
    end

    @testset "full-run monitoring is independent of completion warm-up" begin
        result = simulate(Scenario(Constant(1.0), Constant(3.0), 3, 42), Dict(:db => 2), 2)
        stats = result.monitoring
        @test summarize(result; warmup_fraction = 1/3).num_discarded == 1
        @test result.monitoring === stats
        @test stats.duration == 7.0
        @test stats.mean_queue_length ≈ 1/7
        @test stats.worker_utilization ≈ 9/14
        @test stats.resources[:db] == ResourceSummary(2, 0.0, 0.0)
        manual = SimulationResult(result.completed, result.rejected)
        @test manual.monitoring === nothing
        @test occursin("monitoring: unavailable", sprint(show, MIME("text/plain"), manual))
        empty_report = SimulationResult(JobResult[], JobRejection[])
        @test empty_report.monitoring === nothing
    end

    @testset "display labels the window and sorts resource names" begin
        stats = simulate([Job(1, 1.0, 3.0)], Dict(:zeta => 1, :alpha => 2)).monitoring
        text = sprint(show, MIME("text/plain"), stats)
        @test occursin("full run, time 0 to 4.0", text)
        @test occursin("worker_utilization: 0.75", text)
        @test occursin("mean_queue_length", text)
        @test first(findfirst("resource alpha", text)) < first(findfirst("resource zeta", text))
        result_text = sprint(show, MIME("text/plain"),
                            simulate([Job(1, 1.0, 3.0)], Dict{Symbol,Int}()))
        @test occursin("MonitoringSummary", result_text)
    end

    @testset "conservation checks on seeded multi-stage workloads" for seed in 1:10
        rng = Xoshiro(seed)
        jobs = [Job(i, (i - 1) * 0.1,
                    [QueueLens.ServiceStep(:db, 0.1 + rand(rng)),
                     QueueLens.ServiceStep(:cache, 0.1 + rand(rng)),
                     QueueLens.ServiceStep(nothing, 0.1)]) for i in 1:25]
        config = Dict(:db => 2, :cache => 1)
        result = simulate(jobs, config, 3; queue_capacity = 2)
        stats = result.monitoring
        completed_ids = Set(r.id for r in result.completed)
        served = filter(job -> job.id in completed_ids, jobs)
        @test stats.mean_queue_length * stats.duration ≈ sum(r.waiting_time for r in result.completed)
        @test stats.worker_utilization * 3 * stats.duration ≈
              sum(r.latency - r.waiting_time for r in result.completed)
        for (name, capacity) in config
            occupied_area = sum(step.duration for job in served for step in job.steps if step.resource === name)
            @test stats.resources[name].utilization * capacity * stats.duration ≈ occupied_area
            @test 0.0 <= stats.resources[name].utilization <= 1.0
            @test stats.resources[name].mean_queue_length >= 0.0
        end
        resource_wait_area = sum(r.latency - r.waiting_time for r in result.completed) -
                             sum(job.service_time for job in served)
        @test sum(r.mean_queue_length for r in values(stats.resources)) * stats.duration ≈ resource_wait_area atol=1e-10
        @test 0.0 <= stats.worker_utilization <= 1.0
        @test length(result.completed) + length(result.rejected) == length(jobs)
    end
end

@testset "repeated monitoring reports" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)
    result = simulate_repeated(scenario, Dict(:db => 2), 4, 2)
    warm = simulate_repeated(scenario, Dict(:db => 2), 4, 2; warmup_fraction = 1/3)
    for (field, value) in ((:mean_queue_length, 1/7), (:worker_utilization, 9/14))
        actual = getfield(result, field)
        @test actual.mean ≈ value
        @test actual.halfwidth == 0.0
        @test actual.num_runs == 4
        @test getfield(warm, field) == actual
    end
    @test result.resource_mean_queue_length[:db] == Estimate(0.0, 0.0, 4)
    @test result.resource_utilization[:db] == Estimate(0.0, 0.0, 4)
    @test warm.resource_mean_queue_length == result.resource_mean_queue_length
    @test warm.resource_utilization == result.resource_utilization
    text = sprint(show, MIME("text/plain"), result)
    @test occursin("worker_utilization (full run)", text)
    @test occursin("resource db utilization (full run)", text)

    random_scenario = Scenario(Exponential(4.0), Exponential(2.0), 50, 42)
    repeated = simulate_repeated(random_scenario, Dict(:db => 1), 4, 2;
                                 queue_capacity = 2, warmup_fraction = 0.2)
    singles = [simulate(Scenario(random_scenario.arrivals, random_scenario.service, 50, seed),
                        Dict(:db => 1), 2; queue_capacity = 2).monitoring for seed in 42:45]
    for field in (:mean_queue_length, :worker_utilization)
        expected = QueueLens.estimate([getfield(run, field) for run in singles])
        actual = getfield(repeated, field)
        @test actual.mean ≈ expected.mean
        @test actual.halfwidth ≈ expected.halfwidth
        @test actual.num_runs == expected.num_runs
    end
    for (field, resource_field) in ((:resource_mean_queue_length, :mean_queue_length),
                                     (:resource_utilization, :utilization))
        expected = QueueLens.estimate([getfield(run.resources[:db], resource_field) for run in singles])
        @test getfield(repeated, field)[:db] == expected
    end
end

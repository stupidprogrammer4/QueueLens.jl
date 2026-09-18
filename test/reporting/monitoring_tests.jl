@testset "time-weighted accumulator construction" begin
    stat = QueueLens.TimeWeightedStat()
    @test stat.area === 0.0
    @test stat.last_time === 0.0
    @test stat.last_value === 0.0

    other = QueueLens.TimeWeightedStat()
    @test other !== stat
    stat.area = 6.0
    stat.last_time = 4.0
    stat.last_value = 2.0
    @test other.area === 0.0
    @test other.last_time === 0.0
    @test other.last_value === 0.0
end

@testset "state monitoring construction" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 3, 42)
    state = QueueLens.SimState(scenario, Dict(:db => 1), 2)
    other = QueueLens.SimState(scenario, Dict(:db => 1), 2)
    for stat in (state.queue_length_stat, state.worker_busy_stat,
                 other.queue_length_stat, other.worker_busy_stat)
        @test (stat.area, stat.last_time, stat.last_value) === (0.0, 0.0, 0.0)
    end
    @test state.queue_length_stat !== state.worker_busy_stat
    @test state.queue_length_stat !== other.queue_length_stat
    @test state.worker_busy_stat !== other.worker_busy_stat
    QueueLens.observe!(state.queue_length_stat, 0.0, 2.0)
    QueueLens.observe!(state.queue_length_stat, 3.0, 0.0)
    @test state.queue_length_stat.area == 6.0
    @test state.worker_busy_stat.area == 0.0
    @test other.queue_length_stat.area == 0.0
    @test other.queue_length_stat.last_time == 0.0
    @test other.worker_busy_stat.last_time == 0.0
end

@testset "state observations" begin
    state = QueueLens.SimState(Scenario(Constant(1.0), Constant(3.0), 3, 42),
                               Dict(:db => 1), 3)
    @test QueueLens.observe_state!(state) === nothing
    @test state.queue_length_stat.area == 0.0
    @test state.worker_busy_stat.area == 0.0

    # A resource wait still occupies a worker but is not part of its entry queue.
    state.resources[:db].in_use = 1
    push!(state.resource_waiting[:db], 11)
    queue = state.waiting
    queue_stat = state.queue_length_stat
    busy_stat = state.worker_busy_stat
    for (now, waiting, busy, queue_area, busy_area) in (
        (5.0, [1, 2, 3], 2, 0.0, 0.0),
        (7.0, [3], 1, 6.0, 4.0),
        (7.0, Int[], 2, 6.0, 4.0),
        (9.0, Int[], 2, 6.0, 8.0),
    )
        state.now = now
        empty!(queue)
        append!(queue, waiting)
        state.in_use = busy
        @test QueueLens.observe_state!(state) === nothing
        @test (queue_stat.area, queue_stat.last_time, queue_stat.last_value) ==
              (queue_area, now, Float64(length(waiting)))
        @test (busy_stat.area, busy_stat.last_time, busy_stat.last_value) ==
              (busy_area, now, Float64(busy))
        @test state.now == now
        @test state.in_use == busy
        @test state.waiting === queue
        @test state.waiting == waiting
        @test state.resources[:db].in_use == 1
        @test state.resource_waiting[:db] == [11]
        @test isempty(state.calendar)
        @test isempty(state.results)
        @test isempty(state.rejected)
        @test state.jobs_generated == 0
    end
    @test state.queue_length_stat === queue_stat
    @test state.worker_busy_stat === busy_stat
    @test QueueLens.time_weighted_mean(queue_stat) == 6.0 / 9.0
    @test QueueLens.time_weighted_mean(busy_stat) == 8.0 / 9.0
end

@testset "event-driven monitoring" begin
    for (input, finish, queue_area, busy_area) in (
        ([Job(1, 1.0, 3.0), Job(2, 2.0, 3.0)], 7.0, 2.0, 6.0),
        (Scenario(Constant(1.0), Constant(3.0), 2, 42), 7.0, 2.0, 6.0),
        (Scenario(Constant(0.0), Constant(3.0), 2, 42), 6.0, 3.0, 6.0),
        (Scenario(Constant(0.0), Constant(0.0), 2, 42), 0.0, 0.0, 0.0),
    )
        scenario = input isa Scenario ? input :
                   Scenario(Constant(0.0), Constant(0.0), length(input), 42)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        if input isa Scenario
            QueueLens.schedule_next_arrival!(state)
        else
            state.jobs_generated = length(input)
            for job in input
                state.records[job.id] = QueueLens.JobRecord(job)
                QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
            end
        end
        # Inspect raw accumulator areas here; monitoring_report_tests covers simulate.
        while !isempty(state.calendar)
            event = QueueLens.pop_next!(state)
            state.now = event.time
            QueueLens.handle!(state, event)
            QueueLens.observe_state!(state)
        end
        @test state.now == finish
        @test length(state.results) == 2
        @test isempty(state.rejected)
        @test (state.queue_length_stat.area, state.queue_length_stat.last_time,
               state.queue_length_stat.last_value) == (queue_area, finish, 0.0)
        @test (state.worker_busy_stat.area, state.worker_busy_stat.last_time,
               state.worker_busy_stat.last_value) == (busy_area, finish, 0.0)
        @test state.in_use == 0
        @test isempty(state.waiting)
        @test QueueLens.time_weighted_mean(state.worker_busy_stat) ==
              (finish == 0.0 ? 0.0 : busy_area / finish)
    end
end

@testset "resource queue monitoring" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 2, 42)
    state = QueueLens.SimState(scenario, Dict(:db => 1, :cache => 2), 2)
    other = QueueLens.SimState(scenario, Dict(:db => 1, :cache => 2), 2)
    @test Set(keys(state.res_queue_stat)) == Set([:db, :cache])
    @test state.res_queue_stat[:db] !== state.res_queue_stat[:cache]
    @test state.res_queue_stat[:db] !== other.res_queue_stat[:db]
    for stat in values(state.res_queue_stat)
        @test (stat.area, stat.last_time, stat.last_value) == (0.0, 0.0, 0.0)
    end

    append!(state.resource_waiting[:db], [1, 2])
    push!(state.resource_waiting[:cache], 3)
    @test QueueLens.observe_state!(state) === nothing
    state.now = 3.0
    empty!(state.resource_waiting[:db])
    QueueLens.observe_state!(state)
    @test state.res_queue_stat[:db].area == 6.0
    @test state.res_queue_stat[:db].last_value == 0.0
    @test state.res_queue_stat[:cache].area == 3.0
    @test state.res_queue_stat[:cache].last_value == 1.0
    @test state.resource_waiting[:db] == Int[]
    @test state.resource_waiting[:cache] == [3]
    @test state.queue_length_stat.area == 0.0
    @test state.worker_busy_stat.area == 0.0
    @test other.res_queue_stat[:db].area == 0.0

    QueueLens.register_resource!(state, :disk, 1)
    @test state.res_queue_stat[:disk] !== state.res_queue_stat[:db]
    @test state.res_queue_stat[:disk].area == 0.0
    QueueLens.observe_state!(state)
    @test state.res_queue_stat[:cache].area == 3.0
    state.now = 5.0
    QueueLens.observe_state!(state)
    @test state.res_queue_stat[:db].area == 6.0
    @test state.res_queue_stat[:cache].area == 5.0
    @test state.res_queue_stat[:disk].last_time == 5.0
    @test state.res_queue_stat[:disk].area == 0.0

    @testset "contention followed by a resource-free tail" begin
        run = QueueLens.SimState(scenario, Dict(:db => 1, :cache => 2), 2)
        jobs = [Job(1, 0.0, [QueueLens.ServiceStep(:db, 3.0)]),
                Job(2, 0.0, [QueueLens.ServiceStep(:db, 3.0),
                             QueueLens.ServiceStep(nothing, 2.0)])]
        run.jobs_generated = length(jobs)
        for job in jobs
            run.records[job.id] = QueueLens.JobRecord(job)
            QueueLens.schedule!(run, QueueLens.JobArrival(job.arrival_time, job.id))
        end
        # Inspect retained state using real handlers, as in the worker monitoring fixtures.
        while !isempty(run.calendar)
            event = QueueLens.pop_next!(run)
            run.now = event.time
            QueueLens.handle!(run, event)
            QueueLens.observe_state!(run)
        end
        @test [r.completion_time for r in run.results] == [3.0, 8.0]
        @test (run.res_queue_stat[:db].area, run.res_queue_stat[:db].last_time,
               run.res_queue_stat[:db].last_value) == (3.0, 8.0, 0.0)
        @test QueueLens.time_weighted_mean(run.res_queue_stat[:db]) == 3.0 / 8.0
        @test (run.res_queue_stat[:cache].area, run.res_queue_stat[:cache].last_time,
               run.res_queue_stat[:cache].last_value) == (0.0, 8.0, 0.0)
        @test run.queue_length_stat.area == 0.0
        @test run.worker_busy_stat.area == 11.0
        @test isempty(run.resource_waiting[:db])
        @test run.resources[:db].in_use == 0
        @test (run.res_busy_stat[:db].area, run.res_busy_stat[:db].last_time,
               run.res_busy_stat[:db].last_value) == (6.0, 8.0, 0.0)
        @test (run.res_busy_stat[:cache].area, run.res_busy_stat[:cache].last_time,
               run.res_busy_stat[:cache].last_value) == (0.0, 8.0, 0.0)
        @test QueueLens.time_weighted_mean(run.res_busy_stat[:db]) == 0.75
    end
end

@testset "resource occupancy monitoring" begin
    scenario = Scenario(Constant(1.0), Constant(3.0), 2, 42)
    state = QueueLens.SimState(scenario, Dict(:db => 3, :cache => 2), 4)
    other = QueueLens.SimState(scenario, Dict(:db => 3, :cache => 2), 4)
    @test Set(keys(state.res_busy_stat)) == Set(keys(state.resources))
    @test state.res_busy_stat[:db] !== state.res_busy_stat[:cache]
    @test state.res_busy_stat[:db] !== state.res_queue_stat[:db]
    @test state.res_busy_stat[:db] !== state.worker_busy_stat
    @test state.res_busy_stat[:db] !== other.res_busy_stat[:db]
    for stat in values(state.res_busy_stat)
        @test (stat.area, stat.last_time, stat.last_value) == (0.0, 0.0, 0.0)
    end
    # Occupied pools can have empty waiting queues; sample counts, not fractions.
    state.resources[:db].in_use = 2
    state.resources[:cache].in_use = 1
    @test QueueLens.observe_state!(state) === nothing
    @test state.res_busy_stat[:db].last_value == 2.0
    state.now = 3.0
    state.resources[:db].in_use = 1
    state.resources[:cache].in_use = 0
    QueueLens.observe_state!(state)
    @test state.res_busy_stat[:db].area == 6.0
    @test state.res_busy_stat[:cache].area == 3.0
    @test state.res_queue_stat[:db].area == 0.0
    @test state.res_queue_stat[:cache].area == 0.0
    @test state.resources[:db].in_use == 1
    @test isempty(state.resource_waiting[:db])
    QueueLens.observe_state!(state)
    @test state.res_busy_stat[:db].area == 6.0
    state.now = 5.0
    state.resources[:db].in_use = 0
    QueueLens.observe_state!(state)
    @test state.res_busy_stat[:db].area == 8.0
    @test state.res_busy_stat[:cache].area == 3.0
    @test state.res_busy_stat[:db].last_value == 0.0
    @test other.res_busy_stat[:db].area == 0.0
    @test other.res_busy_stat[:db].last_time == 0.0

    QueueLens.register_resource!(state, :disk, 1)
    @test state.res_busy_stat[:disk] !== state.res_queue_stat[:disk]
    @test state.res_busy_stat[:disk].area == 0.0
    QueueLens.observe_state!(state)
    @test state.res_busy_stat[:disk].last_time == 5.0
    @test state.res_busy_stat[:disk].area == 0.0
    db_stat = state.res_busy_stat[:db]
    @test_throws ArgumentError QueueLens.register_resource!(state, :db, 1)
    @test state.res_busy_stat[:db] === db_stat
    @test db_stat.area == 8.0
    @test_throws ArgumentError QueueLens.register_resource!(state, :invalid, 0)
    @test !haskey(state.res_busy_stat, :invalid)
    @test !haskey(state.res_queue_stat, :invalid)
end

@testset "time-weighted mean" begin
    @testset "mean of a piecewise-constant history" begin
        stat = QueueLens.TimeWeightedStat()
        @test QueueLens.time_weighted_mean(stat) === 0.0
        QueueLens.observe!(stat, 1.0, 2.0)
        QueueLens.observe!(stat, 4.0, 0.0)
        before = (stat.area, stat.last_time, stat.last_value)
        @test QueueLens.time_weighted_mean(stat) === 1.5
        @test QueueLens.time_weighted_mean(stat) === 1.5
        @test (stat.area, stat.last_time, stat.last_value) == before
        QueueLens.observe!(stat, 5.0, 0.0)
        @test QueueLens.time_weighted_mean(stat) === 1.2
    end

    @testset "zero area over positive time" begin
        stat = QueueLens.TimeWeightedStat()
        QueueLens.observe!(stat, 5.0, 0.0)
        @test QueueLens.time_weighted_mean(stat) === 0.0
        @test stat.last_time == 5.0
    end

    @testset "nonzero value at time zero has no elapsed duration" begin
        stat = QueueLens.TimeWeightedStat()
        QueueLens.observe!(stat, 0.0, 3.0)
        @test QueueLens.time_weighted_mean(stat) === 0.0
        @test stat.last_value == 3.0
    end

    @testset "zero-duration policy depends on time, not area" begin
        # Deliberately constructed state isolates the guard's denominator check.
        stat = QueueLens.TimeWeightedStat(6.0, 0.0, 2.0)
        @test QueueLens.time_weighted_mean(stat) === 0.0
        @test (stat.area, stat.last_time, stat.last_value) == (6.0, 0.0, 2.0)
    end
end

@testset "utilization" begin
    stat = QueueLens.TimeWeightedStat()
    @test QueueLens.utilization(stat, 4) === 0.0
    QueueLens.observe!(stat, 0.0, 2.0)
    @test QueueLens.utilization(stat, 4) === 0.0
    QueueLens.observe!(stat, 5.0, 0.0)
    before = (stat.area, stat.last_time, stat.last_value)
    @test QueueLens.utilization(stat, 4) == 0.5
    @test QueueLens.utilization(stat, 2) == 1.0
    @test QueueLens.utilization(stat, 4) == 0.5
    @test (stat.area, stat.last_time, stat.last_value) == before
    QueueLens.observe!(stat, 10.0, 0.0)
    @test QueueLens.utilization(stat, 4) == 0.25

    idle = QueueLens.TimeWeightedStat()
    QueueLens.observe!(idle, 5.0, 0.0)
    @test QueueLens.utilization(idle, 3) === 0.0

    @testset "invalid capacity $capacity at time $(invalid_stat.last_time)" for
        capacity in (0, -1, typemin(Int)),
        invalid_stat in (QueueLens.TimeWeightedStat(), QueueLens.TimeWeightedStat(10.0, 5.0, 2.0))
        before = (invalid_stat.area, invalid_stat.last_time, invalid_stat.last_value)
        @test_throws ArgumentError QueueLens.utilization(invalid_stat, capacity)
        @test (invalid_stat.area, invalid_stat.last_time, invalid_stat.last_value) == before
    end
end

@testset "time-weighted observations" begin
    @testset "integrate the previous value, not the new value" begin
        stat = QueueLens.TimeWeightedStat()
        @test QueueLens.observe!(stat, 1.0, 2.0) === nothing
        @test stat.area == 0.0
        @test stat.last_time == 1.0
        @test stat.last_value == 2.0
        @test QueueLens.observe!(stat, 4.0, 0.0) === nothing
        @test stat.area == 6.0
        @test stat.last_time == 4.0
        @test stat.last_value == 0.0
    end

    @testset "new area is added to accumulated history" begin
        stat = QueueLens.TimeWeightedStat(6.0, 4.0, 2.0)
        QueueLens.observe!(stat, 7.0, 1.0)
        @test stat.area == 12.0
        @test stat.last_time == 7.0
        @test stat.last_value == 1.0
    end

    @testset "equal timestamps update the value without adding area" begin
        stat = QueueLens.TimeWeightedStat(6.0, 4.0, 2.0)
        QueueLens.observe!(stat, 4.0, 5.0)
        @test stat.area == 6.0
        @test stat.last_time == 4.0
        @test stat.last_value == 5.0
        QueueLens.observe!(stat, 5.0, 0.0)
        @test stat.area == 11.0
    end

    @testset "record the final interval even without a value change" begin
        stat = QueueLens.TimeWeightedStat()
        QueueLens.observe!(stat, 0.0, 2.0)
        QueueLens.observe!(stat, 5.0, 2.0)
        @test stat.area == 10.0
        QueueLens.observe!(stat, 5.0, 2.0)
        @test stat.area == 10.0
    end

    @testset "invalid observation leaves state unchanged ($now, $value)" for (now, value) in (
        (-1.0, 1.0), (3.0, 1.0), (-Inf, 1.0), (Inf, 1.0), (NaN, 1.0),
        (7.0, -1.0), (7.0, -Inf), (7.0, Inf), (7.0, NaN),
    )
        stat = QueueLens.TimeWeightedStat(6.0, 4.0, 2.0)
        @test_throws ArgumentError QueueLens.observe!(stat, now, value)
        @test isequal((stat.area, stat.last_time, stat.last_value), (6.0, 4.0, 2.0))
    end
end

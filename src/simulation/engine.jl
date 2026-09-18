# Public simulation entry points and the shared event loop.

"""
    simulate(jobs, resources, capacity = 1;
             queue_capacity = typemax(Int), failures = JobFailed[]) -> SimulationResult

Run to completion and return completed, rejected and failed jobs separately.
`capacity` is a positive number of parallel worker slots,
passed positionally, as in `simulate(jobs, Dict(:db => 2), 3)`. Waiting jobs
start in FIFO order, but different service times can change completion order.
`resources` is a required dictionary of named pool capacities; use
`Dict{Symbol,Int}()` for no pools. Every run creates fresh pools and queues.
`queue_capacity` is the nonnegative limit on jobs waiting for a worker, not
on jobs holding workers or waiting for resources. Zero permits no worker
waiting; the default is effectively unbounded. Full worker queues reject
new arrivals with reason `:queue_full`.

`failures` is an experimental explicit-job-only list of `JobFailed` events,
with at most one fault per job. Faults must target known stages at or after
arrival and, at dispatch, a stage actually executing. They are scheduled after
the input arrivals, with normal insertion-order ties. Failure releases the
job's worker and held resource; its old completions are ignored without
advancing the clock. Failed jobs are not retried.

Explicit jobs may set `timeout`, measured from worker start and including
resource waits. Whole-job completion exactly at the deadline wins. Timeouts
are reported as failures with reason `:timeout`.

The loop pops the earliest event, advances the virtual clock to it, and
dispatches to its handler without branching on event type. After each handler,
record queue length and worker occupancy through the current event time.

This explicit-job overload schedules every arrival up front. The `Scenario`
overload generates arrivals lazily, keeping only the next arrival on the
calendar alongside at most `capacity` service completions.
"""
function simulate(jobs::Vector{Job}, resources::Dict{Symbol,Int}, capacity::Int = 1;
                  queue_capacity::Int = typemax(Int), failures::Vector{JobFailed} = JobFailed[])
    # The distributions are placeholders: this path never samples them, because
    # jobs_generated already sits at the limit, which switches lazy generation
    # off. See the `jobs_generated` note on SimState.
    scenario = Scenario(Constant(0.0), Constant(0.0), length(jobs), 0)
    state = SimState(scenario, resources, capacity; queue_capacity)
    state.jobs_generated = length(jobs)
    for job in jobs
        QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
        state.records[job.id] = JobRecord(job)
    end
    failure_ids = Set{Int}()
    for failure in failures
        if !haskey(state.records, failure.job_id)
            throw(ArgumentError("failure targets unknown job id $(failure.job_id)"))
        end
        if failure.job_id in failure_ids
            throw(ArgumentError("at most one injected failure per job is supported"))
        end
        record = state.records[failure.job_id]
        if failure.time < record.arrival_time || failure.step_index > length(record.steps)
            throw(ArgumentError("failure must target an existing stage at or after arrival"))
        end
        push!(failure_ids, failure.job_id)
        schedule!(state, failure)
    end

    return run!(state)
end

"""
    simulate(scenario::Scenario, resources, capacity = 1; queue_capacity = typemax(Int)) -> SimulationResult

Run `scenario` with a positive number of worker slots and return completed
and rejected jobs separately. Capacity is a positional argument
and defaults to one; the workload and seed remain in `Scenario`.
The required `resources` dictionary supplies pool capacities, with fresh pools
and queues per run. Generated jobs currently contain one resource-free step;
use explicit jobs for resource-dependent stages.
`queue_capacity` limits the worker waiting queue exactly as for explicit jobs.
Rejected arrivals do not interrupt generation of the remaining workload.

Builds the state, seeds it from `scenario.seed`, schedules the first arrival,
and then runs the same loop as [`simulate(::Vector{Job})`](@ref) — the loop
itself does not know arrivals are being generated as it goes.

The first arrival lands at `t = sample(rng, scenario.arrivals)`: the system
starts empty and waits one sampled gap. A zero gap, such as `Constant(0.0)`,
places the first arrival at zero. Explicit `Vector{Job}` inputs specify their
own arrival times.
"""
function simulate(scenario::Scenario, resources::Dict{Symbol,Int}, capacity::Int = 1;
                  queue_capacity::Int = typemax(Int))
    state = SimState(scenario, resources, capacity; queue_capacity)
    schedule_next_arrival!(state)
    return run!(state)
end

"""
    run!(state::SimState) -> SimulationResult

Drain a prepared calendar and return its outcomes and monitoring snapshot.
Both simulation entry points use this loop. Ignore stale events before moving
the clock, then dispatch and observe each real event exactly once. Handlers
may schedule further work, including lazy arrivals. Outcome vectors belong to
the state; the monitoring summary is an independent snapshot.
"""
function run!(state::SimState)
    while !isempty(state.calendar)
        event = pop_next!(state)
        if (event isa JobTimedOut || !isempty(state.failed_ids)) && is_stale_event(state, event)
            continue
        end
        state.now = event.time
        handle!(state, event)
        observe_state!(state)
    end
    return SimulationResult(state.results, state.rejected, summarize_monitoring(state), state.failed)
end


"""
    observe_state!(state::SimState) -> Nothing

Record worker queue length, occupied worker count and each resource's waiting
queue length and occupied slot count at `state.now`.
Each accumulator integrates its previous value before storing the new one.
Occupied workers include jobs waiting for shared resources; this records counts,
not capacity-normalized utilization. Only the accumulators are changed.

The shared simulation loop calls this after each handler, including the final event.
The accumulators cover time zero through the last event; simulation reports
expose their scalar summaries in `result.monitoring`.
"""
function observe_state!(state::SimState)
    now = state.now

    queue_len = Float64(length(state.waiting))
    observe!(state.queue_length_stat, now, queue_len)

    busy_cnt = Float64(state.in_use)
    observe!(state.worker_busy_stat, now, busy_cnt)

    for (name, waiting) in state.resource_waiting
        stat = state.res_queue_stat[name]
        len = Float64(length(waiting))
        observe!(stat, now, len)
    end

    for (name, pool) in state.resources
        stat = state.res_busy_stat[name]
        busy = Float64(pool.in_use)
        observe!(stat, now, busy)
    end

    return nothing
end

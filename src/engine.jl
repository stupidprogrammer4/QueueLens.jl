# Event handlers and the main loop.

"""
    handle!(state, event::JobArrival)

A job has arrived. If `can_admit` accepts it, put it at the back of the FIFO
worker queue and try to start one job. Otherwise record a `:queue_full`
rejection without occupying a worker or creating a completion event.

Arrival never starts a job directly: it only makes the queue non-empty and
lets [`start_next_job!`](@ref) decide. That keeps the "may the worker begin?"
rule in exactly one place. Both admission and rejection schedule the next
arrival so a full queue does not stop workload generation.
"""
function handle!(state::SimState, event::JobArrival)
    if can_admit(state, state.queue_capacity)
        state.waiting = push!(state.waiting, event.job_id)
        start_next_job!(state)
    else
        record_rejection!(state, event.job_id)
    end
    schedule_next_arrival!(state)
end

"""
    handle!(state, event::ServiceCompleted)

A worker has finished a job. Record its `JobResult`, release one occupied
slot, then try to start the next waiting job.

The record is deleted once its result is built. A second `ServiceCompleted`
for that job therefore throws `ArgumentError` instead of producing a duplicate
result. Timeout and retry handling will need attempt-aware checks in milestone 4.
"""
function handle!(state::SimState, event::ServiceCompleted)
    if haskey(state.records, event.job_id)
        record = state.records[event.job_id]
        arrival_time = record.arrival_time
        start_time = record.start_time
        completion_time = state.now
        waiting_time = start_time - arrival_time
        latency = completion_time - arrival_time
        result = JobResult(event.job_id, record.arrival_time, record.start_time, completion_time, waiting_time, latency)
        push!(state.results, result)
        delete!(state.records, event.job_id)
        state.in_use -= 1
        start_next_job!(state)
    else
        throw(ArgumentError("ServiceCompleted for unknown job id $(event.job_id)"))
    end
end


"""
    handle!(state, event::StepCompleted)

Finish the current stage after validating the job id and stage index.
Release its resource, if any, and let the first job in that resource's FIFO
queue acquire it before the completing job advances to its next stage.

Stage completion preserves worker occupancy and the original job start time.
If no stages remain, `start_current_step!` schedules whole-job completion.
Unknown jobs, invalid stage indices and unregistered resources throw
`ArgumentError`; releasing an idle pool also throws.
"""
function handle!(state::SimState, event::StepCompleted)
    if !haskey(state.records, event.job_id)
        throw(ArgumentError("StepCompleted for unknown job id $(event.job_id)"))
    end
    record = state.records[event.job_id]
    if !(1 <= event.step_index <= length(record.steps))
        throw(ArgumentError("StepCompleted for job id $(event.job_id): expected step index in 1:$(length(record.steps)), got $(event.step_index)"))
    end
    if event.step_index != record.step_index
        throw(ArgumentError("StepCompleted for job id $(event.job_id): expected current step $(record.step_index), got $(event.step_index)"))
    end
    resource = record.steps[event.step_index].resource
    if resource !== nothing
        pool = get(state.resources, resource, nothing)
        if pool === nothing
            throw(ArgumentError("StepCompleted for job id $(event.job_id): resource $(resource) not registered"))
        end
        release!(pool)
        waiting_queue = state.resource_waiting[resource]
        if !isempty(waiting_queue)
            next_job_id = popfirst!(waiting_queue)
            start_current_step!(state, next_job_id)
        end
    end
    record.step_index += 1
    start_current_step!(state, event.job_id)
end

"""
    start_current_step!(state, job_id)

Acquire the current stage's resource, if any, and schedule `StepCompleted` at
`state.now + step.duration`. A full pool queues the job without scheduling its
completion. An unregistered resource throws `ArgumentError`.
When no stages remain, schedule `ServiceCompleted` at `state.now`.

The job must already hold a worker slot. This helper does not change worker
occupancy, the job's start time, or its step index.
"""
function start_current_step!(state::SimState, job_id::Int)
    record = state.records[job_id]
    step_index = record.step_index
    if step_index <= length(record.steps)
        step::ServiceStep = record.steps[step_index]
        if step.resource !== nothing
            pool = get(state.resources, step.resource, nothing)
            if pool === nothing
                throw(ArgumentError("StepCompleted for job id $(job_id): resource $(step.resource) not registered"))
            end
            if !try_acquire!(pool)
                push!(state.resource_waiting[step.resource], job_id)
                return nothing
            end
        end
        completion_time = state.now + step.duration
        QueueLens.schedule!(state, QueueLens.StepCompleted(completion_time, job_id, step_index))
    else
        QueueLens.schedule!(state, QueueLens.ServiceCompleted(state.now, job_id))
    end
    return nothing
end

"""
    start_next_job!(state)

If `in_use < capacity` and the waiting queue is non-empty, start one job from
the front. Increment `in_use`, record its start time, and schedule its
first step (or wait for its resource). Otherwise leave the state unchanged.

Step durations and resource names come from the job's own `JobRecord`.

Each arrival introduces one job and each whole-job completion frees one slot, so
starting at most one job per handler keeps the current fixed-capacity model
fully occupied whenever work is waiting. Bulk arrivals or capacity changes
would require revisiting this rule.
"""
function start_next_job!(state::SimState)
    rem = state.capacity - state.in_use
    if rem > 0 && !isempty(state.waiting)
        job_id = popfirst!(state.waiting)
        state.in_use += 1
        record = state.records[job_id]
        record.start_time = state.now
        start_current_step!(state, job_id)
    end
    
end

"""
    can_admit(state, queue_capacity) -> Bool

Return whether a new job can take a free worker slot or join the worker queue.
`queue_capacity` bounds only waiting jobs, not jobs already holding workers.
Zero allows admission only when a worker is free; negative values throw
`ArgumentError`. This predicate does not mutate state or enqueue the job.
"""
function can_admit(state::SimState, queue_capacity::Int)
    if queue_capacity < 0
        throw(ArgumentError("queue_capacity must be non-negative"))
    end
    rem_worker = state.capacity - state.in_use
    result = false
    if rem_worker > 0
        result = true
    end
    if length(state.waiting) < queue_capacity
        result = true
    end
    return result
end

"""
    simulate(jobs, resources, capacity = 1; queue_capacity = typemax(Int)) -> SimulationResult

Run to completion and return completed and rejected jobs separately.
`capacity` is a positive number of parallel worker slots,
passed positionally, as in `simulate(jobs, Dict(:db => 2), 3)`. Waiting jobs
start in FIFO order, but different service times can change completion order.
`resources` is a required dictionary of named pool capacities; use
`Dict{Symbol,Int}()` for no pools. Every run creates fresh pools and queues.
`queue_capacity` is the nonnegative limit on jobs waiting for a worker, not
on jobs holding workers or waiting for resources. Zero permits no worker
waiting; the default is effectively unbounded. Full worker queues reject
new arrivals with reason `:queue_full`.

The loop pops the earliest event, advances the virtual clock to it, and
dispatches to its handler without branching on event type. After each handler,
record queue length and worker occupancy through the current event time.

This explicit-job overload schedules every arrival up front. The `Scenario`
overload generates arrivals lazily, keeping only the next arrival on the
calendar alongside at most `capacity` service completions.
"""
function simulate(jobs::Vector{Job}, resources::Dict{Symbol,Int}, capacity::Int = 1;
                  queue_capacity::Int = typemax(Int))
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

    while !isempty(state.calendar)
        event = QueueLens.pop_next!(state)
        state.now = event.time
        handle!(state, event)
        observe_state!(state)
    end

    return SimulationResult(state.results, state.rejected, summarize_monitoring(state))
end

"""
    schedule_next_arrival!(state)

Draw the gap to the next arrival, create its `JobRecord`, and put its
`JobArrival` on the calendar — unless `scenario.num_jobs` arrivals have already
been generated, in which case do nothing and let the run wind down.

This is what keeps the calendar small. Scheduling every arrival up front makes
the calendar as large as the job count; generating them one at a time leaves it
holding only the next arrival and at most one completion per occupied worker
slot. Its size is bounded by `state.capacity + 1`, regardless of job count.

Both the gap and the service time are drawn here, in that order, from
`state.rng`. Changing the draw order changes the workload produced by a seed.
"""
function schedule_next_arrival!(state::SimState)
    if state.jobs_generated < state.scenario.num_jobs
        gap = sample(state.rng, state.scenario.arrivals)
        service_time = sample(state.rng, state.scenario.service)
        arrival_time = state.now + gap
        job_id = state.jobs_generated + 1
        job = Job(job_id, arrival_time, service_time)
        state.records[job_id] = JobRecord(job)
        QueueLens.schedule!(state, QueueLens.JobArrival(arrival_time, job_id))
        state.jobs_generated += 1
    end
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
    while !isempty(state.calendar)
        event = QueueLens.pop_next!(state)
        state.now = event.time
        handle!(state, event)
        observe_state!(state)
    end
    return SimulationResult(state.results, state.rejected, summarize_monitoring(state))
end


"""
    observe_state!(state::SimState) -> Nothing

Record worker queue length, occupied worker count and each resource's waiting
queue length and occupied slot count at `state.now`.
Each accumulator integrates its previous value before storing the new one.
Occupied workers include jobs waiting for shared resources; this records counts,
not capacity-normalized utilization. Only the accumulators are changed.

Both simulation loops call this after each handler, including the final event.
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

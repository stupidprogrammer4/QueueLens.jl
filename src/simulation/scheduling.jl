# Worker admission, service stages and FIFO resource scheduling.

"""
    start_current_step!(state, job_id)

Acquire the current stage's resource, if any, and schedule `StepCompleted` at
`state.now + step.duration`. A full pool queues the job without scheduling its
completion. An unregistered resource throws `ArgumentError`.
When no stages remain, schedule `ServiceCompleted` at `state.now`.

The job must already hold a worker slot. This helper does not change worker
occupancy, the job's start time, its step index, or its attempt identity.
Every completion captures the record's current attempt when scheduled.
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
            record.held_resource = step.resource
        end
        record.step_active = true
        completion_time = state.now + step.duration
        isfinite(completion_time) || throw(ArgumentError("step completion time overflow"))
        if step.failure_probability > 0 && rand(state.rng) < step.failure_probability
            schedule!(state, JobFailed(state.now + step.duration / 2, job_id, step_index,
                                      :stochastic; attempt_id=record.attempt_id))
        end
        schedule!(state, StepCompleted(completion_time, job_id, step_index; attempt_id=record.attempt_id))
    else
        schedule!(state, ServiceCompleted(state.now, job_id; attempt_id=record.attempt_id))
    end
    return nothing
end

"""
    start_next_job!(state)

If `in_use < capacity` and the waiting queue is non-empty, start one job from
the front. Increment `in_use`, record its start time, and schedule its
first step (or wait for its resource). Otherwise leave the state unchanged.

Step durations and resource names come from the job's own `JobRecord`.
If configured, schedule one whole-job timeout from this worker start. Reject
an overflowing or unrepresentable deadline before changing worker ownership.

Each arrival introduces one job and each whole-job completion frees one slot, so
starting at most one job per handler keeps the current fixed-capacity model
fully occupied whenever work is waiting. Bulk arrivals or capacity changes
would require revisiting this rule.
"""
function start_next_job!(state::SimState)
    rem = state.capacity - state.in_use
    if rem > 0 && !isempty(state.waiting)
        job_id = first(state.waiting)
        record = state.records[job_id]
        deadline = record.timeout === nothing ? nothing : state.now + record.timeout
        if deadline !== nothing && (!isfinite(deadline) || deadline <= state.now)
            throw(ArgumentError("job deadline must be finite and later than worker start"))
        end
        popfirst!(state.waiting)
        state.in_use += 1
        record.start_time = state.now
        if isnan(record.first_start_time)
            record.first_start_time = state.now
        end
        if deadline !== nothing
            schedule!(state, JobTimedOut(deadline, job_id; attempt_id=record.attempt_id))
        end
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
        schedule!(state, JobArrival(arrival_time, job_id))
        state.jobs_generated += 1
    end
end

"""
    release_resource!(state, record, resource = record.held_resource) -> Nothing

Release one acquired slot, clear the record's ownership and resume the first
resource waiter before any newly started worker job can take the slot.
`nothing` is a no-op. Callers validate the job before releasing capacity;
step completion supplies its validated stage resource explicitly.
Worker occupancy and terminal outcomes are unchanged.
"""
function release_resource!(state::SimState, record::JobRecord,
                           resource::Union{Nothing,Symbol} = record.held_resource)
    resource === nothing && return nothing
    release!(state.resources[resource])
    record.held_resource = nothing
    waiting = state.resource_waiting[resource]
    if !isempty(waiting)
        next_job_id = popfirst!(waiting)
        start_current_step!(state, next_job_id)
    end
    return nothing
end

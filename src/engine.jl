# Event handlers and the main loop.

"""
    handle!(state, event::JobArrival)

A job has arrived. Put it at the back of the FIFO waiting queue, then try to
start one job if a worker slot is available.

Arrival never starts a job directly: it only makes the queue non-empty and
lets [`start_next_job!`](@ref) decide. That keeps the "may the worker begin?"
rule in exactly one place.
"""
function handle!(state::SimState, event::JobArrival)
    state.waiting = push!(state.waiting, event.job_id)
    start_next_job!(state)
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
    start_next_job!(state)

If `in_use < capacity` and the waiting queue is non-empty, start one job from
the front. Increment `in_use`, record its start time, and schedule its
`ServiceCompleted`. Otherwise leave the state unchanged.

The service time comes from the job's own `JobRecord`, so callers need to know
nothing about how long work takes.

Each arrival introduces one job and each completion frees one slot, so
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
        completion_time = state.now + record.service_time
        QueueLens.schedule!(state, QueueLens.ServiceCompleted(completion_time, job_id))
    end
    
end

"""
    simulate(jobs, capacity = 1) -> Vector{JobResult}

Run the simulation to completion and return one `JobResult` per job, in
completion order. `capacity` is a positive number of parallel worker slots,
passed positionally, as in `simulate(jobs, 2)`. Waiting jobs start in FIFO
order, but different service times can put completions in a different order.

The loop pops the earliest event, advances the virtual clock to it, and
dispatches to its handler without branching on event type.

This explicit-job overload schedules every arrival up front. The `Scenario`
overload generates arrivals lazily, keeping only the next arrival on the
calendar alongside at most `capacity` service completions.
"""
function simulate(jobs::Vector{Job}, capacity::Int = 1)
    # The distributions are placeholders: this path never samples them, because
    # jobs_generated already sits at the limit, which switches lazy generation
    # off. See the `jobs_generated` note on SimState.
    scenario = Scenario(Constant(0.0), Constant(0.0), length(jobs), 0)
    state = SimState(scenario, capacity)
    state.jobs_generated = length(jobs)
    for job in jobs
        QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
        state.records[job.id] = JobRecord(job)
    end

    while !isempty(state.calendar)
        event = QueueLens.pop_next!(state)
        state.now = event.time
        handle!(state, event)
    end

    return state.results
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
    simulate(scenario::Scenario, capacity = 1) -> Vector{JobResult}

Run `scenario` with a positive number of worker slots and return one
`JobResult` per job, in completion order. Capacity is a positional argument
and defaults to one; the workload and seed remain in `Scenario`.

Builds the state, seeds it from `scenario.seed`, schedules the first arrival,
and then runs the same loop as [`simulate(::Vector{Job})`](@ref) — the loop
itself does not know arrivals are being generated as it goes.

The first arrival lands at `t = sample(rng, scenario.arrivals)`: the system
starts empty and waits one sampled gap. A zero gap, such as `Constant(0.0)`,
places the first arrival at zero. Explicit `Vector{Job}` inputs specify their
own arrival times.
"""
function simulate(scenario::Scenario, capacity::Int = 1)
    state = SimState(scenario, capacity)
    schedule_next_arrival!(state)
    while !isempty(state.calendar)
        event = QueueLens.pop_next!(state)
        state.now = event.time
        handle!(state, event)
    end
    return state.results
end

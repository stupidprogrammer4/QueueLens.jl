# Event handlers and the main loop.

"""
    handle!(state, event::JobArrival)

A job has arrived. Put it at the back of the waiting queue, then give the
worker a chance to pick something up.

Arrival never starts a job directly: it only makes the queue non-empty and
lets [`start_next_job!`](@ref) decide. That keeps the "may the worker begin?"
rule in exactly one place.
"""
function handle!(state::SimState, event::JobArrival)
    state.waiting = push!(state.waiting, event.job_id)
    start_next_job!(state)
end

"""
    handle!(state, event::ServiceCompleted)

The worker has finished a job. Record its `JobResult`, free the worker, then
give it a chance to pick up the next job.

Invariant (guide section 12: every logical job has one terminal outcome) —
the record is deleted once its result is built, so a second `ServiceCompleted`
for the same job finds nothing and throws `ArgumentError` instead of quietly
producing a duplicate result. Milestone 4 relies on this when stale
completions arrive for attempts that already timed out.
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
        state.busy = false
        start_next_job!(state)
    else
        throw(ArgumentError("ServiceCompleted for unknown job id $(event.job_id)"))
    end
end

"""
    start_next_job!(state)

If the worker is free and the waiting queue is non-empty, take the job at the
front, mark the worker busy, record its start time, and schedule its
`ServiceCompleted`. Otherwise do nothing — a busy worker or an empty queue is
an ordinary situation, not an error.

The service time comes from the job's own `JobRecord`, so callers need to know
nothing about how long work takes.

Both `handle!` methods call this, because those are the only two moments when
the worker can possibly pick up new work: something arrived, or something
finished. Keeping the rule in one place means milestone 3 only has to change
one function when a database pool becomes a second precondition.
"""
function start_next_job!(state::SimState)
    if ~state.busy && !isempty(state.waiting)
        job_id = popfirst!(state.waiting)
        state.busy = true
        record = state.records[job_id]
        record.start_time = state.now
        completion_time = state.now + record.service_time
        QueueLens.schedule!(state, QueueLens.ServiceCompleted(completion_time, job_id))
    end
    
end

"""
    simulate(jobs) -> Vector{JobResult}

Run the simulation to completion and return one `JobResult` per job, in
completion order.

The loop is deliberately ignorant of event types: it pops the earliest event,
advances the virtual clock to it, and dispatches. Adding `RetryReady` in
milestone 4 will not touch a single line of this function.

Every arrival is scheduled up front. Milestone 2 replaces that with lazy
generation — each arrival scheduling the next — so that the calendar holds a
handful of events rather than one per job.
"""
function simulate(jobs::Vector{Job})
    state = SimState()
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

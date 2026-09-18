"""Construct all attempt-bearing event kinds with the same identity and time."""
function attempt_events(attempt_id; time=2.0, job_id=1)
    return (QueueLens.StepCompleted(time, job_id, 1; attempt_id),
            QueueLens.ServiceCompleted(time, job_id; attempt_id),
            QueueLens.JobFailed(time, job_id, 1; attempt_id),
            QueueLens.JobTimedOut(time, job_id; attempt_id))
end

"""Snapshot operational state and monitoring for no-mutation assertions."""
function attempt_snapshot(state)
    stat_values(stat) = (stat.area, stat.last_time, stat.last_value)
    return (
        now=state.now, in_use=state.in_use, waiting=copy(state.waiting),
        records=Dict(id => deepcopy(Tuple(getfield(record, f) for f in fieldnames(typeof(record))))
                     for (id, record) in state.records),
        pools=Dict(name => (pool.capacity, pool.in_use) for (name, pool) in state.resources),
        resource_waiting=deepcopy(state.resource_waiting),
        results=copy(state.results), failed=copy(state.failed), rejected=copy(state.rejected),
        failed_ids=copy(state.failed_ids), calendar=attempt_calendar(state),
        sequence=state.next_sequence, generated=state.jobs_generated,
        max_calendar_size=state.max_calendar_size, clock_log=copy(state.clock_log),
        queue_stat=stat_values(state.queue_length_stat),
        worker_stat=stat_values(state.worker_busy_stat),
        resource_queue=Dict(k => stat_values(v) for (k, v) in state.res_queue_stat),
        resource_busy=Dict(k => stat_values(v) for (k, v) in state.res_busy_stat),
    )
end

"""
Prepare an attempt-two record before worker start so scheduled events capture
its identity. This fixture does not implement retry or reuse terminal records.
"""
function attempt_fixture(; resource=:db, steps=nothing, timeout=20.0)
    resources = resource === nothing ? Dict{Symbol,Int}() : Dict(resource => 1)
    steps = steps === nothing ? [QueueLens.ServiceStep(resource, 5.0)] : steps
    state = failure_fixture([Job(1, 0.0, steps; timeout)], resources)
    state.records[1].attempt_id = 2
    QueueLens.handle!(state, QueueLens.pop_next!(state))
    QueueLens.observe_state!(state)
    return state
end
using DataStructures: extract_all!

"""Read scheduled entries in order without consuming the live heap."""
attempt_calendar(state) = extract_all!(deepcopy(state.calendar))

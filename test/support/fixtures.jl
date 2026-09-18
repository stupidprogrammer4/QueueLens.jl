"""
    failure_fixture(jobs, resources, capacity = 1)

Build a test-owned run with explicit arrivals and no lazy generation. Expose
its calendar and state for direct fault scheduling and ownership checks.
"""
function failure_fixture(jobs, resources, capacity = 1)
    scenario = Scenario(Constant(0.0), Constant(0.0), length(jobs), 42)
    state = QueueLens.SimState(scenario, resources, capacity)
    state.jobs_generated = length(jobs)
    for job in jobs
        state.records[job.id] = QueueLens.JobRecord(job)
        QueueLens.schedule!(state, QueueLens.JobArrival(job.arrival_time, job.id))
    end
    return state
end

"""
    active_failure_fixture(; resource = :db)

Start one five-second stage and advance the test clock to time two. No fault
is dispatched: this fixture tests ownership and failure bookkeeping alone.
"""
function active_failure_fixture(; resource = :db)
    resources = resource === nothing ? Dict{Symbol,Int}() : Dict(resource => 1)
    state = failure_fixture([Job(1, 0.0, [QueueLens.ServiceStep(resource, 5.0)])], resources)
    event = QueueLens.pop_next!(state)
    state.now = event.time
    QueueLens.handle!(state, event)
    QueueLens.observe_state!(state)
    state.now = 2.0
    QueueLens.observe_state!(state)
    return state
end

"""
    timeout_fixture(; waiting = false, resource = :db)

Start a job with a two-second deadline, either executing or waiting for a DB
held by another job. Return state at the deadline before timeout dispatch.
Uses failure_fixture to expose state without dispatching the timeout handler.
"""
function timeout_fixture(; waiting = false, resource = :db)
    jobs = waiting ? [Job(1, 0.0, [QueueLens.ServiceStep(:db, 5.0)]),
                      Job(2, 0.0, [QueueLens.ServiceStep(:db, 1.0)]; timeout=2.0)] :
                     [Job(1, 0.0, [QueueLens.ServiceStep(resource, 5.0)]; timeout=2.0)]
    resources = resource === nothing ? Dict{Symbol,Int}() : Dict(:db => 1)
    state = failure_fixture(jobs, resources, waiting ? 2 : 1)
    for _ in jobs
        event = QueueLens.pop_next!(state)
        state.now = event.time
        QueueLens.handle!(state, event)
        QueueLens.observe_state!(state)
    end
    state.now = 2.0
    QueueLens.observe_state!(state)
    return state
end

"""
    drain_fixture!(state) -> SimState

Use the production event loop while retaining state for ownership, queue and
terminal-outcome assertions. Expected timelines are asserted independently
by each test; there is no separate test-only simulation implementation.
"""
function drain_fixture!(state)
    QueueLens.run!(state)
    return state
end

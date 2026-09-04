# Job entities: the input, the in-flight bookkeeping, and the output.

"""
    Job(id, arrival_time, service_time)

A unit of work entering the system. Immutable: a job's identity, arrival time
and service demand are facts that never change once the job exists.

`service_time` lives on the job rather than being a parameter of the run,
because in milestone 2 each job draws its own service time from a
distribution. A single per-run service time is just the degenerate case where
every job happens to draw the same number.
"""
struct Job
    id::Int
    arrival_time::Float64
    service_time::Float64
end

"""
    JobRecord(job)

Mutable bookkeeping for a job that is currently inside the system.

The engine needs `arrival_time` and `start_time` when it finally builds a
`JobResult`, and `service_time` when the worker picks the job up — but by
then the arrival event is long gone from the calendar. `JobRecord` is where
that information lives in the meantime.

`start_time` is `NaN` until the job actually enters service. Milestone 4 will
add `attempt` and timeout bookkeeping here.
"""
mutable struct JobRecord
    id::Int
    arrival_time::Float64
    service_time::Float64
    start_time::Float64
end

JobRecord(job::Job) = JobRecord(job.id, job.arrival_time, job.service_time, NaN)

"""
    JobResult(id, arrival_time, start_time, completion_time, waiting_time, latency)

The terminal outcome of one job. Immutable — a completed job is history.

Invariants (guide section 12: every logical job has one terminal outcome):

  - `arrival_time <= start_time <= completion_time`
  - `waiting_time == start_time - arrival_time`
  - `latency == completion_time - arrival_time`
"""
struct JobResult
    id::Int
    arrival_time::Float64
    start_time::Float64
    completion_time::Float64
    waiting_time::Float64
    latency::Float64
end

module QueueLens

struct Job
    id::Int
    arrival_time::Float64
end

struct JobResult
    id::Int
    arrival_time::Float64
    completion_time::Float64
    waiting_time::Float64
    latency::Float64
end

function process_jobs(jobs::Vector{Job}, service_time::Float64)
    queue::Vector{JobResult} = []
    jobs = sort(jobs, by=x -> x.arrival_time)
    worker_free_at = 0.0
    for job in jobs
        worker_free_at = max(worker_free_at, job.arrival_time)
        completion_time = worker_free_at + service_time
        waiting_time = worker_free_at - job.arrival_time
        latency = waiting_time + service_time
        push!(queue, JobResult(job.id, job.arrival_time, completion_time, waiting_time, latency))
        worker_free_at = completion_time
    end
    return queue
end

end # module QueueLens

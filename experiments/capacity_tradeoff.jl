# Does adding workers help when the database is the bottleneck?
# Run with: julia --project=. experiments/capacity_tradeoff.jl

using QueueLens

"""
    run_capacity_comparison()

Run four simultaneous jobs, each requiring a three-second DB step, under
three worker/DB capacity pairs. All worker queues are unbounded. Each run
creates fresh jobs and pools; no randomness or warm-up discard is involved.
Return labeled simulation results for inspection or regression tests.
"""
function run_capacity_comparison()
    configurations = ((name = "A", workers = 2, db_capacity = 1),
                      (name = "B", workers = 4, db_capacity = 1),
                      (name = "C", workers = 2, db_capacity = 2))
    return map(configurations) do config
        jobs = [Job(i, 0.0, [QueueLens.ServiceStep(:db, 3.0)]) for i in 1:4]
        result = simulate(jobs, Dict(:db => config.db_capacity), config.workers)
        return (; config..., result)
    end
end

"""
    main(io = stdout)

Display capacity, completion times and time-weighted monitoring for each case.
Queue metrics are mean counts and utilization values are fractions over the
full run, from time zero through the final event.
"""
function main(io::IO = stdout)
    cases = run_capacity_comparison()
    println(io, "Four jobs at time 0, each with one 3-second DB step.")
    println(io, "Unbounded worker queues; deterministic workload; no warm-up discard.")
    println(io)
    println(io, rpad("case", 6), lpad("workers", 9), lpad("DB slots", 10),
            lpad("end (s)", 10), lpad("worker queue", 15), lpad("DB queue", 12),
            lpad("worker util", 14), lpad("DB util", 10))
    println(io, "-"^86)
    for case in cases
        stats = case.result.monitoring
        db = stats.resources[:db]
        println(io, rpad(case.name, 6), lpad(case.workers, 9), lpad(case.db_capacity, 10),
                lpad(stats.duration, 10), lpad(round(stats.mean_queue_length, digits = 3), 15),
                lpad(round(db.mean_queue_length, digits = 3), 12),
                lpad(round(stats.worker_utilization, digits = 3), 14),
                lpad(round(db.utilization, digits = 3), 10))
    end
    println(io)
    for case in cases
        times = join((job.completion_time for job in case.result.completed), ", ")
        println(io, case.name, " completion times (s): ", times)
    end
    println(io)
    println(io, "Queue columns are time-weighted mean counts; utilization is a fraction.")
    println(io, "Each observation window runs from 0 to that case's final event.")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

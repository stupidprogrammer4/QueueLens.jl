# Does service-time variance matter when the mean is held fixed?
#
# Compares simulated mean waiting time against the Pollaczek-Khinchine formula
# for M/G/1, with and without a warm-up discard, using a single seed.
# Seed-to-seed uncertainty is measured separately with simulate_repeated.
#
# Run with:  julia --project=. experiments/variance_effect.jl

using QueueLens

const RATE     = 8.0    # arrivals per second
const MEAN_SVC = 0.1    # seconds
const NUM_JOBS = 50_000 # workload size for each service distribution
const SEED     = 42    # reproducible single-run comparison
const WARMUP   = 0.1   # fraction of completed jobs discarded for warm summaries

const RHO = RATE * MEAN_SVC # offered load for the single-worker experiment

"""
    pk_mean_wait(cv2)

Mean waiting time for an M/G/1 queue by the Pollaczek-Khinchine formula, where
`cv2` is the squared coefficient of variation of the service time.

    W = rho * E[S] * (1 + C^2) / (2 * (1 - rho))

At `cv2 = 0` (constant service) this is the smallest waiting time any service
distribution with this mean can produce. Everything above it is variance.
"""
pk_mean_wait(cv2) = RHO * MEAN_SVC * (1 + cv2) / (2 * (1 - RHO))

"""
    lognormal_with_mean(mean, sigma)

Convert a positive arithmetic mean and log-space standard deviation to the
parameters accepted by `LogNormal`, using `mu = log(mean) - sigma^2 / 2`.
"""
lognormal_with_mean(mean, sigma) = LogNormal(log(mean) - sigma^2 / 2, sigma)

# For a log-normal, C^2 = exp(sigma^2) - 1.
cases = [
    ("Constant",       Constant(MEAN_SVC),                       0.0),
    ("LogNormal s=0.6", lognormal_with_mean(MEAN_SVC, 0.6),      exp(0.6^2) - 1),
    ("LogNormal s=1.0", lognormal_with_mean(MEAN_SVC, 1.0),      exp(1.0^2) - 1),
]

"""
    main()

Run each service distribution with the same arrival model and seed. Print
theoretical mean waiting time, raw and warm-up-adjusted simulated waiting,
and warm-up-adjusted P99 latency to compare the effect of service variance.
"""
function main()
    println("arrivals = Exponential($RATE)   mean service = $(MEAN_SVC)s   rho = $RHO")
    println("$NUM_JOBS jobs, seed $SEED, warm-up discard = $(round(Int, WARMUP * 100))%")
    println()
    println(rpad("service", 17), lpad("C^2", 7), lpad("W theory", 10),
            lpad("W raw", 9), lpad("W warm", 9), lpad("P99 lat", 9))
    println("-"^62)

    for (name, service, cv2) in cases
        results = simulate(Scenario(Exponential(RATE), service, NUM_JOBS, SEED), Dict{Symbol,Int}())
        raw  = summarize(results)
        warm = summarize(results; warmup_fraction = WARMUP)

        println(rpad(name, 17),
                lpad(round(cv2, digits = 2), 7),
                lpad(round(pk_mean_wait(cv2), digits = 3), 10),
                lpad(round(raw.mean_waiting, digits = 3), 9),
                lpad(round(warm.mean_waiting, digits = 3), 9),
                lpad(round(warm.p99_latency, digits = 3), 9))
    end

    println()
    println("W theory assumes steady state; this experiment uses one seed.")
    println("Warm-up need not close the gap. Use repeated seeds to assess uncertainty.")
end

main()

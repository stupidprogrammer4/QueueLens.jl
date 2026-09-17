# Print a text histogram of each distribution, so their shapes can be compared
# side by side without a plotting dependency.
#
# Run with:  julia --project=. experiments/distribution_shapes.jl

using Random
using QueueLens
using Statistics

"""
    histogram(samples; bins, width) -> nothing

Print a text histogram of `samples`.

Use equal-width bins spanning the sample range. Label each row with its bin
edges and share of all samples; bar length is that share times `width`.
Identical samples produce a single full-width row.

The current indexing excludes samples mapped past the last bin, including
the maximum for an exactly representable upper edge.
"""
function histogram(samples::Vector{Float64}; bins::Int = 20, width::Int = 50)
    hi = maximum(samples)
    lo = minimum(samples)
    bin_width = (hi - lo) / bins
    if bin_width == 0.0
        println(repeat("#", width), "  all samples are ", lo)
        return
    end
    counts = zeros(Int, bins)
    for sample in samples
        bin = floor(Int, (sample - lo) / bin_width) + 1
        if 1 <= bin <= bins
            counts[bin] += 1
        end
    end
    for (bin, count) in enumerate(counts)
        share = count / length(samples)
        edge_lo = lo + (bin - 1) * bin_width
        edge_hi = lo + bin * bin_width
        println(lpad(round(edge_lo, digits=2), 7), " – ", lpad(round(edge_hi, digits=2), 7),
                " | ", rpad(repeat("#", round(Int, share * width)), width),
                " ", lpad(round(100 * share, digits=1), 5), "%")
    end
end

"""
    main()

Print seeded sample histograms for four distributions with the same mean.
Use one RNG stream so rerunning the experiment reproduces every histogram.
"""
function main()
    rng = Xoshiro(42)
    n = 100_000

    # All four distributions have mean 3.0, with different variances and tails.
    for (name, d) in (
        ("Constant(3.0)",             Constant(3.0)),
        ("Exponential(1/3)",          Exponential(1 / 3)),
        ("LogNormal(mean 3, s=0.6)",  LogNormal(log(3.0) - 0.6^2 / 2, 0.6)),
        ("LogNormal(mean 3, s=1.2)",  LogNormal(log(3.0) - 1.2^2 / 2, 1.2)),
    )
        println("\n", name, "  (n = ", n, ")")
        println("-"^70)
        histogram(sample(rng, d, n))
    end
end

main()

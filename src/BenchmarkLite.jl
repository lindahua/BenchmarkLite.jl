module BenchmarkLite

import Base: size, length, get, getindex, run, show

export BenchmarkTable, BenchmarkEntry, cfgname, procname

##### Types

## The abstract type to represent a (typed) procedure
#
# Following methods should be defined on each subtype of Proc
#
# - string(proc):          get a description
# - length(proc):          the problem size (e.g. the number of elements to process)
# - isvalid(proc, cfg):    test whether a config is valid for the given proc
#
# - s = start(proc, cfg):  set up (not count in the run-time)
# - run(proc, cfg, s):     run the procedure under the given config  
# - done(proc, cfg, s):    tear down (not count in the run-time)
#
abstract Proc
                  

##### Results

type BenchmarkTable
    cfgs::Vector        # length = m
    procs::Vector       # length = n
    plens::Vector{Int}  # n vector, proc lengths
    nruns::Matrix{Int}      # m-by-n matrix, number of repeat times (in measuring stage)
    etime::Matrix{Float64}  # m-by-n matrix, elapsed time (in measuring stage)
end

function BenchmarkTable(cfgs::Vector, procs::Vector)
    m = length(cfgs)
    n = length(procs)
    for p in procs
        isa(p, Proc) || error("Each element in procs must be an instance of Proc.")
    end
    plens = Int[length(p) for p in procs]
    nruns = zeros(Int, m, n)
    etime = zeros(m, n)
    BenchmarkTable(cfgs, procs, plens, nruns, etime)
end

cfgname(bt::BenchmarkTable, i::Integer) = string(bt.cfgs[i])
procname(bt::BenchmarkTable, i::Integer) = string(bt.procs[i])

immutable BenchmarkEntry
    plen::Int       # proc length
    nruns::Int      # number of repeat times
    etime::Float64  # elapsed time (in seconds)
end

size(bt::BenchmarkTable) = (length(bt.cfgs), length(bt.procs))

size(bt::BenchmarkTable, i::Integer) = i == 1 ? length(bt.cfgs) :
                                       i == 2 ? length(bt.procs) : 1

getindex(bt::BenchmarkTable, i::Integer, j::Integer) = 
    BenchmarkEntry(bt.plens[j], bt.nruns[i,j], bt.etime[i,j])


##### Show Results

abstract BenchmarkUnit

type Sec <: BenchmarkUnit end
type Msec <: BenchmarkUnit end
type Usec <: BenchmarkUnit end
type Kps <: BenchmarkUnit end
type Mps <: BenchmarkUnit end
type Gps <: BenchmarkUnit end

get(e::BenchmarkEntry, unit::Sec) = e.etime
get(e::BenchmarkEntry, unit::Msec) = e.etime * 1.0e3
get(e::BenchmarkEntry, unit::Usec) = e.etime * 1.0e6
get(e::BenchmarkEntry, unit::Kps) = (1.0e-3 * e.plen * e.nruns) / e.etime
get(e::BenchmarkEntry, unit::Mps) = (1.0e-6 * e.plen * e.nruns) / e.etime
get(e::BenchmarkEntry, unit::Gps) = (1.0e-9 * e.plen * e.nruns) / e.etime


function _show_table(bt::BenchmarkTable, unit::BenchmarkUnit)
    m = length(bt.cfgs)
    n = length(bt.procs)
    S = Matrix(String, m+1, n+1)
    S[1,1] = ""
    for j=1:n; S[1,j+1] = procname(bt,j); end
    for i=1:m; S[i+1,1] = cfgname(bt,i); end

    for j=1:n, i=1:m
        v = get(bt[i,j], unit)::Float64
        S[i+1,j+1] = @sprintf("%.4f", v)
    end
    return S
end

function show(io::IO, bt::BenchmarkTable; unit::Symbol=:sec)
    # getting all strings first
    u = unit == :sec ? Sec() :
        unit == :msec ? MSec() :
        unit == :usec ? USec() :
        unit == :kps ? Kps() :
        unit == :mps ? Mps() :
        unit == :gps ? Gps() : 
        error("Invalid unit value :$(unit).")
    S = _show_table(bt, unit)
    nrows, ncols = size(S)

    # calculate the width of each column
    colwids = Array(Int, ncols)
    for j = 1:ncols
        w = 1
        for i = 1:nrows
            wij = length(S[i,j])
            if wij > w; w = wij; end
        end
        colwids[j] = w
    end

    # print the table
    for i = 1:nrows
        # first column
        print(io, rpad(S[i,1], colwids[1]))
        print(io, "  ")
        # remaining columns
        for j = 2:ncols
            print(io, lpad(S[i,j], colwids[j]))
            print(io, "  ")
        end
        println(io)
    end
end


##### Run Benchmarks

function run{P<:Proc}(p::P, cfg; 
                      nruns::Int = 0, duration::Float64=1.0, allowgc::Bool=true)
    # Run a procedure under a certain config
    #
    # Arguments:
    #
    #   - p:        the procedure to be tested
    #   - cfg:      the configuration to be tested
    #   - nruns:    the number of repeating times (in measuring stage)
    #
    # Keyword arguments:
    #
    #   - duration: the rough duration of the whole multi-run process
    #
    #   When nruns > 0, it runs a fixed number of times in measuring stage,
    #   otherwise, it uses a probing stage to roughly measure the runtime
    #   for each run, and uses it to determine nruns.
    #
    # Returns:  (nruns, etime)
    #
    #   - nruns:    the actual number of running times (in measuring stage)
    #   - etime:    the elapsed seconds (in measuring stage)
    #

    # check validity
    if !isvalid(p, cfg)
        return (0, 0.0)
    end

    # set up
    s = start(p, cfg)

    # warming
    run(p, cfg, s)

    if !allowgc
        gc_disable()
    end

    # probing
    if nruns <= 0
        et = @elapsed run(p, cfg)
        nruns = iceil(duration / et)
    end

    # measuring
    etime = @elapsed for i = 1:nruns
        run(p, cfg)
    end

    # tear down
    done(p, cfg, s)

    if !allowgc
        gc_enable()
    end

    return (nruns, etime)
end


function run(procs::Vector, cfgs::Vector; 
             duration::Float64=1.0, verbose::Int=2, logger::IO=STDOUT)
    # Run a list of procedures against a list of configurations
    #
    # Arguments:
    #
    #   - procs:    the list of procedures to run
    #   - cfgs:     the list of configurations to run
    #   
    # Keyword arguments:
    #
    #   - duration: the duration for each procedure on each config
    #   - verbose:  0 - prints nothing 
    #               1 - prints one line for each procedure 
    #               2 - prints one line for each procedure on each config
    #   - logger:   the IO to which the information is sent
    #   
    # Returns: a BenchmarkTable instance capturing all results
    #

    bt = BenchmarkTable(cfgs, procs)
    m = length(cfgs)
    n = length(procs)
    for (j, p) in procs
        procname = string(p)
        verbose >= 1 && println(logger, "Benchmarking $procname ...")

        for (i, cfg) in cfgs
            cfgname = string(cfg)
            (nr, et) = run(p, cfg; duration=duration)

            bt.nruns[i, j] = nr
            bt.etime[i, j] = et

            verbose >= 2 && 
                println(logger, "  $procname with cfg = $cfgname: nruns = $nr, elapsed = $et secs")
        end
    end
    return bt
end


end # module

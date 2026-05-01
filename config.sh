#!/usr/bin/env bash
# =============================================================================
# config.sh — Central configuration for OSU MPI benchmark suite
# Edit this file to match your system before running any scripts.
# =============================================================================

# -----------------------------------------------------------------------------
# OSU benchmark installation
# Set OSU_ROOT only if you have a single pre-built OSU installation.
# If you use build_osu.sh, OSU_INSTALLATIONS is populated automatically
# (see bottom of this file) and OSU_ROOT is not used.
# -----------------------------------------------------------------------------
OSU_ROOT="/home/lcebamanos/test/osu-bench-suite/osu-builds/openmpi-ucx/osu-micro-benchmarks-7.5.1/libexec/osu-micro-benchmarks"
OSU_COLLECTIVE="${OSU_ROOT}/mpi/collective"
OSU_PT2PT="${OSU_ROOT}/mpi/pt2pt"
OSU_ONE_SIDED="${OSU_ROOT}/mpi/one-sided"

# -----------------------------------------------------------------------------
# MPI installations to compare
#
# Two modes — pick one per label:
#
# MODE A: module-based (most HPC clusters)
#   Set MPI_MODULES["label"]="module1 module2 ..."
#   After loading, mpirun is resolved from PATH automatically.
#   Leave MPI_INSTALLATIONS["label"] empty or omit it.
#
# MODE B: explicit path
#   Set MPI_INSTALLATIONS["label"]="/full/path/to/mpirun"
#   Leave MPI_MODULES["label"] empty or omit it.
#
# You can mix both modes across labels.
# Each label becomes a column in plots and a subdirectory in results/.
# -----------------------------------------------------------------------------

# Labels — defines which MPI installations to benchmark
MPI_LABELS=(
    openmpi-ucx
    openmpi-hcoll
    openmpi-ucc
    intelmpi
)

# Module(s) to load per label (space-separated, loaded in order)
# Leave empty string "" if using explicit path for that label instead.
declare -A MPI_MODULES=(
    ["openmpi-ucx"]="amd-compilers aocc/5.1.0 openmpi"
#    ["openmpi-hcoll"]="OpenMPI/5.0.3-GCC-13.3.0-hcoll"
#    ["openmpi-ucc"]="OpenMPI/5.0.3-GCC-13.3.0-ucc"
#    ["intelmpi"]="intel-oneapi-mpi/2021.13"
)

# Explicit mpirun path per label (used only if MPI_MODULES entry is empty)
# Leave empty string "" if using modules for that label instead.
declare -A MPI_INSTALLATIONS=(
    ["openmpi-ucx"]=""
    ["openmpi-hcoll"]=""
    ["openmpi-ucc"]=""
    ["intelmpi"]=""
)

# Extra mpirun flags per label (optional, space-separated)
declare -A MPI_EXTRA_FLAGS=(
    ["openmpi-ucx"]="--mca pml ucx --mca osc ucx"
    ["openmpi-hcoll"]="--mca coll_hcoll_enable 1 --mca pml ucx"
    ["openmpi-ucc"]="--mca coll_ucc_enable 1 --mca pml ucx"
    ["intelmpi"]=""
)

# Environment variables to set per label (optional)
# Useful for UCX_TLS, HCOLL_*, I_MPI_* etc.
declare -A MPI_ENV_VARS=(
    ["openmpi-ucx"]="UCX_TLS=rc,sm"
    ["openmpi-hcoll"]="UCX_TLS=rc,sm HCOLL_ENABLE_MCAST_ALL=1"
    ["openmpi-ucc"]="UCX_TLS=rc,sm UCC_TLS=ucp"
    ["intelmpi"]="I_MPI_FABRICS=shm:ofi"
)

# -----------------------------------------------------------------------------
# Helper: resolve mpirun for a given label at runtime
# Usage: mpirun=$(get_mpirun "$label")
# -----------------------------------------------------------------------------
get_mpirun() {
    local label="$1"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"
    local modules="${MPI_MODULES[$label]:-}"

    if [[ -n "$explicit" ]]; then
        # Mode B: explicit path
        echo "$explicit"
    elif [[ -n "$modules" ]]; then
        # Mode A: resolve from PATH after module load
        # This function is called in the current shell so modules are active
        for mod in $modules; do
            module load "$mod" 2>/dev/null || {
                echo "ERROR: failed to load module: $mod" >&2
                return 1
            }
        done
        command -v mpirun || command -v srun || {
            echo "ERROR: mpirun not found after loading modules for $label" >&2
            return 1
        }
    else
        echo "ERROR: no module or path defined for label: $label" >&2
        return 1
    fi
}

# Helper: emit shell commands that load modules for a label
# Used in Slurm job scripts where we need to embed module load commands
get_module_load_cmds() {
    local label="$1"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"
    local modules="${MPI_MODULES[$label]:-}"
    local env_vars="${MPI_ENV_VARS[$label]:-}"

    if [[ -n "$modules" ]]; then
        echo "source \$(pkg config --variable=prefix modules 2>/dev/null)/etc/profile.d/modules.sh 2>/dev/null || true"
        for mod in $modules; do
            echo "module load ${mod}"
        done
    fi

    # Export any extra env vars
    for kv in $env_vars; do
        echo "export ${kv}"
    done
}

# Helper: get the mpicc compiler for a label (used by build_osu.sh)
get_mpicc() {
    local label="$1"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"

    if [[ -n "$explicit" ]]; then
        echo "$(dirname "$explicit")/mpicc"
    else
        # Module-based: mpicc is on PATH after module load
        echo "mpicc"
    fi
}

get_mpicxx() {
    local label="$1"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"

    if [[ -n "$explicit" ]]; then
        echo "$(dirname "$explicit")/mpicxx"
    else
        echo "mpicxx"
    fi
}

get_mpifort() {
    local label="$1"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"

    if [[ -n "$explicit" ]]; then
        echo "$(dirname "$explicit")/mpifort"
    else
        echo "mpifort"
    fi
}

# -----------------------------------------------------------------------------
# Hostfile / node configuration
# -----------------------------------------------------------------------------
RANKS_PER_NODE="${RANKS_PER_NODE:-192}" # set to your node's physical core count

# Node counts to sweep for collective benchmarks
NODE_COUNTS=( 2 )

# -----------------------------------------------------------------------------
# Scheduler (set to "slurm", "pbs", or "none")
# -----------------------------------------------------------------------------
SCHEDULER="${SCHEDULER:-slurm}"

# Slurm settings
SLURM_PARTITION="${SLURM_PARTITION:-amd9654}"
SLURM_TIME="${SLURM_TIME:-02:00:00}"
SLURM_ACCOUNT="${SLURM_ACCOUNT:-}"
SLURM_CONSTRAINT="${SLURM_CONSTRAINT:-}"

# -----------------------------------------------------------------------------
# Benchmark parameters
# -----------------------------------------------------------------------------
MSG_MIN=1
MSG_MAX=$((1 * 256 * 256))   # 1 MiB — increase for bandwidth benchmarks

ITERATIONS=1000
WARMUP=200

# Collective benchmarks to run
COLLECTIVES=(
    osu_allreduce
    osu_alltoall
    osu_allgather
    osu_bcast
    osu_barrier
    osu_reduce
    osu_reduce_scatter
    osu_alltoallv
)

# Point-to-point benchmarks to run
PT2PT=(
    osu_latency
    osu_bw
    osu_bibw
    osu_mbw_mr
    osu_latency_mp
)

# -----------------------------------------------------------------------------
# Results and output
# -----------------------------------------------------------------------------
RESULTS_DIR="$(pwd)/results"
PLOTS_DIR="$(pwd)/plots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${RESULTS_DIR}/logs_${TIMESTAMP}"



# --- Generated by build_osu.sh on 2026-05-01 11:09 ---
declare -A OSU_INSTALLATIONS=(
    ["openmpi-ucx"]="/home/lcebamanos/test/osu-bench-suite/osu-builds/openmpi-ucx/osu-micro-benchmarks-7.5.1/libexec/osu-micro-benchmarks"
)

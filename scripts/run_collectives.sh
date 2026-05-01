#!/usr/bin/env bash
# =============================================================================
# run_collectives.sh — OSU collective benchmarks, all MPI labels sequential
#
# Submit:    sbatch scripts/run_collectives.sh
# Or direct: bash scripts/run_collectives.sh --dry-run
#
# Node allocation must be >= max(NODE_COUNTS) from config.sh.
# Node sweeps are done by varying -np: mpirun uses Slurm's PMI to discover
# nodes — no hostfile needed.
#
# Options:
#   --dry-run      Print mpirun commands without executing
#   --mpi LABEL    Run only this MPI label
#   --nodes N      Run only this node count
#   --bench NAME   Run only this benchmark
# =============================================================================

#SBATCH --job-name=osu_collectives
#SBATCH --nodes=8
#SBATCH --partition=compute
#SBATCH --time=04:00:00
#SBATCH --output=/tmp/osu_collectives_%j.out
#SBATCH --error=/tmp/osu_collectives_%j.err
# Note: output/error paths are overridden by submit.sh at submission time.
# The /tmp fallback above only applies if you sbatch this script directly.
# Uncomment if needed:
# #SBATCH --account=your_account
# #SBATCH --constraint=infiniband

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ ! -f "${SUITE_DIR}/config.sh" ]]; then
    SUITE_DIR="$(pwd)"
fi
cd "${SUITE_DIR}"
source "${SUITE_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
FILTER_MPI=""
FILTER_NODES=""
FILTER_BENCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --mpi)      FILTER_MPI="$2";   shift ;;
        --nodes)    FILTER_NODES="$2"; shift ;;
        --bench)    FILTER_BENCH="$2"; shift ;;
        *) ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()     { echo "[$(date '+%H:%M:%S')] $*"; }
run_cmd() { if [[ $DRY_RUN -eq 1 ]]; then echo "    [DRY-RUN] $*"; else eval "$*"; fi; }

load_mpi() {
    local label="$1"
    local module_paths="${MPI_MODULE_PATHS[$label]:-}"
    local modules="${MPI_MODULES[$label]:-}"
    local explicit="${MPI_INSTALLATIONS[$label]:-}"
    if [[ -n "$explicit" ]]; then
        MPIRUN="$explicit"
    else
        for path in $module_paths; do
            module use "$path" 2>/dev/null || {
                log "  ERROR: failed to add module path: $path"; return 1
            }
        done
        for mod in $modules; do
            module load "$mod" 2>/dev/null || {
                log "  ERROR: failed to load module: $mod"; return 1
            }
        done
        MPIRUN=$(command -v mpirun 2>/dev/null || echo "mpirun")
    fi
    for kv in ${MPI_ENV_VARS[$label]:-}; do export "${kv?}"; done
    log "  mpirun : ${MPIRUN}"
}

unload_mpi() {
    local label="$1"
    local modules="${MPI_MODULES[$label]:-}"
    [[ -n "$modules" ]] && module unload $modules 2>/dev/null || true
    for kv in ${MPI_ENV_VARS[$label]:-}; do unset "${kv%%=*}" 2>/dev/null || true; done
}

check_binary() {
    local bin="$1"
    [[ -x "$bin" ]] && return 0
    log "  ERROR: binary not found: $bin"
    return 1
}

# ---------------------------------------------------------------------------
# Validate node count against Slurm allocation
# ---------------------------------------------------------------------------
validate_nodes() {
    local requested="$1"
    local available="${SLURM_JOB_NUM_NODES:-999}"
    if [[ $requested -gt $available ]]; then
        log "  WARNING: ${requested} nodes requested but only ${available} in allocation — skipping"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Run a single collective benchmark
#
# Node sweep: -np controls how many ranks are launched. With --map-by node
# OpenMPI places exactly RANKS_PER_NODE ranks on each of the first N nodes
# in the Slurm allocation. No hostfile needed — Slurm's PMI plugin provides
# the node list automatically.
# ---------------------------------------------------------------------------
run_benchmark() {
    local label="$1"
    local bench_name="$2"
    local bench_bin="$3"
    local nodes="$4"
    local nprocs=$(( nodes * RANKS_PER_NODE ))
    local outdir="${RESULTS_DIR}/${label}/${bench_name}"
    local outfile="${outdir}/nodes${nodes}.dat"

    mkdir -p "$outdir"
    validate_nodes "$nodes" || return 0

    local bench_args="-m ${MSG_MIN}:${MSG_MAX} -i ${ITERATIONS} -x ${WARMUP}"
    [[ "$bench_name" == "osu_barrier" ]] && bench_args="-i ${ITERATIONS} -x ${WARMUP}"

    local extra="${MPI_EXTRA_FLAGS[$label]:-}"
    local map_flag="--map-by ppr:${RANKS_PER_NODE}:node"

    # --map-by ppr:<RANKS_PER_NODE>:node distributes ranks evenly across nodes.
    # -np limits the launch to exactly nodes*RANKS_PER_NODE ranks so we sweep
    # node counts without needing separate allocations.
    local cmd="${MPIRUN} -np ${nprocs} ${map_flag} ${extra} ${bench_bin} ${bench_args}"

    log "    ${bench_name} | ${nodes} node(s) | ${nprocs} ranks"
    log "      cmd: ${cmd}"
    run_cmd "${cmd} 2>&1 | tee ${outfile}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "============================================================"
log " OSU Collective Benchmarks"
log " Job ID    : ${SLURM_JOB_ID:-none (direct run)}"
log " Nodes     : ${SLURM_JOB_NUM_NODES:-unknown}"
log " Node list : ${SLURM_JOB_NODELIST:-unknown}"
log " Host      : $(hostname)"
log " Started   : $(date)"
log "============================================================"

mkdir -p "${RESULTS_DIR}/logs"

for label in "${MPI_LABELS[@]}"; do
    [[ -n "$FILTER_MPI" && "$label" != "$FILTER_MPI" ]] && continue

    log ""
    log "━━━ MPI label: ${label} ━━━"

    load_mpi "$label" || { log "  Skipping ${label}"; continue; }

    if declare -p OSU_INSTALLATIONS &>/dev/null 2>&1 && \
       [[ -n "${OSU_INSTALLATIONS[$label]:-}" ]]; then
        osu_collective="${OSU_INSTALLATIONS[$label]}/mpi/collective"
    else
        osu_collective="${OSU_COLLECTIVE}"
    fi
    log "  OSU dir: ${osu_collective}"

    for bench_name in "${COLLECTIVES[@]}"; do
        [[ -n "$FILTER_BENCH" && "$bench_name" != "$FILTER_BENCH" ]] && continue

        bench_bin="${osu_collective}/${bench_name}"
        check_binary "$bench_bin" || continue

        log "  ── ${bench_name}"
        for nodes in "${NODE_COUNTS[@]}"; do
            [[ -n "$FILTER_NODES" && "$nodes" != "$FILTER_NODES" ]] && continue
            run_benchmark "$label" "$bench_name" "$bench_bin" "$nodes"
        done
    done

    unload_mpi "$label"
done

log ""
log "============================================================"
log " All collectives done: $(date)"
log " Results: ${RESULTS_DIR}"
log "============================================================"

#!/usr/bin/env bash
# =============================================================================
# run_pt2pt.sh — OSU point-to-point benchmarks, all MPI labels sequential
#
# Submit:    sbatch scripts/run_pt2pt.sh
# Or direct: bash scripts/run_pt2pt.sh --dry-run
#
# Always uses exactly 2 nodes (1 rank per node for latency/bw,
# RANKS_PER_NODE total for multi-pair benchmarks).
# Node discovery via Slurm PMI — no hostfile needed.
#
# Options:
#   --dry-run      Print mpirun commands without executing
#   --mpi LABEL    Run only this MPI label
#   --bench NAME   Run only this benchmark
# =============================================================================

#SBATCH --job-name=osu_pt2pt
#SBATCH --nodes=2
#SBATCH --partition=compute
#SBATCH --time=02:00:00
#SBATCH --output=/tmp/osu_pt2pt_%j.out
#SBATCH --error=/tmp/osu_pt2pt_%j.err
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
FILTER_BENCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --mpi)      FILTER_MPI="$2";   shift ;;
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
        init_modules || {
            log "  ERROR: environment modules command not available"; return 1
        }
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

# ---------------------------------------------------------------------------
# Run a single P2P benchmark
#
# Standard latency/bw: 2 ranks, 1 per node (rank 0 sender, rank 1 receiver).
# Multi-pair (mbw_mr, latency_mp): RANKS_PER_NODE total, half per node.
# --map-by node ensures ranks alternate across the 2 allocated nodes.
# ---------------------------------------------------------------------------
run_pt2pt() {
    local label="$1"
    local bench_name="$2"
    local bench_bin="$3"
    local extra="${MPI_EXTRA_FLAGS[$label]:-}"
    local outdir="${RESULTS_DIR}/${label}/${bench_name}"
    local outfile="${outdir}/pt2pt.dat"

    mkdir -p "$outdir"

    local nprocs=2
    local map_flag="--map-by node"
    if [[ "$bench_name" == "osu_mbw_mr" || "$bench_name" == "osu_latency_mp" ]]; then
        nprocs=$(( RANKS_PER_NODE ))
        map_flag="--map-by node:PE=$(( RANKS_PER_NODE / 2 ))"
    fi

    local bench_args="-m ${MSG_MIN}:${MSG_MAX} -i ${ITERATIONS} -x ${WARMUP}"
    local cmd="${MPIRUN} -np ${nprocs} ${map_flag} ${extra} ${bench_bin} ${bench_args}"

    log "    ${bench_name} | ${nprocs} ranks | 2 nodes"
    log "      cmd: ${cmd}"
    run_cmd "${cmd} 2>&1 | tee ${outfile}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "============================================================"
log " OSU Point-to-Point Benchmarks"
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
        osu_pt2pt="${OSU_INSTALLATIONS[$label]}/mpi/pt2pt"
    else
        osu_pt2pt="${OSU_PT2PT}"
    fi
    log "  OSU dir: ${osu_pt2pt}"

    for bench_name in "${PT2PT[@]}"; do
        [[ -n "$FILTER_BENCH" && "$bench_name" != "$FILTER_BENCH" ]] && continue

        bench_bin="${osu_pt2pt}/${bench_name}"
        if [[ ! -x "$bench_bin" ]]; then
            log "  WARNING: not found, skipping: $(basename "$bench_bin")"; continue
        fi

        log "  ── ${bench_name}"
        run_pt2pt "$label" "$bench_name" "$bench_bin"
    done

    unload_mpi "$label"
done

log ""
log "============================================================"
log " All P2P benchmarks done: $(date)"
log " Results: ${RESULTS_DIR}"
log "============================================================"

#!/usr/bin/env bash
# =============================================================================
# submit.sh — Submit OSU benchmark jobs to Slurm
#
# Usage:
#   ./submit.sh [collectives] [pt2pt] [all] [OPTIONS]
#
# Examples:
#   ./submit.sh all                          # submit both jobs
#   ./submit.sh collectives                  # collectives only
#   ./submit.sh pt2pt --mpi openmpi-hcoll    # pt2pt, one label only
#   ./submit.sh all --partition gpu --time 06:00:00
#   ./submit.sh all --dry-run                # preview sbatch commands
#
# Slurm options (override #SBATCH defaults in the run scripts):
#   --partition NAME
#   --account NAME
#   --constraint STR
#   --time HH:MM:SS
#   --nodes N            (collectives only — pt2pt always uses 2)
#   --dry-run            print sbatch commands without submitting
# =============================================================================

set -euo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SUITE_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
RUN_COLLECTIVES=0
RUN_PT2PT=0
DRY_RUN=0
BENCH_ARGS=()

PARTITION="${SLURM_PARTITION:-compute}"
ACCOUNT="${SLURM_ACCOUNT:-}"
CONSTRAINT="${SLURM_CONSTRAINT:-}"
TIME_COLL="04:00:00"
TIME_PT2PT="02:00:00"
NODES_COLL="${NODE_COUNTS[-1]}"   # largest node count in config

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        all)          RUN_COLLECTIVES=1; RUN_PT2PT=1 ;;
        collectives)  RUN_COLLECTIVES=1 ;;
        pt2pt)        RUN_PT2PT=1 ;;
        --partition)  PARTITION="$2";   shift ;;
        --account)    ACCOUNT="$2";     shift ;;
        --constraint) CONSTRAINT="$2";  shift ;;
        --time)       TIME_COLL="$2"; TIME_PT2PT="$2"; shift ;;
        --nodes)      NODES_COLL="$2";  shift ;;
        --dry-run)    DRY_RUN=1; BENCH_ARGS+=(--dry-run) ;;
        --mpi|--bench|--nodes-filter)
                      BENCH_ARGS+=("$1" "$2"); shift ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ $RUN_COLLECTIVES -eq 0 && $RUN_PT2PT -eq 0 ]]; then
    echo "Usage: $0 [all|collectives|pt2pt] [options]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Build sbatch override flags
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}/logs"

sbatch_common=(
    "--partition=${PARTITION}"
    "--chdir=${SUITE_DIR}"
    "--output=${RESULTS_DIR}/logs/%x_%j.out"
    "--error=${RESULTS_DIR}/logs/%x_%j.err"
)
[[ -n "$ACCOUNT" ]]    && sbatch_common+=("--account=${ACCOUNT}")
[[ -n "$CONSTRAINT" ]] && sbatch_common+=("--constraint=${CONSTRAINT}")

submit() {
    local script="$1"; shift
    local extra_sbatch=("$@")
    local cmd="sbatch ${sbatch_common[*]} ${extra_sbatch[*]} ${script} ${BENCH_ARGS[*]:-}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] ${cmd}"
    else
        echo "Submitting: $(basename ${script})"
        eval "$cmd"
    fi
}

# ---------------------------------------------------------------------------
# Submit
# ---------------------------------------------------------------------------
echo "=============================="
echo " OSU Benchmark Submission"
echo " Partition : ${PARTITION}"
[[ -n "$ACCOUNT" ]]    && echo " Account   : ${ACCOUNT}"
[[ -n "$CONSTRAINT" ]] && echo " Constraint: ${CONSTRAINT}"
echo "=============================="
echo ""

if [[ $RUN_COLLECTIVES -eq 1 ]]; then
    submit "${SUITE_DIR}/scripts/run_collectives.sh" \
        "--nodes=${NODES_COLL}" \
        "--ntasks-per-node=1" \
        "--time=${TIME_COLL}"
fi

if [[ $RUN_PT2PT -eq 1 ]]; then
    submit "${SUITE_DIR}/scripts/run_pt2pt.sh" \
        "--nodes=2" \
        "--ntasks-per-node=1" \
        "--time=${TIME_PT2PT}"
fi

echo ""
echo "Results will appear in: ${RESULTS_DIR}/"
echo "Monitor with:  squeue -u \$USER"
echo "Collect with:  ./scripts/collect_results.sh"
echo "Plot with:     python3 scripts/plot_results.py"

#!/usr/bin/env bash
# =============================================================================
# check_jobs.sh — Show status of submitted OSU benchmark Slurm jobs
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ "$SCHEDULER" != "slurm" ]]; then
    log "Scheduler is not Slurm — nothing to check."
    exit 0
fi

log "Checking OSU benchmark jobs in queue..."
echo ""
squeue --name="osu_*" --format="%-30j %-10T %-10M %-6D %R" 2>/dev/null || \
    squeue -u "$USER" --format="%-30j %-10T %-10M %-6D %R" | grep osu || \
    echo "(no osu_ jobs found in queue)"

echo ""
log "Checking result files..."
printf "%-35s %-20s %s\n" "Benchmark" "Label" "Status"
printf "%-35s %-20s %s\n" "---------" "-----" "------"

for bench_name in "${COLLECTIVES[@]}" "${PT2PT[@]}"; do
    for label in "${!MPI_INSTALLATIONS[@]}"; do
        # Check collective result files
        for nodes in "${NODE_COUNTS[@]}"; do
            dat="${RESULTS_DIR}/${label}/${bench_name}/nodes${nodes}.dat"
            pt2pt="${RESULTS_DIR}/${label}/${bench_name}/pt2pt.dat"
            if [[ -f "$dat" ]]; then
                lines=$(grep -c "^[0-9]" "$dat" 2>/dev/null || echo 0)
                printf "%-35s %-20s %s\n" "${bench_name}:n${nodes}" "${label}" "✓ ${lines} data points"
            elif [[ -f "$pt2pt" ]]; then
                lines=$(grep -c "^[0-9]" "$pt2pt" 2>/dev/null || echo 0)
                printf "%-35s %-20s %s\n" "${bench_name}:pt2pt" "${label}" "✓ ${lines} data points"
            fi
        done
    done
done

echo ""
log "Log files: ${LOG_DIR}"

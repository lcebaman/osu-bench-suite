#!/usr/bin/env bash
# =============================================================================
# collect_results.sh — Parse OSU output files into a unified CSV per benchmark
#
# Output: results/csv/<benchmark_name>.csv
# Format: mpi_label, nodes, nranks, msg_bytes, latency_us_or_bw_mbps
#
# Run after all benchmark jobs have completed.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

CSV_DIR="${RESULTS_DIR}/csv"
mkdir -p "$CSV_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# -----------------------------------------------------------------------------
# Parse a single OSU output file
# OSU files look like:
#   # OSU MPI Allreduce Latency Test ...
#   # Size          Avg Latency(us)
#   1               0.54
#   2               0.55
#   ...
# We strip comment lines and emit: label,nodes,nranks,size,value
# -----------------------------------------------------------------------------
parse_osu_file() {
    local file="$1"
    local label="$2"
    local nodes="$3"
    local nranks=$(( nodes * RANKS_PER_NODE ))

    # Skip files that are empty or contain only errors
    if [[ ! -s "$file" ]]; then
        log "  WARN: empty file: $file"; return
    fi
    if grep -q "^# OSU" "$file" 2>/dev/null || grep -q "^[0-9]" "$file" 2>/dev/null; then
        grep -E "^[0-9]" "$file" | awk -v l="$label" -v n="$nodes" -v r="$nranks" \
            'NF>=2 { printf "%s,%d,%d,%s,%s\n", l, n, r, $1, $2 }'
    else
        log "  WARN: unrecognised format or error in: $file"
        head -5 "$file" | sed 's/^/    /'
    fi
}

# -----------------------------------------------------------------------------
# Determine header second column name from benchmark name
# -----------------------------------------------------------------------------
bench_value_col() {
    local bench="$1"
    case "$bench" in
        osu_bw|osu_bibw|osu_mbw_mr) echo "bandwidth_mbps" ;;
        osu_barrier)                  echo "latency_us" ;;
        *)                            echo "latency_us" ;;
    esac
}

# -----------------------------------------------------------------------------
# Process all collective results
# -----------------------------------------------------------------------------
log "Collecting collective benchmark results..."

for bench_name in "${COLLECTIVES[@]}"; do
    csv_file="${CSV_DIR}/${bench_name}.csv"
    val_col=$(bench_value_col "$bench_name")
    echo "mpi_label,nodes,nranks,msg_bytes,${val_col}" > "$csv_file"

    found=0
    for label in "${!MPI_INSTALLATIONS[@]}"; do
        for nodes in "${NODE_COUNTS[@]}"; do
            dat="${RESULTS_DIR}/${label}/${bench_name}/nodes${nodes}.dat"
            if [[ -f "$dat" ]]; then
                parse_osu_file "$dat" "$label" "$nodes" >> "$csv_file"
                found=$(( found + 1 ))
            fi
        done
    done

    if [[ $found -gt 0 ]]; then
        log "  ${bench_name}: ${found} result files → ${csv_file}"
    else
        log "  ${bench_name}: no results found (jobs may still be running)"
        rm -f "$csv_file"
    fi
done

# -----------------------------------------------------------------------------
# Process all P2P results
# -----------------------------------------------------------------------------
log "Collecting P2P benchmark results..."

for bench_name in "${PT2PT[@]}"; do
    csv_file="${CSV_DIR}/${bench_name}.csv"
    val_col=$(bench_value_col "$bench_name")
    echo "mpi_label,nodes,nranks,msg_bytes,${val_col}" > "$csv_file"

    found=0
    for label in "${!MPI_INSTALLATIONS[@]}"; do
        dat="${RESULTS_DIR}/${label}/${bench_name}/pt2pt.dat"
        if [[ -f "$dat" ]]; then
            parse_osu_file "$dat" "$label" 2 >> "$csv_file"
            found=$(( found + 1 ))
        fi
    done

    if [[ $found -gt 0 ]]; then
        log "  ${bench_name}: ${found} result files → ${csv_file}"
    else
        log "  ${bench_name}: no results found"
        rm -f "$csv_file"
    fi
done

# -----------------------------------------------------------------------------
# Print summary table of what was collected
# -----------------------------------------------------------------------------
log ""
log "=== Collection Summary ==="
printf "%-30s %8s %8s\n" "Benchmark" "Configs" "DataPts"
printf "%-30s %8s %8s\n" "---------" "-------" "-------"
for csv in "${CSV_DIR}"/*.csv; do
    [[ -f "$csv" ]] || continue
    bname=$(basename "$csv" .csv)
    configs=$(tail -n +2 "$csv" | cut -d, -f1 | sort -u | wc -l)
    datapts=$(tail -n +2 "$csv" | wc -l)
    printf "%-30s %8d %8d\n" "$bname" "$configs" "$datapts"
done

log ""
log "CSV files written to: ${CSV_DIR}"
log "Run ./scripts/plot_results.py to generate plots."

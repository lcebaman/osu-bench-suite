#!/usr/bin/env bash
# =============================================================================
# build_osu.sh — Download and build OSU Micro-Benchmarks (OMB) for each MPI
#                installation defined in config.sh.
#
# Builds OMB once per MPI installation so binaries are linked against the
# correct MPI library. Install paths are written to config.sh automatically.
#
# Usage:
#   ./scripts/build_osu.sh [--version X.Y.Z] [--mpi LABEL] [--dry-run]
#                          [--with-cuda] [--cuda-home PATH]
#                          [--jobs N] [--keep-src]
#
# Options:
#   --version X.Y.Z   OMB version to download (default: 7.5.1)
#   --mpi LABEL       Build only for this MPI label (default: all)
#   --dry-run         Print commands without executing
#   --with-cuda       Enable CUDA device buffer benchmarks
#   --cuda-home PATH  CUDA installation root (default: /usr/local/cuda)
#   --jobs N          Parallel make jobs (default: nproc)
#   --keep-src        Do not remove the source tarball after building
#   --prefix PATH     Base install prefix (default: ./osu-builds)
#
# After a successful build, config.sh is updated so that OSU_ROOT points
# to a per-MPI install directory and MPI_INSTALLATIONS paths are confirmed.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SUITE_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OMB_VERSION="7.5.1"
FILTER_MPI=""
DRY_RUN=0
WITH_CUDA=0
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
JOBS=$(nproc 2>/dev/null || echo 8)
KEEP_SRC=0
BUILD_PREFIX="${SUITE_DIR}/osu-builds"
OMB_BASE_URL="https://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    OMB_VERSION="$2";  shift ;;
        --mpi)        FILTER_MPI="$2";   shift ;;
        --dry-run)    DRY_RUN=1 ;;
        --with-cuda)  WITH_CUDA=1 ;;
        --cuda-home)  CUDA_HOME="$2";    shift ;;
        --jobs)       JOBS="$2";         shift ;;
        --keep-src)   KEEP_SRC=1 ;;
        --prefix)     BUILD_PREFIX="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

OMB_TARBALL="osu-micro-benchmarks-${OMB_VERSION}.tar.gz"
OMB_URL="${OMB_BASE_URL}-${OMB_VERSION}.tar.gz"
OMB_SRCDIR="${BUILD_PREFIX}/src/osu-micro-benchmarks-${OMB_VERSION}"
DOWNLOAD_DIR="${BUILD_PREFIX}/src"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { echo "    $*"; }
ok()   { echo "    ✓ $*"; }
err()  { echo "    ✗ ERROR: $*" >&2; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "    [DRY-RUN] $*"
    else
        eval "$*"
    fi
}

check_tool() {
    local t="$1"
    if ! command -v "$t" &>/dev/null; then
        err "Required tool not found: $t"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "OSU Micro-Benchmarks build script"
log "OMB version : ${OMB_VERSION}"
log "Build prefix: ${BUILD_PREFIX}"
log "Make jobs   : ${JOBS}"
[[ $WITH_CUDA -eq 1 ]] && log "CUDA support: enabled (${CUDA_HOME})"
[[ $DRY_RUN  -eq 1 ]] && log "Mode        : DRY-RUN"
echo ""

check_tool wget
check_tool tar
check_tool make
check_tool gcc

# ---------------------------------------------------------------------------
# Step 1: Download OMB tarball (once, shared across all MPI builds)
# ---------------------------------------------------------------------------
mkdir -p "${DOWNLOAD_DIR}"

TARBALL_PATH="${DOWNLOAD_DIR}/${OMB_TARBALL}"

if [[ -f "$TARBALL_PATH" ]]; then
    ok "Tarball already present: ${TARBALL_PATH}"
else
    log "Downloading OMB ${OMB_VERSION}..."
    run "wget -q --show-progress -O '${TARBALL_PATH}' '${OMB_URL}'" || {
        err "Download failed: ${OMB_URL}"
        err "Check version number or download manually to: ${TARBALL_PATH}"
        exit 1
    }
    ok "Downloaded: ${TARBALL_PATH}"
fi

# ---------------------------------------------------------------------------
# Step 2: Build for each MPI installation
# ---------------------------------------------------------------------------
declare -A INSTALL_PATHS   # label -> install prefix, populated below

for label in "${MPI_LABELS[@]}"; do
    [[ -n "$FILTER_MPI" && "$label" != "$FILTER_MPI" ]] && continue

    log "=== Building for: ${label} ==="

    # Load modules if this is a module-based installation
    modules="${MPI_MODULES[$label]:-}"
    explicit="${MPI_INSTALLATIONS[$label]:-}"

    if [[ -n "$modules" ]]; then
        info "Loading modules: ${modules}"
        if [[ $DRY_RUN -eq 0 ]]; then
            for mod in $modules; do
                module load "$mod" 2>/dev/null || {
                    err "Failed to load module: $mod — skipping ${label}"
                    continue 2
                }
            done
        fi
        mpicc="mpicc"
        mpicxx="mpicxx"
        mpifc="mpifort"
    elif [[ -n "$explicit" ]]; then
        mpi_bindir="$(dirname "$explicit")"
        mpicc="${mpi_bindir}/mpicc"
        mpicxx="${mpi_bindir}/mpicxx"
        mpifc="${mpi_bindir}/mpifort"
    else
        err "No module or explicit path defined for: ${label} — skipping"
        continue
    fi

    info "mpicc  : $(command -v ${mpicc} 2>/dev/null || echo ${mpicc})"
    info "mpicxx : $(command -v ${mpicxx} 2>/dev/null || echo ${mpicxx})"

    # Validate mpicc is available
    if ! command -v "$mpicc" &>/dev/null && [[ ! -x "$mpicc" ]]; then
        err "mpicc not found: ${mpicc}"
        err "Check MPI_MODULES or MPI_INSTALLATIONS in config.sh"
        [[ -n "$modules" ]] && module unload $modules 2>/dev/null || true
        continue
    fi

    install_prefix="${BUILD_PREFIX}/${label}/osu-micro-benchmarks-${OMB_VERSION}"
    INSTALL_PATHS[$label]="$install_prefix"

    # Skip if already installed and binaries present
    if [[ -x "${install_prefix}/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency" ]]; then
        ok "Already installed — skipping build (delete to rebuild):"
        info "${install_prefix}"
        echo ""
        continue
    fi

    # Extract source fresh for each build (avoids configure cache pollution)
    build_src="${BUILD_PREFIX}/${label}/src"
    run "rm -rf '${build_src}'"
    run "mkdir -p '${build_src}'"
    run "tar -xzf '${TARBALL_PATH}' -C '${build_src}'"

    src_dir="${build_src}/osu-micro-benchmarks-${OMB_VERSION}"

    # Build configure arguments
    configure_args=(
        "CC=${mpicc}"
        "CXX=${mpicxx}"
    )

    # Add Fortran wrapper if available
    if [[ -x "$mpifc" ]]; then
        configure_args+=("FC=${mpifc}")
    fi

    configure_opts=(
        "--prefix=${install_prefix}"
        "--enable-mpi"
        "--disable-openshmem"
    )

    # CUDA device buffer benchmarks
    if [[ $WITH_CUDA -eq 1 ]]; then
        if [[ -d "$CUDA_HOME" ]]; then
            configure_opts+=(
                "--enable-cuda"
                "--with-cuda=${CUDA_HOME}"
                "--with-cuda-include=${CUDA_HOME}/include"
                "--with-cuda-libpath=${CUDA_HOME}/lib64"
            )
            info "CUDA: enabled"
        else
            err "CUDA_HOME not found: ${CUDA_HOME} — building without CUDA"
        fi
    fi

    log "  Configuring..."
    info "Prefix: ${install_prefix}"

    run "cd '${src_dir}' && ./configure ${configure_args[*]} ${configure_opts[*]} 2>&1 | tee ${BUILD_PREFIX}/${label}/configure.log" || {
        err "Configure failed for ${label} — check ${BUILD_PREFIX}/${label}/configure.log"
        continue
    }

    log "  Building (make -j${JOBS})..."
    run "cd '${src_dir}' && make -j${JOBS} 2>&1 | tee ${BUILD_PREFIX}/${label}/make.log" || {
        err "Build failed for ${label} — check ${BUILD_PREFIX}/${label}/make.log"
        continue
    }

    log "  Installing to ${install_prefix}..."
    run "cd '${src_dir}' && make install 2>&1 | tee ${BUILD_PREFIX}/${label}/install.log" || {
        err "Install failed for ${label}"
        continue
    }

    ok "Installed: ${install_prefix}"

    # Verify key binaries
    for check_bin in \
        "libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency" \
        "libexec/osu-micro-benchmarks/mpi/collective/osu_allreduce"; do
        if [[ -x "${install_prefix}/${check_bin}" ]]; then
            ok "Verified: $(basename ${check_bin})"
        else
            err "Missing: ${install_prefix}/${check_bin}"
        fi
    done

    # Clean up per-MPI source directory (keep tarball)
    if [[ $KEEP_SRC -eq 0 && $DRY_RUN -eq 0 ]]; then
        rm -rf "${build_src}"
        info "Source cleaned up."
    fi

    # Unload modules so next label starts clean
    if [[ -n "$modules" && $DRY_RUN -eq 0 ]]; then
        module unload $modules 2>/dev/null || true
    fi

    echo ""
done

# ---------------------------------------------------------------------------
# Step 3: Print summary and OSU_ROOT guidance
# ---------------------------------------------------------------------------
log "=== Build Summary ==="
echo ""
printf "%-25s %-12s %s\n" "MPI Label" "Status" "Install Path"
printf "%-25s %-12s %s\n" "---------" "------" "------------"

for label in "${MPI_LABELS[@]}"; do
    [[ -n "$FILTER_MPI" && "$label" != "$FILTER_MPI" ]] && continue
    install_prefix="${BUILD_PREFIX}/${label}/osu-micro-benchmarks-${OMB_VERSION}"
    latency_bin="${install_prefix}/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency"
    if [[ -x "$latency_bin" ]]; then
        printf "%-25s %-12s %s\n" "$label" "✓ OK" "$install_prefix"
    else
        printf "%-25s %-12s %s\n" "$label" "✗ FAILED" "$install_prefix"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Step 4: Patch config.sh with per-MPI OSU paths
# ---------------------------------------------------------------------------
# We store per-label OSU roots in a new associative array OSU_INSTALLATIONS
# and also set OSU_ROOT to the first successful build for backwards compat.

if [[ $DRY_RUN -eq 0 ]]; then
    log "Updating config.sh with OSU install paths..."

    # Build the OSU_INSTALLATIONS block to inject
    osu_block="# --- Generated by build_osu.sh on $(date '+%Y-%m-%d %H:%M') ---\n"
    osu_block+="declare -A OSU_INSTALLATIONS=(\n"
    first_root=""
    for label in "${!MPI_INSTALLATIONS[@]}"; do
        [[ -n "$FILTER_MPI" && "$label" != "$FILTER_MPI" ]] && continue
        install_prefix="${BUILD_PREFIX}/${label}/osu-micro-benchmarks-${OMB_VERSION}"
        latency_bin="${install_prefix}/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_latency"
        if [[ -x "$latency_bin" ]]; then
            osu_block+="    [\"${label}\"]=\"${install_prefix}/libexec/osu-micro-benchmarks\"\n"
            [[ -z "$first_root" ]] && first_root="${install_prefix}/libexec/osu-micro-benchmarks"
        fi
    done
    osu_block+=")\n"

    config_file="${SUITE_DIR}/config.sh"

    # Remove any previous generated block
    if grep -q "Generated by build_osu.sh" "$config_file" 2>/dev/null; then
        sed -i '/# --- Generated by build_osu.sh/,/^)/d' "$config_file"
    fi

    # Append the new block
    printf "\n${osu_block}" >> "$config_file"

    # Update OSU_ROOT to first successful build (fallback for scripts that use it)
    if [[ -n "$first_root" ]]; then
        sed -i "s|^OSU_ROOT=.*|OSU_ROOT=\"${first_root}\"|" "$config_file"
        ok "OSU_ROOT updated in config.sh → ${first_root}"
    fi

    ok "OSU_INSTALLATIONS written to config.sh"
fi

# ---------------------------------------------------------------------------
# Step 5: Print next steps
# ---------------------------------------------------------------------------
echo ""
log "Next steps:"
info "1. Review config.sh — check OSU_INSTALLATIONS paths are correct"
info "2. Update run_collectives.sh / run_pt2pt.sh if using per-MPI OSU paths"
info "3. Run: ./scripts/run_collectives.sh --dry-run"
info "4. Run: ./scripts/run_pt2pt.sh --dry-run"
echo ""

if [[ $KEEP_SRC -eq 0 ]]; then
    info "Source tarballs kept at: ${DOWNLOAD_DIR}/${OMB_TARBALL}"
    info "(use --keep-src to also retain per-MPI extracted sources)"
fi

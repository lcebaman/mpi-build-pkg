#!/bin/bash
# lib/detect.sh — Auto-detection for optional build dependencies

# -----------------------------------------------------------------------------
# have_any_path: returns 0 if at least one path exists
# -----------------------------------------------------------------------------
have_any_path() {
    local p
    for p in "$@"; do [[ -e "$p" ]] && return 0; done
    return 1
}

# -----------------------------------------------------------------------------
# find_cuda_dir: locate CUDA installation
# Prints path on success, returns 1 if not found
# -----------------------------------------------------------------------------
find_cuda_dir() {
    # 1. Explicit env vars
    for v in CUDA_HOME CUDA_ROOT CUDA_PATH; do
        if [[ -n "${!v:-}" && -f "${!v}/include/cuda.h" ]]; then
            printf '%s\n' "${!v}"; return 0
        fi
    done

    # 2. nvcc in PATH
    local nvcc
    if nvcc=$(command -v nvcc 2>/dev/null); then
        local candidate
        candidate="$(dirname "$(dirname "$nvcc")")"
        if [[ -f "$candidate/include/cuda.h" ]]; then
            printf '%s\n' "$candidate"; return 0
        fi
    fi

    # 3. Common fixed locations
    local p
    for p in /usr/local/cuda /usr/cuda /opt/cuda; do
        if [[ -f "$p/include/cuda.h" ]]; then
            printf '%s\n' "$p"; return 0
        fi
    done

    # 4. Versioned symlinks /usr/local/cuda-*
    local latest
    latest=$(ls -d /usr/local/cuda-* 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -n "$latest" && -f "$latest/include/cuda.h" ]]; then
        printf '%s\n' "$latest"; return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# find_gdrcopy_dir
# -----------------------------------------------------------------------------
find_gdrcopy_dir() {
    local p
    for p in /usr/local/gdrcopy /opt/gdrcopy /usr; do
        if [[ -f "$p/include/gdrapi.h" ]]; then
            printf '%s\n' "$p"; return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# find_hcoll_dir: prefers HPC-X over standalone /opt/mellanox/hcoll
# -----------------------------------------------------------------------------
find_hcoll_dir() {
    local candidate

    # 1. Explicit env var
    if [[ -n "${HCOLL_DIR:-}" && -f "${HCOLL_DIR}/include/hcoll/api/hcoll_api.h" ]]; then
        printf '%s\n' "$HCOLL_DIR"; return 0
    fi

    # 2. HPC-X (NVIDIA recommended)
    if [[ -d /opt/mellanox/hpc-x ]]; then
        candidate=$(find /opt/mellanox/hpc-x -maxdepth 3 -type d -name hcoll 2>/dev/null \
                    | sort -V | tail -n1 || true)
        if [[ -n "$candidate" && -f "$candidate/include/hcoll/api/hcoll_api.h" ]]; then
            printf '%s\n' "$candidate"; return 0
        fi
    fi

    # 3. Standalone
    if [[ -f /opt/mellanox/hcoll/include/hcoll/api/hcoll_api.h ]]; then
        printf '%s\n' /opt/mellanox/hcoll; return 0
    fi

    return 1
}

# validate_hcoll <dir>
validate_hcoll() {
    local dir=$1
    local ok=1
    [[ -f "$dir/include/hcoll/api/hcoll_api.h" ]] || { log_warn "hcoll: missing header $dir/include/hcoll/api/hcoll_api.h"; ok=0; }
    ls "$dir/lib/libhcoll.so"* &>/dev/null  || { log_warn "hcoll: missing $dir/lib/libhcoll.so*"; ok=0; }
    return $(( 1 - ok ))
}

# -----------------------------------------------------------------------------
# find_nccl_dir
# -----------------------------------------------------------------------------
find_nccl_dir() {
    local cuda_dir="${1:-}"
    local p

    # Explicit env var
    if [[ -n "${NCCL_HOME:-}" ]]; then
        ls "${NCCL_HOME}/lib"*/libnccl.so* &>/dev/null && { printf '%s\n' "$NCCL_HOME"; return 0; }
    fi

    # HPC-X
    if [[ -d /opt/mellanox/hpc-x ]]; then
        local candidate
        candidate=$(find /opt/mellanox/hpc-x -maxdepth 3 -name "libnccl.so*" 2>/dev/null \
                    | head -n1 | xargs -r dirname | xargs -r dirname || true)
        [[ -n "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    fi

    # Alongside CUDA
    for p in /usr/local/nccl /opt/nccl "$cuda_dir"; do
        [[ -z "$p" ]] && continue
        ls "$p/lib"*/libnccl.so* &>/dev/null && { printf '%s\n' "$p"; return 0; }
    done

    return 1
}

# -----------------------------------------------------------------------------
# find_knem_dir
# -----------------------------------------------------------------------------
find_knem_dir() {
    [[ -d /opt ]] || return 1
    local candidate
    candidate=$(find /opt -maxdepth 1 -mindepth 1 -type d -name 'knem*' | head -n1 || true)
    [[ -n "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    return 1
}

# -----------------------------------------------------------------------------
# resolve_* helpers — parse mode string and return resolved path or empty
# mode: "no" | "auto" | "yes:<path>"
# -----------------------------------------------------------------------------
resolve_cuda() {
    local mode=$1
    case "$mode" in
    no)      return 0 ;;
    yes:*)
        local p="${mode#yes:}"
        [[ -f "$p/include/cuda.h" ]] || log_die "CUDA not found at '$p' (missing include/cuda.h)"
        printf '%s\n' "$p"
        ;;
    auto)
        find_cuda_dir || log_warn "CUDA not found — building without GPU support"
        ;;
    esac
}

resolve_gdrcopy() {
    local mode=$1
    case "$mode" in
    no)      return 0 ;;
    yes:*)
        local p="${mode#yes:}"
        [[ -f "$p/include/gdrapi.h" ]] || log_die "GDRCopy not found at '$p'"
        printf '%s\n' "$p"
        ;;
    auto)    find_gdrcopy_dir || true ;;
    esac
}

resolve_hcoll() {
    local mode=$1
    case "$mode" in
    no)      return 0 ;;
    yes:*)
        local p="${mode#yes:}"
        validate_hcoll "$p" || log_die "hcoll at '$p' is incomplete (see warnings above)"
        printf '%s\n' "$p"
        ;;
    auto)
        local found
        if found=$(find_hcoll_dir); then
            validate_hcoll "$found" && printf '%s\n' "$found" || \
                log_warn "hcoll found at $found but validation failed — skipping"
        else
            log_info "hcoll not found — building without it"
        fi
        ;;
    esac
}

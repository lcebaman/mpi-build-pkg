#!/bin/bash
# lib/build_ucc.sh — UCC download, configure, build, install

ucc_download() {
    local version="$1"
    # GitHub refs/tags archives extract as ucc-<version>/ but the tarball
    # itself is named v<version>.tar.gz — rename locally for consistency.
    local tarball="ucc-${version}.tar.gz"
    local archive_file="${ARCHIVE_DIR}/${tarball}"
    local url="https://github.com/openucx/ucc/archive/refs/tags/v${version}.tar.gz"
    local src_dir="${BUILDING_DIR}/ucc-${version}"

    log_info "Preparing UCC ${version}..."
    mkdir -p "$ARCHIVE_DIR" "$BUILDING_DIR"

    if [[ -f "$archive_file" ]]; then
        log_info "Tarball exists: $archive_file (skipping download)"
    else
        log_info "Downloading: $url"
        wget -q --show-progress -c "$url" -O "$archive_file" || log_die "UCC download failed"
    fi

    if [[ -d "$src_dir" ]]; then
        log_info "Removing stale source dir $src_dir"
        rm -rf "$src_dir"
    fi

    tar -xzf "$archive_file" -C "$BUILDING_DIR" || log_die "UCC extraction failed"

    # GitHub archive extracts as ucc-<version>/ — confirm and run autogen.
    # The refs/tags archive never contains a pre-generated configure script.
    [[ -d "$src_dir" ]] || log_die "Expected source dir '$src_dir' after extraction"
    apply_package_patches "ucc" "$version" "$COMPILER" "$COMPILER_VERSION" "$src_dir"

    if [[ ! -f "$src_dir/configure" ]]; then
        log_info "Running autogen.sh for UCC ${version}..."
        # autogen.sh requires autoconf, automake, libtool in PATH
        for tool in autoconf automake libtool; do
            command -v "$tool" >/dev/null 2>&1 || \
                log_die "autogen.sh requires '$tool' — install it and retry"
        done
        ( cd "$src_dir" && ./autogen.sh ) || log_die "UCC autogen.sh failed"
    fi
}

# ucc_build <version> <install_prefix> <ucx_prefix> <cuda_dir|"">
ucc_build() {
    local version=$1
    local install_dir=$2
    local ucx_dir=$3
    local cuda_dir="${4:-}"
    local build_dir="${BUILDING_DIR}/ucc-${version}"
    local nccl_dir=""
    local ucx_arg=""
    local -a configure_args

    log_info "Configuring UCC ${version} → ${install_dir}"
    cd "$build_dir"

    if [[ "$ucx_dir" == "system" ]]; then
        log_info "UCC: enabling system UCX"
        ucx_arg="--with-ucx"
    else
        ucx_arg="--with-ucx=${ucx_dir}"
    fi

    configure_args=(
        "--prefix=${install_dir}"
        "$ucx_arg"
        "--enable-shared"
        "--enable-static"
        "--with-pic"
    )

    # --- CUDA backends ---
    if [[ -n "$cuda_dir" ]]; then
        log_info "UCC: enabling CUDA backend ($cuda_dir)"
        configure_args+=("--with-cuda=${cuda_dir}")

        # NCCL — accelerated GPU collectives
        if nccl_dir=$(find_nccl_dir "$cuda_dir" 2>/dev/null); then
            log_info "UCC: enabling NCCL backend ($nccl_dir)"
            configure_args+=("--with-nccl=${nccl_dir}")
        else
            log_info "UCC: NCCL not found — GPU collectives use basic CUDA backend"
        fi
    else
        log_info "UCC: no CUDA — CPU-only build"
        configure_args+=("--without-cuda")
    fi

    CC=${CC} CXX=${CXX} FC=${FC} \
        CFLAGS="-O3" CXXFLAGS="-O3" \
        ./configure "${configure_args[@]}"

    log_info "Building UCC ($(nproc) jobs)..."
    make -j"$(nproc)"
    make install

    cd ..
    log_ok "UCC ${version} installed → ${install_dir}"
}

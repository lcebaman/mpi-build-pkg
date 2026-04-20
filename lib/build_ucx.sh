#!/bin/bash
# lib/build_ucx.sh — UCX download, configure, build, install

ucx_download() {
    local version="$1"
    local tarball="ucx-${version}.tar.gz"
    local url="https://github.com/openucx/ucx/releases/download/v${version}/${tarball}"

    log_info "Preparing UCX ${version}..."

    if [[ -f "$tarball" ]]; then
        log_info "Tarball exists: $tarball (skipping download)"
    else
        log_info "Downloading: $url"
        wget -q --show-progress -c "$url" || log_die "UCX download failed"
    fi

    if [[ -d "ucx-${version}" ]]; then
        log_info "Removing stale source dir ucx-${version}"
        rm -rf "ucx-${version}"
    fi

    tar -xzf "$tarball" || log_die "UCX extraction failed"
}

# ucx_build <version> <install_prefix> <cuda_dir|""> <gdrcopy_dir|"">
ucx_build() {
    local version=$1
    local install_dir=$2
    local cuda_dir="${3:-}"
    local gdrcopy_dir="${4:-}"
    local build_dir="ucx-${version}"
    local compiler_basename="${CC##*/}"
    local commonflags="-O3"
    local knem_dir=""
    local -a configure_args

    log_info "Configuring UCX ${version} → ${install_dir}"
    cd "$build_dir"

    # Suppress clang/icx unused-arg noise
    if [[ "$compiler_basename" == "icx" || "$compiler_basename" == "icpx" \
       || "$compiler_basename" == "clang" ]]; then
        commonflags+=" -Wno-unused-command-line-argument"
    fi

    configure_args=(
        "--prefix=${install_dir}"
        "--enable-mt"
        "--enable-shared"
        "--enable-static"
        "--with-pic"
        "--enable-optimizations"
        "--with-avx"
        "--without-rocm"
        "--without-ugni"
        "--disable-logging"
        "--disable-debug"
        "--disable-assertions"
        "--disable-params-check"
        "--disable-dependency-tracking"
        "--enable-cma"
    )

    # --- InfiniBand / RDMA ---
    # --with-mlx5-dv was removed in UCX 1.15+ — mlx5 is auto-detected when
    # verbs are enabled. --with-dc is also version-dependent so we probe first.
    if have_any_path \
            /usr/include/infiniband/verbs.h \
            /usr/local/include/infiniband/verbs.h \
            /usr/lib64/libibverbs.so \
            /usr/lib/libibverbs.so; then
        log_info "UCX: enabling verbs"
        configure_args+=("--with-verbs")
        # --with-dc only exists in UCX < 1.15; probe to avoid spurious WARNING
        if ./configure --help 2>&1 | grep -q -- '--with-dc'; then
            log_info "UCX: enabling DC transport"
            configure_args+=("--with-dc")
        fi
    fi

    if have_any_path \
            /usr/include/rdma/rdma_cma.h \
            /usr/lib64/librdmacm.so \
            /usr/lib/librdmacm.so; then
        log_info "UCX: enabling rdmacm"
        configure_args+=("--with-rdmacm")
    fi

    # --- Shared memory transports ---
    if have_any_path \
            /usr/include/xpmem.h \
            /usr/lib64/libxpmem.so \
            /usr/lib/libxpmem.so \
            /opt/lib64/libxpmem.so; then
        log_info "UCX: enabling xpmem"
        configure_args+=("--with-xpmem")
    fi

    if knem_dir=$(find_knem_dir 2>/dev/null); then
        log_info "UCX: enabling knem ($knem_dir)"
        configure_args+=("--with-knem=${knem_dir}")
    fi

    # --- CUDA ---
    if [[ -n "$cuda_dir" ]]; then
        log_info "UCX: enabling CUDA ($cuda_dir)"
        configure_args+=(
            "--with-cuda=${cuda_dir}"
            "--with-cuda-libdir=${cuda_dir}/lib64"
        )
        if [[ -n "$gdrcopy_dir" ]]; then
            log_info "UCX: enabling GDRCopy ($gdrcopy_dir)"
            configure_args+=("--with-gdrcopy=${gdrcopy_dir}")
        else
            log_info "UCX: GDRCopy not available — skipping"
        fi
    else
        configure_args+=("--without-cuda")
    fi

    # Extra CUDA opts from environment
    if [[ -n "${UCXCUDAOPT:-}" ]]; then
        read -r -a _extra <<< "${UCXCUDAOPT}"
        configure_args+=("${_extra[@]}")
    fi

    CC=${CC} CXX=${CXX} FC=${FC} \
        CFLAGS="$commonflags" CXXFLAGS="$commonflags" FCFLAGS="$commonflags" \
        ./configure "${configure_args[@]}"

    log_info "Building UCX ($(nproc) jobs)..."
    make -j"$(nproc)"
    make install

    cd ..
    log_ok "UCX ${version} installed → ${install_dir}"
}

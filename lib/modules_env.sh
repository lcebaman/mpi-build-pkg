#!/bin/bash
# lib/modules_env.sh — Compiler environment setup driven by compilers.conf

# Default config file location — can be overridden by COMPILERS_CONF env var
_COMPILERS_CONF="${COMPILERS_CONF:-${SCRIPT_DIR}/compilers.conf}"

# =============================================================================
# conf_lookup <compiler> <version> <field>
# Parse compilers.conf and return the value of <field> for [compiler/version].
# Prints the value on stdout, returns 1 if not found.
# =============================================================================
conf_lookup() {
    local compiler=$1
    local version=$2
    local field=$3
    local key="${compiler}/${version}"
    local in_section=0
    local line key_part val_part

    [[ -f "$_COMPILERS_CONF" ]] || \
        log_die "Compiler config not found: $_COMPILERS_CONF"

    while IFS= read -r line; do
        # Strip inline comments and trim whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Section header
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            in_section=0
            [[ "${BASH_REMATCH[1]}" == "$key" ]] && in_section=1
            continue
        fi

        if (( in_section )); then
            key_part="${line%%=*}"
            val_part="${line#*=}"
            # Trim whitespace from both sides
            key_part="${key_part#"${key_part%%[![:space:]]*}"}"
            key_part="${key_part%"${key_part##*[![:space:]]}"}"
            val_part="${val_part#"${val_part%%[![:space:]]*}"}"
            val_part="${val_part%"${val_part##*[![:space:]]}"}"

            if [[ "$key_part" == "$field" ]]; then
                printf '%s\n' "$val_part"
                return 0
            fi
        fi
    done < "$_COMPILERS_CONF"

    return 1
}

# =============================================================================
# conf_list_compilers
# Print all [compiler/version] entries defined in compilers.conf
# =============================================================================
conf_list_compilers() {
    [[ -f "$_COMPILERS_CONF" ]] || \
        log_die "Compiler config not found: $_COMPILERS_CONF"

    grep -E '^\[.+\]$' "$_COMPILERS_CONF" | tr -d '[]'
}

# =============================================================================
# load_compiler_modules <compiler> <version>
# Load modules and set CC/CXX/FC from compilers.conf entry.
# =============================================================================
load_compiler_modules() {
    local compiler=$1
    local cversion=$2
    local key="${compiler}/${cversion}"

    log_info "Looking up compiler: $key"

    # Validate entry exists
    local family
    if ! family=$(conf_lookup "$compiler" "$cversion" "family"); then
        log_warn "Compiler '$key' not found in $_COMPILERS_CONF"
        log_warn "Known compilers:"
        conf_list_compilers | sed 's/^/    /' >&2
        log_die "Add '$key' to compilers.conf and retry"
    fi

    # Load modules
    if command -v module >/dev/null 2>&1; then
        local modules_str
        modules_str=$(conf_lookup "$compiler" "$cversion" "modules") || \
            log_die "No 'modules' field for $key in compilers.conf"

        log_info "Loading modules: $modules_str"
        local mod
        for mod in $modules_str; do
            module load "$mod" || log_die "Failed to load module: $mod"
        done
    else
        log_warn "Environment modules not available — assuming compilers are in PATH"
    fi

    # Set compiler variables
    _set_compiler_vars_from_conf "$compiler" "$cversion"
}

# =============================================================================
# _set_compiler_vars_from_conf <compiler> <version>
# Set CC/CXX/FC/F90/F77 from compilers.conf cc/cxx/fc fields.
# =============================================================================
_set_compiler_vars_from_conf() {
    local compiler=$1
    local cversion=$2

    local cc cxx fc
    cc=$(conf_lookup  "$compiler" "$cversion" "cc")  || log_die "No 'cc' field for ${compiler}/${cversion}"
    cxx=$(conf_lookup "$compiler" "$cversion" "cxx") || log_die "No 'cxx' field for ${compiler}/${cversion}"
    fc=$(conf_lookup  "$compiler" "$cversion" "fc")  || log_die "No 'fc' field for ${compiler}/${cversion}"

    export CC="$(command -v "$cc"   2>/dev/null || echo "$cc")"
    export CXX="$(command -v "$cxx" 2>/dev/null || echo "$cxx")"
    export FC="$(command -v "$fc"   2>/dev/null || echo "$fc")"
    export F90="$FC"
    export F77="$FC"

    [[ -x "$CC"  ]] || log_die "C compiler not found in PATH after module load: $cc"
    [[ -x "$CXX" ]] || log_die "C++ compiler not found in PATH after module load: $cxx"
    [[ -x "$FC"  ]] || log_die "Fortran compiler not found in PATH after module load: $fc"

    log_info "CC=$CC"
    log_info "CXX=$CXX"
    log_info "FC=$FC"
}

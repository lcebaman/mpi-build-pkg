#!/bin/bash
# lib/log.sh — Coloured logging helpers

# Colours (disabled if not a terminal)
if [[ -t 1 ]]; then
    _C_RESET='\033[0m'
    _C_BOLD='\033[1m'
    _C_CYAN='\033[1;36m'
    _C_GREEN='\033[1;32m'
    _C_YELLOW='\033[1;33m'
    _C_RED='\033[1;31m'
    _C_GREY='\033[0;37m'
else
    _C_RESET='' _C_BOLD='' _C_CYAN='' _C_GREEN='' _C_YELLOW='' _C_RED='' _C_GREY=''
fi

log_info()  { echo -e "${_C_GREY}[INFO ]${_C_RESET} $*"; }
log_step()  { echo -e "\n${_C_CYAN}${_C_BOLD}[STEP ]${_C_RESET} $*"; }
log_ok()    { echo -e "${_C_GREEN}[  OK ]${_C_RESET} $*"; }
log_warn()  { echo -e "${_C_YELLOW}[ WARN]${_C_RESET} $*" >&2; }
log_die()   { echo -e "${_C_RED}[ERROR]${_C_RESET} $*" >&2; exit 1; }

log_kv() {
    local key=$1; shift
    printf "${_C_BOLD}  %-18s${_C_RESET} %s\n" "$key" "$*"
}

log_banner() {
    local msg="$*"
    local line
    printf -v line '%*s' "${#msg}" ''
    echo -e "\n${_C_CYAN}${_C_BOLD}=== ${msg} ===${_C_RESET}"
}

# elapsed <start_seconds> → seconds since start
elapsed() { echo $(( SECONDS - ${1:-0} )); }

# validate_version <ver> <name>
validate_version() {
    local ver=$1 name=$2
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        log_die "Invalid $name version '$ver' — expected X.Y.Z"
}

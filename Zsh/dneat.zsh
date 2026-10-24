#!/usr/bin/env zsh
# dneat (macOS) – smart batch downloader: resumable, multi-connection transfers powered by aria2.
# URLs come from the clipboard, the command line or list files; unfinished downloads are saved for resuming.
# Installs Homebrew + aria2 automatically when aria2 is missing.

setopt ERR_EXIT NO_UNSET PIPE_FAIL EXTENDED_GLOB

readonly VERSION="1.0.0"
readonly DEFAULT_JOBS=1
readonly DEFAULT_CONNECTIONS=16
readonly DEFAULT_SESSION="resume.session"
readonly URL_RE='(https?|ftps?)://[^[:space:]]+'          # what is picked out of clipboard text
readonly ITEM_RE='^(https?|ftps?|sftp)://|^magnet:'       # a URL line in an aria2 input file (options are indented)

output_dir="" jobs=$DEFAULT_JOBS connections=$DEFAULT_CONNECTIONS limit="" session_file=$DEFAULT_SESSION
force=0 keep_list=0 allow_install=1 install_deps=0
typeset -a sources LIST_FILES URLS ARIA_ARGS NORM
INSTALL_LOG="" NETWORK_STATE="" INPUT_FILE="" source_label="" aria_rc=0 aria_running=0 interrupted=0
total_items=0 finished=0 ok=0 fail=0 skipped=0 total_bytes=0 NAME_COL=24 frame=0 remaining=0
exc_pending=0 exc_uri="" exc_code=0 exc_msg="" last_event=0
started_at=$SECONDS

# ══ UI layer ══════════════════════════════════════════════════════════════════
COLOR_LEVEL=0   # 0 = none, 1 = 16 colors, 2 = 256 colors, 3 = truecolor
C_RESET="" C_BOLD="" C_ACC="" C_OK="" C_WARN="" C_ERR="" C_MUTED=""
UI_TTY=0 UI_COLS=80 RULE_W=62 BAR_W=26 BAR_COL="" G_UNICODE=0
readonly -a LOGO_RAMP=(99 105 141 177 213 219)            # violet → pink

init_ui() {
    if [[ -t 1 ]]; then UI_TTY=1; fi
    if (( UI_TTY )); then
        UI_COLS=$(tput cols 2>/dev/null || print 80)
        if [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
            COLOR_LEVEL=1
            if [[ ${TERM:-} == *256color* || -n ${COLORTERM:-} ]]; then COLOR_LEVEL=2; fi
            if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* ]]; then COLOR_LEVEL=3; fi
        fi
    fi
    if (( COLOR_LEVEL >= 1 )); then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
        if (( COLOR_LEVEL >= 2 )); then
            C_ACC=$'\e[38;5;141m' C_OK=$'\e[38;5;78m' C_WARN=$'\e[38;5;221m' C_ERR=$'\e[38;5;203m'
            C_MUTED=$'\e[38;5;244m'
        else
            C_ACC=$'\e[35m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m'
            C_MUTED=$'\e[2m'
        fi
    fi
    RULE_W=$(( UI_COLS < 66 ? UI_COLS - 4 : 62 ))
    BAR_W=$(( UI_COLS >= 100 ? 30 : (UI_COLS >= 76 ? 24 : 14) ))
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff](-|)8* ]]; then
        G_OK="✔" G_FAIL="✖" G_SKIP="⊘" G_WARN="▲" G_STEP="◆" G_ARROW="→" G_DOT="·"
        G_TIMES="×" G_ELLIPSIS="…" G_H="─" G_V="│" G_TL="╭─" G_BL="╰"
        G_BAR_FULL="━" G_BAR_HEAD="╸" G_BAR_EMPTY="─" G_UNICODE=1
        G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    else
        G_OK="+" G_FAIL="x" G_SKIP="-" G_WARN="!" G_STEP="*" G_ARROW="->" G_DOT="-"
        G_TIMES="x" G_ELLIPSIS="~" G_H="-" G_V="|" G_TL="+-" G_BL="+"
        G_BAR_FULL="#" G_BAR_HEAD="" G_BAR_EMPTY="-" G_UNICODE=0
        G_SPIN=('|' '/' '-' '\')
    fi
}

rep() { # <string> <count>
    local out="" i
    for (( i = 0; i < $2; i++ )); do out+=$1; done
    print -rn -- "$out"
}

clip() { # <text> <max>
    if (( ${#1} > $2 )); then print -rn -- "${1[1,$2-1]}$G_ELLIPSIS"; else print -rn -- "$1"; fi
}

pad() { # <text> <width>  (left-aligned, clipped)
    local text; text=$(clip "$1" $2)
    print -rn -- "$text$(rep ' ' $(( $2 - ${#text} )))"
}

fmt_time() { # <seconds>
    local s=$1
    if (( s >= 3600 )); then
        printf '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    else
        printf '%d:%02d' $(( s / 60 )) $(( s % 60 ))
    fi
}

human_bytes() { # <bytes>
    local -a units=(B KB MB GB TB)
    local unit=1 tenths=$(( $1 * 10 ))
    while (( tenths >= 10240 && unit < 5 )); do tenths=$(( tenths / 1024 )); unit=$(( unit + 1 )); done
    if (( unit == 1 )); then printf '%d B' $1; else printf '%d.%d %s' $(( tenths / 10 )) $(( tenths % 10 )) $units[unit]; fi
}

# aria2 prints sizes as 1.4MiB / 512KiB / 0B; the UI uses the same KB/MB style as vneat and pneat.
speed_label() { # <aria2 size> → "1.4 MB/s"
    if [[ $1 =~ '^([0-9.]+)([KMGT]?)i?B$' ]]; then print -rn -- "$match[1] ${match[2]}B/s"; else print -rn -- "$1/s"; fi
}

eta_seconds() { # <aria2 eta, e.g. 1h2m3s> → seconds
    local rest=$1 total=0
    while [[ $rest =~ '^([0-9]+)([dhms])(.*)$' ]]; do
        case $match[2] in
            d) total=$(( total + match[1] * 86400 )) ;;
            h) total=$(( total + match[1] * 3600 )) ;;
            m) total=$(( total + match[1] * 60 )) ;;
            s) total=$(( total + match[1] )) ;;
        esac
        rest=$match[3]
    done
    print -rn -- $total
}

url_decode() { local s=$1; printf '%b' "${s//\%/\\x}" }

url_name() { # <url> → the file name aria2 will most likely use
    local u=${1%%[?#]*} name
    if [[ $1 == magnet:* ]]; then print -rn -- "magnet link"; return 0; fi
    u=${u%/}; name=${u##*/}
    if [[ $u == *://*/* && -n $name ]]; then url_decode "$name"; else print -rn -- "${u#*://}"; fi
}

url_scheme() { local s=${1%%:*}; print -rn -- ${s:u} }

# Colored pill with a short label (plain "[LABEL]" without colors).
badge() { # <label>
    local label=$1 bg
    if (( COLOR_LEVEL >= 2 )); then
        case $label in HTTPS) bg=141 ;; HTTP) bg=221 ;; FTP|FTPS|SFTP) bg=215 ;; MAGNET) bg=213 ;; *) bg=245 ;; esac
        printf '\e[48;5;%d;38;5;16m %s %s' $bg $label $C_RESET
    elif (( COLOR_LEVEL == 1 )); then
        case $label in HTTPS) bg=45 ;; HTTP) bg=43 ;; FTP|FTPS|SFTP) bg=41 ;; MAGNET) bg=45 ;; *) bg=47 ;; esac
        printf '\e[30;%dm %s %s' $bg $label $C_RESET
    else
        printf '[%s]' $label
    fi
}

info() { print -r -- "$*" }
note() { print -r -- "  ${C_MUTED}$*${C_RESET}" }
step() { print -r -- "  ${C_ACC}${G_STEP}${C_RESET} $*" }
warn() { print -r -- "  ${C_WARN}${G_WARN} $*${C_RESET}" >&2 }
die() { # <message> [hint ...]
    print -r -- $'\n'"  ${C_ERR}${G_FAIL} $1${C_RESET}" >&2
    shift
    local hint
    for hint in "$@"; do print -r -- "    ${C_MUTED}${hint}${C_RESET}" >&2; done
    print >&2
    exit 1
}

# ── Cards: a titled block with a left gutter ──────────────────────────────────
card_open()  { print -r -- $'\n'"  ${C_MUTED}${G_TL} ${C_BOLD}${C_ACC}$1${C_RESET}${C_MUTED} $(rep "$G_H" $(( RULE_W - ${#1} - 4 )))${C_RESET}" }
card_line()  { print -r -- "  ${C_MUTED}${G_V}${C_RESET}${1:+ $1}" }
card_row()   { card_line "$(printf '%s%-10s%s %s' "$C_MUTED" "$1" "$C_RESET" "$2")" }
card_close() { print -r -- "  ${C_MUTED}${G_BL}$(rep "$G_H" $(( RULE_W - 1 )))${C_RESET}" }

hide_cursor() { if (( UI_TTY )); then printf '\e[?25l'; fi; return 0 }
show_cursor() { if (( UI_TTY )); then printf '\e[?25h'; fi; return 0 }

# ── Progress bars ─────────────────────────────────────────────────────────────
# Sets BAR_COL to the color of cell <i> of <width> (smooth violet→pink gradient on truecolor terminals).
bar_color() { # <i> <width>
    if (( COLOR_LEVEL >= 3 )); then
        local w=$(( $2 > 1 ? $2 - 1 : 1 ))
        BAR_COL=$'\e[38;2;'"$(( 140 + 115 * $1 / w ));$(( 100 + 10 * $1 / w ));$(( 255 - 45 * $1 / w ))m"
    else
        BAR_COL=$C_ACC
    fi
}

make_bar() { # <pct 0-100> <width>
    local pct=$1 width=$2 cells head=0 i out="" empty
    cells=$(( pct * width / 100 ))
    if [[ -n $G_BAR_HEAD ]] && (( cells < width && pct * width % 100 >= 50 )); then head=1; fi
    for (( i = 0; i < cells; i++ )); do bar_color $i $width; out+="$BAR_COL$G_BAR_FULL"; done
    if (( head )); then bar_color $cells $width; out+="$BAR_COL$G_BAR_HEAD"; fi
    empty=$(( width - cells - head ))
    print -rn -- "${out}${C_RESET}${C_MUTED}$(rep "$G_BAR_EMPTY" $empty)${C_RESET}"
}

# ── Logo & banners ────────────────────────────────────────────────────────────
print_logo() {
    local -a rows=(
        "██████╗ ███╗   ██╗███████╗ █████╗ ████████╗"
        "██╔══██╗████╗  ██║██╔════╝██╔══██╗╚══██╔══╝"
        "██║  ██║██╔██╗ ██║█████╗  ███████║   ██║   "
        "██║  ██║██║╚██╗██║██╔══╝  ██╔══██║   ██║   "
        "██████╔╝██║ ╚████║███████╗██║  ██║   ██║   "
        "╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝   "
    )
    local i
    print
    if (( G_UNICODE && UI_COLS >= 52 )); then
        for (( i = 1; i <= $#rows; i++ )); do
            if (( COLOR_LEVEL >= 2 )); then printf '  \e[38;5;%dm%s%s\n' $LOGO_RAMP[i] $rows[i] $C_RESET
            else printf '  %s%s%s\n' $C_ACC $rows[i] $C_RESET; fi
        done
    else
        printf '  %s%sdneat%s\n' $C_BOLD $C_ACC $C_RESET
    fi
}

run_banner() {
    print -r -- $'\n'"  ${C_ACC}${C_BOLD}${G_STEP} dneat${C_RESET}  ${C_MUTED}smart batch downloader ${G_ARROW} resumable multi-connection ${G_DOT} v${VERSION}${C_RESET}"
}

print_system() {
    card_open "System"
    card_row "OS" "macOS $(sw_vers -productVersion)"
    card_row "CPU" "$(clip "$(sysctl -n machdep.cpu.brand_string) ($(uname -m))" $(( UI_COLS - 18 )))"
    card_close
}

print_plan() {
    local jobs_line limit_line existing
    if (( jobs == 1 )); then jobs_line="1 file at a time"; else jobs_line="$jobs files at a time"; fi
    if [[ -z $limit ]]; then limit_line="no speed limit"
    elif [[ $limit == *[KM] ]]; then limit_line="max ${limit%[KM]} ${limit[-1]}B/s"
    else limit_line="max $limit B/s"; fi
    if (( force )); then existing="replaced (--force)"; else existing="skipped (use -f to replace)"; fi
    card_open "Plan"
    card_row "Source" "$source_label $G_DOT $total_items URL(s)"
    card_row "Output" "$output_dir"
    card_row "Engine" "aria2 $(aria2c --version | awk 'NR == 1 { print $3 }')"
    card_row "Transfer" "$jobs_line $G_DOT $connections connection(s) per file $G_DOT $limit_line"
    card_row "Existing" "$existing"
    card_row "Resume" "$session_file"
    card_close
    print
}

cleanup() {
    show_cursor
    if [[ -n $INPUT_FILE ]]; then rm -f "$INPUT_FILE"; fi
    if [[ -n $INSTALL_LOG ]]; then rm -f "$INSTALL_LOG"; fi
}

# While aria2 runs, Ctrl-C only sets a flag: aria2 receives the same signal, shuts down gracefully (writing its
# session file) and closes the pipe, which ends the parser loop. Anywhere else the script stops right away.
report_interrupted() {
    clear_live
    show_cursor
    printf '\n  %s%s Interrupted%s\n' "$C_WARN" "$G_WARN" "$C_RESET"
    remaining=$(( $(count_items "$session_file") - skipped ))
    if (( remaining > 0 )); then note "$remaining unfinished URL(s) saved $G_ARROW continue with: $(resume_command)"; fi
    print
    exit 130
}
on_interrupt() { if (( aria_running )); then interrupted=1; else report_interrupted; fi }
on_terminate() {
    if (( aria_running )); then
        interrupted=1
        pkill -INT -f -- "--input-file=$INPUT_FILE" 2>/dev/null || true     # a plain kill never reaches aria2
    else
        report_interrupted
    fi
}
trap cleanup EXIT
trap on_interrupt INT
trap on_terminate TERM

# ══ Help ══════════════════════════════════════════════════════════════════════
help_opt() { # <flags> <description> [default]
    card_line "$(printf '%s%-27s%s %s%s' "$C_OK" "$1" "$C_RESET" "$2" "${3:+  $C_MUTED($3)$C_RESET}")"
}
help_cmd() { card_line "$(printf '%s$%s %-31s %s%s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")" }
help_example() { card_line "$(printf '%s$%s %-38s %s# %s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")" }

show_help() {
    print_logo
    printf '\n  %sSmart batch downloader %s resumable multi-connection transfers%s\n' "$C_BOLD" "$G_ARROW" "$C_RESET"
    printf '  %saria2 powered %s automatic setup %s live progress %s v%s%s\n' "$C_MUTED" "$G_DOT" "$G_DOT" "$G_DOT" "$VERSION" "$C_RESET"

    card_open "USAGE"
    help_cmd "dneat [options] [url|list ...]" "download links and/or list files"
    help_cmd "dneat [options] -i <list>" "download every URL in a list file"
    help_cmd "dneat" "download the URLs on the clipboard"
    card_close

    card_open "INPUT & OUTPUT"
    help_opt "-i, --input <file>" "File that contains the URLs" "default: clipboard"
    help_opt "-o, --output <dir>" "Download folder" "default: ."
    help_opt "-f, --force" "Replace files that already exist"
    help_opt "-k, --keep-list" "Never ask to remove the URL list"
    card_close

    card_open "TRANSFER"
    help_opt "-j, --jobs <1-16>" "Files downloaded at the same time" "default: $DEFAULT_JOBS"
    help_opt "-c, --connections <1-16>" "Connections used for each file" "default: $DEFAULT_CONNECTIONS"
    help_opt "-l, --limit <rate>" "Max total speed, e.g. 500K or 2M" "default: none"
    help_opt "-s, --session <file>" "Where unfinished downloads are saved" "default: $DEFAULT_SESSION"
    card_close

    card_open "SETUP"
    help_opt "-y, --install-deps" "Install Homebrew + aria2, then exit"
    help_opt "-n, --no-install" "Never install anything (wins over -y)"
    card_close

    card_open "OTHER"
    help_opt "-h, --help" "Show this help"
    help_opt "-V, --version" "Show the version"
    card_line "${C_MUTED}Long options also accept the --option=value form.${C_RESET}"
    card_close

    card_open "EXAMPLES"
    help_example "dneat" "download the clipboard links"
    help_example "dneat urls.txt" "download every URL in a file"
    help_example "dneat https://a.io/x.zip <url>" "download two links"
    help_example "dneat -o ~/Downloads -j 3 urls.txt" "3 files in parallel"
    help_example "dneat --limit=2M urls.txt" "cap the speed at 2 MB/s"
    help_example "dneat resume.session" "continue an interrupted batch"
    help_example "dneat -y" "install Homebrew + aria2"
    card_close

    card_open "GOOD TO KNOW"
    card_line "${C_MUTED}Links${C_RESET}        https $G_DOT http $G_DOT ftps $G_DOT ftp $G_DOT sftp $G_DOT magnet"
    card_line "${C_MUTED}Resume${C_RESET}       unfinished URLs are saved in $DEFAULT_SESSION –"
    card_line "${C_MUTED}${C_RESET}             run  dneat $DEFAULT_SESSION  to continue them"
    card_line "${C_MUTED}Lists${C_RESET}        aria2 list files work too (out=, dir=, mirrors)"
    card_line "${C_MUTED}Env${C_RESET}          NO_COLOR=1  disable colors"
    card_line "${C_MUTED}${C_RESET}             DNEAT_NETWORK=online|offline  skip the internet check"
    card_line "${C_MUTED}Exit codes${C_RESET}   0 ok   1 error or a download failed   130 interrupted"
    card_close
    print
}

# ══ CLI ═══════════════════════════════════════════════════════════════════════
typeset -A LONG_VALUE LONG_FLAG
LONG_VALUE=(input i output o output-dir o jobs j connections c limit l session s)
LONG_FLAG=(force f keep-list k no-install n install-deps y install y help h version V)

# Rewrites --long options into their short equivalents so getopts can handle everything.
normalize_args() {
    NORM=()
    local arg name
    while (( $# > 0 )); do
        arg=$1; shift
        case $arg in
            --)    NORM+=(-- "$@"); break ;;
            --*=*) name=${arg%%=*}; name=${name#--}
                   [[ -n ${LONG_VALUE[$name]:-} ]] || die "Option --$name does not take a value." "Run 'dneat --help' to see all options."
                   NORM+=("-${LONG_VALUE[$name]}" "${arg#*=}") ;;
            --*)   name=${arg#--}
                   if [[ -n ${LONG_VALUE[$name]:-} ]]; then
                       (( $# > 0 )) || die "Option $arg requires a value."
                       NORM+=("-${LONG_VALUE[$name]}" "$1"); shift
                   elif [[ -n ${LONG_FLAG[$name]:-} ]]; then
                       NORM+=("-${LONG_FLAG[$name]}")
                   else
                       die "Unknown option '$arg'." "Run 'dneat --help' to see all options."
                   fi ;;
            *)     NORM+=("$arg") ;;
        esac
    done
}

validate_count() { [[ $1 == <-> ]] && (( $1 >= 1 && $1 <= 16 )) }
validate_limit() { [[ $1 == (#b)<->(.<->|)[KkMm](#c0,1) ]] }

parse_args() {
    local opt
    normalize_args "$@"
    set -- "${NORM[@]}"
    while getopts ":i:o:j:c:l:s:fknyVh" opt; do
        case $opt in
            i) sources+=("$OPTARG") ;;
            o) output_dir=$OPTARG ;;
            j) jobs=$OPTARG ;;
            c) connections=$OPTARG ;;
            l) limit=${OPTARG:u} ;;
            s) session_file=$OPTARG ;;
            f) force=1 ;;
            k) keep_list=1 ;;
            n) allow_install=0 ;;
            y) install_deps=1 ;;
            V) print "dneat $VERSION"; exit 0 ;;
            h) show_help; exit 0 ;;
            :) die "Option -$OPTARG requires a value." ;;
            *) die "Unknown option -$OPTARG." "Run 'dneat --help' to see all options." ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    sources+=("$@")
    validate_count $jobs || die "Jobs must be a number from 1 to 16."
    validate_count $connections || die "Connections must be a number from 1 to 16."
    if [[ -n $limit ]]; then validate_limit $limit || die "Invalid speed limit '$limit'." "Use a number with an optional K or M, e.g. 500K or 2M."; fi
}

require_macos() {
    [[ $(uname -s) == Darwin ]] || die "This is the macOS script. Use dneat (Linux) or dneat.ps1 (Windows)."
}

# ══ Prerequisites ═════════════════════════════════════════════════════════════
# ── Connectivity ──
probe_network() {
    case ${DNEAT_NETWORK:-} in online) return 0 ;; offline) return 1 ;; esac
    curl -fsI -m 5 -o /dev/null https://github.com 2>/dev/null
}

has_network() {
    if [[ -z $NETWORK_STATE ]]; then
        if probe_network; then NETWORK_STATE=up; else NETWORK_STATE=down; fi
    fi
    [[ $NETWORK_STATE == up ]]
}

# Explains a failed install: network problem (re-checked live) or the last line of the log.
report_install_failure() { # <what failed>
    local last
    NETWORK_STATE=""
    if grep -Eqi 'could not resolve host|failed to connect|connection (timed out|refused|reset)|network is unreachable|name resolution|curl: \((6|7|28|35|56)\)|failed to download|ssl_connect' "$INSTALL_LOG" 2>/dev/null || ! has_network; then
        NETWORK_STATE=down
        warn "$1: network problem – check your internet connection."
    else
        last=$(grep -v '^[[:space:]]*$' "$INSTALL_LOG" | tail -n 1 | cut -c1-110 || true)
        warn "$1${last:+: $last}"
    fi
}

load_homebrew() {
    local candidate
    for candidate in ${commands[brew]:-} /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x $candidate ]] || continue
        eval "$("$candidate" shellenv)"
        return 0
    done
    return 1
}

install_homebrew() {
    has_network || die "Homebrew is not installed and there is no internet connection." \
        "Connect to the network and run again, or install Homebrew from https://brew.sh"
    step "Homebrew not found – installing (may ask for your password)…"
    local installer; installer=$(mktemp "${TMPDIR:-/tmp}/brew-install.XXXXXX")
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer" \
        || { rm -f "$installer"; die "Could not download the Homebrew installer (network problem)." "Check your internet connection and run again, or install Homebrew from https://brew.sh"; }
    NONINTERACTIVE=1 /bin/bash "$installer" \
        || { rm -f "$installer"; die "Homebrew installation failed." "Install it manually from https://brew.sh"; }
    rm -f "$installer"
    load_homebrew || die "Homebrew was installed but could not be found." "Open a new terminal and run again."
}

ensure_aria2() {
    if (( ${+commands[aria2c]} )); then return 0; fi
    (( allow_install )) || die "aria2 is not installed (auto-install disabled)." "Install it manually: brew install aria2"
    has_network || die "aria2 is not installed and there is no internet connection." \
        "Connect to the network and run again, or install it manually: brew install aria2"
    load_homebrew || install_homebrew
    step "Installing aria2 via Homebrew…"
    if ! brew install aria2 2>&1 | tee "$INSTALL_LOG"; then
        report_install_failure "Could not install aria2"
        die "aria2 installation failed." "Install it manually: brew install aria2"
    fi
    rehash
    (( ${+commands[aria2c]} )) || die "aria2 installation failed." "Install it manually: brew install aria2"
}

# -y: make sure Homebrew + aria2 are present; returns 1 when nothing could be done.
ensure_dependencies() {
    (( allow_install )) || { warn "-n (no install) takes precedence over -y – nothing was installed."; return 1 }
    has_network || { warn "No internet connection – dependencies were not installed."; return 1 }
    ensure_aria2
    note "aria2 is ready."
}

# ══ Input ═════════════════════════════════════════════════════════════════════
count_items() { # <aria2 input file> → number of URL lines
    [[ -s $1 ]] || { print 0; return 0 }
    grep -cE "$ITEM_RE" "$1" || true
}

same_file() { [[ -e $1 && -e $2 && ${1:A} == ${2:A} ]] }

resume_command() {
    local cmd="dneat"        # aria2 stores each download's folder in the session file, so -o is not needed
    if [[ $session_file != $DEFAULT_SESSION ]]; then cmd+=" -s ${(q)session_file}"; fi
    print -rn -- "$cmd ${(q)session_file}"
}

# Builds one aria2 input file from the clipboard, URLs and list files (list files are copied as they are).
build_input() {
    local item n_urls=0 n_files=0 clip_text
    : >"$INPUT_FILE"
    if (( $#sources == 0 )); then
        step "Reading URLs from the clipboard…"
        clip_text=$(pbpaste 2>/dev/null || true)
        grep -Eo "$URL_RE" <<<"$clip_text" | sed -E "s/[].,;:!?)>\"']+\$//" >"$INPUT_FILE" || true
        [[ -s $INPUT_FILE ]] || die "No URLs found on the clipboard." "Copy one or more http(s)/ftp links, or pass URLs / a list file as arguments."
        source_label="clipboard"
    else
        for item in "${sources[@]}"; do
            if [[ $item =~ $ITEM_RE ]]; then
                print -r -- "$item" >>"$INPUT_FILE"; n_urls=$(( n_urls + 1 ))
            elif [[ -f $item ]]; then
                tr -d '\r' <"$item" >>"$INPUT_FILE"; print >>"$INPUT_FILE"; n_files=$(( n_files + 1 ))
                if ! same_file "$item" "$session_file"; then LIST_FILES+=("$item"); fi
            else
                die "'$item' is neither a URL nor an existing file." "Run 'dneat --help' for usage."
            fi
        done
        if (( n_files > 0 && n_urls > 0 )); then source_label="$n_files list file(s) + command line"
        elif (( n_files > 0 )); then source_label="$n_files list file(s)"
        else source_label="command line"; fi
    fi
    total_items=$(count_items "$INPUT_FILE")
    (( total_items > 0 )) || die "No URLs found." "A list file needs one URL per line."
    URLS=("${(@f)$(grep -E "$ITEM_RE" "$INPUT_FILE" | cut -f1 | cut -d' ' -f1)}")
}

# A leftover session from an earlier run is replaced by this run's – tell the user before that happens.
warn_stale_session() {
    local item left
    for item in "${sources[@]}"; do if same_file "$item" "$session_file"; then return 0; fi; done
    left=$(count_items "$session_file")
    if (( left > 0 )); then
        warn "$session_file still holds $left unfinished URL(s) from an earlier run – it will be replaced."
        note "To continue them instead, stop now and run: $(resume_command)"
    fi
}

compute_layout() {
    local u longest=0 name
    for u in "${URLS[@]}"; do name=$(url_name "$u"); if (( ${#name} > longest )); then longest=${#name}; fi; done
    NAME_COL=$(( UI_COLS - 60 ))
    if (( NAME_COL < 14 )); then NAME_COL=14; fi
    if (( NAME_COL > 40 )); then NAME_COL=40; fi
    if (( longest < NAME_COL )); then NAME_COL=$longest; fi
    if (( NAME_COL < 8 )); then NAME_COL=8; fi
}

file_bytes() { if [[ -f $1 ]]; then print $(( $(wc -c <"$1") )); else print 0; fi }

# ══ Progress & reporting ══════════════════════════════════════════════════════
clear_live() { if (( UI_TTY )); then printf '\r\e[2K\n\e[2K\e[1A\r'; fi; return 0 }

# Two live lines: the current file (spinner, bar, speed, ETA, protocol) and the whole batch.
draw_live() { # <pct|-1> <speed> <eta> <active> <overall pct>
    local pct=$1 speed=$2 eta=$3 active=$4 opct=$5
    local idx=$(( finished + 1 )) tag name label plain colored bar="" badge_w avail bw=0 obw name_max prefix_w l1 l2 spin spin_index
    if (( jobs == 1 )); then
        if (( idx > total_items )); then idx=$total_items; fi
        tag="[$idx/$total_items]"
        name=$(url_name "${URLS[idx]:-}"); label=$(url_scheme "${URLS[idx]:-?}")
    else
        tag="[$finished/$total_items]"
        name="$active active"; label="$G_TIMES$active"
    fi
    badge_w=$(( ${#label} + 2 ))
    if (( pct >= 0 )); then
        plain=$(printf '%3d%%  %9s  ETA %-5s' $pct $speed $eta)
        colored=$(printf '%s%3d%%%s  %s%9s  ETA %-5s%s' "$C_BOLD" $pct "$C_RESET" "$C_MUTED" $speed $eta "$C_RESET")
    else
        plain=$(printf '%7s  %9s' "$(fmt_time $(( SECONDS - started_at )))" $speed)
        colored="$C_MUTED$plain$C_RESET"
    fi
    avail=$(( UI_COLS - (2 + 1 + 1 + ${#tag} + 1 + 1 + ${#plain} + 2 + badge_w) - 1 ))   # room for the name and the bar
    if (( pct >= 0 )); then
        bw=$(( avail - 15 )); if (( bw > BAR_W )); then bw=$BAR_W; fi
        if (( bw < 8 )); then bw=0; fi
    fi
    if (( bw > 0 )); then bar="$(make_bar $pct $bw) "; name_max=$(( avail - bw - 1 )); else name_max=$avail; fi
    if (( name_max < 10 )); then name_max=10; fi
    prefix_w=$(( 2 + 1 + 1 + ${#tag} + 1 + name_max + 1 ))
    if (( bw > 0 )); then obw=$bw; else obw=$(( UI_COLS - prefix_w - 24 )); if (( obw > BAR_W )); then obw=$BAR_W; fi; if (( obw < 6 )); then obw=6; fi; fi
    spin_index=$(( frame % $#G_SPIN + 1 ))
    spin=$G_SPIN[spin_index]
    l1=$(printf '  %s%s%s %s%s%s %s%s%s %s%s  %s' "$C_ACC" "$spin" "$C_RESET" "$C_MUTED" "$tag" "$C_RESET" \
        "$C_BOLD" "$(pad "$name" $name_max)" "$C_RESET" "$bar" "$colored" "$(badge "$label")")
    l2=$(printf '%s%*s%s %s  %s%3d%%  %s elapsed%s' "$C_MUTED" $(( prefix_w - 1 )) "overall" "$C_RESET" \
        "$(make_bar $opct $obw)" "$C_MUTED" $opct "$(fmt_time $(( SECONDS - started_at )))" "$C_RESET")
    printf '\r\e[2K%s\n\e[2K%s\e[1A\r' "$l1" "$l2"
}

# One aria2 readout line:  [#gid 4.5MiB/5.7MiB(80%) CN:1 DL:1.5MiB ETA:3s]   or   [DL:1.4MiB][#gid …(16%)][#gid …(35%)]
handle_readout() { # <line>
    (( UI_TTY )) || return 0
    local line=$1 rest=$1 sum=0 n=0 pct=-1 speed="--" eta="--:--" marks active opct elapsed
    if [[ $line =~ 'DL:([0-9.]+[KMGT]?i?B)' ]]; then speed=$(speed_label $match[1]); fi
    while [[ $rest =~ '\(([0-9]+)%\)' ]]; do
        sum=$(( sum + match[1] )); n=$(( n + 1 ))
        rest=${rest#*"$MATCH"}
    done
    marks=${line//[^#]/}; active=${#marks}
    if (( active < 1 )); then active=1; fi
    if (( n > 0 )); then pct=$(( sum / n )); fi
    opct=$(( (finished * 100 + (n > 0 ? sum : 0)) / total_items ))
    if (( opct > 100 )); then opct=100; fi
    elapsed=$(( SECONDS - started_at ))
    if (( jobs == 1 || active == 1 )) && [[ $line =~ 'ETA:([0-9dhms]+)' ]]; then
        eta=$(fmt_time $(eta_seconds $match[1]))
    elif (( opct > 0 && opct < 100 && elapsed > 0 )); then
        eta=$(fmt_time $(( elapsed * (100 - opct) / opct )))
    fi
    frame=$(( frame + 1 ))
    draw_live $pct "$speed" "$eta" $active $opct
}

report_ok() { # <tag> <name> <bytes> <seconds|-1>
    local speed="" secs=""
    if (( $4 >= 0 )); then
        secs=$(fmt_time $4)
        if (( $4 > 0 )); then speed="$(human_bytes $(( $3 / $4 )))/s"; else speed="--"; fi
    fi
    printf '  %s%s%s %s%s%s %s%s%s  %9s  %s%10s  %5s%s\n' \
        "$C_OK" "$G_OK" "$C_RESET" "$C_MUTED" "$1" "$C_RESET" "$C_BOLD" "$(pad "$2" $NAME_COL)" "$C_RESET" \
        "$(human_bytes $3)" "$C_MUTED" "$speed" "$secs" "$C_RESET"
}

report_note() { # <fail|skip> <tag> <name> <detail>
    local glyph color room
    if [[ $1 == fail ]]; then glyph=$G_FAIL color=$C_ERR; else glyph=$G_SKIP color=$C_MUTED; fi
    room=$(( UI_COLS - ${#2} - NAME_COL - 8 ))
    if (( room < 10 )); then room=10; fi
    printf '  %s%s%s %s%s%s %s%s%s  %s%s%s\n' "$color" "$glyph" "$C_RESET" "$C_MUTED" "$2" "$C_RESET" \
        "$C_BOLD" "$(pad "$3" $NAME_COL)" "$C_RESET" "$color" "$(clip "$4" $room)" "$C_RESET"
}

handle_complete() { # <file>
    local file=$1 bytes secs now=$SECONDS      # (never name a zsh variable "path": it is tied to $PATH)
    bytes=$(file_bytes "$file")
    finished=$(( finished + 1 )); ok=$(( ok + 1 )); total_bytes=$(( total_bytes + bytes ))
    if (( jobs == 1 )); then secs=$(( now - last_event )); else secs=-1; fi
    last_event=$now
    clear_live
    report_ok "[$finished/$total_items]" "${file:t}" $bytes $secs
}

# "Exception: … errorCode=3 …" (+ "  -> … errorCode=3 Resource not found"): the last errorCode/message pair wins.
parse_exception() { # <line>
    if [[ $1 =~ '^.*errorCode=([0-9]+) ?(.*)$' ]]; then exc_code=$match[1]; exc_msg=$match[2]; fi
}

friendly_reason() { # <message>
    local msg=$1
    if [[ $msg =~ 'status=([0-9]+)' ]]; then printf 'HTTP %s' $match[1]; else print -rn -- "${msg%.}"; fi
}

flush_failure() {
    local name; name=$(url_name "$exc_uri")
    exc_pending=0
    finished=$(( finished + 1 ))
    clear_live
    if (( exc_code == 13 )); then
        skipped=$(( skipped + 1 )); report_note skip "[$finished/$total_items]" "$name" "already exists – use -f to replace"
    else
        fail=$(( fail + 1 )); report_note fail "[$finished/$total_items]" "$name" "failed: $(friendly_reason "$exc_msg")"
    fi
}

# Reads aria2's merged output line by line and turns it into the neat UI.
parse_stream() {
    local line
    while IFS= read -r line; do
        if (( exc_pending )) && [[ $line != Exception:* && $line != '  ->'* ]]; then flush_failure; fi
        case $line in
            '[#'*|'[DL:'*)                         handle_readout "$line" ;;
            *'[NOTICE] Download complete: '*)      handle_complete "${line##*Download complete: }" ;;
            *'[ERROR] '*'Download aborted. URI='*) exc_pending=1; exc_uri=${line##*URI=}; exc_code=0; exc_msg="" ;;
            Exception:*|'  ->'*)                   parse_exception "$line" ;;
            '@@EXIT '*)                            aria_rc=${line#@@EXIT } ;;
        esac
    done
    if (( exc_pending )); then flush_failure; fi
}

run_aria2() {
    local rc
    ARIA_ARGS=(--input-file="$INPUT_FILE" --dir="$output_dir"
        --max-concurrent-downloads=$jobs --split=$connections --max-connection-per-server=$connections
        --summary-interval=0 --console-log-level=notice --enable-color=false --download-result=hide
        --auto-file-renaming=false --save-session="$session_file" --save-session-interval=60)
    if (( force )); then ARIA_ARGS+=(--allow-overwrite=true); fi
    if [[ -n $limit ]]; then ARIA_ARGS+=(--max-overall-download-limit=$limit); fi
    last_event=$SECONDS
    hide_cursor
    aria_running=1
    {
        aria2c "${ARIA_ARGS[@]}" 2>&1 && rc=0 || rc=$?
        print "@@EXIT $rc"
    } | parse_stream
    aria_running=0
    clear_live
    show_cursor
    if (( interrupted )); then report_interrupted; fi
}

# Unfinished URLs live in the session file; items skipped because they already exist are not "unfinished".
settle_session() {
    remaining=$(( $(count_items "$session_file") - skipped ))
    if (( remaining < 0 )); then remaining=0; fi
    if (( remaining == 0 )); then rm -f "$session_file"; fi
    return 0
}

print_summary() {
    local line wall=$(( SECONDS - started_at ))
    card_open "Summary"
    line="${C_OK}${G_OK} $ok downloaded${C_RESET}"
    if (( fail > 0 ));    then line+="   ${C_ERR}${G_FAIL} $fail failed${C_RESET}"; fi
    if (( skipped > 0 )); then line+="   ${C_MUTED}${G_SKIP} $skipped skipped${C_RESET}"; fi
    card_row "Result" "$line"
    if (( total_bytes > 0 )); then
        card_row "Size" "$(human_bytes $total_bytes)"
        if (( wall > 0 )); then card_row "Speed" "$(human_bytes $(( total_bytes / wall )))/s average"; fi
    fi
    card_row "Time" "$(fmt_time $wall)"
    card_row "Output" "$output_dir"
    if (( remaining > 0 )); then
        card_row "Resume" "${C_WARN}$remaining URL(s) left${C_RESET} $G_ARROW $(resume_command)"
    else
        card_row "Resume" "${C_MUTED}nothing left to resume${C_RESET}"
    fi
    card_close
    if (( fail == 0 )); then
        printf '\n  %s%s%s All done.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET"
    else
        printf '\n  %s%s%s Finished with %d failure(s).%s\n\n' "$C_ERR" "$C_BOLD" "$G_FAIL" $fail "$C_RESET"
    fi
}

# Offers to delete the URL lists that were used (never the resume file – dneat manages that one).
offer_list_removal() {
    local list answer
    if (( keep_list || $#LIST_FILES == 0 )); then return 0; fi
    [[ -t 0 && -t 1 ]] || return 0
    for list in "${LIST_FILES[@]}"; do
        [[ -f $list ]] || continue
        card_open "URL list"
        card_line "'$list' is no longer needed."
        if (( remaining > 0 )); then
            card_line "${C_MUTED}Finished downloads are on disk; the unfinished ones are saved in $session_file.${C_RESET}"
        else
            card_line "${C_MUTED}Everything in it has been handled.${C_RESET}"
        fi
        printf '  %s%s%s %sRemove it?%s %s[y/N]%s: ' "$C_MUTED" "$G_V" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
        read -r answer || answer=""
        if [[ $answer == [Yy] ]]; then rm -f -- "$list"; card_line "${C_OK}${G_OK}${C_RESET} removed"; else card_line "${C_MUTED}kept${C_RESET}"; fi
        card_close
    done
}

# ══ Main ══════════════════════════════════════════════════════════════════════
main() {
    init_ui
    require_macos
    parse_args "$@"
    INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/dneat-install.XXXXXX")
    INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/dneat.XXXXXX")
    run_banner; print_system

    if (( install_deps )); then
        ensure_dependencies || exit 1
        printf '\n  %s%s%s Dependency setup finished.%s %sRe-run without -y to download.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET" "$C_MUTED" "$C_RESET"
        exit 0
    fi
    ensure_aria2
    build_input
    output_dir=${output_dir:-.}
    mkdir -p -- "$output_dir"
    output_dir=${output_dir:A}
    compute_layout
    warn_stale_session
    print_plan

    run_aria2
    if (( aria_rc != 0 && aria_rc != 13 && fail == 0 && skipped == 0 && ok < total_items )); then
        fail=1; warn "aria2 stopped with exit code $aria_rc."
    fi
    settle_session
    print_summary
    offer_list_removal
    (( fail == 0 ))
}

main "$@"

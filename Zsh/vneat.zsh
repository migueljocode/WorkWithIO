#!/usr/bin/env zsh
# vneat (macOS) – smart batch video → H.264/AAC MP4 converter.
# Encoder priority: VideoToolbox (Apple hardware) → CPU (libx264).
# Installs Homebrew + a VideoToolbox-enabled ffmpeg automatically when ffmpeg is missing or lacks h264_videotoolbox.

setopt ERR_EXIT NO_UNSET PIPE_FAIL EXTENDED_GLOB

readonly VERSION="2.0.0"
readonly DEFAULT_QUALITY=50
readonly COMPRESSED_SUBDIR="compressed"
readonly SUPPORTED_ALT="mov|mp4|mkv|avi|webm"
readonly EVEN_SCALE="scale=trunc(iw/2)*2:trunc(ih/2)*2"

# Maximum output resolution caps (width x height). Smaller sources are never upscaled.
readonly RES_SD_W=854   RES_SD_H=480
readonly RES_HD_W=1280  RES_HD_H=720
readonly RES_FULLHD_W=1920 RES_FULLHD_H=1080
readonly RES_4K_W=3840  RES_4K_H=2160

input_dir="" output_dir="" quality=$DEFAULT_QUALITY max_res=""
preserve_times=1 allow_install=1 install_deps=0 list_only=0 interactive=0 wanted_encoder=auto
typeset -a direct_files FILES ENCODERS PRE_ARGS ENC_ARGS NORM
VF="" CURRENT_TMP="" ERR_LOG="" INSTALL_LOG="" NETWORK_STATE="" mode=dir
max_w=0 max_h=0
ok=0 fail=0 skipped=0 file_index=0 file_total=0 total_in=0 total_out=0 total_src=0
total_media_us=0 total_wall=0 NAME_COL=24
started_at=$SECONDS
typeset -A enc_used

# ══ UI layer ══════════════════════════════════════════════════════════════════
COLOR_LEVEL=0   # 0 = none, 1 = 16 colors, 2 = 256 colors, 3 = truecolor
C_RESET="" C_BOLD="" C_ACC="" C_OK="" C_WARN="" C_ERR="" C_MUTED=""
UI_TTY=0 UI_COLS=80 RULE_W=62 BAR_W=26 BAR_COL="" G_UNICODE=0

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
            C_ACC=$'\e[38;5;81m' C_OK=$'\e[38;5;78m' C_WARN=$'\e[38;5;221m' C_ERR=$'\e[38;5;203m'
            C_MUTED=$'\e[38;5;244m'
        else
            C_ACC=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m'
            C_MUTED=$'\e[2m'
        fi
    fi
    RULE_W=$(( UI_COLS < 66 ? UI_COLS - 4 : 62 ))
    BAR_W=$(( UI_COLS >= 100 ? 30 : (UI_COLS >= 76 ? 24 : 14) ))
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff](-|)8* ]]; then
        G_OK="✔" G_FAIL="✖" G_SKIP="⊘" G_WARN="▲" G_STEP="◆" G_ARROW="→" G_CHAIN="▸" G_DOT="·"
        G_TIMES="×" G_ELLIPSIS="…" G_UP="▲" G_DOWN="▼" G_H="─" G_V="│" G_TL="╭─" G_BL="╰"
        G_BAR_FULL="━" G_BAR_HEAD="╸" G_BAR_EMPTY="─" G_UNICODE=1
        G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    else
        G_OK="+" G_FAIL="x" G_SKIP="-" G_WARN="!" G_STEP="*" G_ARROW="->" G_CHAIN=">" G_DOT="-"
        G_TIMES="x" G_ELLIPSIS="~" G_UP="^" G_DOWN="v" G_H="-" G_V="|" G_TL="+-" G_BL="+"
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

quality_label() { # <pct 1-100>
    if   (( $1 >= 90 )); then print "near-lossless"
    elif (( $1 >= 65 )); then print "high quality"
    elif (( $1 >= 40 )); then print "balanced"
    elif (( $1 >= 20 )); then print "small files"
    else print "tiny files"
    fi
}

# libx264 CRF equivalent of the user-facing percentage (shown in the UI and used for the CPU encoder).
quality_to_actual() { # <pct 1-100> → CRF 1-51
    local pct=$1
    if (( pct < 1 )); then pct=1; fi
    if (( pct > 100 )); then pct=100; fi
    print $(( 51 - pct / 2 ))
}

encoder_label() {
    case $1 in
        videotoolbox) print "Apple VideoToolbox" ;;
        cpu)          print "CPU (libx264)" ;;
        auto)         print "Automatic (best available)" ;;
        *)            print -r -- $1 ;;
    esac
}

encoder_short() {
    case $1 in
        videotoolbox) print VT ;;
        cpu)          print CPU ;;
        *)            print -r -- $1 ;;
    esac
}

# Colored pill with the encoder's short name (plain "[NAME]" without colors).
badge() { # <encoder>
    local label bg
    label=$(encoder_short $1)
    if (( COLOR_LEVEL >= 2 )); then
        case $1 in videotoolbox) bg=255 ;; *) bg=245 ;; esac
        printf '\e[48;5;%d;38;5;16m %s %s' $bg $label $C_RESET
    elif (( COLOR_LEVEL == 1 )); then
        case $1 in videotoolbox) bg=47 ;; *) bg=47 ;; esac
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
# Sets BAR_COL to the color of cell <i> of <width> (smooth blue→green gradient on truecolor terminals).
bar_color() { # <i> <width>
    if (( COLOR_LEVEL >= 3 )); then
        local w=$(( $2 > 1 ? $2 - 1 : 1 ))
        BAR_COL=$'\e[38;2;'"$(( 64 + 30 * $1 / w ));$(( 160 + 90 * $1 / w ));$(( 255 - 95 * $1 / w ))m"
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
        "██╗   ██╗███╗   ██╗███████╗ █████╗ ████████╗"
        "██║   ██║████╗  ██║██╔════╝██╔══██╗╚══██╔══╝"
        "██║   ██║██╔██╗ ██║█████╗  ███████║   ██║   "
        "╚██╗ ██╔╝██║╚██╗██║██╔══╝  ██╔══██║   ██║   "
        " ╚████╔╝ ██║ ╚████║███████╗██║  ██║   ██║   "
        "  ╚═══╝  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝   "
    )
    local -a ramp=(39 45 51 50 49 48)
    local i
    print
    if (( G_UNICODE && UI_COLS >= 52 )); then
        for (( i = 1; i <= $#rows; i++ )); do
            if (( COLOR_LEVEL >= 2 )); then printf '  \e[38;5;%dm%s%s\n' $ramp[i] $rows[i] $C_RESET
            else printf '  %s%s%s\n' $C_ACC $rows[i] $C_RESET; fi
        done
    else
        printf '  %s%svneat%s\n' $C_BOLD $C_ACC $C_RESET
    fi
}

run_banner() {
    print -r -- $'\n'"  ${C_ACC}${C_BOLD}${G_STEP} vneat${C_RESET}  ${C_MUTED}smart batch video ${G_ARROW} H.264/AAC converter ${G_DOT} v${VERSION}${C_RESET}"
}

print_system() {
    card_open "System"
    card_row "OS" "macOS $(sw_vers -productVersion)"
    card_row "CPU" "$(clip "$(sysctl -n machdep.cpu.brand_string) ($(uname -m))" $(( UI_COLS - 18 )))"
    card_close
}

print_plan() {
    local chain="" enc first=1 size_line
    for enc in $ENCODERS; do
        if (( first )); then
            chain+="${C_OK}${C_BOLD}$(encoder_label $enc)${C_RESET}"; first=0
        else
            chain+=" ${C_MUTED}${G_CHAIN}${C_RESET} $(encoder_label $enc)"
        fi
    done
    if (( max_w > 0 )); then size_line="$max_res $G_DOT ${max_w}×${max_h} max $G_DOT never upscaled"; else size_line="original size"; fi
    card_open "Plan"
    card_row "Encoders" "$chain"
    card_row "Quality" "$quality% $G_DOT $(quality_label $quality) ${C_MUTED}(CRF $(quality_to_actual $quality))${C_RESET}"
    card_row "Size" "$size_line"
    card_row "Output" "$output_dir"
    card_row "Files" "$file_total video(s) $G_DOT $(human_bytes $total_src) $G_DOT timestamps $( (( preserve_times )) && print kept || print not kept)"
    card_close
    print
}

cleanup() {
    show_cursor
    if [[ -n $CURRENT_TMP ]]; then rm -f "$CURRENT_TMP"; fi
    if [[ -n $ERR_LOG ]]; then rm -f "$ERR_LOG"; fi
    if [[ -n $INSTALL_LOG ]]; then rm -f "$INSTALL_LOG"; fi
}
on_interrupt() {
    cleanup
    if (( UI_TTY )); then printf '\r\e[2K\n\e[2K\e[1A\r'; fi
    printf '  %s%s Interrupted%s\n\n' "$C_WARN" "$G_WARN" "$C_RESET"
    exit 130
}
trap cleanup EXIT
trap on_interrupt INT TERM

# ══ Help ══════════════════════════════════════════════════════════════════════
help_opt() { # <flags> <description> [default]
    card_line "$(printf '%s%-27s%s %s%s' "$C_OK" "$1" "$C_RESET" "$2" "${3:+  $C_MUTED($3)$C_RESET}")"
}
help_cmd() { card_line "$(printf '%s$%s %-31s %s%s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")" }
help_example() { card_line "$(printf '%s$%s %-38s %s# %s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")" }
help_quality_row() { # <pct> <label> [marker]
    local crf; crf=$(quality_to_actual $1)
    card_line "$(printf '%s%4d%%%s  %s  %-14s %sCRF %2d%s%s' "$C_BOLD" $1 "$C_RESET" "$(make_bar $1 12)" "$2" "$C_MUTED" $crf "$C_RESET" "${3:+   $C_OK$G_CHAIN $3$C_RESET}")"
}

show_help() {
    print_logo
    printf '\n  %sSmart batch video %s H.264/AAC MP4 converter%s\n' "$C_BOLD" "$G_ARROW" "$C_RESET"
    printf '  %sGPU-accelerated %s automatic setup %s live progress %s v%s%s\n' "$C_MUTED" "$G_DOT" "$G_DOT" "$G_DOT" "$VERSION" "$C_RESET"

    card_open "USAGE"
    help_cmd "vneat [options] [file ...]" "convert specific files"
    help_cmd "vneat [options] -i <folder>" "convert every video in a folder"
    help_cmd "vneat" "convert the current folder"
    card_close

    card_open "INPUT & OUTPUT"
    help_opt "-i, --input <dir>" "Folder that contains the videos" "default: ."
    help_opt "-o, --output <dir>" "Output folder" "default: <input>/$COMPRESSED_SUBDIR"
    help_opt "-t, --no-timestamps" "Don't copy the original file dates"
    card_close

    card_open "QUALITY & SIZE"
    help_opt "-q, --quality <1-100>" "Quality in %, higher = better" "default: $DEFAULT_QUALITY"
    help_opt "-s, --max-size <preset>" "Cap the resolution (never upscales,"
    card_line "$(printf '%-27s %s' '' 'keeps aspect ratio, portrait-aware)')"
    card_line "$(printf '%-27s %ssd 854×480 %s hd 1280×720%s' '' "$C_MUTED" "$G_DOT" "$C_RESET")"
    card_line "$(printf '%-27s %sfullhd 1920×1080 %s 4k 3840×2160%s' '' "$C_MUTED" "$G_DOT" "$C_RESET")"
    card_close

    card_open "ENCODER"
    help_opt "-e, --encoder <name>" "auto  videotoolbox  cpu" "default: auto"
    help_opt "-c, --cpu" "Shortcut for --encoder cpu"
    help_opt "-l, --list-encoders" "Show which encoders work here, then exit"
    help_opt "-m, --interactive" "Pick encoder, quality and size from a menu"
    card_line ""
    card_line "${C_MUTED}auto tries, in order:${C_RESET} Apple VideoToolbox $G_CHAIN CPU"
    card_close

    card_open "SETUP"
    help_opt "-y, --install-deps" "Install Homebrew + ffmpeg, then exit"
    help_opt "-n, --no-install" "Never install anything (wins over -y)"
    card_close

    card_open "OTHER"
    help_opt "-h, --help" "Show this help"
    help_opt "-V, --version" "Show the version"
    card_line "${C_MUTED}Long options also accept the --option=value form.${C_RESET}"
    card_close

    card_open "QUALITY GUIDE"
    help_quality_row 100 "near-lossless"
    help_quality_row 75 "high quality"
    help_quality_row $DEFAULT_QUALITY "balanced" "default"
    help_quality_row 25 "small files"
    help_quality_row 10 "tiny files"
    card_close

    card_open "EXAMPLES"
    help_example "vneat" "convert this folder, best settings"
    help_example "vneat -i ~/Movies -q 70" "higher quality"
    help_example "vneat -s hd -o out *.mov" "720p cap, hardware encoder"
    help_example "vneat --max-size=fullhd --cpu" "1080p cap on the CPU"
    help_example "vneat -m" "guided interactive setup"
    help_example "vneat -l" "list encoders that work here"
    help_example "vneat -y" "install Homebrew + ffmpeg"
    card_close

    card_open "GOOD TO KNOW"
    card_line "${C_MUTED}Formats${C_RESET}      ${${SUPPORTED_ALT//|/ $G_DOT }}"
    card_line "${C_MUTED}Audio${C_RESET}        first audio track is kept (AAC 96k)"
    card_line "${C_MUTED}Env${C_RESET}          NO_COLOR=1  disable colors"
    card_line "${C_MUTED}${C_RESET}             VNEAT_NETWORK=online|offline  skip the internet check"
    card_line "${C_MUTED}Exit codes${C_RESET}   0 ok   1 error or a file failed   130 interrupted"
    card_close
    print
}

# ══ CLI ═══════════════════════════════════════════════════════════════════════
typeset -A LONG_VALUE LONG_FLAG
LONG_VALUE=(input i input-dir i output o output-dir o quality q encoder e max-size s)
LONG_FLAG=(interactive m no-timestamps t no-install n install-deps y install y list-encoders l list l cpu c help h version V)

# Rewrites --long options into their short equivalents so getopts can handle everything.
normalize_args() {
    NORM=()
    local arg name
    while (( $# > 0 )); do
        arg=$1; shift
        case $arg in
            --)    NORM+=(-- "$@"); break ;;
            --*=*) name=${arg%%=*}; name=${name#--}
                   [[ -n ${LONG_VALUE[$name]:-} ]] || die "Option --$name does not take a value." "Run 'vneat --help' to see all options."
                   NORM+=("-${LONG_VALUE[$name]}" "${arg#*=}") ;;
            --*)   name=${arg#--}
                   if [[ -n ${LONG_VALUE[$name]:-} ]]; then
                       (( $# > 0 )) || die "Option $arg requires a value."
                       NORM+=("-${LONG_VALUE[$name]}" "$1"); shift
                   elif [[ -n ${LONG_FLAG[$name]:-} ]]; then
                       NORM+=("-${LONG_FLAG[$name]}")
                   else
                       die "Unknown option '$arg'." "Run 'vneat --help' to see all options."
                   fi ;;
            *)     NORM+=("$arg") ;;
        esac
    done
}

validate_quality() { [[ $1 == <-> ]] && (( $1 >= 1 && $1 <= 100 )) }
validate_max_res() { [[ $1 == (sd|hd|fullhd|4k|) ]] }

# Sets max_w/max_h from a max_res name; leaves them 0 when unset (no resize).
resize_dimensions() { # <sd|hd|fullhd|4k|>
    case $1 in
        sd)     max_w=$RES_SD_W;     max_h=$RES_SD_H ;;
        hd)     max_w=$RES_HD_W;     max_h=$RES_HD_H ;;
        fullhd) max_w=$RES_FULLHD_W; max_h=$RES_FULLHD_H ;;
        4k)     max_w=$RES_4K_W;     max_h=$RES_4K_H ;;
        *)      max_w=0; max_h=0 ;;
    esac
}

# ffmpeg scale filter: cap the output to max WxH (swapped for portrait videos), keep the aspect
# ratio and never upscale. min(iw,..)/min(ih,..) is what prevents upscaling: on its own,
# force_original_aspect_ratio=decrease would still stretch a small source up to the box.
resize_scale_filter() { # → filter string, or empty when no resize is requested
    (( max_w > 0 && max_h > 0 )) || return 0
    printf "scale=w='if(gt(a,1),min(iw,%d),min(iw,%d))':h='if(gt(a,1),min(ih,%d),min(ih,%d))':force_original_aspect_ratio=decrease" \
        $max_w $max_h $max_h $max_w
}

parse_args() {
    local opt
    normalize_args "$@"
    set -- "${NORM[@]}"
    while getopts ":i:o:q:e:s:mtnylcVh" opt; do
        case $opt in
            i) input_dir=$OPTARG ;;
            o) output_dir=$OPTARG ;;
            q) quality=$OPTARG ;;
            e) wanted_encoder=${OPTARG:l} ;;
            s) max_res=${OPTARG:l} ;;
            m) interactive=1 ;;
            t) preserve_times=0 ;;
            n) allow_install=0 ;;
            y) install_deps=1 ;;
            l) list_only=1 ;;
            c) wanted_encoder=cpu ;;
            V) print "vneat $VERSION"; exit 0 ;;
            h) show_help; exit 0 ;;
            :) die "Option -$OPTARG requires a value." ;;
            *) die "Unknown option -$OPTARG." "Run 'vneat --help' to see all options." ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    direct_files=("$@")
    [[ $wanted_encoder == (auto|videotoolbox|cpu) ]] || die "Unknown encoder '$wanted_encoder'." "Choose one of: auto, videotoolbox, cpu."
    validate_quality $quality || die "Quality must be a number from 1 to 100 (higher = better)."
    validate_max_res "$max_res" || die "Invalid max size '$max_res'." "Choose one of: sd, hd, fullhd, 4k."
    resize_dimensions "$max_res"
}

require_macos() {
    [[ $(uname -s) == Darwin ]] || die "This is the macOS script. Use vneat (Linux) or vneat.ps1 (Windows)."
}

# ══ Prerequisites ═════════════════════════════════════════════════════════════
# ── Connectivity ──
probe_network() {
    case ${VNEAT_NETWORK:-${VIDEO2MP4_NETWORK:-}} in online) return 0 ;; offline) return 1 ;; esac
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

ffmpeg_has_videotoolbox() {
    local encoders; encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    [[ $encoders == *h264_videotoolbox* ]]
}

ensure_ffmpeg() {
    local have_ffmpeg=$(( ${+commands[ffmpeg]} ))
    if (( have_ffmpeg )) && ffmpeg_has_videotoolbox; then return 0; fi
    if (( ! allow_install )); then
        (( have_ffmpeg )) || die "ffmpeg is not installed (auto-install disabled)." "Install it manually: brew install ffmpeg"
        warn "ffmpeg has no VideoToolbox support (auto-install disabled) – using CPU."
        return 0
    fi
    if ! has_network; then
        (( have_ffmpeg )) || die "ffmpeg is not installed and there is no internet connection." \
            "Connect to the network and run again, or install it manually: brew install ffmpeg"
        warn "ffmpeg has no VideoToolbox support and there is no internet to install a better build – using CPU."
        return 0
    fi
    load_homebrew || install_homebrew
    step "Installing ffmpeg with VideoToolbox support via Homebrew…"
    if ! brew list ffmpeg &>/dev/null && ! brew install ffmpeg 2>&1 | tee "$INSTALL_LOG"; then
        report_install_failure "Could not install ffmpeg"
        if (( have_ffmpeg )); then warn "Continuing with the existing ffmpeg (CPU encoding)."; return 0; fi
        die "ffmpeg installation failed." "Install it manually: brew install ffmpeg"
    fi
    rehash
    (( ${+commands[ffmpeg]} )) || die "ffmpeg installation failed." "Install it manually: brew install ffmpeg"
    ffmpeg_has_videotoolbox || warn "ffmpeg still lacks VideoToolbox – using CPU."
}

# -y: make sure Homebrew + a VideoToolbox-enabled ffmpeg are present; returns 1 when nothing could be done.
ensure_dependencies() {
    (( allow_install )) || { warn "-n (no install) takes precedence over -y – nothing was installed."; return 1 }
    has_network || { warn "No internet connection – dependencies were not installed."; return 1 }
    ensure_ffmpeg
    ffmpeg_has_videotoolbox || { warn "ffmpeg is installed but has no VideoToolbox support."; return 1 }
    note "ffmpeg with VideoToolbox is ready."
}

warn_if_no_libx264() {
    local encoders; encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    [[ $encoders == *libx264* ]] || warn "This ffmpeg build has no libx264 – CPU fallback will fail."
}

# ══ Encoders ══════════════════════════════════════════════════════════════════
# Sets PRE_ARGS (before -i), VF and ENC_ARGS for the given encoder.
set_encoder() {
    local rsf base_vf crf vt_q
    rsf=$(resize_scale_filter)
    if [[ -n $rsf ]]; then base_vf="$rsf,$EVEN_SCALE"; else base_vf=$EVEN_SCALE; fi
    crf=$(quality_to_actual $quality)
    vt_q=$quality   # VideoToolbox -q:v is already "higher = better" on a 1-100 scale
    PRE_ARGS=(); VF=$base_vf
    case $1 in
        videotoolbox)
            ENC_ARGS=(-c:v h264_videotoolbox -q:v "$vt_q" -profile:v high -pix_fmt yuv420p) ;;
        cpu)
            ENC_ARGS=(-c:v libx264 -crf "$crf" -preset medium -pix_fmt yuv420p) ;;
    esac
    return 0
}

# Real 1-frame test encode using the exact arguments used for conversion.
probe_encoder() {
    set_encoder $1
    ffmpeg -nostdin -hide_banner -loglevel quiet "${PRE_ARGS[@]}" \
        -f lavfi -i "color=c=black:s=256x256:d=0.1" \
        -vf "$VF" "${ENC_ARGS[@]}" -frames:v 1 -f null - &>/dev/null
}

select_encoders() {
    ENCODERS=()
    if [[ $wanted_encoder != cpu ]] && probe_encoder videotoolbox; then
        ENCODERS+=(videotoolbox)
    fi
    ENCODERS+=(cpu)
}

# Keeps only the requested encoder (plus the CPU as a safety net).
apply_encoder_choice() {
    case $wanted_encoder in
        auto) return 0 ;;
        cpu)  ENCODERS=(cpu); return 0 ;;
    esac
    local -a picked=(${(M)ENCODERS:#${wanted_encoder}*})
    (( $#picked > 0 )) || die "Encoder '$wanted_encoder' is not available." "Available: ${ENCODERS[*]}"
    ENCODERS=($picked cpu)
}

choose_interactively() {
    [[ -t 0 && -t 1 ]] || die "Interactive mode needs a terminal."
    local -a options=(auto $ENCODERS)
    local i choice answer gutter
    gutter="  ${C_MUTED}${G_V}${C_RESET} "
    card_open "Interactive setup"
    card_line "${C_BOLD}Encoder${C_RESET}"
    for (( i = 1; i <= $#options; i++ )); do card_line "  ${C_ACC}${i}${C_RESET}  $(encoder_label $options[i])"; done
    printf '%s%sChoice%s %s[1]%s: ' "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"; read -r choice
    choice=${choice:-1}
    if ! [[ $choice == <-> ]] || (( choice < 1 || choice > $#options )); then die "Invalid choice."; fi
    wanted_encoder=$options[choice]
    card_line ""
    printf '%s%sQuality %s1-100, higher = better%s %s[%s]%s: ' "$gutter" "$C_BOLD" "$C_MUTED" "$C_RESET" "$C_MUTED" "$quality" "$C_RESET"; read -r answer
    if [[ -n $answer ]]; then
        validate_quality $answer || die "Quality must be a number from 1 to 100."
        quality=$answer
    fi
    printf '%s%sMax size %ssd | hd | fullhd | 4k | none%s %s[%s]%s: ' "$gutter" "$C_BOLD" "$C_MUTED" "$C_RESET" "$C_MUTED" "${max_res:-none}" "$C_RESET"; read -r answer
    if [[ -n $answer ]]; then
        answer=${answer:l}; if [[ $answer == none ]]; then answer=""; fi
        validate_max_res "$answer" || die "Invalid max size '$answer'." "Choose one of: sd, hd, fullhd, 4k, none."
        max_res=$answer; resize_dimensions "$max_res"
    fi
    card_close
}

# ══ Files ═════════════════════════════════════════════════════════════════════
is_supported() { [[ ${1:e:l} == (${~SUPPORTED_ALT}) ]] }

collect_files() {
    FILES=()
    local f
    if [[ $mode == files ]]; then
        for f in $direct_files; do
            if [[ ! -f $f ]]; then warn "File not found: $f"
            elif ! is_supported "$f"; then note "$G_SKIP ${f:t} (unsupported)"; skipped=$(( skipped + 1 ))
            else FILES+=("$f")
            fi
        done
    else
        FILES=("$input_dir"/*.(#i)(${~SUPPORTED_ALT})(N.))
    fi
    file_total=$#FILES
    (( file_total > 0 )) || die "No supported video files found."
}

probe_duration_us() { # <file> → microseconds, 0 if unknown
    local raw whole frac=""
    raw=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)
    [[ $raw =~ ^[0-9]+(\.[0-9]+)?$ ]] || { print 0; return 0 }
    whole=${raw%%.*}
    if [[ $raw == *.* ]]; then frac=${raw#*.}; fi
    frac="${frac}000000"
    print $(( 10#$whole * 1000000 + 10#${frac[1,6]} ))
}

file_bytes() { print $(( $(wc -c <"$1") )) }

# ══ Progress & reporting ══════════════════════════════════════════════════════
# Two live lines: the current file (spinner, bar, speed, ETA, encoder) and the whole batch.
draw_live() { # <spinner> <tag> <name> <enc> <pct|-1> <speed> <elapsed> <eta>
    local spin=$1 tag=$2 name=$3 enc=$4 pct=$5 speed=$6 elapsed=$7 eta=$8
    local plain colored="" bar="" short badge_w name_max prefix_w opct l1 l2
    short=$(encoder_short $enc); badge_w=$(( ${#short} + 2 ))
    if (( pct >= 0 )); then
        plain=$(printf '%3d%%  %6s  ETA %-5s' $pct $speed $eta)
        colored=$(printf '%s%3d%%%s  %s%6s  ETA %-5s%s' "$C_BOLD" $pct "$C_RESET" "$C_MUTED" $speed $eta "$C_RESET")
        bar="$(make_bar $pct $BAR_W) "
    else
        plain=$(printf '%5s  %6s' "$(fmt_time $elapsed)" $speed)
        colored="$C_MUTED$plain$C_RESET"
    fi
    name_max=$(( UI_COLS - (2 + 1 + 1 + ${#tag} + 1 + 1 + ${#plain} + 2 + badge_w) - 1 ))
    if (( pct >= 0 )); then name_max=$(( name_max - BAR_W - 1 )); fi
    if (( name_max < 10 )); then name_max=10; fi
    prefix_w=$(( 2 + 1 + 1 + ${#tag} + 1 + name_max + 1 ))
    opct=$(( ((file_index - 1) * 100 + (pct > 0 ? pct : 0)) / file_total ))
    l1=$(printf '  %s%s%s %s%s%s %s%s%s %s%s  %s' "$C_ACC" "$spin" "$C_RESET" "$C_MUTED" "$tag" "$C_RESET" \
        "$C_BOLD" "$(pad "$name" $name_max)" "$C_RESET" "$bar" "$colored" "$(badge $enc)")
    l2=$(printf '%s%*s%s %s  %s%3d%%  %s elapsed%s' "$C_MUTED" $(( prefix_w - 1 )) "overall" "$C_RESET" \
        "$(make_bar $opct $BAR_W)" "$C_MUTED" $opct "$(fmt_time $(( SECONDS - started_at )))" "$C_RESET")
    printf '\r\e[2K%s\n\e[2K%s\e[1A\r' "$l1" "$l2"
}

# Reads ffmpeg's `-progress` key=value stream on stdin and animates the live lines.
render_progress() { # <tag> <name> <encoder> <duration_us>
    if (( ! UI_TTY )); then cat >/dev/null; return 0; fi
    local tag=$1 name=$2 enc=$3 dur_us=$4 key value out_us=0 speed="--" frame=0
    local start=$SECONDS pct eta elapsed spin_index
    draw_live $G_SPIN[1] "$tag" "$name" $enc $(( dur_us > 0 ? 0 : -1 )) $speed 0 "--:--"
    while IFS='=' read -r key value; do
        case $key in
            out_time_us|out_time_ms) if [[ $value == <-> ]]; then out_us=$value; fi ;;
            speed)                   speed=${value// /}; if [[ $speed == N/A ]]; then speed="--"; fi ;;
            progress)
                frame=$(( frame + 1 )); elapsed=$(( SECONDS - start )); pct=-1; eta="--:--"
                if (( dur_us > 0 )); then
                    pct=$(( out_us * 100 / dur_us )); if (( pct > 100 )); then pct=100; fi
                    if (( out_us > 0 && elapsed > 0 && out_us < dur_us )); then
                        eta=$(fmt_time $(( elapsed * (dur_us - out_us) / out_us )))
                    fi
                fi
                spin_index=$(( frame % $#G_SPIN + 1 ))
                draw_live $G_SPIN[spin_index] "$tag" "$name" $enc $pct $speed $elapsed $eta ;;
        esac
    done
    printf '\r\e[2K\n\e[2K\e[1A\r'
}

report_ok() { # <tag> <name> <in_bytes> <out_bytes> <encoder> <seconds>
    local delta color arrow
    delta=$(( ($4 - $3) * 100 / ($3 > 0 ? $3 : 1) ))
    if (( delta <= 0 )); then color=$C_OK arrow=$G_DOWN delta=$(( -delta )); else color=$C_WARN arrow=$G_UP; fi
    printf '  %s%s%s %s%s%s %s%s%s  %9s %s%s%s %-9s  %s%s %3d%%%s  %s  %s%5s%s\n' \
        "$C_OK" "$G_OK" "$C_RESET" "$C_MUTED" "$1" "$C_RESET" "$C_BOLD" "$(pad "$2" $NAME_COL)" "$C_RESET" \
        "$(human_bytes $3)" "$C_MUTED" "$G_ARROW" "$C_RESET" "$(human_bytes $4)" \
        "$color" "$arrow" $delta "$C_RESET" "$(badge $5)" "$C_MUTED" "$(fmt_time $6)" "$C_RESET"
}

report_note() { # <fail|skip> <tag> <name> <detail>
    local glyph color room
    if [[ $1 == fail ]]; then glyph=$G_FAIL color=$C_ERR; else glyph=$G_SKIP color=$C_MUTED; fi
    room=$(( UI_COLS - ${#2} - NAME_COL - 8 ))
    if (( room < 10 )); then room=10; fi
    printf '  %s%s%s %s%s%s %s%s%s  %s%s%s\n' "$color" "$glyph" "$C_RESET" "$C_MUTED" "$2" "$C_RESET" \
        "$C_BOLD" "$(pad "$3" $NAME_COL)" "$C_RESET" "$color" "$(clip "$4" $room)" "$C_RESET"
}

encode() { # <src> <dst> <tag> <name> <encoder> <duration_us>
    ffmpeg -nostdin -hide_banner -loglevel error -nostats -progress pipe:1 "${PRE_ARGS[@]}" \
        -i "$1" -map 0:v:0 -map '0:a:0?' -sn -dn -vf "$VF" "${ENC_ARGS[@]}" \
        -c:a aac -b:a 96k -movflags +faststart -f mp4 -y "$2" 2>"$ERR_LOG" | render_progress "$3" "$4" "$5" "$6"
}

process_video() {
    local src=$1 base=${1:t} name=${1:t:r} out enc tag dur_us in_bytes out_bytes reason="" started=$SECONDS
    local last_enc=${ENCODERS[-1]}
    out="$output_dir/$name.mp4"
    CURRENT_TMP="$output_dir/.$name.partial.mp4"
    tag="[$file_index/$file_total]"

    if [[ ${src:A} == "${output_dir:A}"/* ]]; then
        report_note skip "$tag" "$base" "already in the output folder"; skipped=$(( skipped + 1 )); return 0
    fi
    if [[ -f $out ]]; then
        report_note skip "$tag" "$base" "output already exists"; skipped=$(( skipped + 1 )); return 0
    fi

    dur_us=$(probe_duration_us "$src")
    hide_cursor
    for enc in $ENCODERS; do
        set_encoder $enc
        if encode "$src" "$CURRENT_TMP" "$tag" "$base" $enc $dur_us; then
            mv -f "$CURRENT_TMP" "$out"
            if (( preserve_times )); then touch -r "$src" "$out"; fi
            in_bytes=$(file_bytes "$src"); out_bytes=$(file_bytes "$out")
            total_in=$(( total_in + in_bytes )); total_out=$(( total_out + out_bytes ))
            total_media_us=$(( total_media_us + dur_us )); total_wall=$(( total_wall + SECONDS - started ))
            enc_used[$enc]=$(( ${enc_used[$enc]:-0} + 1 ))
            report_ok "$tag" "$base" $in_bytes $out_bytes $enc $(( SECONDS - started ))
            ok=$(( ok + 1 )); show_cursor; return 0
        fi
        rm -f "$CURRENT_TMP"
        reason=$(tail -n 1 "$ERR_LOG" 2>/dev/null || true)
        if [[ $enc != $last_enc ]]; then warn "$(encoder_label $enc) failed${reason:+: $reason} – trying next encoder"; fi
    done
    report_note fail "$tag" "$base" "failed${reason:+: $reason}"
    fail=$(( fail + 1 )); show_cursor
}

print_summary() {
    local enc used="" line saved pct kept speed10
    card_open "Summary"
    line="${C_OK}${G_OK} $ok converted${C_RESET}"
    if (( fail > 0 ));    then line+="   ${C_ERR}${G_FAIL} $fail failed${C_RESET}"; fi
    if (( skipped > 0 )); then line+="   ${C_MUTED}${G_SKIP} $skipped skipped${C_RESET}"; fi
    card_row "Result" "$line"
    if (( total_in > 0 )); then
        saved=$(( total_in - total_out )); pct=$(( (saved < 0 ? -saved : saved) * 100 / total_in ))
        if (( saved >= 0 )); then line="${C_OK}${G_DOWN} $pct% smaller${C_RESET}"; else line="${C_WARN}${G_UP} $pct% larger${C_RESET}"; fi
        card_row "Size" "$(human_bytes $total_in) $G_ARROW $(human_bytes $total_out)  $line"
        kept=$(( total_out * 100 / total_in )); if (( kept > 100 )); then kept=100; fi
        card_row "" "$(make_bar $kept 24)  ${C_MUTED}$kept% of original${C_RESET}"
        if (( saved > 0 )); then card_row "Saved" "${C_OK}$(human_bytes $saved)${C_RESET}"; fi
    fi
    if (( total_wall > 0 && total_media_us > 0 )); then
        speed10=$(( total_media_us * 10 / (total_wall * 1000000) ))
        card_row "Speed" "$(( speed10 / 10 )).$(( speed10 % 10 ))$G_TIMES realtime"
    fi
    for enc in ${(k)enc_used}; do used+="$(badge $enc) $G_TIMES${enc_used[$enc]}  "; done
    if [[ -n $used ]]; then card_row "Encoders" "$used"; fi
    card_row "Time" "$(fmt_time $(( SECONDS - started_at )))"
    card_row "Output" "$output_dir"
    card_close
    if (( fail == 0 )); then
        printf '\n  %s%s%s All done.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET"
    else
        printf '\n  %s%s%s Finished with %d failure(s).%s\n\n' "$C_ERR" "$C_BOLD" "$G_FAIL" $fail "$C_RESET"
    fi
}

# ══ Main ══════════════════════════════════════════════════════════════════════
compute_layout() {
    local f longest=0 base
    for f in $FILES; do
        base=${f:t}; if (( ${#base} > longest )); then longest=${#base}; fi
        total_src=$(( total_src + $(file_bytes "$f") ))
    done
    NAME_COL=$(( UI_COLS - 60 ))
    if (( NAME_COL < 14 )); then NAME_COL=14; fi
    if (( NAME_COL > 40 )); then NAME_COL=40; fi
    if (( longest < NAME_COL )); then NAME_COL=$longest; fi
    if (( NAME_COL < 8 )); then NAME_COL=8; fi
}

main() {
    init_ui
    require_macos
    parse_args "$@"
    if (( ! list_only )); then run_banner; print_system; fi

    if (( $#direct_files > 0 )); then
        mode=files
        output_dir=${output_dir:-./$COMPRESSED_SUBDIR}
    else
        input_dir=${input_dir:-.}
        [[ -d $input_dir ]] || die "Folder '$input_dir' not found."
        output_dir=${output_dir:-$input_dir/$COMPRESSED_SUBDIR}
    fi
    if (( ! list_only && ! install_deps )); then collect_files; fi

    INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/vneat-install.XXXXXX")
    if (( install_deps )); then
        ensure_dependencies || exit 1
        printf '\n  %s%s%s Dependency setup finished.%s %sRe-run without -y to convert videos.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET" "$C_MUTED" "$C_RESET"
        exit 0
    fi
    ensure_ffmpeg
    warn_if_no_libx264
    select_encoders
    if (( list_only )); then info "Available encoders: ${ENCODERS[*]}"; exit 0; fi
    if (( interactive )); then choose_interactively; fi
    apply_encoder_choice
    mkdir -p "$output_dir"
    ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/vneat.XXXXXX")
    compute_layout
    print_plan

    local f
    for f in $FILES; do
        file_index=$(( file_index + 1 ))
        process_video "$f"
    done

    print_summary
    (( fail == 0 ))
}

main "$@"

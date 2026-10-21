#!/usr/bin/env zsh
# pneat (macOS, zsh) – smart batch image → JPEG converter.
# Standard images go through ImageMagick; RAW files through LibRaw → dcraw → embedded preview.
# Missing prerequisites (ImageMagick, exiftool, dcraw, LibRaw) are installed with Homebrew only when needed.

# zsh runs this script with bash-like semantics: 0-based arrays, word splitting, no "no matches" errors.
emulate -L zsh
setopt err_exit pipe_fail no_unset ksh_arrays sh_word_split null_glob typeset_silent no_nomatch
setopt no_bg_nice no_hup no_check_jobs no_notify
zmodload zsh/datetime 2>/dev/null || true
# Homebrew lives in /opt/homebrew (Apple silicon) or /usr/local (Intel); GUI-launched shells may lack them.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

readonly VERSION="1.4.1"
readonly DEFAULT_QUALITY=80
readonly DEFAULT_HIGHLIGHT=5      # rebuild the blown highlights (0 clip, 1 unclip/pink, 2 blend, 3-9 rebuild)
readonly DEFAULT_BRIGHTNESS=1.9   # midtone lift (gamma); highlights are never clipped by it
readonly DEFAULT_CONTRAST=6      # sigmoidal S-curve for RAW, 0 = off
readonly DEFAULT_SATURATION=112   # colour saturation for RAW, 100 = unchanged
readonly DEFAULT_SHARPEN=70      # RAW sharpening amount, 0 = off
readonly COMPRESSED_SUBDIR="compressed"

# RAW: Canon, Nikon, Sony, Fuji, Olympus, Panasonic, Pentax, Leica, Samsung, Mamiya, Hasselblad, Sigma, Adobe DNG…
readonly RAW_EXTS="cr2 cr3 crw dng nef nrw arw srf sr2 raf orf rw2 pef srw mos 3fr mef mrw x3f rwl iiq dcr kdc erf"
# Standard: raster, JPEG 2000, HEIF/AVIF, JPEG XL, Photoshop, GIMP/X11, legacy raster, HDR, icons.
readonly STD_EXTS="jpg jpeg jfif png gif tiff tif webp bmp jp2 j2k j2c jpf jpx jpm mj2 heic heif avif avifs jxl psd psb xcf xpm xbm pcx tga sgi pnm pgm pbm ppm pam hdr exr ico cur wbmp"

# Maximum length (px) of the longest side per preset. Smaller sources are never upscaled.
readonly RES_SD=854 RES_HD=1280 RES_FULLHD=1920 RES_4K=3840

input_dir="" output_dir="" quality=$DEFAULT_QUALITY highlight=$DEFAULT_HIGHLIGHT brightness=$DEFAULT_BRIGHTNESS max_res=""
contrast=$DEFAULT_CONTRAST saturation=$DEFAULT_SATURATION sharpen=$DEFAULT_SHARPEN
auto_level=1 camera_wb=1 preserve_times=1 allow_install=1 install_deps=0 list_only=0 interactive=0 wanted_decoder=auto jobs_opt=auto
dry_run=0 force=0 skip_existing=0 overwrite_mode=ask
demosaic="" dcb_enhance=0 denoise="" fbdd="" max_adjust="" best=0 libraw_args=""
# "set_*" marks the settings the user typed on the command line – everything else is "missing".
set_q=0 set_res=0 set_dec=0 set_dem=0 set_hl=0 set_br=0 set_wb=0 set_al=0 set_dn=0 set_fbdd=0 set_ma=0 set_c=0 set_s=0 set_u=0
# The RAW profile that resolve_raw_profile picks (auto_* mark values it filled in itself).
dem_auto=0 fbdd_auto=0 ma_auto=0 raw_tier=none profile_notes=()
direct_files=() FILES=() DECODERS=() IM=() NORM=() DEC_CMD=() EXTRA_ARGS=() TONE_ARGS=() RESIZE_ARGS=() FINISH_ARGS=()
PM="" PM_LOG="" NETWORK_STATE="" RES_DIR="" mode=dir max_px=0 JOBS=1 CORES=1 THREADS=1 JOBS_NOTE="" largest_bytes=0
ok=0 fail=0 skipped=0 finished=0 dry_shown=0 file_total=0 raw_total=0 total_in=0 total_out=0 total_src=0 batch_ms=0 NAME_COL=24
# ETA bookkeeping: RAW and ordinary files are timed separately, the last 5 runs of each are kept.
eta_raw_left=0 eta_ord_left=0 eta_raw_ring=() eta_ord_ring=()
started_at=$SECONDS
batch_started_at=$SECONDS
declare -A engine_used=() WORKERS=() DUP_OF=() OVERWRITE=()

# ══ UI layer ══════════════════════════════════════════════════════════════════
COLOR_LEVEL=0   # 0 = none, 1 = 16 colors, 2 = 256 colors, 3 = truecolor
C_RESET="" C_BOLD="" C_ACC="" C_OK="" C_WARN="" C_ERR="" C_MUTED=""
UI_TTY=0 UI_COLS=80 RULE_W=62 BAR_W=26 BAR_COL=""
readonly BAR_RAMP=(208 214 220 226 227 228)       # amber → pale yellow (256-color fallback)
readonly LOGO_RAMP=(214 220 221 226 227 228)

init_ui() {
    [[ -t 1 ]] && UI_TTY=1
    if (( UI_TTY )); then
        UI_COLS=$(tput cols 2>/dev/null || echo 80)
        if [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
            COLOR_LEVEL=1
            if [[ ${TERM:-} == *256color* || -n ${COLORTERM:-} ]]; then COLOR_LEVEL=2; fi
            if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* ]]; then COLOR_LEVEL=3; fi
        fi
    fi
    if (( COLOR_LEVEL >= 1 )); then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
        if (( COLOR_LEVEL >= 2 )); then
            C_ACC=$'\e[38;5;220m' C_OK=$'\e[38;5;114m' C_WARN=$'\e[38;5;208m' C_ERR=$'\e[38;5;203m'
            C_MUTED=$'\e[38;5;244m'
        else
            C_ACC=$'\e[33m' C_OK=$'\e[32m' C_WARN=$'\e[1;33m' C_ERR=$'\e[31m'
            C_MUTED=$'\e[2m'
        fi
    fi
    RULE_W=$(( UI_COLS < 66 ? UI_COLS - 4 : 62 ))
    BAR_W=$(( UI_COLS >= 100 ? 30 : (UI_COLS >= 76 ? 24 : 14) ))
    if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} =~ [Uu][Tt][Ff]-?8 ]]; then
        G_OK="✔" G_FAIL="✖" G_SKIP="⊘" G_WARN="▲" G_STEP="◆" G_ARROW="→" G_CHAIN="▸" G_DOT="·"
        G_ELLIPSIS="…" G_UP="▲" G_DOWN="▼" G_H="─" G_V="│" G_TL="╭─" G_BL="╰"
        G_BAR_FULL="━" G_BAR_HEAD="╸" G_BAR_EMPTY="─" G_UNICODE=1
        G_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    else
        G_OK="+" G_FAIL="x" G_SKIP="-" G_WARN="!" G_STEP="*" G_ARROW="->" G_CHAIN=">" G_DOT="-"
        G_ELLIPSIS="~" G_UP="^" G_DOWN="v" G_H="-" G_V="|" G_TL="+-" G_BL="+"
        G_BAR_FULL="#" G_BAR_HEAD="" G_BAR_EMPTY="-" G_UNICODE=0
        # shellcheck disable=SC1003
        G_SPIN=('|' '/' '-' '\')
    fi
}

rep() { # <string> <count>
    local out="" i
    for (( i = 0; i < $2; i++ )); do out+=$1; done
    printf '%s' "$out"
}

clip() { # <text> <max>
    if (( ${#1} > $2 )); then printf '%s%s' "${1:0:$2-1}" "$G_ELLIPSIS"; else printf '%s' "$1"; fi
}

pad() { # <text> <width>  (left-aligned, clipped)
    local text; text=$(clip "$1" "$2")
    printf '%s%s' "$text" "$(rep ' ' $(( $2 - ${#text} )))"
}

now_ms() {
    if [[ -n ${EPOCHREALTIME:-} ]]; then
        local -i t=$(( EPOCHREALTIME * 1000 ))      # float seconds → whole milliseconds
        echo "$t"
    else
        echo $(( SECONDS * 1000 ))
    fi
}

fmt_ms() { # <milliseconds>
    local ms=$1
    if   (( ms < 10000 ));  then printf '%d.%ds' $(( ms / 1000 )) $(( ms % 1000 / 100 ))
    elif (( ms < 60000 ));  then printf '%ds' $(( ms / 1000 ))
    else fmt_time $(( ms / 1000 ))
    fi
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
    local units=(B KB MB GB TB) unit=0 tenths=$(( $1 * 10 ))
    while (( tenths >= 10240 && unit < 4 )); do tenths=$(( tenths / 1024 )); unit=$(( unit + 1 )); done
    if (( unit == 0 )); then printf '%d B' "$1"; else printf '%d.%d %s' $(( tenths / 10 )) $(( tenths % 10 )) "${units[unit]}"; fi
}

quality_label() { # <pct 1-100>
    if   (( $1 >= 90 )); then echo "near-lossless"
    elif (( $1 >= 75 )); then echo "high quality"
    elif (( $1 >= 50 )); then echo "balanced"
    elif (( $1 >= 30 )); then echo "small files"
    else echo "tiny files"
    fi
}

engine_label() {
    case $1 in
        im)      echo "ImageMagick" ;;
        dcraw)   echo "dcraw" ;;
        libraw)  echo "LibRaw (dcraw_emu)" ;;
        preview) echo "Embedded preview" ;;
        auto)    echo "Automatic (best available)" ;;
        *)       echo "$1" ;;
    esac
}

engine_short() {
    case $1 in im) echo IM ;; dcraw) echo DCRAW ;; libraw) echo LIBRAW ;; preview) echo PREVIEW ;; *) echo "$1" ;; esac
}

# Colored pill with the engine's short name (plain "[NAME]" without colors).
badge() { # <engine>
    local label bg=""
    label=$(engine_short "$1")
    if (( COLOR_LEVEL >= 2 )); then
        case $1 in im) bg=228 ;; dcraw) bg=214 ;; libraw) bg=220 ;; *) bg=250 ;; esac
        printf '\e[48;5;%d;38;5;16m %s %s' "$bg" "$label" "$C_RESET"
    elif (( COLOR_LEVEL == 1 )); then
        case $1 in preview) bg=47 ;; *) bg=43 ;; esac
        printf '\e[30;%dm %s %s' "$bg" "$label" "$C_RESET"
    else
        printf '[%s]' "$label"
    fi
}

info() { printf '%s\n' "$*"; }
note() { printf '  %s%s%s\n' "$C_MUTED" "$*" "$C_RESET"; }
step() { printf '  %s%s%s %s\n' "$C_ACC" "$G_STEP" "$C_RESET" "$*"; }
warn() { printf '  %s%s %s%s\n' "$C_WARN" "$G_WARN" "$*" "$C_RESET" >&2; }
die() { # <message> [hint ...]
    printf '\n  %s%s %s%s\n' "$C_ERR" "$G_FAIL" "$1" "$C_RESET" >&2
    shift
    local hint
    for hint in "$@"; do printf '    %s%s%s\n' "$C_MUTED" "$hint" "$C_RESET" >&2; done
    printf '\n' >&2
    exit 1
}

# ── Cards: a titled block with a left gutter ──────────────────────────────────
card_open()  { printf '\n  %s%s %s%s%s %s%s\n' "$C_MUTED" "$G_TL" "$C_BOLD$C_ACC" "$1" "$C_RESET$C_MUTED" "$(rep "$G_H" $(( RULE_W - ${#1} - 4 )))" "$C_RESET"; }
card_line()  { printf '  %s%s%s%s\n' "$C_MUTED" "$G_V" "$C_RESET" "${1:+ $1}"; }
card_row()   { card_line "$(printf '%s%-10s%s %s' "$C_MUTED" "$1" "$C_RESET" "$2")"; }
card_close() { printf '  %s%s%s%s\n' "$C_MUTED" "$G_BL" "$(rep "$G_H" $(( RULE_W - 1 )))" "$C_RESET"; }

hide_cursor() { if (( UI_TTY )); then printf '\e[?25l'; fi; return 0; }
show_cursor() { if (( UI_TTY )); then printf '\e[?25h'; fi; return 0; }

# ── Progress bars ─────────────────────────────────────────────────────────────
# Sets BAR_COL to the color of cell <i> of <width> (smooth amber→yellow gradient on truecolor terminals).
bar_color() { # <i> <width>
    local w=$(( $2 > 1 ? $2 - 1 : 1 ))
    if (( COLOR_LEVEL >= 3 )); then
        printf -v BAR_COL '\e[38;2;255;%d;%dm' $(( 150 + 95 * $1 / w )) $(( 20 + 80 * $1 / w ))
    elif (( COLOR_LEVEL == 2 )); then
        printf -v BAR_COL '\e[38;5;%dm' "${BAR_RAMP[$(( (${#BAR_RAMP[@]} - 1) * $1 / w ))]}"
    else
        BAR_COL=$C_ACC
    fi
}

make_bar() { # <pct 0-100> <width>
    local pct=$1 width=$2 cells head=0 i out="" empty
    cells=$(( pct * width / 100 ))
    if [[ -n $G_BAR_HEAD ]] && (( cells < width && pct * width % 100 >= 50 )); then head=1; fi
    for (( i = 0; i < cells; i++ )); do bar_color "$i" "$width"; out+="$BAR_COL$G_BAR_FULL"; done
    if (( head )); then bar_color "$cells" "$width"; out+="$BAR_COL$G_BAR_HEAD"; fi
    empty=$(( width - cells - head ))
    printf '%s%s%s%s%s' "$out" "$C_RESET" "$C_MUTED" "$(rep "$G_BAR_EMPTY" "$empty")" "$C_RESET"
}

# ── Logo & banners ────────────────────────────────────────────────────────────
print_logo() {
    local -a rows=(
        "██████╗ ███╗   ██╗███████╗ █████╗ ████████╗"
        "██╔══██╗████╗  ██║██╔════╝██╔══██╗╚══██╔══╝"
        "██████╔╝██╔██╗ ██║█████╗  ███████║   ██║   "
        "██╔═══╝ ██║╚██╗██║██╔══╝  ██╔══██║   ██║   "
        "██║     ██║ ╚████║███████╗██║  ██║   ██║   "
        "╚═╝     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝   "
    )
    local i
    printf '\n'
    if (( G_UNICODE && UI_COLS >= 52 )); then
        for (( i = 0; i < ${#rows[@]}; i++ )); do
            if (( COLOR_LEVEL >= 2 )); then printf '  \e[38;5;%dm%s%s\n' "${LOGO_RAMP[i]}" "${rows[i]}" "$C_RESET"
            else printf '  %s%s%s\n' "$C_ACC" "${rows[i]}" "$C_RESET"; fi
        done
    else
        printf '  %s%spneat%s\n' "$C_BOLD" "$C_ACC" "$C_RESET"
    fi
}

run_banner() {
    printf '\n  %s%s%s pneat%s  %ssmart batch image %s JPEG converter %s v%s%s\n' \
        "$C_ACC" "$C_BOLD" "$G_STEP" "$C_RESET" "$C_MUTED" "$G_ARROW" "$G_DOT" "$VERSION" "$C_RESET"
}

print_system() {
    local cpu os
    cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    os="macOS $(sw_vers -productVersion 2>/dev/null || true) ($(uname -m))"
    card_open "System"
    card_row "OS" "$os"
    card_row "CPU" "$(clip "${cpu:-$(uname -m)}" $(( UI_COLS - 18 )))"
    card_close
}

engine_chain() { # <engine>... → "a ▸ b ▸ c" (first one highlighted)
    local engine first=1 chain=""
    for engine in "$@"; do
        if (( first )); then
            chain+="$C_OK$C_BOLD$(engine_label "$engine")$C_RESET"; first=0
        else
            chain+=" $C_MUTED$G_CHAIN$C_RESET $(engine_label "$engine")"
        fi
    done
    printf '%s' "$chain"
}

print_plan() {
    local size_line raw_line="" note out_line
    if (( max_px > 0 )); then size_line="$max_res $G_DOT ${max_px}px longest side $G_DOT never upscaled"; else size_line="original size"; fi
    out_line=$output_dir
    case $overwrite_mode in
        replace) out_line+=" $G_DOT existing files replaced" ;;
        skip)    out_line+=" $G_DOT existing files kept" ;;
        mixed)   out_line+=" $G_DOT existing files: some replaced" ;;
    esac
    card_open "Plan"
    card_row "Engine" "$(magick_version)"
    if (( raw_total > 0 )); then
        card_row "RAW" "$(engine_chain "${DECODERS[@]}")"
        raw_line="highlights $(highlight_name) $G_DOT wb $( (( camera_wb )) && echo camera || echo auto ) $G_DOT brightness $brightness $G_DOT auto-level $( (( auto_level )) && echo on || echo off )"
        if [[ -n $fbdd ]]; then raw_line+=" $G_DOT fbdd $fbdd"; fi
        if [[ -n $max_adjust ]]; then raw_line+=" $G_DOT max-adjust $max_adjust"; fi
    fi
    if (( raw_total > 0 )); then card_row "Demosaic" "$(demosaic_summary)"; fi
    if (( raw_total > 0 )) && [[ $raw_tier != preview ]]; then
        card_row "RAW look" "contrast $contrast $G_DOT saturation $saturation% $G_DOT sharpen $sharpen"
    fi
    card_row "Quality" "$quality% $G_DOT $(quality_label "$quality")"
    card_row "Size" "$size_line"
    if [[ -n $raw_line ]]; then card_row "RAW opts" "$raw_line"; fi
    card_row "Output" "$out_line"
    card_row "Files" "$file_total image(s) ($raw_total RAW) $G_DOT $(human_bytes "$total_src") $G_DOT timestamps $( (( preserve_times )) && echo kept || echo "not kept")"
    card_row "Jobs" "$JOBS in parallel $G_DOT $THREADS thread(s) each $G_DOT $CORES cores$JOBS_NOTE"
    if (( ${#profile_notes[@]} > 0 )); then
        for note in "${profile_notes[@]}"; do card_row "Note" "$C_WARN$note$C_RESET"; done
    fi
    card_close
    printf '\n'
}

demosaic_name() { # <number|empty>
    case $1 in
        0) echo "linear" ;; 1) echo "VNG" ;; 2) echo "PPG" ;; 3|"") echo "AHD" ;;
        4) echo "DCB" ;; 11) echo "DHT" ;; 12) echo "AAHD" ;;
    esac
}

# One-line description of the RAW tuning that is in effect.
demosaic_summary() {
    local out
    if [[ -z $demosaic ]]; then out="none"; else out=$(demosaic_name "$demosaic"); fi
    if (( dem_auto )); then out+=" (auto)"; fi
    if (( dcb_enhance )); then out+=" + enhance"; fi
    if [[ -n $denoise ]]; then out+=" $G_DOT denoise $denoise"; fi
    if [[ -n $fbdd ]]; then out+=" $G_DOT fbdd $fbdd"; if (( fbdd_auto )); then out+=" (auto)"; fi; fi
    if [[ -n $max_adjust ]]; then out+=" $G_DOT max-adjust $max_adjust"; if (( ma_auto )); then out+=" (auto)"; fi; fi
    if [[ -n $libraw_args ]]; then out+=" $G_DOT extra: $libraw_args"; fi
    printf '%s' "$out"
}

highlight_name() {
    case $highlight in
        0) echo "clip" ;;
        1) echo "unclip" ;;
        2) echo "blend" ;;
        *) echo "rebuild $highlight" ;;
    esac
}

stop_workers() {
    local pid
    for pid in "${WORKERS[@]}"; do
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    done
    return 0
}

cleanup() {
    show_cursor
    stop_workers
    if [[ -n $output_dir && -d $output_dir ]]; then
        rm -f "$output_dir"/.*."$$".*.partial.jpg "$output_dir"/.*."$$".*.partial.jpg_exiftool_tmp
    fi
    [[ -z $RES_DIR ]] || rm -rf "$RES_DIR"
    [[ -z $PM_LOG ]] || rm -f "$PM_LOG"
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
    card_line "$(printf '%s%-27s%s %s%s%s' "$C_OK" "$1" "$C_RESET" "$2" "${3:+  $C_MUTED($3)$C_RESET}" "")"
}
help_cmd() { card_line "$(printf '%s$%s %-31s %s%s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")"; }
help_example() { card_line "$(printf '%s$%s %-38s %s# %s%s' "$C_ACC" "$C_RESET" "$1" "$C_MUTED" "$2" "$C_RESET")"; }
help_quality_row() { # <pct> <label> [marker]
    card_line "$(printf '%s%4d%%%s  %s  %-14s%s' "$C_BOLD" "$1" "$C_RESET" "$(make_bar "$1" 12)" "$2" "${3:+   $C_OK$G_CHAIN $3$C_RESET}")"
}

show_help() {
    print_logo
    printf '\n  %sSmart batch image %s JPEG converter%s\n' "$C_BOLD" "$G_ARROW" "$C_RESET"
    printf '  %sRAW + 40 formats %s automatic setup %s live progress %s v%s%s\n' "$C_MUTED" "$G_DOT" "$G_DOT" "$G_DOT" "$VERSION" "$C_RESET"

    card_open "USAGE"
    help_cmd "pneat [options] [file ...]" "convert specific files"
    help_cmd "pneat [options] -i <folder>" "convert every image in a folder"
    help_cmd "pneat" "convert the current folder"
    card_close

    card_open "INPUT & OUTPUT"
    help_opt "-i, --input <dir>" "Folder that contains the images" "default: ."
    help_opt "-o, --output <dir>" "Output folder" "default: <input>/$COMPRESSED_SUBDIR"
    help_opt "-t, --no-timestamps" "Don't copy the original file dates"
    help_opt "-f, --force" "Replace existing output files, no question"
    help_opt "-k, --skip-existing" "Keep existing output files, no question"
    card_line "$(printf '%-27s %swithout either, pneat asks what to do%s' '' "$C_MUTED" "$C_RESET")"
    card_close

    card_open "QUALITY & SIZE"
    help_opt "-q, --quality <1-100>" "JPEG quality, higher = better" "default: $DEFAULT_QUALITY"
    help_opt "-s, --max-size <preset>" "Cap the longest side (never upscales,"
    card_line "$(printf '%-27s %s' '' 'keeps aspect ratio, works for portrait too)')"
    card_line "$(printf '%-27s %ssd 854px %s hd 1280px%s' '' "$C_MUTED" "$G_DOT" "$C_RESET")"
    card_line "$(printf '%-27s %sfullhd 1920px %s 4k 3840px%s' '' "$C_MUTED" "$G_DOT" "$C_RESET")"
    card_close

    card_open "RAW FILES"
    help_opt "-H, --highlight <0-9>" "Highlight handling" "default: $DEFAULT_HIGHLIGHT"
    card_line "$(printf '%-27s %s0 clip %s 1 unclip (pink!) %s 2 blend%s' '' "$C_MUTED" "$G_DOT" "$G_DOT" "$C_RESET")"
    card_line "$(printf '%-27s %s3-9 rebuild: more detail, may tint%s' '' "$C_MUTED" "$C_RESET")"
    help_opt "-b, --brightness <num>" "Midtone lift, 1 = off" "default: $DEFAULT_BRIGHTNESS"
    help_opt "-C, --contrast <0-20>" "RAW contrast (soft S-curve), 0 = off" "default: $DEFAULT_CONTRAST"
    help_opt "-S, --saturation <0-200>" "RAW saturation, 100 = unchanged" "default: $DEFAULT_SATURATION"
    help_opt "-U, --sharpen <0-100>" "RAW sharpening, 0 = off" "default: $DEFAULT_SHARPEN"
    card_line "$(printf '%-27s %scontrast, saturation and sharpen: RAW only%s' '' "$C_MUTED" "$C_RESET")"
    help_opt "-W, --no-camera-wb" "Auto white balance (image average)"
    help_opt "-A, --no-auto-level" "Don't stretch the histogram"
    help_opt "-D, --demosaic <name>" "linear vng ppg ahd dcb dht aahd" "default: auto"
    card_line "$(printf '%-27s %swithout a value = the best the tools allow%s' '' "$C_MUTED" "$C_RESET")"
    card_line "$(printf '%-27s %sdcraw only knows linear … ahd%s' '' "$C_MUTED" "$C_RESET")"
    help_opt "-E, --dcb-enhance" "DCB color enhance (implies -D dcb, needs LibRaw)"
    help_opt "-N, --denoise <n>" "Wavelet denoise threshold, e.g. 100-500"
    help_opt "-F, --fbdd <0-2>" "FBDD noise reduction (LibRaw only)" "default: off"
    card_line "$(printf '%-27s %swithout a value = 1 (light denoise)%s' '' "$C_MUTED" "$C_RESET")"
    help_opt "-M, --max-adjust <0-1>" "LibRaw auto-maximum, 0 = off" "default: 0.75"
    help_opt "-X, --libraw-args \"..\"" "Extra dcraw_emu flags, appended last"
    help_opt "-B, --best" "Preset: -D dcb -E -M 0"
    help_opt "-d, --decoder <name>" "auto  libraw  dcraw  preview" "default: auto"
    help_opt "-l, --list-decoders" "Show which decoders work here, then exit"
    help_opt "-Z, --dry-run" "Show the decoder commands, convert nothing"
    card_line ""
    card_line "${C_MUTED}auto tries, in order:${C_RESET} LibRaw $G_CHAIN dcraw $G_CHAIN embedded preview"
    card_close

    card_open "AUTO PROFILE"
    card_line "${C_MUTED}Settings you leave out are picked for you, based on the decoder${C_RESET}"
    card_line "${C_MUTED}that is installed. With LibRaw: AAHD demosaic, FBDD off,${C_RESET}"
    card_line "${C_MUTED}max-adjust 0.75. With plain dcraw: AHD. With the embedded${C_RESET}"
    card_line "${C_MUTED}preview: no RAW tuning at all. Anything you type on the${C_RESET}"
    card_line "${C_MUTED}command line always wins.${C_RESET}"
    card_close

    card_open "SETUP"
    help_opt "-j, --jobs <n|auto>" "Parallel images (all cores)" "default: auto"
    help_opt "-m, --interactive" "Pick quality/speed/auto + the missing settings"
    help_opt "-y, --install-deps" "Install ImageMagick, exiftool, dcraw, LibRaw"
    help_opt "-n, --no-install" "Never install anything (wins over -y)"
    card_close

    card_open "OTHER"
    help_opt "-h, --help" "Show this help"
    help_opt "-V, --version" "Show the version"
    card_line "${C_MUTED}Long options also accept the --option=value form.${C_RESET}"
    card_close

    card_open "QUALITY GUIDE"
    help_quality_row 100 "near-lossless"
    if [[ $DEFAULT_QUALITY != 92 ]]; then help_quality_row 92 "near-lossless"; fi
    help_quality_row "$DEFAULT_QUALITY" "$(quality_label "$DEFAULT_QUALITY")" "default"
    help_quality_row 75 "high quality"
    help_quality_row 50 "balanced"
    help_quality_row 25 "tiny files"
    card_close

    card_open "EXAMPLES"
    help_example "pneat" "convert this folder"
    help_example "pneat -i ~/Photos -q 85" "smaller files"
    help_example "pneat -s fullhd -o web *.cr3 *.png" "1920px cap, custom output"
    help_example "pneat -b 1.2 -H 6 *.nef -j 2" "tune RAW, 2 parallel jobs"
    help_example "pneat --best -q 95" "best demosaic + highlights"
    help_example "pneat -D dht -N 200 -j 8" "DHT, denoise, 8 jobs"
    help_example "pneat -D" "best demosaic your tools allow"
    help_example "pneat -F" "light denoise profile (FBDD 1)"
    help_example "pneat -m" "guided interactive setup"
    help_example "pneat -y" "install all prerequisites"
    card_close

    card_open "GOOD TO KNOW"
    card_line "${C_MUTED}Highlights${C_RESET}   RAW skips dcraw auto-brighten (it clips 1% of"
    card_line "${C_MUTED}${C_RESET}             pixels); blend mode fades blown areas to white"
    card_line "${C_MUTED}RAW look${C_RESET}     RAW gets a soft S-curve and a little more"
    card_line "${C_MUTED}${C_RESET}             colour – tune with -C and -S"
    card_line "${C_MUTED}Parallel${C_RESET}     auto uses every core, limited by free memory"
    card_line "${C_MUTED}Metadata${C_RESET}     EXIF / IPTC / XMP copied, orientation applied"
    card_line "${C_MUTED}Progress${C_RESET}     live bar with the remaining time (ETA)"
    card_line "${C_MUTED}Auto profile${C_RESET} missing settings are chosen for you"
    card_line "${C_MUTED}Alpha${C_RESET}        transparency is flattened onto white"
    card_line "${C_MUTED}Animated${C_RESET}     only the first frame / page is converted"
    card_line "${C_MUTED}CR3 & new${C_RESET}    need LibRaw (pneat -y installs it)"
    card_line "${C_MUTED}Existing${C_RESET}     files that already have a .jpg output are skipped"
    card_line "${C_MUTED}${C_RESET}             (ask what to do, or use -f / -k)"
    card_line "${C_MUTED}Env${C_RESET}          NO_COLOR=1  disable colors"
    card_line "${C_MUTED}${C_RESET}             PNEAT_NETWORK=online|offline  skip the internet check"
    card_line "${C_MUTED}Exit codes${C_RESET}   0 ok   1 error or a file failed   130 interrupted"
    card_close
    printf '\n'
}

# ══ CLI ═══════════════════════════════════════════════════════════════════════
declare -A LONG_VALUE=([input]=i [input-dir]=i [output]=o [output-dir]=o [quality]=q [highlight]=H [brightness]=b
                       [decoder]=d [max-size]=s [jobs]=j [demosaic]=D [denoise]=N [fbdd]=F [max-adjust]=M
                       [libraw-args]=X [contrast]=C [saturation]=S [sharpen]=U)
declare -A LONG_FLAG=([interactive]=m [no-timestamps]=t [no-camera-wb]=W [no-auto-level]=A [no-install]=n
                      [install-deps]=y [install]=y [list-decoders]=l [list]=l [help]=h [version]=V [dcb-enhance]=E [best]=B
                      [dry-run]=Z [force]=f [skip-existing]=k)

# True when <candidate> looks like a value for the option <flag> (used for the optional ones).
# A value that is clearly meant for the option but is invalid (e.g. "1.3") is consumed as well,
# so the option can report a proper error instead of treating it as a file name.
opt_takes_value() { # <flag> <candidate>
    case $1 in
        D) [[ $2 =~ ^[a-z0-9]+(\.[0-9]+)?$ ]] ;;
        F) [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] ;;
        N) [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] ;;
        *) return 1 ;;
    esac
}

# Rewrites --long options into their short equivalents so getopts can handle everything.
# -D, -F and -N may be used without a value: they then mean "auto" (the best the tools allow).
normalize_args() {
    NORM=()
    local arg name flag
    while (( $# > 0 )); do
        arg=$1; shift
        case $arg in
            --)    NORM+=(-- "$@"); break ;;
            --*=*) name=${arg%%=*}; name=${name#--}
                   [[ -n ${LONG_VALUE[$name]:-} ]] || die "Option --$name does not take a value." "Run 'pneat --help' to see all options."
                   NORM+=("-${LONG_VALUE[$name]}" "${arg#*=}") ;;
            --*)   name=${arg#--}
                   if [[ -n ${LONG_VALUE[$name]:-} ]]; then
                       flag=${LONG_VALUE[$name]}
                       if [[ $name == demosaic || $name == fbdd || $name == denoise ]]; then
                           if (( $# > 0 )) && opt_takes_value "$flag" "$1"; then
                               NORM+=("-$flag" "$1"); shift
                           else
                               NORM+=("-$flag" auto)
                           fi
                       else
                           (( $# > 0 )) || die "Option $arg requires a value."
                           NORM+=("-$flag" "$1"); shift
                       fi
                   elif [[ -n ${LONG_FLAG[$name]:-} ]]; then
                       NORM+=("-${LONG_FLAG[$name]}")
                   else
                       die "Unknown option '$arg'." "Run 'pneat --help' to see all options."
                   fi ;;
            -D|-F|-N)
                   if (( $# > 0 )) && opt_takes_value "${arg#-}" "$1"; then
                       NORM+=("$arg" "$1"); shift
                   else
                       NORM+=("${arg}auto")
                   fi ;;
            *)     NORM+=("$arg") ;;
        esac
    done
}

validate_quality()    { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 100 )); }
validate_highlight()  { [[ $1 =~ ^[0-9]$ ]]; }
validate_brightness() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ && $1 =~ [1-9] ]]; }
validate_max_res()    { [[ $1 =~ ^(sd|hd|fullhd|4k|)$ ]]; }
validate_jobs()       { [[ $1 == auto ]] || { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 64 )); }; }
validate_demosaic()   { [[ $1 == auto ]] || demosaic_number "$1" >/dev/null 2>&1; }
validate_fbdd()       { [[ $1 == auto || $1 =~ ^[0-2]$ ]]; }
validate_denoise()    { [[ $1 == auto ]] || [[ $1 =~ ^[0-9]+$ ]]; }
validate_max_adjust() { [[ $1 == auto ]] || [[ $1 =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; }
validate_contrast()   { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 20 )); }
validate_saturation() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 200 )); }
validate_sharpen()    { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 100 )); }

demosaic_number() { # <name|0-4|11|12> → number
    case $1 in
        linear) echo 0 ;; vng) echo 1 ;; ppg) echo 2 ;; ahd) echo 3 ;; dcb) echo 4 ;; dht) echo 11 ;; aahd) echo 12 ;;
        0|1|2|3|4|11|12) echo "$1" ;;
        *) return 1 ;;
    esac
}

# Validates the LibRaw tuning options and expands --best. Unset options keep LibRaw's own defaults.
# "auto" means: pick the best the installed tools allow (resolved later, when the decoder is known).
resolve_raw_options() {
    if [[ -n $demosaic ]]; then
        if [[ $demosaic == auto ]]; then demosaic=""
        else
            validate_demosaic "$demosaic" || die "Unknown demosaic '$demosaic'." "Choose one of: linear, vng, ppg, ahd, dcb, dht, aahd, auto."
            demosaic=$(demosaic_number "$demosaic")
        fi
    fi
    if [[ -n $denoise ]]; then
        if [[ $denoise == auto ]]; then denoise=""
        else validate_denoise "$denoise" || die "Denoise threshold must be a whole number (e.g. 100)."
        fi
    fi
    if [[ -n $fbdd ]]; then
        if [[ $fbdd == auto ]]; then fbdd=1            # "auto" = the light denoise profile
        else validate_fbdd "$fbdd" || die "FBDD level must be 0, 1 or 2."
        fi
    fi
    if [[ -n $max_adjust ]]; then
        if [[ $max_adjust == auto ]]; then max_adjust=""
        else validate_max_adjust "$max_adjust" || die "Max-adjust must be between 0 and 1 (0 = off)."
        fi
    fi
    if (( best )); then
        if [[ -z $demosaic ]]; then demosaic=4; set_dem=1; fi
        if [[ -z $max_adjust ]]; then max_adjust=0; set_ma=1; fi
        if [[ $demosaic == 4 ]]; then dcb_enhance=1; fi
    fi
    return 0
}

# Sets max_px from a max_res name; leaves it 0 when unset (no resize).
resize_dimensions() { # <sd|hd|fullhd|4k|>
    case $1 in
        sd)     max_px=$RES_SD ;;
        hd)     max_px=$RES_HD ;;
        fullhd) max_px=$RES_FULLHD ;;
        4k)     max_px=$RES_4K ;;
        *)      max_px=0 ;;
    esac
}

parse_args() {
    local opt prev
    normalize_args "$@"
    set -- "${NORM[@]}"
    direct_files=()
    local -a argv_copy
    while (( $# > 0 )); do
        argv_copy=("$@")
        OPTIND=1
        while getopts ":i:o:q:H:b:d:s:j:D:N:F:M:X:C:S:U:fkmtWAnylVhEBZ" opt; do
            case $opt in
                i) input_dir=$OPTARG ;;
                o) output_dir=$OPTARG ;;
                q) quality=$OPTARG; set_q=1 ;;
                H) highlight=$OPTARG; set_hl=1 ;;
                b) brightness=$OPTARG; set_br=1 ;;
                d) wanted_decoder=${OPTARG:l}; set_dec=1 ;;
                s) max_res=${OPTARG:l}; set_res=1 ;;
                j) jobs_opt=${OPTARG:l} ;;
                D) demosaic=${OPTARG:l}; set_dem=1 ;;
                N) denoise=$OPTARG; set_dn=1 ;;
                F) fbdd=$OPTARG; set_fbdd=1 ;;
                M) max_adjust=$OPTARG; set_ma=1 ;;
                C) contrast=$OPTARG; set_c=1 ;;
                S) saturation=$OPTARG; set_s=1 ;;
                U) sharpen=$OPTARG; set_u=1 ;;
                f) force=1 ;;
                k) skip_existing=1 ;;
                X) libraw_args=$OPTARG ;;
                E) dcb_enhance=1 ;;
                B) best=1 ;;
                Z) dry_run=1 ;;
                m) interactive=1 ;;
                t) preserve_times=0 ;;
                W) camera_wb=0 ;;
                A) auto_level=0 ;;
                n) allow_install=0 ;;
                y) install_deps=1 ;;
                l) list_only=1 ;;
                V) echo "pneat $VERSION"; exit 0 ;;
                h) show_help; exit 0 ;;
                :) die "Option -$OPTARG requires a value." ;;
                *) die "Unknown option -$OPTARG." "Run 'pneat --help' to see all options." ;;
            esac
        done
        prev=""; if (( OPTIND > 1 )); then prev=${argv_copy[OPTIND-2]}; fi
        shift $(( OPTIND - 1 ))
        if [[ $prev == -- ]]; then direct_files+=("$@"); break; fi      # everything after -- is a file
        if (( $# > 0 )); then direct_files+=("$1"); shift; fi            # options may follow files
    done
    [[ $wanted_decoder =~ ^(auto|libraw|dcraw|preview)$ ]] || die "Unknown decoder '$wanted_decoder'." "Choose one of: auto, libraw, dcraw, preview."
    validate_quality "$quality" || die "Quality must be a number from 1 to 100 (higher = better)."
    validate_highlight "$highlight" || die "Highlight mode must be a number from 0 to 9."
    validate_brightness "$brightness" || die "Brightness must be a positive number (e.g. 1.0, 1.4, 2)."
    validate_max_res "$max_res" || die "Invalid max size '$max_res'." "Choose one of: sd, hd, fullhd, 4k."
    validate_jobs "$jobs_opt" || die "Jobs must be a number from 1 to 64, or 'auto'."
    validate_contrast "$contrast" || die "Contrast must be a number from 0 to 20 (0 = off)."
    validate_saturation "$saturation" || die "Saturation must be a number from 0 to 200 (100 = unchanged)."
    validate_sharpen "$sharpen" || die "Sharpen must be a number from 0 to 100 (0 = off)."
    resolve_raw_options
    resize_dimensions "$max_res"
    if (( highlight == 1 )); then warn "Highlight mode 1 (unclip) leaves pink highlights – mode 2 (blend) is safer."; fi
}

require_macos() {
    [[ $(uname -s) == Darwin ]] || die "This is the macOS script." "On Linux use the bash version of pneat."
}

# ══ Package management (Homebrew) ═════════════════════════════════════════════
detect_pkg_manager() { # → path of the brew executable, empty when Homebrew is missing
    local candidate
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x $candidate ]]; then echo "$candidate"; return 0; fi
    done
    command -v brew 2>/dev/null || true
    return 0
}

# ── Connectivity ──────────────────────────────────────────────────────────────
probe_network() {
    case ${PNEAT_NETWORK:-} in online) return 0 ;; offline) return 1 ;; esac
    if [[ -n ${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}} ]]; then return 0; fi
    curl -s -o /dev/null --max-time 4 https://formulae.brew.sh 2>/dev/null
}

has_network() {
    if [[ -z $NETWORK_STATE ]]; then
        if probe_network; then NETWORK_STATE=up; else NETWORK_STATE=down; fi
    fi
    [[ $NETWORK_STATE == up ]]
}

# ── Homebrew runs (output captured so failures can be explained; brew must not run as root) ─────
run_logged() { # <command...> → all output goes to $PM_LOG
    : >"$PM_LOG"
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$@" >>"$PM_LOG" 2>&1
}

classify_pm_failure() {
    local log; log=$(<"$PM_LOG")
    if grep -Eqi 'could not resolve|failed to connect|connection (timed out|refused|reset)|network is unreachable|curl: \(|download failed|failed to download|ssl' <<<"$log"; then echo network
    elif grep -Eqi 'no available formula|no formulae found|formula .* not found' <<<"$log"; then echo missing
    elif grep -Eqi 'another .*brew.* process|already locked|lock' <<<"$log"; then echo busy
    elif grep -Eqi 'permission denied|not writable|sudo' <<<"$log"; then echo auth
    else echo other
    fi
}

report_pm_failure() { # <what failed>
    local last
    case $(classify_pm_failure) in
        network) NETWORK_STATE=down; warn "$1: network problem – check your internet connection." ;;
        missing) warn "$1: formula not found in Homebrew." ;;
        busy)    warn "$1: another Homebrew process is running – wait for it to finish, then re-run." ;;
        auth)    warn "$1: Homebrew cannot write to its folders (try: brew doctor)." ;;
        *)       last=$(grep -v '^[[:space:]]*$' "$PM_LOG" | tail -n 1 | cut -c1-110 || true)
                 warn "$1${last:+: $last}" ;;
    esac
}

manual_install_hint() { # <role>...
    local role group pkgs=()
    for role in "$@"; do
        for group in $(packages_for "$role"); do pkgs+=("${group%%|*}"); done
    done
    if [[ -n $PM ]]; then echo "brew install ${pkgs[*]}"
    else echo "install Homebrew from https://brew.sh, then: brew install ${pkgs[*]:-imagemagick exiftool}"
    fi
}

pm_refresh() { return 0; }        # brew updates its formulae itself

pm_install() { run_logged "$PM" install "$@"; }

# Space-separated package groups per role; "a|b" = install the first alternative that works.
packages_for() { # <role>
    case "$1" in
        imagemagick) echo "imagemagick" ;;
        exiftool)    echo "exiftool" ;;
        dcraw)       echo "dcraw" ;;
        libraw)      echo "libraw" ;;
    esac
}

install_group() {
    local alts alt
    alts=("${(@s:|:)1}")
    for alt in "${alts[@]}"; do
        step "Installing $alt"
        if pm_install "$alt"; then return 0; fi
        report_pm_failure "Could not install $alt"
        if [[ $NETWORK_STATE == down ]]; then return 1; fi
    done
    return 1
}

install_roles() {
    local role group
    for role in "$@"; do
        for group in $(packages_for "$role"); do
            if [[ $NETWORK_STATE == down ]]; then return 1; fi
            install_group "$group" || true
        done
    done
    return 0
}

# ══ Prerequisites ═════════════════════════════════════════════════════════════
have_role() { # <role>
    case $1 in
        imagemagick) command -v magick &>/dev/null || command -v convert &>/dev/null ;;
        exiftool)    command -v exiftool &>/dev/null ;;
        dcraw)       command -v dcraw &>/dev/null ;;
        libraw)      command -v dcraw_emu &>/dev/null ;;
    esac
}

# Installs the absent roles; returns 1 when something is still missing afterwards.
install_missing() { # <role>...
    local role missing=()
    for role in "$@"; do
        if ! have_role "$role"; then missing+=("$role"); fi
    done
    (( ${#missing[@]} > 0 )) || return 0
    (( allow_install )) || { warn "Auto-install is disabled – missing: ${missing[*]}."; return 1; }
    [[ -n $PM ]] || { warn "Homebrew not found – cannot install: ${missing[*]} (https://brew.sh)."; return 1; }
    has_network || { warn "No internet connection – cannot install: ${missing[*]}."; return 1; }
    step "Installing missing tools: ${missing[*]}"
    pm_refresh || true
    install_roles "${missing[@]}" || true
    for role in "${missing[@]}"; do
        if ! have_role "$role"; then return 1; fi
    done
    return 0
}

require_essentials() {
    local role
    for role in imagemagick exiftool; do
        have_role "$role" || die "$role is not installed." "Install it manually: $(manual_install_hint "$role")"
    done
}

# RAW tools are only needed (and installed) when RAW files are in the batch.
ensure_tools() {
    local roles=(imagemagick exiftool)
    if (( raw_total > 0 )); then roles+=(dcraw libraw); fi
    install_missing "${roles[@]}" || true
    require_essentials
}

select_imagemagick() {
    if command -v magick &>/dev/null; then IM=(magick); else IM=(convert); fi
}

magick_version() {
    "${IM[@]}" -version | awk 'NR == 1 { print $2, $3, $4 }'
}

# ══ Decoders & image pipeline ═════════════════════════════════════════════════
discover_decoders() {
    DECODERS=()
    if have_role libraw; then DECODERS+=(libraw); fi
    if have_role dcraw; then DECODERS+=(dcraw); fi
    if have_role exiftool; then DECODERS+=(preview); fi
    return 0
}

has_decoder() {
    local candidate
    for candidate in "${DECODERS[@]}"; do
        [[ $candidate == "$1" ]] && return 0
    done
    return 1
}

# Keeps only the requested decoder (no silent fallback: an explicit choice is respected).
apply_decoder_choice() {
    [[ $wanted_decoder == auto ]] && return 0
    (( raw_total > 0 )) || return 0
    has_decoder "$wanted_decoder" || die "Decoder '$wanted_decoder' is not available. Available: ${DECODERS[*]:-none}" \
        "Install the missing tools with: pneat -y"
    DECODERS=("$wanted_decoder")
}

# The tier that decides which RAW settings are available: libraw | dcraw | preview | none.
decoder_tier() {
    local e
    for e in "${DECODERS[@]:-}"; do
        case $e in
            libraw)  echo libraw;  return 0 ;;
            dcraw)   echo dcraw;   return 0 ;;
            preview) echo preview; return 0 ;;
        esac
    done
    echo none
}

# The best the given tier can do: "<demosaic> <fbdd> <max-adjust>" (empty field = not applicable).
recommended_profile() { # <tier>
    case $1 in
        libraw) echo "12 0 0.75" ;;   # AAHD demosaic, FBDD off, max-adjust 0.75
        dcraw)  echo "3" ;;           # AHD is all classic dcraw can do
        *)      echo "" ;;            # embedded preview: nothing to tune
    esac
}

# Fills the RAW tuning: values from the command line win, everything else comes from the
# recommended profile of the decoder that is actually available. Degradations are noted.
resolve_raw_profile() {
    local tier rec_dem rec_fbdd rec_ma dem fb ma
    tier=$(decoder_tier)
    raw_tier=$tier
    read -r rec_dem rec_fbdd rec_ma <<<"$(recommended_profile "$tier")"
    profile_notes=()

    # ── demosaic ──
    if [[ -z $demosaic ]]; then dem=$rec_dem; dem_auto=1; else dem=$demosaic; dem_auto=0; fi

    # ── DCB enhance (-E, --best) ──
    if (( dcb_enhance )); then
        if [[ $tier != libraw ]]; then
            dcb_enhance=0
            profile_notes+=("DCB enhance ignored – LibRaw is not installed")
            if (( dem_auto )); then dem=$rec_dem; fi
        elif (( dem_auto )); then
            dem=4                                   # DCB is what the enhance works on
        elif [[ $dem != 4 ]]; then
            dcb_enhance=0
            profile_notes+=("DCB enhance ignored – it needs the dcb demosaic")
        fi
    fi

    # ── demosaic the decoder cannot do (classic dcraw stops at AHD) ──
    if [[ $tier != libraw && $dem =~ ^[0-9]+$ ]] && (( dem > 3 )); then
        if (( dem_auto )); then
            dem=$rec_dem
        else
            profile_notes+=("demosaic $(demosaic_name "$dem") is not supported by dcraw – using AHD")
            dem=3
        fi
    fi

    # ── FBDD (LibRaw only) ──
    if [[ $tier == libraw ]]; then
        if [[ -z $fbdd ]]; then fb=$rec_fbdd; fbdd_auto=1; else fb=$fbdd; fbdd_auto=0; fi
    else
        if (( set_fbdd )); then warn "FBDD needs LibRaw – ignored."; fi
        fb=""; fbdd_auto=1
    fi

    # ── max-adjust (LibRaw only – in classic dcraw -c means "write to stdout") ──
    if [[ $tier == libraw ]]; then
        if [[ -z $max_adjust ]]; then ma=$rec_ma; ma_auto=1; else ma=$max_adjust; ma_auto=0; fi
    else
        if (( set_ma )); then warn "Max-adjust needs LibRaw – ignored."; fi
        ma=""; ma_auto=1
    fi

    # ── the embedded preview carries no RAW settings at all ──
    if [[ $tier == preview ]]; then
        dem=""; fb=""; ma=""; dcb_enhance=0; dem_auto=1; fbdd_auto=1; ma_auto=1
        profile_notes+=("embedded preview – no RAW tuning available")
    fi

    demosaic=$dem; fbdd=$fb; max_adjust=$ma
    return 0
}

# Writes the embedded full-size JPEG of a RAW file to stdout (fails when there is none).
extract_preview() { # <file>
    local tag
    for tag in JpgFromRaw PreviewImage OtherImage; do
        if [[ $(exiftool -s3 "-$tag" "$1" 2>/dev/null) == *Binary* ]]; then
            exiftool -b "-$tag" "$1"; return 0
        fi
    done
    echo "no embedded preview found" >&2
    return 1
}

# Option-dependent ImageMagick stages, built once: resize → (RAW tone) → JPEG output.
build_image_args() {
    RESIZE_ARGS=()
    if (( max_px > 0 )); then RESIZE_ARGS=(-resize "${max_px}x${max_px}>"); fi
    FINISH_ARGS=(-background white -alpha remove -alpha off -colorspace sRGB -strip
                 -interlace Plane -depth 8 -quality "$quality")
}

# Sets DEC_CMD (decoder command) and TONE_ARGS (RAW tone stage) for an engine.
# RAW is decoded WITHOUT dcraw's auto-brighten (-W), which deliberately clips 1% of the pixels.
# Brightness is applied afterwards as a gamma lift, so highlights stay put and fade to white.
set_engine() { # <libraw|dcraw|preview|im>
    local amount
    DEC_CMD=(); TONE_ARGS=()
    case $1 in
        libraw|dcraw)
            if [[ $1 == libraw ]]; then DEC_CMD=(dcraw_emu -Z -); else DEC_CMD=(dcraw -c); fi   # both write a PPM to stdout
            DEC_CMD+=(-W -H "$highlight" -6 -g 2.4 12.92)
            if (( camera_wb )); then DEC_CMD+=(-w); else DEC_CMD+=(-a); fi
            if [[ -n $denoise ]]; then DEC_CMD+=(-n "$denoise"); fi
            if [[ $1 == libraw ]]; then
                if [[ -n $demosaic ]]; then DEC_CMD+=(-q "$demosaic"); fi
                if (( dcb_enhance )); then DEC_CMD+=(-dcbe); fi
                if [[ -n $fbdd ]]; then DEC_CMD+=(-fbdd "$fbdd"); fi
                if [[ -n $max_adjust ]]; then DEC_CMD+=(-c "$max_adjust"); fi
                DEC_CMD+=("${EXTRA_ARGS[@]}")
            elif [[ -n $demosaic ]]; then
                DEC_CMD+=(-q $(( demosaic > 3 ? 3 : demosaic )))    # classic dcraw stops at AHD
            fi
            if (( auto_level )); then TONE_ARGS+=(-auto-level); fi
            if [[ ! $brightness =~ ^1(\.0+)?$ ]]; then TONE_ARGS+=(-gamma "$brightness"); fi
            if (( contrast > 0 )); then TONE_ARGS+=(-sigmoidal-contrast "${contrast}x50%"); fi
            if [[ $saturation != 100 ]]; then TONE_ARGS+=(-modulate "100,$saturation"); fi
            if (( sharpen > 0 )); then
                printf -v amount "%d.%02d" $(( sharpen / 100 )) $(( sharpen % 100 ))
                TONE_ARGS+=(-unsharp "0x1+$amount+0.02")
            fi ;;
        preview)
            DEC_CMD=(extract_preview) ;;
    esac
    return 0
}

# The preview keeps the RAW file's orientation tag (copy_metadata) instead of being rotated here.
run_pipeline() { # <engine> <src> <dst>
    case $1 in
        im)      "${IM[@]}" "${2}[0]" -auto-orient "${RESIZE_ARGS[@]}" "${FINISH_ARGS[@]}" "jpg:$3" ;;
        preview) "${DEC_CMD[@]}" "$2" | "${IM[@]}" - "${RESIZE_ARGS[@]}" "${FINISH_ARGS[@]}" "jpg:$3" ;;
        *)       "${DEC_CMD[@]}" "$2" | "${IM[@]}" - "${RESIZE_ARGS[@]}" "${TONE_ARGS[@]}" "${FINISH_ARGS[@]}" "jpg:$3" ;;
    esac
}

run_engine() { # <engine> <src> <dst> <errfile>
    set_engine "$1"
    run_pipeline "$1" "$2" "$3" 2>"$4" && [[ -s $3 ]]
}

copy_metadata() { # <raw|std> <src> <dst> <engine>  (best effort – never fails the conversion)
    local tags=(-EXIF:all -IPTC:all -XMP:all) orient=(-Orientation=1)
    if [[ $1 == raw ]]; then tags=(-all:all); fi
    if [[ $4 == preview ]]; then orient=(); fi     # pixels are unrotated, so keep the original tag
    exiftool -q -overwrite_original -P -tagsFromFile "$2" "${tags[@]}" "${orient[@]}" -n "$3" &>/dev/null || true
}

# ══ Files ═════════════════════════════════════════════════════════════════════
ext_in() { # <file> <extension list>
    local ext=${1##*.} candidate
    ext=${ext:l}
    for candidate in $2; do
        [[ $ext == "$candidate" ]] && return 0
    done
    return 1
}

is_raw()   { ext_in "$1" "$RAW_EXTS"; }
is_image() { is_raw "$1" || ext_in "$1" "$STD_EXTS"; }

# Regular files (symlinks followed) of a folder that have an image extension, sorted by name.
list_images() { # <dir>
    local f
    local -a all
    all=("$1"/*(N-.))
    for f in "${(@o)all[@]}"; do
        if is_image "$f"; then print -r -- "$f"; fi
    done
}

collect_files() {
    FILES=()
    if [[ $mode == files ]]; then
        local f
        for f in "${direct_files[@]}"; do
            if [[ $f == -* ]]; then f=./$f; fi          # a leading '-' must not look like an option
            if [[ ! -f $f ]]; then warn "File not found: $f"
            elif ! is_image "$f"; then note "$G_SKIP ${f##*/} (unsupported)"; skipped=$(( skipped + 1 ))
            else FILES+=("$f")
            fi
        done
    else
        FILES=("${(@f)$(list_images "$input_dir")}")
        if [[ ${#FILES[@]} -eq 1 && -z ${FILES[0]} ]]; then FILES=(); fi
    fi
    file_total=${#FILES[@]}
    (( file_total > 0 )) || die "No supported image files found."
    local f
    for f in "${FILES[@]}"; do
        if is_raw "$f"; then raw_total=$(( raw_total + 1 )); fi
    done
}

file_bytes() { echo $(( $(wc -c <"$1") )); }

# Two sources with the same name (a.cr2 + a.png) would write the same a.jpg: only the first is converted.
mark_duplicates() {
    local i base stem
    local -A first=()
    for (( i = 0; i < ${#FILES[@]}; i++ )); do
        base=${FILES[i]##*/}; stem=${base%.*}
        if [[ -n ${first["$stem"]:-} ]]; then DUP_OF[$(( i + 1 ))]=${first["$stem"]}; else first["$stem"]=$base; fi
    done
}

# The JPEG a source file would be written to.
output_path() { # <src>
    local base=${1##*/}
    echo "$output_dir/${base%.*}.jpg"
}

# Asks what to do with the files whose output already exists:
# replace all / replace this one / ignore this one / ignore all and exit.
handle_existing_outputs() {
    local i idx base out choice pos=0 count rep=0 skp=0
    local -a existing=()
    for (( i = 0; i < ${#FILES[@]}; i++ )); do
        [[ -n ${DUP_OF[$(( i + 1 ))]:-} ]] && continue        # a duplicate is skipped anyway
        out=$(output_path "${FILES[i]}")
        if [[ -f $out ]]; then existing+=("$(( i + 1 ))"); fi
    done
    count=${#existing[@]}
    if (( count == 0 )); then overwrite_mode=none; return 0; fi
    if (( force )); then
        for i in "${existing[@]}"; do OVERWRITE[$i]=replace; done
        overwrite_mode=replace
        return 0
    fi
    if (( skip_existing )); then
        overwrite_mode=skip
        return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        note "$count file(s) already exist in the output folder – skipped."
        note "Use -f to replace them, -k to skip them without asking."
        overwrite_mode=skip
        return 0
    fi

    while (( pos < count )); do
        idx=${existing[$pos]}
        base=${FILES[idx-1]##*/}
        if (( pos == 0 )); then
            card_open "Existing files"
            card_row "Found" "$count file(s) already exist in $output_dir"
            card_line ""
            local shown=0
            for i in "${existing[@]}"; do
                if (( shown >= 6 )); then break; fi
                card_line "  $G_DOT ${FILES[i-1]##*/} $G_DOT $(output_path "${FILES[i-1]}")"
                shown=$(( shown + 1 ))
            done
            if (( count > 6 )); then card_line "  $G_DOT … and $(( count - 6 )) more"; fi
            card_close
        fi
        card_line "${C_BOLD}$base${C_RESET} already exists ($(( pos + 1 )) of $count) – what should happen?"
        card_line "  ${C_ACC}1${C_RESET} replace all         ${C_ACC}2${C_RESET} replace this one"
        card_line "  ${C_ACC}3${C_RESET} ignore this one     ${C_ACC}4${C_RESET} ignore all and exit"
        printf '  %sChoice%s %s[3]%s: ' "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET"
        read -r choice
        choice=${choice:-3}
        case $choice in
            1) for i in "${existing[@]}"; do OVERWRITE[$i]=replace; done; break ;;
            2) OVERWRITE[$idx]=replace; pos=$(( pos + 1 )) ;;
            3) OVERWRITE[$idx]=skip;    pos=$(( pos + 1 )) ;;
            4) printf '\n  %s%s%s Nothing written – %d existing file(s) left untouched.%s\n\n' \
                   "$C_MUTED" "$C_BOLD" "$G_DOT" "$count" "$C_RESET"
               exit 0 ;;
            *) die "Invalid choice." ;;
        esac
    done

    for i in "${existing[@]}"; do
        if [[ ${OVERWRITE[$i]:-skip} == replace ]]; then rep=$(( rep + 1 )); else skp=$(( skp + 1 )); fi
    done
    if (( rep == count )); then overwrite_mode=replace
    elif (( skp == count )); then overwrite_mode=skip
    else overwrite_mode=mixed; fi
    return 0
}

# Free + inactive + speculative + purgeable pages, which macOS hands out on demand.
available_mb() {
    vm_stat 2>/dev/null | awk '
        /page size of/ { size = $8 }
        /^Pages (free|inactive|speculative|purgeable)/ { gsub(/\./, "", $NF); pages += $NF }
        END { if (size > 0 && pages > 0) print int(pages * size / 1048576); else print 4096 }' || echo 4096
}

# Parallel jobs = every core, unless free memory can't hold that many full-size images.
auto_jobs() { # <cores> <available_mb> <per_job_mb>
    local jobs=$1 by_memory=$(( $2 / $3 ))
    if (( by_memory < 1 )); then by_memory=1; fi
    if (( by_memory < jobs )); then jobs=$by_memory; fi
    echo "$jobs"
}

# Splits the CPU between parallel jobs so decoder and ImageMagick threads never oversubscribe it.
resolve_jobs() {
    local per_job_mb=$(( largest_bytes * 25 / 1048576 )) wanted
    if (( per_job_mb < 512 )); then per_job_mb=512; fi
    CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
    if [[ $jobs_opt == auto ]]; then
        wanted=$CORES
        JOBS=$(auto_jobs "$CORES" "$(available_mb)" "$per_job_mb")
        if (( JOBS < wanted && JOBS < file_total )); then JOBS_NOTE=" $G_DOT memory-limited"; fi
    else
        JOBS=$jobs_opt
    fi
    if (( JOBS > file_total )); then JOBS=$file_total; fi
    THREADS=$(( CORES / JOBS )); if (( THREADS < 1 )); then THREADS=1; fi
    export OMP_NUM_THREADS=$THREADS MAGICK_THREAD_LIMIT=$THREADS
}

# ══ Interactive setup ═════════════════════════════════════════════════════════
# Asks only for the settings that are still missing and that the batch really needs:
# ordinary images need quality + size, RAW files need the decoder and the RAW tuning.
choose_interactively() {
    [[ -t 0 && -t 1 ]] || die "Interactive mode needs a terminal."
    local gutter="  $C_MUTED$G_V$C_RESET "
    local ordinary=$(( file_total - raw_total )) mix="" tier i answer choice rec_dem
    local p_quality=$DEFAULT_QUALITY p_dem="" p_fbdd="" p_denoise="" p_res="" accept=0
    local -a menu=() names=()
    tier=$(decoder_tier)

    card_open "Interactive setup"
    if (( raw_total > 0 )); then mix="$raw_total RAW"; fi
    if (( ordinary > 0 )); then
        if [[ -n $mix ]]; then mix+=", "; fi
        mix+="$ordinary ordinary"
    fi
    card_line "${C_BOLD}Batch${C_RESET} $file_total image(s) $G_DOT ${mix:-none}"
    card_line ""

    # ── 1. the simple choice that seeds every other setting ──
    card_line "${C_BOLD}Priority${C_RESET} ${C_MUTED}how the files should come out${C_RESET}"
    card_line "  ${C_ACC}1${C_RESET}  Quality  ${C_MUTED}best detail, larger files${C_RESET}"
    card_line "  ${C_ACC}2${C_RESET}  Speed    ${C_MUTED}smaller files, faster${C_RESET}"
    card_line "  ${C_ACC}3${C_RESET}  Auto     ${C_MUTED}recommended defaults${C_RESET}"
    printf '%s%sChoice%s %s[3]%s %s(Enter takes all recommended values)%s: ' \
        "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET"
    read -r choice
    if [[ -z $choice ]]; then choice=3; accept=1; fi
    case $choice in
        1) p_quality=95; p_dem="";  p_fbdd=0; p_denoise="";    p_res="" ;;
        2) p_quality=75; p_dem=3;  p_fbdd=1; p_denoise=100;    p_res="fullhd" ;;
        3) p_quality=$DEFAULT_QUALITY; p_dem=""; p_fbdd=0; p_denoise=""; p_res="" ;;
        *) die "Invalid choice." ;;
    esac
    if [[ $tier != libraw ]]; then p_fbdd=""; fi        # FBDD exists in LibRaw only

    # ── 2. seed the settings that are still missing ──
    if (( ! set_q )); then quality=$p_quality; fi
    if (( ! set_res )); then max_res=$p_res; fi
    if (( ! set_dem )); then demosaic=$p_dem; fi
    if (( ! set_fbdd )); then fbdd=$p_fbdd; fi
    if (( ! set_dn )); then denoise=$p_denoise; fi

    # ── 3. ask for the rest, one line each (Enter keeps the value in brackets) ──
    if (( ! accept )); then
        if (( ! set_q )); then
            printf '%s%sQuality %s1-100, higher = better%s %s[%s]%s: ' "$gutter" "$C_BOLD" "$C_MUTED" "$C_RESET" "$C_MUTED" "$quality" "$C_RESET"
            read -r answer
            if [[ -n $answer ]]; then
                validate_quality "$answer" || die "Quality must be a number from 1 to 100."
                quality=$answer
            fi
        fi
        if (( ! set_res )); then
            printf '%s%sMax size %ssd | hd | fullhd | 4k | none%s %s[%s]%s: ' "$gutter" "$C_BOLD" "$C_MUTED" "$C_RESET" "$C_MUTED" "${max_res:-none}" "$C_RESET"
            read -r answer
            if [[ -n $answer ]]; then
                answer=${answer:l}; if [[ $answer == none ]]; then answer=""; fi
                validate_max_res "$answer" || die "Invalid max size '$answer'." "Choose one of: sd, hd, fullhd, 4k, none."
                max_res=$answer
            fi
        fi

        if (( raw_total > 0 )); then
            card_line ""
            card_line "${C_BOLD}RAW tuning${C_RESET} ${C_MUTED}($raw_total RAW file(s))${C_RESET}"
            if (( ! set_dec )); then
                menu=(auto "${DECODERS[@]}")
                for (( i = 0; i < ${#menu[@]}; i++ )); do card_line "  $C_ACC$(( i + 1 ))$C_RESET  $(engine_label "${menu[i]}")"; done
                printf '%s%sDecoder%s %s[1]%s: ' "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
                read -r answer
                answer=${answer:-1}
                if ! [[ $answer =~ ^[0-9]+$ ]] || (( answer < 1 || answer > ${#menu[@]} )); then die "Invalid choice."; fi
                wanted_decoder=${menu[answer-1]}
            fi
            if (( ! set_dem )); then
                if [[ $tier == libraw ]]; then names=(aahd dht dcb ahd vng ppg linear); else names=(ahd vng ppg linear); fi
                rec_dem="ahd"
                if [[ $tier == libraw ]]; then rec_dem="aahd"; fi
                if (( dcb_enhance )); then rec_dem="dcb"; fi
                if [[ -n $demosaic ]]; then rec_dem=$(demosaic_name "$demosaic"); fi
                printf '%s%sDemosaic%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "${names[*]}" "$C_RESET" \
                    "$C_MUTED" "$rec_dem" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    answer=${answer:l}
                    demosaic=$(demosaic_number "$answer") || die "Unknown demosaic '$answer'." "Choose one of: ${names[*]}."
                fi
            fi
            if (( ! set_hl )); then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Highlights" "$C_RESET" \
                    "$C_MUTED" "0-9 (2 = fade to white)" "$C_RESET" "$C_MUTED" "$highlight" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    validate_highlight "$answer" || die "Highlight mode must be a number from 0 to 9."
                    highlight=$answer
                fi
            fi
            if (( ! set_br )); then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Brightness" "$C_RESET" \
                    "$C_MUTED" "midtone lift, 1 = off" "$C_RESET" "$C_MUTED" "$brightness" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    validate_brightness "$answer" || die "Brightness must be a positive number (e.g. 1.0, 1.4, 2)."
                    brightness=$answer
                fi
            fi
            if (( ! set_c )) && [[ $tier != preview ]]; then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Contrast" "$C_RESET" \
                    "$C_MUTED" "0-20, soft S-curve (0 = off)" "$C_RESET" "$C_MUTED" "$contrast" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    validate_contrast "$answer" || die "Contrast must be a number from 0 to 20 (0 = off)."
                    contrast=$answer
                fi
            fi
            if (( ! set_s )) && [[ $tier != preview ]]; then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Saturation" "$C_RESET" \
                    "$C_MUTED" "0-200, 100 = unchanged" "$C_RESET" "$C_MUTED" "$saturation" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    validate_saturation "$answer" || die "Saturation must be a number from 0 to 200 (100 = unchanged)."
                    saturation=$answer
                fi
            fi
            if (( ! set_u )) && [[ $tier != preview ]]; then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Sharpen" "$C_RESET" \
                    "$C_MUTED" "0-100, 0 = off" "$C_RESET" "$C_MUTED" "$sharpen" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    validate_sharpen "$answer" || die "Sharpen must be a number from 0 to 100 (0 = off)."
                    sharpen=$answer
                fi
            fi
            if (( ! set_wb )); then
                card_line "  ${C_ACC}1${C_RESET} camera white balance   ${C_ACC}2${C_RESET} automatic"
                printf '%s%sWhite balance%s %s[1]%s: ' "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
                read -r answer
                answer=${answer:-1}
                if [[ $answer == 2 ]]; then camera_wb=0; elif [[ $answer != 1 ]]; then die "Invalid choice."; fi
            fi
            if (( ! set_al )); then
                card_line "  ${C_ACC}1${C_RESET} stretch the histogram   ${C_ACC}2${C_RESET} keep it"
                printf '%s%sAuto-level%s %s[1]%s: ' "$gutter" "$C_BOLD" "$C_RESET" "$C_MUTED" "$C_RESET"
                read -r answer
                answer=${answer:-1}
                if [[ $answer == 2 ]]; then auto_level=0; elif [[ $answer != 1 ]]; then die "Invalid choice."; fi
            fi
            if (( ! set_dn )); then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Denoise" "$C_RESET" \
                    "$C_MUTED" "wavelet threshold or off" "$C_RESET" "$C_MUTED" "${denoise:-off}" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    answer=${answer:l}; if [[ $answer == off || $answer == none ]]; then answer=""; fi
                    if [[ -n $answer ]]; then
                        [[ $answer =~ ^[0-9]+$ ]] || die "Denoise threshold must be a whole number (e.g. 100)."
                        denoise=$answer
                    fi
                fi
            fi
            if (( ! set_fbdd )) && [[ $tier == libraw ]]; then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "FBDD" "$C_RESET" \
                    "$C_MUTED" "0-2 noise reduction (2 = strongest)" "$C_RESET" "$C_MUTED" "${fbdd:-0}" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    [[ $answer =~ ^[0-2]$ ]] || die "FBDD level must be 0, 1 or 2."
                    fbdd=$answer
                fi
            fi
            if (( ! set_ma )) && [[ $tier == libraw ]]; then
                printf '%s%s%s%s %s%s%s %s[%s]%s: ' "$gutter" "$C_BOLD" "Max-adjust" "$C_RESET" \
                    "$C_MUTED" "0-1 (0 = off)" "$C_RESET" "$C_MUTED" "${max_adjust:-0.75}" "$C_RESET"
                read -r answer
                if [[ -n $answer ]]; then
                    [[ $answer =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "Max-adjust must be between 0 and 1 (0 = off)."
                    max_adjust=$answer
                fi
            fi
        fi
    fi

    resize_dimensions "$max_res"
    card_line ""
    card_line "${C_MUTED}Plan: quality $quality $G_DOT size ${max_res:-original} $G_DOT decoder $wanted_decoder${demosaic:+ $G_DOT demosaic $(demosaic_name "$demosaic")}${C_RESET}"
    card_close
}

# ══ Progress & reporting ══════════════════════════════════════════════════════
# Remembers how long a finished file took. RAW and ordinary files are timed separately:
# a RAW conversion takes seconds, a screenshot only milliseconds.
eta_track() { # <src> <ms>
    local ms=$2
    if is_raw "$1"; then
        eta_raw_ring+=("$ms")
        if (( ${#eta_raw_ring[@]} > 5 )); then eta_raw_ring=("${eta_raw_ring[@]:1}"); fi
        eta_raw_left=$(( eta_raw_left - 1 ))
    else
        eta_ord_ring+=("$ms")
        if (( ${#eta_ord_ring[@]} > 5 )); then eta_ord_ring=("${eta_ord_ring[@]:1}"); fi
        eta_ord_left=$(( eta_ord_left - 1 ))
    fi
}

eta_skip() { # <src>  (a skipped or failed file takes no time)
    if is_raw "$1"; then eta_raw_left=$(( eta_raw_left - 1 )); else eta_ord_left=$(( eta_ord_left - 1 )); fi
}

# Average of a ring buffer of milliseconds → 0 when nothing was measured yet.
eta_avg() { # <array-name>
    local -a arr
    eval "arr=("\${$1[@]}")"       # copy of the array whose name was passed
    local sum=0 n=0 ms
    if (( ${#arr[@]} > 0 )); then
        for ms in "${arr[@]}"; do sum=$(( sum + ms )); n=$(( n + 1 )); done
    fi
    if (( n == 0 )); then echo 0; return 0; fi
    echo $(( sum / n ))
}

# Milliseconds still needed for the whole batch; fails when there is nothing to estimate.
# The files that are already running are credited with the time they spent so far – that
# is what makes the ETA count down every second instead of only when a file is finished.
eta_remaining_ms() {
    local raw_avg ord_avg glob_avg rem=0 idx engine start now elapsed avg budget
    local run_raw=0 run_ord=0
    raw_avg=$(eta_avg eta_raw_ring)
    ord_avg=$(eta_avg eta_ord_ring)
    if (( raw_avg > 0 && ord_avg > 0 )); then glob_avg=$(( (raw_avg + ord_avg) / 2 ))
    elif (( raw_avg > 0 )); then glob_avg=$raw_avg
    elif (( ord_avg > 0 )); then glob_avg=$ord_avg
    else return 1; fi
    (( raw_avg > 0 )) || raw_avg=$glob_avg
    (( ord_avg > 0 )) || ord_avg=$glob_avg
    now=$(now_ms)
    for idx in "${(@k)WORKERS[@]}"; do
        [[ -r $RES_DIR/$idx.run ]] || continue
        read -r engine start <"$RES_DIR/$idx.run" || continue
        elapsed=$(( now - start ))
        if (( elapsed < 0 )); then elapsed=0; fi
        if is_raw "${FILES[idx-1]}"; then avg=$raw_avg; run_raw=$(( run_raw + 1 )); else avg=$ord_avg; run_ord=$(( run_ord + 1 )); fi
        budget=$(( avg * 3 / 2 ))            # a running file may need up to 1.5x the average
        if (( elapsed > budget )); then elapsed=$budget; fi
        rem=$(( rem + budget - elapsed ))
    done
    rem=$(( rem + (eta_raw_left - run_raw) * raw_avg + (eta_ord_left - run_ord) * ord_avg ))
    if (( rem < 0 )); then rem=0; fi
    echo $(( rem / JOBS ))
}

# The remaining time as m:ss, or "--:--" while there is not enough data.
eta_text() {
    local ms
    ms=$(eta_remaining_ms) || { echo "--:--"; return 0; }
    fmt_time $(( ms / 1000 ))
}

# Two live lines: the oldest running file (spinner, engine, elapsed) and the whole batch.
draw_live() { # <spinner> <idx> <engine> <elapsed_ms> <active> <finished>
    local spin=$1 tag="[$2/$file_total]" engine=$3 elapsed=$4 active=$5 finished=$6
    local name=${FILES[$2-1]##*/} short badge_w name_max opct more="" l1 l2 eta="" eta_part=""
    short=$(engine_short "$engine"); badge_w=$(( ${#short} + 2 ))
    if (( active > 1 )); then more="+$(( active - 1 ))"; fi
    name_max=$(( UI_COLS - (2 + 1 + 1 + ${#tag} + 1 + 2 + badge_w + 2 + 6 + 5) - 1 ))
    if (( name_max < 10 )); then name_max=10; fi
    if (( name_max > 48 )); then name_max=48; fi
    opct=$(( finished * 100 / file_total ))
    if (( UI_COLS >= 56 )); then
        if (( SECONDS - batch_started_at >= 2 )); then eta=$(eta_text); else eta="--:--"; fi
        eta_part="  ${C_MUTED}ETA ${eta}${C_RESET}"
    fi
    l1=$(printf '  %s%s%s %s%s%s %s%s%s  %s  %s%6s %-4s%s' "$C_ACC" "$spin" "$C_RESET" "$C_MUTED" "$tag" "$C_RESET" \
        "$C_BOLD" "$(pad "$name" "$name_max")" "$C_RESET" "$(badge "$engine")" "$C_MUTED" "$(fmt_ms "$elapsed")" "$more" "$C_RESET")
    l2=$(printf '  %soverall%s  %s  %s%3d%%  %s elapsed%s%s' "$C_MUTED" "$C_RESET" \
        "$(make_bar "$opct" "$BAR_W")" "$C_MUTED" "$opct" "$(fmt_time $(( SECONDS - started_at )))" "$C_RESET" "$eta_part")
    printf '\r\e[2K%s\n\e[2K%s\e[1A\r' "$l1" "$l2"
}

clear_live() { printf '\r\e[2K\n\e[2K\e[1A\r'; }

report_ok() { # <tag> <name> <in_bytes> <out_bytes> <engine> <ms>
    local delta color arrow
    delta=$(( ($4 - $3) * 100 / ($3 > 0 ? $3 : 1) ))
    if (( delta <= 0 )); then color=$C_OK arrow=$G_DOWN delta=$(( -delta )); else color=$C_WARN arrow=$G_UP; fi
    printf '  %s%s%s %s%s%s %s%s%s  %9s %s%s%s %-9s  %s%s %3d%%%s  %s  %s%6s%s\n' \
        "$C_OK" "$G_OK" "$C_RESET" "$C_MUTED" "$1" "$C_RESET" "$C_BOLD" "$(pad "$2" "$NAME_COL")" "$C_RESET" \
        "$(human_bytes "$3")" "$C_MUTED" "$G_ARROW" "$C_RESET" "$(human_bytes "$4")" \
        "$color" "$arrow" "$delta" "$C_RESET" "$(badge "$5")" "$C_MUTED" "$(fmt_ms "$6")" "$C_RESET"
}

report_note() { # <fail|skip|note> <tag> <name> <detail>
    local glyph color room
    if [[ $1 == fail ]]; then glyph=$G_FAIL color=$C_ERR; elif [[ $1 == skip ]]; then glyph=$G_SKIP color=$C_MUTED; else glyph=$G_DOT color=$C_MUTED; fi
    room=$(( UI_COLS - ${#2} - NAME_COL - 8 ))
    if (( room < 10 )); then room=10; fi
    printf '  %s%s%s %s%s%s %s%s%s  %s%s%s\n' "$color" "$glyph" "$C_RESET" "$C_MUTED" "$2" "$C_RESET" \
        "$C_BOLD" "$(pad "$3" "$NAME_COL")" "$C_RESET" "$color" "$(clip "$4" "$room")" "$C_RESET"
}

# A dry run prints the command in full – it is the point of the flag.
report_dry() { # <tag> <name> <engine> <command>
    printf '  %s%s%s %s%s%s %s%s%s  %s%s%s\n' "$C_MUTED" "$G_DOT" "$C_RESET" "$C_MUTED" "$1" "$C_RESET" \
        "$C_BOLD" "$(pad "$2" "$NAME_COL")" "$C_RESET" "$C_MUTED" "$3" "$C_RESET"
    printf '      %s%s%s\n' "$C_MUTED" "$4" "$C_RESET"
}

first_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | head -n 1 | cut -c1-100 || true; }

# ══ Parallel batch ════════════════════════════════════════════════════════════
# A worker converts one file in the background and finishes by renaming $RES_DIR/<idx>.log to .done.
# Log lines: "warn|text" for decoder fallbacks, then one final "ok|in|out|engine|ms", "skip|why" or "fail|why".
finish_worker() { # <idx> <final-line>
    printf '%s\n' "$2" >>"$RES_DIR/$1.log"
    mv "$RES_DIR/$1.log" "$RES_DIR/$1.done"
}

convert_worker() { # <idx> <src> [duplicate-of]
    local idx=$1 src=$2 dup=${3:-} base=${2##*/} name out tmp err engine last started reason="" kind cmd
    local -a engines
    name=${base%.*}; out="$output_dir/$name.jpg"
    tmp="$output_dir/.$name.$$.$idx.partial.jpg"; err="$RES_DIR/$idx.err"
    : >"$RES_DIR/$idx.log"

    if [[ -n $dup ]]; then finish_worker "$idx" "skip|same output name as $dup"; return 0; fi
    if [[ ${src:A} == "${output_dir:A}"/* ]]; then finish_worker "$idx" "skip|already in the output folder"; return 0; fi
    if [[ -f $out ]]; then
        if [[ ${OVERWRITE[$idx]:-skip} != replace ]]; then          # replaced atomically by the final mv, so a
            finish_worker "$idx" "skip|output already exists"; return 0 # failed conversion never destroys the old file
        fi
    fi

    if is_raw "$src"; then kind=raw; engines=("${DECODERS[@]}"); else kind=std; engines=(im); fi
    if (( ${#engines[@]} == 0 )); then
        finish_worker "$idx" "fail|no RAW decoder available (install dcraw or LibRaw)"
        return 0
    fi
    last=${engines[-1]}
    started=$(now_ms)
    for engine in "${engines[@]}"; do
        printf '%s %s\n' "$engine" "$(now_ms)" >"$RES_DIR/$idx.run"
        if (( dry_run )); then
            set_engine "$engine"
            if [[ $engine == im ]]; then
                cmd="${IM[*]} ${src}[0] -auto-orient ${RESIZE_ARGS[*]} ${FINISH_ARGS[*]} jpg:$tmp"
            else
                cmd="${DEC_CMD[*]}  ->  ${IM[*]} - ${RESIZE_ARGS[*]} ${TONE_ARGS[*]} ${FINISH_ARGS[*]} jpg:$tmp"
            fi
            finish_worker "$idx" "dry|$engine|$cmd"
            return 0
        fi
        if run_engine "$engine" "$src" "$tmp" "$err"; then
            copy_metadata "$kind" "$src" "$tmp" "$engine"
            mv -f "$tmp" "$out"
            if (( preserve_times )); then touch -r "$src" "$out"; fi
            finish_worker "$idx" "ok|$(file_bytes "$src")|$(file_bytes "$out")|$engine|$(( $(now_ms) - started ))"
            return 0
        fi
        rm -f "$tmp"
        reason=$(first_line "$err")
        if [[ $engine != "$last" ]]; then
            printf 'warn|%s failed on %s%s – trying next decoder\n' "$(engine_label "$engine")" "$base" "${reason:+: $reason}" >>"$RES_DIR/$idx.log"
        fi
    done
    finish_worker "$idx" "fail|$reason"
}

# Prints the result of file <idx> and updates the batch counters.
report_result() { # <idx>
    local idx=$1 base kind a b c d tag="[$1/$file_total]" src
    base=${FILES[idx-1]##*/}
    src=${FILES[idx-1]}
    while IFS='|' read -r kind a b c d; do
        case $kind in
            warn) warn "$a" ;;
            ok)   total_in=$(( total_in + a )); total_out=$(( total_out + b ))
                  engine_used[$c]=$(( ${engine_used[$c]:-0} + 1 )); ok=$(( ok + 1 ))
                  eta_track "$src" "$d"
                  report_ok "$tag" "$base" "$a" "$b" "$c" "$d" ;;
            skip) report_note skip "$tag" "$base" "$a"; skipped=$(( skipped + 1 )); eta_skip "$src" ;;
            fail) report_note fail "$tag" "$base" "failed${a:+: $a}"; fail=$(( fail + 1 )); eta_skip "$src" ;;
            dry)  report_dry "$tag" "$base" "$a" "$b"; dry_shown=$(( dry_shown + 1 )); eta_skip "$src" ;;
        esac
    done <"$RES_DIR/$idx.done"
}

# Moves finished workers out of WORKERS; a worker that died without a result is reported as failed.
reap_workers() {
    local idx pid
    for idx in "${(@k)WORKERS[@]}"; do
        pid=${WORKERS[$idx]}
        if [[ -f $RES_DIR/$idx.done ]] || ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            if [[ ! -f $RES_DIR/$idx.done ]]; then finish_worker "$idx" "fail|worker stopped unexpectedly"; fi
            unset "WORKERS[$idx]"
            finished=$(( finished + 1 ))
        fi
    done
}

# Draws the live lines for the oldest running file.
draw_batch() { # <frame>
    local idx oldest=0 engine start
    for idx in "${(@k)WORKERS[@]}"; do
        if (( oldest == 0 || idx < oldest )); then oldest=$idx; fi
    done
    (( oldest > 0 )) || return 0
    [[ -r $RES_DIR/$oldest.run ]] || return 0      # the worker has not picked an engine yet
    read -r engine start <"$RES_DIR/$oldest.run" || return 0
    draw_live "${G_SPIN[$1 % ${#G_SPIN[@]}]}" "$oldest" "$engine" $(( $(now_ms) - start )) "${#WORKERS[@]}" "$finished"
}

run_batch() {
    local next=1 printed=0 frame=0 t0
    t0=$(now_ms)
    batch_started_at=$SECONDS
    hide_cursor
    while (( printed < file_total )); do
        while (( ${#WORKERS[@]} < JOBS && next <= file_total )); do
            convert_worker "$next" "${FILES[next-1]}" "${DUP_OF[$next]:-}" &
            WORKERS[$next]=${!}
            next=$(( next + 1 ))
        done
        reap_workers
        frame=$(( frame + 1 ))
        while (( printed < file_total )) && [[ -f $RES_DIR/$(( printed + 1 )).done ]]; do
            if (( UI_TTY )); then clear_live; fi
            printed=$(( printed + 1 ))
            report_result "$printed"
            # Draw the live lines again right away – without this, several results that
            # finish at the same time appear at once and the progress looks frozen.
            if (( UI_TTY )); then draw_batch "$frame"; fi
        done
        if (( printed < file_total )); then
            if (( UI_TTY )); then draw_batch "$frame"; fi
            sleep 0.1
        fi
    done
    batch_ms=$(( $(now_ms) - t0 ))
    show_cursor
}

print_summary() {
    local engine used="" line saved pct kept mbs10 ipm
    card_open "Summary"
    if (( dry_shown > 0 )); then
        line="$C_MUTED$G_DOT $dry_shown command(s) shown – dry run, nothing was written$C_RESET"
    else
        line="$C_OK$G_OK $ok converted$C_RESET"
        if (( fail > 0 ));    then line+="   $C_ERR$G_FAIL $fail failed$C_RESET"; fi
        if (( skipped > 0 )); then line+="   $C_MUTED$G_SKIP $skipped skipped$C_RESET"; fi
    fi
    card_row "Result" "$line"
    if (( total_in > 0 )); then
        saved=$(( total_in - total_out )); pct=$(( (saved < 0 ? -saved : saved) * 100 / total_in ))
        if (( saved >= 0 )); then line="$C_OK$G_DOWN $pct% smaller$C_RESET"; else line="$C_WARN$G_UP $pct% larger$C_RESET"; fi
        card_row "Size" "$(human_bytes "$total_in") $G_ARROW $(human_bytes "$total_out")  $line"
        kept=$(( total_out * 100 / total_in ))
        if (( kept > 100 )); then
            # The bar cannot grow past 100% – the real number is shown instead.
            card_row "" "$(make_bar 100 24)  $C_WARN$kept% of original$C_RESET"
            card_row "Grew" "$C_WARN$(human_bytes $(( -saved )))$C_RESET"
        else
            card_row "" "$(make_bar "$kept" 24)  $C_MUTED$kept% of original$C_RESET"
            if (( saved > 0 )); then card_row "Saved" "$C_OK$(human_bytes "$saved")$C_RESET"; fi
        fi
    fi
    if (( ok > 0 )); then card_row "Average" "$(fmt_ms $(( batch_ms / ok ))) per image ($JOBS parallel)"; fi
    if (( ok > 0 && batch_ms > 0 )); then
        mbs10=$(( total_in * 1000 * 10 / batch_ms / 1048576 ))
        ipm=$(( ok * 60000 / batch_ms ))
        card_row "Throughput" "$(( mbs10 / 10 )).$(( mbs10 % 10 )) MB/s $G_DOT $ipm image(s)/min"
    fi
    for engine in im libraw dcraw preview; do
        if (( ${engine_used[$engine]:-0} > 0 )); then used+="$(badge "$engine") ${engine_used[$engine]}  "; fi
    done
    if [[ -n $used ]]; then card_row "Engines" "$used"; fi
    if (( ${engine_used[preview]:-0} > 0 )); then
        card_row "Note" "${C_WARN}${engine_used[preview]} RAW file(s) used the embedded preview (lower resolution)${C_RESET}"
        card_row "" "${C_MUTED}Run 'pneat -y' to install LibRaw for full decoding${C_RESET}"
    fi
    card_row "Time" "$(fmt_time $(( SECONDS - started_at )))"
    card_row "Output" "$output_dir"
    card_close
    if (( dry_shown > 0 )); then
        printf '\n  %s%s%s Dry run – nothing was written.%s\n\n' "$C_MUTED" "$C_BOLD" "$G_DOT" "$C_RESET"
    elif (( fail == 0 )); then
        printf '\n  %s%s%s All done.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET"
    else
        printf '\n  %s%s%s Finished with %d failure(s).%s\n\n' "$C_ERR" "$C_BOLD" "$G_FAIL" "$fail" "$C_RESET"
    fi
}

# ══ Main ══════════════════════════════════════════════════════════════════════
compute_layout() {
    local f longest=0 base bytes
    for f in "${FILES[@]}"; do
        base=${f##*/}; if (( ${#base} > longest )); then longest=${#base}; fi
        bytes=$(file_bytes "$f"); total_src=$(( total_src + bytes ))
        if (( bytes > largest_bytes )); then largest_bytes=$bytes; fi
    done
    eta_raw_left=$raw_total
    eta_ord_left=$(( file_total - raw_total ))
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
    if (( list_only )); then
        discover_decoders
        info "Available decoders: ${DECODERS[*]:-none}"
        exit 0
    fi
    run_banner; print_system

    if (( ${#direct_files[@]} > 0 )); then
        mode=files
        output_dir=${output_dir:-./$COMPRESSED_SUBDIR}
    else
        input_dir=${input_dir:-.}
        [[ -d $input_dir ]] || die "Folder '$input_dir' not found."
        output_dir=${output_dir:-$input_dir/$COMPRESSED_SUBDIR}
    fi
    if (( ! install_deps )); then collect_files; fi

    PM=$(detect_pkg_manager)
    PM_LOG=$(mktemp "${TMPDIR:-/tmp}/pneat-pm.XXXXXX")
    if (( install_deps )); then
        install_missing imagemagick exiftool dcraw libraw || exit 1
        printf '\n  %s%s%s Dependency setup finished.%s %sRe-run without -y to convert images.%s\n\n' "$C_OK" "$C_BOLD" "$G_OK" "$C_RESET" "$C_MUTED" "$C_RESET"
        exit 0
    fi
    ensure_tools
    select_imagemagick
    discover_decoders
    if (( interactive )); then choose_interactively; fi
    apply_decoder_choice
    resolve_raw_profile
    build_image_args
    mkdir -p "$output_dir"
    RES_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pneat.XXXXXX")
    mark_duplicates
    EXTRA_ARGS=(${=libraw_args})
    compute_layout
    resolve_jobs
    handle_existing_outputs
    print_plan
    run_batch
    print_summary
    (( fail == 0 ))
}

main "$@"

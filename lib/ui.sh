# shellcheck shell=bash
# Terminal UI primitives: raw mode + alternate screen, key decoding,
# frame building with differential rendering, and small widgets
# (status line, confirm prompt, line editor, bars).
#
# Screen layout: row 0 header, rows 1..ROWS-3 body, ROWS-2 status, ROWS-1 footer.

SC_ROWS=24 SC_COLS=80
SC_MIN_ROWS=24 SC_MIN_COLS=80
SC_RESIZED=1 SC_FULL_REDRAW=1 SC_UI_ACTIVE=0
SC_STTY_SAVED=
SC_MSG= SC_MSG_LEVEL=info
SC_KEY= SC_KEY_PENDING=
declare -ga SC_FRAME=() SC_SCREEN=()

# Color themes. Every color of the UI comes from these tokens, set here:
#   C_HDR title bar      C_FOOT footer          C_SEL selected row (background
#   C_EDIT edited field  C_DIM secondary text      only; the row keeps its colors)
#   C_ACCENT headings, info messages   C_OK online, low usage
#   C_WARN warnings, medium usage      C_CRIT errors, high usage
#   C_RX / C_TX network bars
# Themes assume the terminal's own background and text color and never set
# them: default and nord/solarized/high-contrast expect a dark terminal,
# light a light one. NO_COLOR or fewer than 8 colors: no colors in any theme,
# only bold, reverse video and underline.
SC_THEMES=(default light solarized nord high-contrast)

sc_ui_colors() {
    local n theme=${SC_SET[theme]:-default}
    n=$(tput colors 2>/dev/null) || n=0
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_NORM=$'\e[22;39m'
    C_HDR=$'\e[7m' C_FOOT=$'\e[7m' C_SEL=$'\e[7m' C_EDIT=$'\e[4m'
    C_ACCENT= C_OK= C_WARN= C_CRIT= C_RX= C_TX=
    [[ -z ${NO_COLOR:-} ]] && ((n >= 8)) || return 0

    # 8/16 colors: the terminal palette, shared by all themes except
    # high-contrast, which uses the bright colors.
    C_ACCENT=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_CRIT=$'\e[31m'
    C_HDR=$'\e[1;97;44m' C_FOOT=$'\e[30;47m'
    if [[ $theme == high-contrast ]]; then
        C_ACCENT=$'\e[96m' C_OK=$'\e[92m' C_WARN=$'\e[93m' C_CRIT=$'\e[91m'
        C_HDR=$'\e[1;30;107m' C_FOOT=$'\e[97;44m' C_SEL=$'\e[44m' C_DIM=
    fi
    C_RX=$C_OK C_TX=$C_CRIT
    ((n >= 256)) || return 0

    # 256 colors (xterm palette numbers). Contrast was checked against the
    # assumed terminal background: at least 4.5:1 for text, 3:1 for bars.
    case $theme in
        light) # white background
            C_ACCENT=$'\e[38;5;25m' C_OK=$'\e[38;5;28m' C_WARN=$'\e[38;5;130m' C_CRIT=$'\e[38;5;124m'
            C_DIM=$'\e[38;5;242m' C_SEL=$'\e[48;5;153m' C_EDIT=$'\e[4;48;5;254m'
            C_HDR=$'\e[1;38;5;231;48;5;25m' C_FOOT=$'\e[38;5;235;48;5;252m' ;;
        solarized) # Solarized Dark, background base03 #002b36
            C_ACCENT=$'\e[38;5;37m' C_OK=$'\e[38;5;106m' C_WARN=$'\e[38;5;178m' C_CRIT=$'\e[38;5;203m'
            C_DIM=$'\e[38;5;246m' C_SEL=$'\e[48;5;235m' C_EDIT=$'\e[4;48;5;235m'
            C_HDR=$'\e[1;38;5;234;48;5;37m' C_FOOT=$'\e[38;5;247;48;5;235m' ;;
        nord) # Nord, background nord0 #2e3440
            C_ACCENT=$'\e[38;5;110m' C_OK=$'\e[38;5;108m' C_WARN=$'\e[38;5;222m' C_CRIT=$'\e[38;5;174m'
            C_DIM=$'\e[38;5;247m' C_SEL=$'\e[48;5;24m' C_EDIT=$'\e[4;48;5;238m'
            C_HDR=$'\e[1;38;5;236;48;5;110m' C_FOOT=$'\e[38;5;188;48;5;238m' ;;
        high-contrast) # black background
            C_SEL=$'\e[48;5;21m' C_FOOT=$'\e[97;48;5;236m' C_EDIT=$'\e[1;4;48;5;236m' ;;
        *) # default: the original colors; tx is a muted red (#af5f5f)
            C_SEL=$'\e[48;5;24m' C_FOOT=$'\e[38;5;252;48;5;237m' C_EDIT=$'\e[4;48;5;236m'
            C_TX=$'\e[38;5;131m'
            return 0 ;;
    esac
    C_RX=$C_OK C_TX=$C_CRIT
}

# --- terminal state -----------------------------------------------------------

sc_ui_init() {
    SC_STTY_SAVED=$(stty -g </dev/tty) || return 1
    trap 'SC_RESIZED=1' WINCH
    trap 'sc_ui_suspend' TSTP
    sc_ui_enter
}

# ISIG stays on so Ctrl-C reaches the INT trap; -ixon frees Ctrl-S.
sc_ui_enter() {
    stty -echo -icanon -ixon </dev/tty
    printf '\e[?1049h\e[?25l\e[?7l\e[2J'
    SC_UI_ACTIVE=1 SC_FULL_REDRAW=1 SC_RESIZED=1
}

sc_ui_leave() {
    ((SC_UI_ACTIVE)) || return 0
    printf '\e[0m\e[?7h\e[?25h\e[?1049l'
    [[ -n $SC_STTY_SAVED ]] && stty "$SC_STTY_SAVED" </dev/tty 2>/dev/null
    SC_UI_ACTIVE=0
}

# Ctrl-Z: restore the terminal, stop for real, and re-enter on `fg`.
sc_ui_suspend() {
    sc_ui_leave
    trap - TSTP
    kill -TSTP $$
    trap 'sc_ui_suspend' TSTP
    sc_ui_enter
}

sc_ui_update_size() {
    local size
    size=$(stty size </dev/tty 2>/dev/null)
    if [[ $size =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)$ ]]; then
        SC_ROWS=${BASH_REMATCH[1]} SC_COLS=${BASH_REMATCH[2]}
        return
    fi
    # Some ptys report 0x0 when no window size was ever set.
    SC_ROWS=$(tput lines 2>/dev/null) SC_COLS=$(tput cols 2>/dev/null)
    [[ $SC_ROWS =~ ^[1-9][0-9]*$ ]] || SC_ROWS=24
    [[ $SC_COLS =~ ^[1-9][0-9]*$ ]] || SC_COLS=80
}

# Returns 0 (and schedules a full redraw) if the terminal was resized.
sc_ui_check_resize() {
    ((SC_RESIZED)) || return 1
    SC_RESIZED=0
    sc_ui_update_size
    SC_FULL_REDRAW=1
    return 0
}

# --- input --------------------------------------------------------------------

# Reads one key with timeout $1 (fractional seconds) into SC_KEY. Special
# keys become names: UP DOWN LEFT RIGHT HOME END PGUP PGDN DEL ENTER ESC
# BACKSPACE TAB. Returns 1 on timeout.
sc_read_key() {
    local k c seq rc
    SC_KEY=
    if [[ -n $SC_KEY_PENDING ]]; then
        k=$SC_KEY_PENDING
        SC_KEY_PENDING=
    else
        IFS= read -rsn1 -d '' -t "$1" k </dev/tty
        rc=$?
        ((rc > 128)) && return 1
        ((rc != 0)) && exit 1 # tty is gone
    fi
    case $k in
        $'\e')
            SC_KEY=ESC
            IFS= read -rsn1 -d '' -t 0.05 c </dev/tty || return 0
            # Esc followed by an ordinary key: deliver that key next time.
            if [[ $c != '[' && $c != O ]]; then
                SC_KEY_PENDING=$c
                return 0
            fi
            seq=
            while IFS= read -rsn1 -d '' -t 0.05 c </dev/tty; do
                seq+=$c
                [[ $c == [@-~] ]] && break
            done
            case $seq in
                A | 1\;*A) SC_KEY=UP ;;
                B | 1\;*B) SC_KEY=DOWN ;;
                C | 1\;*C) SC_KEY=RIGHT ;;
                D | 1\;*D) SC_KEY=LEFT ;;
                H | 1~ | 7~) SC_KEY=HOME ;;
                F | 4~ | 8~) SC_KEY=END ;;
                5~) SC_KEY=PGUP ;;
                6~) SC_KEY=PGDN ;;
                3~) SC_KEY=DEL ;;
                *) SC_KEY=UNKNOWN ;;
            esac
            ;;
        $'\n' | $'\r') SC_KEY=ENTER ;;
        $'\x7f' | $'\b') SC_KEY=BACKSPACE ;;
        $'\t') SC_KEY=TAB ;;
        *) SC_KEY=$k ;;
    esac
    return 0
}

# Applies a navigation key to selection $1 within $2 items. Sets REPLY and
# returns 0 if SC_KEY was a navigation key.
sc_ui_nav() {
    local sel=$1 n=$2 page=$((SC_ROWS - 5))
    ((page < 1)) && page=1
    case $SC_KEY in
        UP | k) ((sel--)) ;;
        DOWN | j) ((sel++)) ;;
        PGUP) ((sel -= page)) ;;
        PGDN) ((sel += page)) ;;
        HOME | g) sel=0 ;;
        END | G) sel=$((n - 1)) ;;
        *) return 1 ;;
    esac
    ((sel >= n)) && sel=$((n - 1))
    ((sel < 0)) && sel=0
    REPLY=$sel
    return 0
}

# Keeps selection $1 visible in a window of $3 rows over $4 items; REPLY=top.
sc_ui_scroll() {
    local sel=$1 top=$2 h=$3 n=$4
    ((h < 1)) && h=1
    ((sel < top)) && top=$sel
    ((sel >= top + h)) && top=$((sel - h + 1))
    ((top > n - h)) && top=$((n - h))
    ((top < 0)) && top=0
    REPLY=$top
}

# --- frames -------------------------------------------------------------------

sc_msg() {
    SC_MSG_LEVEL=$1 SC_MSG=$2
}

sc_frame_add() {
    SC_FRAME+=("$1")
}

# Adds text $2 fitted to the screen width, wrapped in style $1.
sc_frame_text() {
    sc_fit "$2" "$SC_COLS"
    SC_FRAME+=("$1$REPLY$C_RESET")
}

# Starts a frame with the header; returns 1 (after drawing a notice) when
# the terminal is too small for the views.
# Below the minimum size no view is drawn, only this notice in the middle
# of the screen; keys keep working (q leaves the view, Ctrl-C quits).
sc_ui_too_small() {
    local msg="Terminal too small: at least ${SC_MIN_COLS}${SC_G_TIMES}${SC_MIN_ROWS} needed (now ${SC_COLS}${SC_G_TIMES}${SC_ROWS})"
    local hint="Enlarge the window, or press q to quit." i pad
    SC_FRAME=()
    for ((i = 0; i < SC_ROWS; i++)); do SC_FRAME+=(""); done
    for i in 0 1; do
        [[ $i == 1 ]] && msg=$hint
        if ((${#msg} < SC_COLS)); then
            sc_repeat ' ' $(((SC_COLS - ${#msg}) / 2)); pad=$REPLY
        else
            pad=
        fi
        sc_fit "$pad$msg" "$SC_COLS"
        SC_FRAME[(SC_ROWS - 1) / 2 + i]=$C_BOLD$REPLY$C_RESET
    done
    sc_ui_render
}

sc_ui_begin_frame() {
    local left=" scat $SC_G_SEP $1" right=" $2  " i
    SC_FRAME=() SC_FRAME_STATUS=
    if ((SC_ROWS < SC_MIN_ROWS || SC_COLS < SC_MIN_COLS)); then
        sc_ui_too_small
        return 1
    fi
    ((${#right} > SC_COLS / 2)) && right=
    sc_fit "$left" $((SC_COLS - ${#right}))
    SC_FRAME+=("$C_HDR$REPLY$right$C_RESET")
}

# Finishes the frame with status line and footer, then renders it.
# Args: key/label pairs for the footer, e.g. "q" "quit". SC_FRAME_STATUS
# (set by the view, e.g. a scroll position) is shown dimmed at the right
# end of the status line.
sc_ui_end_frame() {
    local body=$((SC_ROWS - 2)) line= plain=0 seg color right=${SC_FRAME_STATUS-}
    while ((${#SC_FRAME[@]} < body)); do SC_FRAME+=(""); done
    SC_FRAME=("${SC_FRAME[@]:0:body}")
    [[ -n $right ]] && right="$right "
    ((${#right} > SC_COLS / 2)) && right=
    if [[ -n $SC_MSG ]]; then
        case $SC_MSG_LEVEL in
            error) color=$C_CRIT$C_BOLD ;;
            warn) color=$C_WARN ;;
            *) color=$C_ACCENT ;;
        esac
        sc_fit " $SC_MSG" $((SC_COLS - ${#right}))
        line=$color$REPLY$C_RESET
    else
        sc_repeat ' ' $((SC_COLS - ${#right}))
        line=$REPLY
    fi
    SC_FRAME+=("$line$C_DIM$right$C_RESET")
    line=
    while (($# >= 2)); do
        seg=" $1 $2 "
        ((plain + ${#seg} > SC_COLS)) && break
        line+="$C_BOLD $1$C_NORM $2 "
        ((plain += ${#seg}))
        shift 2
    done
    sc_repeat ' ' $((SC_COLS - plain))
    SC_FRAME+=("$C_FOOT$line$REPLY$C_RESET")
    sc_ui_render
}

# Writes only the rows that differ from what is on screen.
sc_ui_render() {
    local out= i line
    if ((SC_FULL_REDRAW)); then
        out=$'\e[0m\e[2J'
        SC_SCREEN=()
        SC_FULL_REDRAW=0
    fi
    for ((i = 0; i < SC_ROWS; i++)); do
        line=${SC_FRAME[i]-}
        [[ -v SC_SCREEN[i] && ${SC_SCREEN[i]} == "$line" ]] && continue
        # Clear first: with autowrap off the cursor stays on the last column
        # after a full-width row, and a trailing erase would remove that cell.
        out+=$'\e['"$((i + 1))"$';1H\e[0m\e[K'"$line"$'\e[0m'
        SC_SCREEN[i]=$line
    done
    [[ -n $out ]] && printf '%s' "$out"
    return 0
}

# --- widgets ------------------------------------------------------------------

sc_level_color() {
    if (($1 >= 85)); then
        SC_LEVEL=$C_CRIT
    elif (($1 >= 60)); then
        SC_LEVEL=$C_WARN
    else
        SC_LEVEL=$C_OK
    fi
}

# Horizontal bar for percentage $1 with width $2; REPLY holds styled text.
sc_ui_bar() {
    local pct=$1 w=$2 fill full
    [[ $pct =~ ^[0-9]+$ ]] || pct=0
    ((pct > 100)) && pct=100
    fill=$(((pct * w + 50) / 100))
    sc_repeat "$SC_G_FULL" "$fill"
    full=$REPLY
    sc_repeat "$SC_G_EMPTY" $((w - fill))
    sc_level_color "$pct"
    REPLY="$SC_LEVEL$full$C_NORM$C_DIM$REPLY$C_NORM"
}

# Bar for a rate of $1 bytes/s on a fixed scale (SC_RATE_FULL = 100 MB/s =
# full bar) with width $2 cells, in eighth-cell steps (whole cells in ASCII
# mode). Faster rates fill the bar; any traffic above zero shows at least the
# smallest step. With $3 = hatch and a hatch glyph (high-contrast theme) the
# bar uses whole hatched cells. Sets REPLY to the filled part, SC_BAR_REST to the empty
# part (both unstyled) and SC_BAR_UNITS to the filled steps.
SC_RATE_FULL=100000000
sc_rate_bar() {
    local v=$1 w=$2 steps=8 max units fill full=$SC_G_FULL
    [[ $v =~ ^[0-9]+$ ]] || v=0
    ((${#SC_G_EIGHTHS[@]} == 8)) || steps=1
    # $3 = hatch: whole cells of SC_G_HATCH (tx in the high-contrast theme).
    [[ ${3-} == hatch && -n ${SC_G_HATCH-} ]] && steps=1 full=$SC_G_HATCH
    max=$((w * steps))
    if ((10#$v >= SC_RATE_FULL)); then
        units=$max
    else
        units=$(((10#$v * max + SC_RATE_FULL / 2) / SC_RATE_FULL))
        ((10#$v > 0 && units == 0)) && units=1
    fi
    SC_BAR_UNITS=$units
    sc_repeat "$full" $((units / steps))
    fill=$REPLY
    ((units % steps)) && fill+=${SC_G_EIGHTHS[units % steps]}
    sc_repeat "$SC_G_EMPTY" $((w - (units + steps - 1) / steps))
    SC_BAR_REST=$REPLY
    REPLY=$fill
}

# Shows a yes/no question in the status line; returns 0 on y/Y.
sc_ui_confirm() {
    local row=$((SC_ROWS - 2))
    sc_fit " $1 [y/N]" "$SC_COLS"
    SC_FRAME[row]=$C_WARN$C_BOLD$REPLY$C_RESET
    sc_ui_render
    until sc_read_key 1; do :; done
    [[ $SC_KEY == [yY] ]]
}

# Shows message $1 in the status line immediately (before a blocking call).
sc_ui_flash() {
    sc_fit " $1" "$SC_COLS"
    SC_FRAME[SC_ROWS - 2]=$C_ACCENT$REPLY$C_RESET
    sc_ui_render
}

# Single-line editor at screen row $1 (0-based), column $2, width $3,
# initial text $4. Sets REPLY; returns 1 if cancelled with Esc.
sc_ui_edit_line() {
    local row=$1 col=$2 width=$3 text=$4 pos off=0 rc=0
    pos=${#text}
    ((width < 5)) && width=5
    printf '\e[?25h'
    while :; do
        ((pos < off)) && off=$pos
        ((pos - off >= width)) && off=$((pos - width + 1))
        sc_fit "${text:off:width}" "$width"
        printf '\e[%d;%dH%s%s%s\e[%d;%dH' $((row + 1)) $((col + 1)) "$C_EDIT" "$REPLY" "$C_RESET" \
            $((row + 1)) $((col + 1 + pos - off))
        sc_read_key 1 || continue
        case $SC_KEY in
            ENTER) break ;;
            ESC) rc=1; break ;;
            LEFT) ((pos > 0)) && ((pos--)) ;;
            RIGHT) ((pos < ${#text})) && ((pos++)) ;;
            HOME | $'\x01') pos=0 ;;
            END | $'\x05') pos=${#text} ;;
            BACKSPACE)
                if ((pos > 0)); then
                    text=${text:0:pos-1}${text:pos}
                    ((pos--))
                fi
                ;;
            DEL | $'\x04') text=${text:0:pos}${text:pos+1} ;;
            $'\x15') text=${text:pos}; pos=0 ;; # Ctrl-U
            $'\x0b') text=${text:0:pos} ;;      # Ctrl-K
            ?) [[ $SC_KEY == [[:print:]] ]] && { text=${text:0:pos}$SC_KEY${text:pos}; ((pos++)); } ;;
        esac
    done
    printf '\e[?25l'
    unset "SC_SCREEN[row]"
    REPLY=$text
    return "$rc"
}

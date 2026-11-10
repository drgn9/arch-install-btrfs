# ui.bash - terminal styling shared by install.bash and rescue-root. Sourced,
# never executed.
#
# Colors are indices into the terminal's own 16-color palette, so the Linux
# console and a themed terminal emulator each draw them from their own
# palette. Blue marks structure and questions, green marks success and
# matches, yellow asks for attention, and red is reserved for destructive
# steps and errors. Borders use plain line-drawing characters, which every
# console font has.
# shellcheck shell=bash

UI_BLUE=12
UI_GREEN=10
UI_YELLOW=11
UI_RED=9
UI_WIDTH=74

# gum prompts read their colors from the environment.
export GUM_CHOOSE_HEADER_FOREGROUND=$UI_BLUE
export GUM_CHOOSE_CURSOR_FOREGROUND=$UI_GREEN
export GUM_CHOOSE_SELECTED_FOREGROUND=$UI_GREEN
export GUM_INPUT_HEADER_FOREGROUND=$UI_BLUE
export GUM_INPUT_PROMPT_FOREGROUND=$UI_BLUE
export GUM_INPUT_CURSOR_FOREGROUND=$UI_GREEN
export GUM_FILTER_HEADER_FOREGROUND=$UI_BLUE
export GUM_FILTER_PROMPT_FOREGROUND=$UI_BLUE
export GUM_FILTER_INDICATOR_FOREGROUND=$UI_GREEN
export GUM_FILTER_MATCH_FOREGROUND=$UI_GREEN
export GUM_CONFIRM_PROMPT_FOREGROUND=$UI_BLUE
export GUM_CONFIRM_SELECTED_BACKGROUND=$UI_BLUE
export GUM_CONFIRM_SELECTED_FOREGROUND=15

# A rule as wide as a box, including its border.
printf -v UI_RULE '%*s' "$((UI_WIDTH + 2))" ''
UI_RULE=${UI_RULE// /─}

# Prints text in bold in the given color. Palette indices 8-15 are the bright
# colors, selected by the standard codes 90-97.
ui_paint() {
    printf '\e[1;%sm%s\e[0m' "$(($1 + 82))" "$2"
}

show_header() {
    local title=$1 subtitle=${2:-}

    clear
    gum style --border normal --border-foreground "$UI_BLUE" \
        --align center --width "$UI_WIDTH" --margin "1 2" --padding "1 2" \
        "$(ui_paint "$UI_BLUE" "$title")" ${subtitle:+"$(printf '\e[2m%s\e[0m' "$subtitle")"}
}

show_section() {
    printf '\n  %s\n  \e[2m%s\e[0m\n' "$(ui_paint "$UI_BLUE" "$1")" "$UI_RULE"
}

# A bordered box. The border and the title take the color; the body stays in
# the terminal's normal text color so it reads as text, not as an alarm.
ui_box() {
    local color=$1 title=$2
    local -a lines=()
    shift 2

    if [[ -n "$title" ]]; then
        lines+=("$(ui_paint "$color" "$title")")
        if (( $# > 0 )); then
            lines+=("")
        fi
    fi
    gum style --border normal --border-foreground "$color" \
        --width "$UI_WIDTH" --margin "1 2 0 2" --padding "0 2" \
        "${lines[@]}" "$@"
}

# Information the user should read: next steps, what was kept.
show_note() {
    ui_box "$UI_BLUE" "$@"
}

# The user has to do something or confirm something.
show_action() {
    ui_box "$UI_YELLOW" "$@"
}

# Data is about to be destroyed.
show_danger() {
    ui_box "$UI_RED" "$@"
}

# A finished milestone with follow-up instructions.
show_done() {
    ui_box "$UI_GREEN" "$@"
}

show_success() {
    printf '\n  %s\n\n' "$(ui_paint "$UI_GREEN" "$1")"
}

# Progress and diagnostics go to stderr, like a logger, so they never end up
# in a captured command substitution.
show_info() {
    printf '  %s %s\n' "$(ui_paint "$UI_BLUE" '::')" "$1" >&2
}

show_warn() {
    printf '  %s %s\n' "$(ui_paint "$UI_YELLOW" 'warning:')" "$1" >&2
}

show_error() {
    printf '  %s %s\n' "$(ui_paint "$UI_RED" 'error:')" "$1" >&2
}

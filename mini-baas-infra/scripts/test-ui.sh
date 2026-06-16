# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    test-ui.sh                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

# Shared terminal UI helpers for smoke tests.

# Allow forcing colors via FORCE_COLORS env var, or detect TTY
if [[ "${FORCE_COLORS:-0}" == "1" ]] || [[ -t 1 ]]; then
    UI_RED='\033[0;31m'
    UI_GREEN='\033[0;32m'
    UI_YELLOW='\033[1;33m'
    UI_BLUE='\033[0;34m'
    UI_MAGENTA='\033[0;35m'
    UI_CYAN='\033[0;36m'
    UI_BOLD='\033[1m'
    UI_DIM='\033[2m'
    UI_NC='\033[0m'
else
    UI_RED=''
    UI_GREEN=''
    UI_YELLOW=''
    UI_BLUE=''
    UI_MAGENTA=''
    UI_CYAN=''
    UI_BOLD=''
    UI_DIM=''
    UI_NC=''
fi

readonly UI_BOX_LINE='════════════════════════════════════════════════════════════'
readonly FMT_LINE='%b\n'

ui_hr() {
    printf "$FMT_LINE" "${UI_DIM}------------------------------------------------------------${UI_NC}"
    return 0
}

ui_banner() {
    local title="$1"
    local subtitle="${2:-}"

    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}╔${UI_BOX_LINE}╗${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║${UI_NC} ${UI_BOLD}${title}${UI_NC}"
    if [[ -n "$subtitle" ]]; then
        printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║${UI_NC} ${UI_DIM}${subtitle}${UI_NC}"
    fi
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}╚${UI_BOX_LINE}╝${UI_NC}"
    return 0
}

ui_kv() {
    local key="$1"
    local value="$2"
    printf "$FMT_LINE" "${UI_BLUE}${key}:${UI_NC} ${value}"
    return 0
}

ui_step() {
    local label="$1"
    printf "\n%b\n" "${UI_MAGENTA}${UI_BOLD}▶ ${label}${UI_NC}"
    return 0
}

ui_summary() {
    local passed="$1"
    local failed="$2"
    local success_msg="$3"
    local fail_msg="$4"
    local total=$((passed + failed))

    printf "\n%b\n" "${UI_CYAN}${UI_BOLD}╔${UI_BOX_LINE}╗${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║ Test Summary${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}╠${UI_BOX_LINE}╣${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║${UI_NC} ${UI_GREEN}${UI_BOLD}✔ Passed:${UI_NC} ${UI_GREEN}${UI_BOLD}${passed}${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║${UI_NC} ${UI_RED}${UI_BOLD}✖ Failed:${UI_NC} ${UI_RED}${UI_BOLD}${failed}${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}║${UI_NC} ${UI_BLUE}${UI_BOLD}Total :${UI_NC} ${UI_BLUE}${UI_BOLD}${total}${UI_NC}"
    printf "$FMT_LINE" "${UI_CYAN}${UI_BOLD}╚${UI_BOX_LINE}╝${UI_NC}"

    if [[ "$failed" -eq 0 ]]; then
        printf "$FMT_LINE" "${UI_GREEN}${UI_BOLD}✔ ${success_msg}${UI_NC}"
    else
        printf "$FMT_LINE" "${UI_RED}${UI_BOLD}✖ ${fail_msg}${UI_NC}"
    fi
    return 0
}

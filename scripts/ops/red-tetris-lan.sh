#!/bin/sh
# red-tetris-lan.sh — discover THIS host's LAN address (never hardcoded) so a
# second computer on the same Wi-Fi/router can open Red Tetris and play live.
#
# It writes a machine-specific config archive (build/red-tetris-lan.env), checks
# that the served port is reachable on the LAN, warns if a firewall is likely
# blocking it, and prints the exact URL each computer opens. The frontend is
# same-origin (every API/WS call is relative), so NOTHING about the network is
# baked into the app — the guest's browser uses its own origin; this address is
# only what a human types in.
set -eu

PORT="${RED_TETRIS_PORT:-5178}"
CONTAINER="${RED_TETRIS_CONTAINER:-mini-baas-red-tetris}"
ARCHIVE="${RED_TETRIS_LAN_ARCHIVE:-build/red-tetris-lan.env}"

main() {
	resolve_port
	discover_network
	[ -n "${LAN_IP}" ] || fail "could not determine this host's LAN IP (no default route?)"
	write_archive
	report
	check_reachable
	check_firewall
}

# resolve_port prefers the container's actually-published host port (resolve-ports
# may have bumped 5178 if it was busy), falling back to RED_TETRIS_PORT.
resolve_port() {
	pub=$(docker port "${CONTAINER}" 80/tcp 2>/dev/null | head -1 | sed 's/.*://') || true
	[ -n "${pub:-}" ] && PORT="${pub}"
}

# discover_network reads the LAN interface, source IP, gateway, and subnet from
# the kernel routing table (with a hostname -I fallback for the IP).
discover_network() {
	route=$(ip route get 1.1.1.1 2>/dev/null || true)
	IFACE=$(printf '%s' "${route}" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
	LAN_IP=$(printf '%s' "${route}" | sed -n 's/.* src \([^ ]*\).*/\1/p')
	GATEWAY=$(ip route show default 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -1)
	[ -n "${IFACE:-}" ] && SUBNET=$(ip -o -4 addr show dev "${IFACE}" 2>/dev/null | sed -n 's#.* inet \([0-9.]*/[0-9]*\).*#\1#p' | head -1)
	[ -n "${LAN_IP:-}" ] || LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
	: "${IFACE:=?}" "${GATEWAY:=?}" "${SUBNET:=?}"
}

# write_archive persists the discovered values for the make target and operators.
write_archive() {
	mkdir -p "$(dirname "${ARCHIVE}")"
	{
		printf '# red-tetris LAN config — generated %s — machine-specific, do not commit\n' "$(date -u +%FT%TZ)"
		printf 'RED_TETRIS_LAN_IP=%s\n' "${LAN_IP}"
		printf 'RED_TETRIS_LAN_IFACE=%s\n' "${IFACE}"
		printf 'RED_TETRIS_LAN_GATEWAY=%s\n' "${GATEWAY}"
		printf 'RED_TETRIS_LAN_SUBNET=%s\n' "${SUBNET}"
		printf 'RED_TETRIS_PORT=%s\n' "${PORT}"
		printf 'RED_TETRIS_HOST_URL=http://%s:%s\n' "${LAN_IP}" "${PORT}"
	} >"${ARCHIVE}"
}

report() {
	printf '\n\033[1;36m┌─ Red Tetris · LAN multiplayer ───────────────────────────────\033[0m\n'
	printf '\033[1;36m│\033[0m  Wi-Fi/iface : %s   router %s   subnet %s\n' "${IFACE}" "${GATEWAY}" "${SUBNET}"
	printf '\033[1;36m│\033[0m  config saved: %s\n' "${ARCHIVE}"
	printf '\033[1;36m│\033[0m\n'
	printf '\033[1;36m│\033[0m  \033[1mThis computer (host):\033[0m serve the game — already up.\n'
	printf '\033[1;36m│\033[0m      open  \033[1;32mhttp://localhost:%s\033[0m\n' "${PORT}"
	printf '\033[1;36m│\033[0m  \033[1mOther computer (same Wi-Fi):\033[0m open in its browser —\n'
	printf '\033[1;36m│\033[0m      \033[1;32mhttp://%s:%s\033[0m\n' "${LAN_IP}" "${PORT}"
	printf '\033[1;36m│\033[0m  Both log in (e.g. alice / bob), join the SAME room name,\n'
	printf '\033[1;36m│\033[0m  host clicks Start — you see both boards live, side by side.\n'
	printf '\033[1;36m└──────────────────────────────────────────────────────────────\033[0m\n'
}

# check_reachable confirms the served port answers on the LAN address itself
# (not just localhost), which is what the guest computer will hit.
check_reachable() {
	if curl -fsS -o /dev/null --max-time 4 "http://${LAN_IP}:${PORT}/baas-config.js" 2>/dev/null; then
		printf '\033[0;32m✓ reachable on the LAN at http://%s:%s\033[0m\n' "${LAN_IP}" "${PORT}"
	else
		printf '\033[0;33m! http://%s:%s did not answer — is `make red-tetris` up? then re-run.\033[0m\n' "${LAN_IP}" "${PORT}"
	fi
}

# check_firewall hints at the one-liner to open the port if a host firewall is
# active. It never edits the firewall — that needs sudo and is the operator's call.
check_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
		printf '\033[0;33m  firewall: ufw is active — allow with:  sudo ufw allow %s/tcp\033[0m\n' "${PORT}"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		printf '\033[0;33m  firewall: firewalld active — allow with:  sudo firewall-cmd --add-port=%s/tcp\033[0m\n' "${PORT}"
	fi
}

fail() { printf '\033[0;31m[red-tetris-lan] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

main "$@"

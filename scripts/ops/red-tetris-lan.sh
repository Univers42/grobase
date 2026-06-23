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
	printf '\033[1;36m│\033[0m  \033[1mOnly THIS computer runs the server.\033[0m The other computer runs\n'
	printf '\033[1;36m│\033[0m  NOTHING — no make, no docker — it just opens the link below.\n'
	printf '\033[1;36m│\033[0m\n'
	printf '\033[1;36m│\033[0m  \033[1mOpen this SAME url on BOTH computers\033[0m (yes, this one too —\n'
	printf '\033[1;36m│\033[0m  do NOT use localhost, or the other PC can'\''t reach you):\n'
	printf '\033[1;36m│\033[0m      \033[1;32mhttp://%s:%s\033[0m\n' "${LAN_IP}" "${PORT}"
	printf '\033[1;36m│\033[0m\n'
	printf '\033[1;36m│\033[0m  Then: log in as DIFFERENT users (e.g. alice / bob), both type\n'
	printf '\033[1;36m│\033[0m  the SAME room name, host clicks Start. The room screen shows\n'
	printf '\033[1;36m│\033[0m  “● N players online” — if it stays 1, you are not on the same\n'
	printf '\033[1;36m│\033[0m  address (see the firewall / Wi-Fi notes below).\n'
	printf '\033[1;36m└──────────────────────────────────────────────────────────────\033[0m\n'
}

# check_reachable confirms the served port answers on the LAN address itself
# (this proves the SERVER is up and bound to the LAN — it does NOT prove a remote
# PC can get through the host firewall or the router, hence the notes below).
check_reachable() {
	if curl -fsS -o /dev/null --max-time 4 "http://${LAN_IP}:${PORT}/baas-config.js" 2>/dev/null; then
		printf '\033[0;32m✓ server is up and bound to %s:%s\033[0m\n' "${LAN_IP}" "${PORT}"
	else
		printf '\033[0;33m! http://%s:%s did not answer — start it first: make red-tetris\033[0m\n' "${LAN_IP}" "${PORT}"
	fi
}

# check_firewall prints the one-liner to OPEN the port if a host firewall is
# active (the #1 reason a remote PC sees nothing), plus the Wi-Fi caveat. It never
# edits the firewall — that needs sudo and is the operator's call.
check_firewall() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
		printf '\033[0;33m  ⚠ ufw firewall is ACTIVE — the other PC is blocked until you run:\n      \033[1msudo ufw allow %s/tcp\033[0m\n' "${PORT}"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
		printf '\033[0;33m  ⚠ firewalld is RUNNING — open the port:  \033[1msudo firewall-cmd --add-port=%s/tcp\033[0m\n' "${PORT}"
	elif command -v iptables >/dev/null 2>&1 && iptables -L INPUT 2>/dev/null | grep -qiE '\b(DROP|REJECT)\b'; then
		printf '\033[0;33m  ⚠ iptables has DROP/REJECT rules — make sure tcp/%s is allowed from %s\033[0m\n' "${PORT}" "${SUBNET}"
	fi
	printf '\033[0;33m  Still stuck at “1 online”? Your Wi-Fi may use AP/client isolation\n'
	printf '    (devices can'\''t see each other). Test from the other PC:  ping %s\n' "${LAN_IP}"
	printf '    — no reply ⇒ disable “AP isolation / client isolation” on the router.\033[0m\n'
}

fail() { printf '\033[0;31m[red-tetris-lan] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

main "$@"

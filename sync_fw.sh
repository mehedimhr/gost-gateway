#!/usr/bin/env bash
# sync_fw.sh - idempotent reconciliation of GOST_ACCESS_CONTROL iptables chain
set -euo pipefail

GOST_HOME="/etc/gost"
ALLOW_FILE="${GOST_HOME}/allowed_ips.txt"
PORT_FILE="${GOST_HOME}/config.port"
CHAIN="GOST_ACCESS_CONTROL"

[[ -f "${PORT_FILE}" ]] || { echo "port file missing: ${PORT_FILE}" >&2; exit 1; }
[[ -f "${ALLOW_FILE}" ]] || { echo "allowlist missing: ${ALLOW_FILE}" >&2; exit 1; }
PORT="$(cat "${PORT_FILE}")"

# Create chain if absent, otherwise flush it for a clean rebuild
if ! iptables -nL "${CHAIN}" >/dev/null 2>&1; then
    iptables -N "${CHAIN}"
fi
iptables -F "${CHAIN}"

# Ensure INPUT jumps to our chain exactly once (idempotent insert)
if ! iptables -C INPUT -p tcp --dport "${PORT}" -j "${CHAIN}" >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "${PORT}" -j "${CHAIN}"
fi

# Populate ACCEPT rules from allowlist (ignore blanks/comments/invalid entries)
IP_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
while IFS= read -r line; do
    line="${line%%#*}"
    ip="$(echo "${line}" | xargs)"
    [[ -z "${ip}" ]] && continue
    if [[ ! "${ip}" =~ ${IP_RE} ]]; then
        echo "sync_fw.sh: skipping invalid entry: ${ip}" >&2
        continue
    fi
    iptables -A "${CHAIN}" -s "${ip}" -p tcp --dport "${PORT}" -j ACCEPT || \
        echo "sync_fw.sh: failed to add rule for ${ip}" >&2
done < "${ALLOW_FILE}"

# Trailing DROP boundary - anything not explicitly allowed is rejected
iptables -A "${CHAIN}" -p tcp --dport "${PORT}" -j DROP

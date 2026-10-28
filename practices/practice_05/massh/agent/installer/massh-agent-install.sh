#!/bin/sh
# massh Agent installer. massh uploads it with the Agent binary and runs it in a terminal tab:
#   sudo sh massh-agent-install.sh install|update <binary>
#   sudo sh massh-agent-install.sh uninstall
# The sudo password is typed by the user in that tab; massh never sees it. Every step is idempotent.
set -eu

action=${1:-}
binary=${2:-}
unit=/etc/systemd/system/massh-agent.service
target=/usr/local/bin/massh-agent
here=$(cd "$(dirname "$0")" && pwd)

say() { printf 'massh: %s\n' "$*"; }
fail() { printf 'massh: %s\n' "$*" >&2; exit 1; }

cleanup() {
	# Only the upload directory massh created, never anything else.
	case "$here" in /tmp/massh-agent.*) rm -rf "$here" ;; esac
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || fail "run with sudo"
[ -d /run/systemd/system ] || fail "this Server has no systemd; the Agent needs it"

install_agent() {
	[ -n "$binary" ] && [ -f "$binary" ] || fail "missing Agent binary"

	if ! id massh >/dev/null 2>&1; then
		say "creating user massh"
		useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin massh
	fi
	groups=""
	if getent group docker >/dev/null 2>&1; then
		usermod -aG docker massh
		groups="SupplementaryGroups=docker"
	fi

	say "installing $target"
	install -m 0755 -o root -g root "$binary" "$target.new"
	mv -f "$target.new" "$target"

	cat >"$unit.new" <<EOF
[Unit]
Description=massh Agent
After=network.target docker.service

[Service]
User=massh
Group=massh
$groups
ExecStart=$target
Restart=always
RestartSec=2
AmbientCapabilities=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
	mv -f "$unit.new" "$unit"
	systemctl daemon-reload
	systemctl enable massh-agent.service >/dev/null 2>&1
	systemctl restart massh-agent.service
	say "Agent $("$target" -version) is running"
}

uninstall_agent() {
	if [ -f "$unit" ]; then
		systemctl disable --now massh-agent.service >/dev/null 2>&1 || true
		rm -f "$unit"
		systemctl daemon-reload
	fi
	rm -f "$target"
	if id massh >/dev/null 2>&1; then
		userdel massh
	fi
	say "Agent removed"
}

case "$action" in
install | update) install_agent ;;
uninstall) uninstall_agent ;;
*) fail "usage: $0 install|update <binary> | uninstall" ;;
esac

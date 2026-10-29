#!/usr/bin/env bash
#
# first-boot.sh - the first ten minutes on a fresh Debian/Ubuntu VPS.
#
# Creates a sudo user from an SSH public key, turns on ufw (SSH, 80, 443),
# installs fail2ban and unattended-upgrades, optionally adds a swap file and
# sets the timezone to Asia/Kolkata, and finally switches SSH to key-only
# with root login off - but only after you confirm the new user can log in.
#
# Intended for Ubuntu 22.04, Ubuntu 24.04 and Debian 12.
# Safe to run more than once: anything already in place is left alone.
#
# https://github.com/bigdomainhost/vps-first-boot - MIT licence.

set -euo pipefail

SCRIPT_VERSION="0.1.0"

SSHD_DROPIN=/etc/ssh/sshd_config.d/01-first-boot.conf
F2B_JAIL=/etc/fail2ban/jail.d/first-boot.local
AUTO_UPGRADES=/etc/apt/apt.conf.d/20auto-upgrades
SWAPFILE=/swapfile
SWAP_SYSCTL=/etc/sysctl.d/90-first-boot-swap.conf
TZ_WANTED=Asia/Kolkata

USERNAME=""
KEY_ARG=""
WANT_SWAP=0
SWAP_MB=""
SET_IST=0
ASSUME_YES=0
SKIP_LOCKDOWN=0
FORCE=0

CHANGED=()
NOTES=()

say()     { printf '\n==> %s\n' "$*"; }
warn()    { printf 'WARN: %s\n' "$*" >&2; NOTES+=("$*"); }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
changed() { CHANGED+=("$*"); printf '    changed: %s\n' "$*"; }
same()    { printf '    ok, already done: %s\n' "$*"; }

usage() {
	cat <<'EOF'
Usage: sudo bash first-boot.sh --user NAME --key KEY [options]

Required:
  -u, --user NAME        login to create (or reuse) and add to the sudo group
  -k, --key KEY          SSH public key, either the key text itself
                         ("ssh-ed25519 AAAA... you@laptop") or a path to a file
                         holding it, e.g. /root/.ssh/authorized_keys

Options:
      --swap             create /swapfile: 1 GB if RAM is under 2 GB, else 2 GB
      --swap-size MB     create /swapfile of this size instead (implies --swap)
      --ist              set the timezone to Asia/Kolkata
  -y, --yes              do not ask before switching SSH to key-only; use this
                         only after you have tested the key yourself
      --skip-ssh-lockdown
                         do everything except the sshd changes
      --force            run on a distro this was not written for
  -h, --help             show this help
EOF
}

# ---------------------------------------------------------------- arguments

need_value() { [ "$2" -ge 2 ] || die "$1 needs a value (try --help)"; }

while [ $# -gt 0 ]; do
	case "$1" in
		-u|--user)          need_value "$1" $#; USERNAME=$2; shift 2 ;;
		-k|--key)           need_value "$1" $#; KEY_ARG=$2; shift 2 ;;
		--swap)             WANT_SWAP=1; shift ;;
		--swap-size)        need_value "$1" $#; SWAP_MB=$2; WANT_SWAP=1; shift 2 ;;
		--ist)              SET_IST=1; shift ;;
		-y|--yes)           ASSUME_YES=1; shift ;;
		--skip-ssh-lockdown) SKIP_LOCKDOWN=1; shift ;;
		--force)            FORCE=1; shift ;;
		-h|--help)          usage; exit 0 ;;
		*)                  die "unknown option: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------- pre-flight

[ "$(id -u)" -eq 0 ] || die "this has to run as root: sudo bash $0 ..."
[ -n "$USERNAME" ] || die "--user is required (try --help)"
[ -n "$KEY_ARG" ]  || die "--key is required (try --help)"
[ "$USERNAME" != root ] || die "--user must be a normal user, not root"
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
	|| die "username '$USERNAME' is not valid (lowercase letters, digits, _ and -)"

if [ -n "$SWAP_MB" ]; then
	[[ "$SWAP_MB" =~ ^[0-9]+$ ]] || die "--swap-size takes a number of MB, e.g. 2048"
	[ "$SWAP_MB" -ge 256 ] || die "--swap-size below 256 MB is not worth having"
fi

[ -r /etc/os-release ] || die "no /etc/os-release; is this Debian or Ubuntu?"
OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
OS_VER=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
case "$OS_ID:$OS_VER" in
	ubuntu:22.04|ubuntu:24.04|debian:12) ;;
	*)
		if [ "$FORCE" -eq 1 ]; then
			warn "$OS_ID $OS_VER is not one of the distros this was written for; carrying on because of --force"
		else
			die "written for Ubuntu 22.04/24.04 and Debian 12, this is '$OS_ID $OS_VER'. Use --force if you know what you are doing."
		fi
		;;
esac
command -v apt-get >/dev/null || die "apt-get not found; this script is for Debian-family systems only"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Pull "type base64" out of the key argument. Accepts a bare key, a .pub file,
# or an authorized_keys file (options such as from="..." are skipped over).
if [ -f "$KEY_ARG" ]; then
	KEY_SOURCE=$(tr -d '\r' <"$KEY_ARG")
else
	KEY_SOURCE=$KEY_ARG
fi
case "$KEY_SOURCE" in
	*"PRIVATE KEY"*) die "that is a PRIVATE key. Pass the .pub file, and do not paste the private one anywhere." ;;
esac
PUBKEY=$(printf '%s\n' "$KEY_SOURCE" | awk '
	/^[[:space:]]*(#|$)/ { next }
	{
		for (i = 1; i < NF; i++)
			if ($i ~ /^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)$/) {
				print $i " " $(i + 1); exit
			}
	}')
[ -n "$PUBKEY" ] || die "could not find an SSH public key in --key"
printf '%s first-boot\n' "$PUBKEY" >"$WORK/key.pub"
# ssh-keygen comes with openssh-client. A console-only minimal install may not
# have it yet, in which case the key is checked after the packages step.
check_key() {
	KEY_FP=$(ssh-keygen -l -f "$WORK/key.pub" 2>/dev/null) \
		|| die "ssh-keygen does not accept that key; check you copied the whole line"
}
KEY_FP="${PUBKEY%% *} key (fingerprint checked after packages are installed)"
if command -v ssh-keygen >/dev/null; then check_key; fi

SSHD=$(command -v sshd || echo /usr/sbin/sshd)

say "first-boot.sh $SCRIPT_VERSION on $OS_ID $OS_VER"
printf '    user: %s\n    key:  %s\n' "$USERNAME" "$KEY_FP"

# ---------------------------------------------------------------- helpers

# write_if_changed PATH MODE CONTENT
# Returns 0 if the file was written, 1 if it already had exactly this content.
write_if_changed() {
	local path=$1 mode=$2 content=$3 tmp
	tmp="$WORK/$(basename "$path").new"
	printf '%s\n' "$content" >"$tmp" || die "could not write $tmp"
	if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
		return 1
	fi
	install -D -m "$mode" -o root -g root "$tmp" "$path" || die "could not write $path"
	return 0
}

pkg_installed() {
	local status
	status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
	[ "$status" = "install ok installed" ]
}

# ---------------------------------------------------------------- packages

say "Packages"
WANT_PKGS=(sudo openssh-server ufw fail2ban python3-systemd unattended-upgrades)
MISSING=()
for p in "${WANT_PKGS[@]}"; do
	pkg_installed "$p" || MISSING+=("$p")
done
if [ ${#MISSING[@]} -gt 0 ]; then
	export DEBIAN_FRONTEND=noninteractive
	# On a box that booted a minute ago, cloud-init or apt-daily may still hold
	# the dpkg lock. Wait for it instead of failing.
	apt-get -o DPkg::Lock::Timeout=300 update -q
	apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends "${MISSING[@]}"
	changed "installed ${MISSING[*]}"
else
	same "${WANT_PKGS[*]}"
fi
case "$KEY_FP" in
	*"checked after packages"*) check_key; printf '    key:  %s\n' "$KEY_FP" ;;
esac

# ---------------------------------------------------------------- user, sudo, key

say "User $USERNAME"
if id "$USERNAME" >/dev/null 2>&1; then
	same "user $USERNAME exists"
else
	useradd --create-home --shell /bin/bash "$USERNAME"
	# useradd leaves the password field as "!" (locked). With UsePAM no, sshd
	# refuses key logins for locked accounts, so mark it "no password" instead.
	usermod -p '*' "$USERNAME"
	changed "created user $USERNAME (no password, key login only)"
fi

case " $(id -nG "$USERNAME") " in
	*" sudo "*) same "$USERNAME is in the sudo group" ;;
	*) usermod -aG sudo "$USERNAME"; changed "added $USERNAME to the sudo group" ;;
esac

# The user has no password, so sudo has to be passwordless. See the README if
# you would rather set a password and delete this file.
SUDOERS_FILE="/etc/sudoers.d/90-first-boot-$USERNAME"
SUDOERS_LINE="$USERNAME ALL=(ALL) NOPASSWD:ALL"
printf '%s\n' "$SUDOERS_LINE" >"$WORK/sudoers"
visudo -cf "$WORK/sudoers" >/dev/null || die "visudo rejected the sudoers line; nothing written"
if write_if_changed "$SUDOERS_FILE" 0440 "$SUDOERS_LINE"; then
	changed "passwordless sudo for $USERNAME in $SUDOERS_FILE"
else
	same "sudoers entry for $USERNAME"
fi

USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
USER_GROUP=$(id -gn "$USERNAME")
[ -d "$USER_HOME" ] || die "home directory $USER_HOME for $USERNAME does not exist"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# sshd's StrictModes ignores authorized_keys if the home dir is group/world writable.
if [ -n "$(find "$USER_HOME" -maxdepth 0 -perm /022)" ]; then
	chmod go-w "$USER_HOME"
	changed "removed group/world write from $USER_HOME (sshd would ignore the key otherwise)"
fi
install -d -m 0700 -o "$USERNAME" -g "$USER_GROUP" "$SSH_DIR"

if [ -f "$AUTH_KEYS" ] && awk -v k="$PUBKEY" '{ for (i = 1; i < NF; i++) if ($i " " $(i + 1) == k) f = 1 } END { exit !f }' "$AUTH_KEYS"; then
	same "key already in $AUTH_KEYS"
else
	# If the file does not end in a newline, appending would glue our key onto
	# the last one and break both.
	if [ -s "$AUTH_KEYS" ] && [ -n "$(tail -c 1 "$AUTH_KEYS")" ]; then
		printf '\n' >>"$AUTH_KEYS"
	fi
	cat "$WORK/key.pub" >>"$AUTH_KEYS"
	changed "added key to $AUTH_KEYS"
fi
chown "$USERNAME:$USER_GROUP" "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"

# ---------------------------------------------------------------- firewall

say "Firewall (ufw)"
# sshd -T needs its privilege separation dir, which may not exist yet on
# Ubuntu 24.04 where ssh is socket-activated.
mkdir -p /run/sshd
SSH_PORTS=$("$SSHD" -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true)
# Also allow the port this session came in on, if we can see it. If sshd -T
# failed and SSH is not on 22, enabling ufw would otherwise cut us off.
# (sudo usually drops SSH_CONNECTION; it is there when you log in as root.)
SESSION_PORT=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{ print $4 }')
SSH_PORTS=$(printf '%s\n%s\n' "$SSH_PORTS" "$SESSION_PORT" | grep -E '^[0-9]+$' | sort -un || true)
[ -n "$SSH_PORTS" ] || SSH_PORTS=22

ufw_allow() {
	local out
	out=$(ufw allow "$1" 2>&1) || die "ufw allow $1 failed: $out"
	case "$out" in
		# "Rule added" when ufw is active, "Rules updated" when it is not yet.
		*"Rule added"*|*"Rule updated"*|*"Rules updated"*) changed "ufw allow $1" ;;
		*) same "ufw allows $1" ;;
	esac
}

for port in $SSH_PORTS; do
	ufw_allow "$port/tcp"
done
ufw_allow 80/tcp
ufw_allow 443/tcp

UFW_STATUS=$(ufw status)
case "$UFW_STATUS" in
	*"Status: active"*)
		same "ufw is active (existing default policies left as they are)"
		;;
	*)
		ufw default deny incoming >/dev/null
		ufw default allow outgoing >/dev/null
		ufw --force enable >/dev/null
		changed "enabled ufw: deny incoming except SSH ($(echo $SSH_PORTS)), 80, 443; allow outgoing"
		;;
esac

# ---------------------------------------------------------------- fail2ban

say "fail2ban"
# backend = systemd because Debian 12 has no /var/log/auth.log by default, and
# the stock sshd jail fails to start without it.
F2B_CONTENT="# Written by first-boot.sh. Edit freely; a re-run will put it back.
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h"
if write_if_changed "$F2B_JAIL" 0644 "$F2B_CONTENT"; then
	changed "wrote $F2B_JAIL (sshd jail: 5 failures in 10m = 1h ban)"
	systemctl enable fail2ban >/dev/null 2>&1 || true
	systemctl restart fail2ban || warn "fail2ban did not restart; see: journalctl -u fail2ban -n 50"
else
	same "$F2B_JAIL"
	systemctl enable --now fail2ban >/dev/null 2>&1 || true
fi
if ! systemctl is-active --quiet fail2ban; then
	warn "fail2ban is not running; see: journalctl -u fail2ban -n 50"
fi

# ---------------------------------------------------------------- updates

say "Unattended security upgrades"
# The distro default policy (50unattended-upgrades) only pulls from the
# security pocket and never reboots on its own. We only switch it on.
AUTO_CONTENT='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
if write_if_changed "$AUTO_UPGRADES" 0644 "$AUTO_CONTENT"; then
	changed "enabled daily unattended-upgrades in $AUTO_UPGRADES"
else
	same "$AUTO_UPGRADES"
fi

# ---------------------------------------------------------------- swap

if [ "$WANT_SWAP" -eq 1 ]; then
	say "Swap"
	ACTIVE_SWAP=$(swapon --noheadings --show=NAME 2>/dev/null || true)
	if [ -n "$ACTIVE_SWAP" ]; then
		same "swap already active: $(printf '%s' "$ACTIVE_SWAP" | tr '\n' ' ')"
	elif [ -e "$SWAPFILE" ]; then
		warn "$SWAPFILE exists but is not in use; not touching it. Check it and run: swapon $SWAPFILE"
	else
		ROOT_FS=$(findmnt -no FSTYPE / 2>/dev/null || true)
		MEM_KB=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
		if [ -z "$SWAP_MB" ]; then
			# 1-2 GB is an emergency buffer, not extra RAM. If the box swaps
			# every day, it needs a bigger plan, not a bigger swap file.
			if [ "$MEM_KB" -lt 2097152 ]; then SWAP_MB=1024; else SWAP_MB=2048; fi
		fi
		AVAIL_KB=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
		NEED_KB=$(( SWAP_MB * 1024 + 1048576 ))   # the swap file plus 1 GB to spare
		if [ "$ROOT_FS" = btrfs ]; then
			warn "root filesystem is btrfs; swap files need extra steps there. Skipped."
		elif [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
			warn "not enough free disk for a ${SWAP_MB} MB swap file plus 1 GB headroom. Skipped."
		else
			install -m 0600 /dev/null "$SWAPFILE"
			if ! fallocate -l "${SWAP_MB}M" "$SWAPFILE" 2>/dev/null; then
				dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_MB" status=none
			fi
			if mkswap "$SWAPFILE" >/dev/null && swapon "$SWAPFILE"; then
				changed "created and enabled ${SWAP_MB} MB $SWAPFILE"
			else
				rm -f "$SWAPFILE"
				warn "could not enable $SWAPFILE; removed it again. No swap added."
			fi
		fi
	fi
	# Only put it in fstab if it is actually our swap file and in use, never a
	# leftover /swapfile we said we would not touch.
	if swapon --noheadings --show=NAME 2>/dev/null | grep -qx "$SWAPFILE" \
		&& ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
		printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
		changed "added $SWAPFILE to /etc/fstab"
	fi
	if write_if_changed "$SWAP_SYSCTL" 0644 "vm.swappiness = 10"; then
		sysctl -q -p "$SWAP_SYSCTL"
		changed "vm.swappiness = 10 (use swap only when RAM is nearly full)"
	else
		same "vm.swappiness = 10"
	fi
fi

# ---------------------------------------------------------------- timezone

if [ "$SET_IST" -eq 1 ]; then
	say "Timezone"
	TZ_NOW=$(timedatectl show -p Timezone --value 2>/dev/null || true)
	if [ "$TZ_NOW" = "$TZ_WANTED" ]; then
		same "timezone is $TZ_WANTED"
	else
		timedatectl set-timezone "$TZ_WANTED"
		changed "timezone ${TZ_NOW:-unknown} -> $TZ_WANTED"
	fi
fi

# ---------------------------------------------------------------- ssh lockdown

SSHD_CONTENT="# Written by first-boot.sh. Files in sshd_config.d are read in name order
# and the first value wins, so 01- beats 50-cloud-init.conf.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes"

server_ip() {
	# Never fail: under set -e a failed $(server_ip) would end the script.
	{ hostname -I 2>/dev/null || true; } | awk '{ print $1 }'
}

ssh_lockdown() {
	local eff ans ip

	say "SSH: key-only, no root login"

	# 1. Is it already done?
	eff=$("$SSHD" -T -C "user=root,host=localhost,addr=127.0.0.1" 2>/dev/null || true)
	if [ -f "$SSHD_DROPIN" ] && cmp -s "$SSHD_DROPIN" <(printf '%s\n' "$SSHD_CONTENT") \
		&& grep -qx 'permitrootlogin no' <<<"$eff" \
		&& grep -qx 'passwordauthentication no' <<<"$eff"; then
		same "root login and password login are already off"
		return 0
	fi

	# 2. Mechanical checks: will sshd accept this user's key at all?
	grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config \
		|| { warn "sshd_config does not include sshd_config.d/*.conf; SSH left unchanged. Add the settings by hand."; return 0; }
	eff=$("$SSHD" -T -C "user=$USERNAME,host=localhost,addr=127.0.0.1" 2>/dev/null) \
		|| { warn "'sshd -T' failed, so the current config could not be checked; SSH left unchanged."; return 0; }
	grep -qx 'pubkeyauthentication yes' <<<"$eff" \
		|| { warn "sshd has PubkeyAuthentication off for $USERNAME; SSH left unchanged."; return 0; }
	grep -q '\.ssh/authorized_keys' <<<"$(grep '^authorizedkeysfile ' <<<"$eff" || true)" \
		|| { warn "sshd does not read ~/.ssh/authorized_keys (AuthorizedKeysFile changed); SSH left unchanged."; return 0; }
	if grep -qE '^(allowusers|allowgroups|denyusers|denygroups) ' <<<"$eff"; then
		warn "sshd has AllowUsers/AllowGroups/DenyUsers/DenyGroups set. Check $USERNAME is allowed, then re-run. SSH left unchanged."
		return 0
	fi
	[ "$(stat -c '%U %a' "$AUTH_KEYS")" = "$USERNAME 600" ] \
		|| { warn "$AUTH_KEYS has the wrong owner or mode; SSH left unchanged."; return 0; }

	# 3. The real check is a human logging in. We do not have the private key,
	#    so we cannot test it from here.
	if [ "$ASSUME_YES" -ne 1 ]; then
		if ! (exec </dev/tty) 2>/dev/null; then
			warn "no terminal to ask on. Test 'ssh $USERNAME@<server>' yourself, then re-run with --yes to switch SSH to key-only."
			return 0
		fi
		ip=$(server_ip)
		cat <<EOF

    Before root and password logins are switched off, prove the key works.
    Keep THIS session open. In a NEW terminal on your own machine, run:

        ssh $USERNAME@${ip:-<server-ip>}
        sudo true

    If both work without a password prompt, type yes here.
    Anything else leaves SSH exactly as it is.

EOF
		printf '    Did the login and sudo work? [yes/no] '
		read -r ans </dev/tty || ans=""
		if [ "$ans" != yes ]; then
			warn "not confirmed; SSH left unchanged. Fix the login, then re-run."
			return 0
		fi
	fi

	# 4. Write, syntax-check, reload. Roll back if sshd does not like it.
	write_if_changed "$SSHD_DROPIN" 0644 "$SSHD_CONTENT" || true
	if ! "$SSHD" -t; then
		rm -f "$SSHD_DROPIN"
		die "'sshd -t' rejected the new config. Removed $SSHD_DROPIN, SSH is unchanged."
	fi
	systemctl try-reload-or-restart ssh.service \
		|| warn "could not reload ssh.service; the change applies on the next restart"
	changed "wrote $SSHD_DROPIN: root login off, password login off"

	# 5. Check sshd actually ended up with these values.
	eff=$("$SSHD" -T -C "user=root,host=localhost,addr=127.0.0.1" 2>/dev/null || true)
	if ! grep -qx 'permitrootlogin no' <<<"$eff" || ! grep -qx 'passwordauthentication no' <<<"$eff"; then
		warn "another sshd setting overrides ours. Check: sshd -T | grep -E 'permitrootlogin|passwordauthentication'"
	fi
}

if [ "$SKIP_LOCKDOWN" -eq 1 ]; then
	say "SSH"
	same "skipped (--skip-ssh-lockdown)"
else
	ssh_lockdown
fi

# ---------------------------------------------------------------- summary

say "Summary"
if [ ${#CHANGED[@]} -eq 0 ]; then
	echo "    Nothing changed. The server already looked the way this script wants it."
else
	for c in "${CHANGED[@]}"; do
		printf '    * %s\n' "$c"
	done
fi
if [ ${#NOTES[@]} -gt 0 ]; then
	echo
	echo "    Needs your attention:"
	for n in "${NOTES[@]}"; do
		printf '    ! %s\n' "$n"
	done
fi
IP=$(server_ip || true)
printf '\n    Log in from now on with: ssh %s@%s\n\n' "$USERNAME" "${IP:-<server-ip>}"

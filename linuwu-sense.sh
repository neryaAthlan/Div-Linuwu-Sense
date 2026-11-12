#!/usr/bin/env bash
#
# linuwu-sense.sh - manage the Linuwu Sense Acer WMI kernel module
#
# Builds and installs src/linuwu_sense.ko for the running kernel, sets up the
# boot-time loading, permissions and shutdown unit, and exposes the sysfs
# settings without having to remember the long paths.
#
# Run with no arguments for usage; "status" does not need root.

set -euo pipefail

# Debian keeps modprobe/depmod/groupadd in sbin, which is missing from some
# user shells' PATH.
export PATH="/usr/sbin:/sbin:${PATH}"

MODNAME="linuwu_sense"
SERVICE="${MODNAME}.service"
KVER="${KVER:-$(uname -r)}"
KDIR="/lib/modules/${KVER}/build"
MDIR="/lib/modules/${KVER}/kernel/drivers/platform/x86"
SYSFS_BASE="/sys/module/${MODNAME}/drivers/platform:acer-wmi/acer-wmi"
KO_SRC="src/${MODNAME}.ko"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ORIG_ARGS=("$@")

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
	GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
	BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

real_user() {
	if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
		printf '%s\n' "$SUDO_USER"
	elif [ -n "${PKEXEC_UID:-}" ]; then
		getent passwd "$PKEXEC_UID" 2>/dev/null | cut -d: -f1
	elif [ "$(id -u)" -ne 0 ] && command -v logname >/dev/null 2>&1; then
		logname 2>/dev/null || id -un
	else
		id -un
	fi
}

REAL_USER="$(real_user)"
[ -n "$REAL_USER" ] || REAL_USER="$(id -un)"

ensure_root() {
	[ "$(id -u)" -eq 0 ] && return 0
	command -v sudo >/dev/null 2>&1 ||
		die "Root privileges are required and sudo is not installed."
	if [ ! -t 0 ]; then
		die "Root privileges are required. Re-run with sudo: sudo $0 ${ORIG_ARGS[*]}"
	fi
	info "Root privileges required, re-running with sudo..."
	exec sudo -- "$0" "${ORIG_ARGS[@]}"
}

# Locate the model directory the driver created (nitro_sense/predator_sense).
detect_model() {
	[ -d "$SYSFS_BASE" ] || return 0
	local d
	for d in "$SYSFS_BASE"/*_sense; do
		[ -e "$d" ] && { basename "$d"; return 0; }
	done
	return 0
}

model_path() { printf '%s/%s\n' "$SYSFS_BASE" "$(detect_model)"; }

module_loaded() { [ -e "/sys/module/${MODNAME}" ]; }

kos_built() { [ -f "$SCRIPT_DIR/$KO_SRC" ]; }

ko_installed() { [ -f "$MDIR/${MODNAME}.ko" ]; }

check_kernel() {
	[ -d "$KDIR" ] ||
		die "Kernel headers for ${KVER} are missing (${KDIR}). Install them: sudo apt install linux-headers-${KVER}"
}

build_module() {
	check_kernel
	info "Building ${MODNAME} for kernel ${KVER}..."
	make -C "$SCRIPT_DIR" -j"$(nproc)"
	ok "Built $SCRIPT_DIR/$KO_SRC"
}

feature_file() {
	case "$1" in
		platform-profile)    printf '/sys/firmware/acpi/platform_profile\n' ;;
		fan-speed)           printf '%s/fan_speed\n' "$(model_path)" ;;
		battery-limiter)     printf '%s/battery_limiter\n' "$(model_path)" ;;
		battery-calibration) printf '%s/battery_calibration\n' "$(model_path)" ;;
		usb-charging)        printf '%s/usb_charging\n' "$(model_path)" ;;
		backlight-timeout)   printf '%s/backlight_timeout\n' "$(model_path)" ;;
		boot-animation-sound) printf '%s/boot_animation_sound\n' "$(model_path)" ;;
		lcd-override)        printf '%s/lcd_override\n' "$(model_path)" ;;
		four-zone-mode)      printf '%s/four_zoned_kb/four_zone_mode\n' "$SYSFS_BASE" ;;
		per-zone-mode)       printf '%s/four_zoned_kb/per_zone_mode\n' "$SYSFS_BASE" ;;
		*) return 1 ;;
	esac
}

validate_value() {
	local name="$1" value="$2" choices
	case "$name" in
		platform-profile)
			choices="$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || true)"
			if [ -n "$choices" ] && ! printf '%s\n' $choices | grep -qxF "$value"; then
				die "Unsupported profile '$value'. Supported: $choices"
			fi
			;;
		fan-speed)
			printf '%s' "$value" | grep -Eq '^[0-9]+(,[0-9]+)?$' ||
				die "fan-speed takes <cpu> or <cpu>,<gpu> with values 0-100"
			local v
			for v in ${value//,/ }; do
				[ "$v" -le 100 ] || die "fan-speed values must be 0-100 (0 = auto)"
			done
			;;
		battery-limiter|battery-calibration|backlight-timeout|boot-animation-sound|lcd-override)
			printf '%s' "$value" | grep -Eq '^[01]$' || die "$name takes 0 or 1"
			;;
		usb-charging)
			printf '%s' "$value" | grep -Eq '^(0|10|20|30)$' || die "usb-charging takes 0, 10, 20 or 30"
			;;
		four-zone-mode)
			printf '%s' "$value" | grep -Eq '^[0-9]+(,[0-9]+){6}$' ||
				die "four-zone-mode takes 7 values: mode,speed,brightness,direction,r,g,b"
			;;
		per-zone-mode)
			printf '%s' "$value" | grep -Eiq '^([0-9a-f]{6},){4}[0-9]{1,3}$' ||
				die "per-zone-mode takes 4 RRGGBB colors and a brightness: c1,c2,c3,c4,0-100"
			;;
	esac
}

setup_tmpfiles() {
	local model conf fields f entry kb_base
	model="$(detect_model)"
	if [ -z "$model" ]; then
		warn "No nitro_sense/predator_sense directory in sysfs; skipped permission setup."
		return 0
	fi
	conf="/etc/tmpfiles.d/${MODNAME}.conf"
	if [ "$model" = "nitro_sense" ]; then
		fields="fan_speed battery_limiter battery_calibration usb_charging"
	else
		fields="backlight_timeout battery_calibration battery_limiter boot_animation_sound fan_speed lcd_override usb_charging"
	fi

	: > "$conf"
	for f in $fields; do
		entry="f ${SYSFS_BASE}/${model}/${f} 0660 root ${MODNAME}"
		grep -qxF "$entry" "$conf" || printf '%s\n' "$entry" >> "$conf"
	done
	kb_base="${SYSFS_BASE}/four_zoned_kb"
	if [ -d "$kb_base" ]; then
		for f in four_zone_mode per_zone_mode; do
			entry="f ${kb_base}/${f} 0660 root ${MODNAME}"
			grep -qxF "$entry" "$conf" || printf '%s\n' "$entry" >> "$conf"
		done
	fi
	chmod 644 "$conf"
	systemd-tmpfiles --create "$conf"
	ok "Writable by group ${MODNAME}: $(printf '%s' "$fields")"
}

cmd_build() { build_module; }

cmd_clean() {
	info "Cleaning build artifacts..."
	make -C "$SCRIPT_DIR" clean >/dev/null
	ok "Clean"
}

cmd_install() {
	if [ "$(id -u)" -ne 0 ]; then
		build_module
		ensure_root "$@"
	fi

	build_module
	ko_installed && warn "Existing ${MDIR}/${MODNAME}.ko will be replaced."

	# The stock driver must not be bound to the same WMI device.
	modprobe -r acer_wmi 2>/dev/null || true
	modprobe -r "$MODNAME" 2>/dev/null || true

	info "Installing ${MODNAME}.ko for kernel ${KVER}..."
	install -d "$MDIR"
	install -m 644 "$SCRIPT_DIR/$KO_SRC" "$MDIR/${MODNAME}.ko"
	depmod -a "$KVER"

	printf 'blacklist acer_wmi\n' > /etc/modprobe.d/blacklist-acer_wmi.conf
	printf '%s\n' "$MODNAME" > "/etc/modules-load.d/${MODNAME}.conf"

	if ! modprobe "$MODNAME"; then
		warn "modprobe failed; kernel log:"
		dmesg | tail -n 20 >&2 || true
		die "Could not load ${MODNAME}. The module and its configs are installed, but it is not active."
	fi
	ok "Module loaded"

	install -m 644 "$SCRIPT_DIR/${MODNAME}.service" "/etc/systemd/system/${SERVICE}"
	systemctl daemon-reload
	systemctl enable "$SERVICE" >/dev/null 2>&1 || warn "Could not enable ${SERVICE}"
	systemctl start "$SERVICE" >/dev/null 2>&1 || warn "Could not start ${SERVICE}"
	ok "Shutdown unit ${SERVICE} enabled"

	if ! getent group "$MODNAME" >/dev/null; then
		groupadd "$MODNAME"
	fi
	if [ "$REAL_USER" != root ]; then
		usermod -aG "$MODNAME" "$REAL_USER"
		ok "Added ${REAL_USER} to group ${MODNAME}"
	fi

	# Give the driver a moment to create its sysfs tree.
	local i
	for i in $(seq 1 20); do
		[ -n "$(detect_model)" ] && break
		sleep 0.25
	done
	setup_tmpfiles

	say
	ok "Installed ${MODNAME} for kernel ${KVER}"
	if [ -n "$(detect_model)" ]; then
		ok "Model interface: $(model_path)"
	else
		warn "Model interface not found under ${SYSFS_BASE}"
	fi
	if ! id -nG "$REAL_USER" 2>/dev/null | grep -qw "$MODNAME"; then
		warn "Log out and back in before using the settings without sudo."
	fi
}

cmd_uninstall() {
	ensure_root "$@"
	info "Removing ${MODNAME}..."
	rm -f "/etc/modules-load.d/${MODNAME}.conf"
	rm -f /etc/modprobe.d/blacklist-acer_wmi.conf
	systemctl stop "$SERVICE" >/dev/null 2>&1 || true
	systemctl disable "$SERVICE" >/dev/null 2>&1 || true
	rm -f "/etc/systemd/system/${SERVICE}"
	systemctl daemon-reload
	modprobe -r "$MODNAME" 2>/dev/null || rmmod "$MODNAME" 2>/dev/null || true
	modprobe acer_wmi 2>/dev/null || true

	if [ "$REAL_USER" != root ]; then
		if getent group "$MODNAME" >/dev/null; then
			gpasswd -d "$REAL_USER" "$MODNAME" >/dev/null 2>&1 || true
		fi
	fi
	if getent group "$MODNAME" >/dev/null; then
		groupdel "$MODNAME" 2>/dev/null || warn "Group ${MODNAME} is still in use; left in place."
	fi

	rm -f "/etc/tmpfiles.d/${MODNAME}.conf"
	rm -f "$MDIR/${MODNAME}.ko"
	depmod -a "$KVER"
	ok "Uninstalled ${MODNAME}; stock acer_wmi restored"
}

cmd_reload() {
	ensure_root "$@"
	info "Reloading ${MODNAME}..."
	modprobe -r "$MODNAME" 2>/dev/null || rmmod "$MODNAME" 2>/dev/null ||
		warn "Could not unload ${MODNAME} (in use?); trying to load anyway."
	modprobe "$MODNAME" || die "Could not load ${MODNAME}"
	setup_tmpfiles
	ok "Reloaded"
}

cmd_status() {
	local model
	model="$(detect_model)"

	printf '%sLinuwu Sense status%s\n' "$BOLD" "$RESET"
	printf '  %-18s %s\n' "Kernel:" "$KVER"
	if [ -d "$KDIR" ]; then
		printf '  %-18s %s\n' "Headers:" "present"
	else
		printf '  %-18s %s\n' "Headers:" "${RED}missing${RESET} (sudo apt install linux-headers-${KVER})"
	fi

	if kos_built; then
		printf '  %-18s %s\n' "Built:" "yes ($KO_SRC)"
	else
		printf '  %-18s %s\n' "Built:" "no (run install or build)"
	fi
	if ko_installed; then
		printf '  %-18s %s\n' "Installed:" "yes ($MDIR/${MODNAME}.ko)"
	else
		printf '  %-18s %s\n' "Installed:" "no"
	fi
	if module_loaded; then
		printf '  %-18s %s\n' "Loaded:" "${GREEN}yes${RESET}"
	else
		printf '  %-18s %s\n' "Loaded:" "${RED}no${RESET}"
	fi

	printf '  %-18s %s\n' "Machine:" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown) $(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
	if [ -n "$model" ]; then
		printf '  %-18s %s\n' "Interface:" "$(model_path)"
	elif module_loaded; then
		printf '  %-18s %s\n' "Interface:" "${YELLOW}not found${RESET}"
	fi

	local service_state group_state
	service_state="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
	[ -n "$service_state" ] || service_state="not installed"
	printf '  %-18s %s\n' "Shutdown unit:" "$service_state"
	if getent group "$MODNAME" >/dev/null 2>&1; then
		if id -nG "$REAL_USER" 2>/dev/null | grep -qw "$MODNAME"; then
			group_state="yes (${REAL_USER})"
		else
			group_state="no (${REAL_USER} not a member)"
		fi
	else
		group_state="group missing"
	fi
	printf '  %-18s %s\n' "Group access:" "$group_state"

	if [ -n "$model" ]; then
		printf '\n%sSettings%s\n' "$BOLD" "$RESET"
		local name file value
		for name in platform-profile fan-speed battery-limiter usb-charging \
			backlight-timeout boot-animation-sound lcd-override \
			four-zone-mode per-zone-mode; do
			file="$(feature_file "$name")"
			[ -e "$file" ] || continue
			value="$(cat "$file" 2>/dev/null || echo "?")"
			printf '  %-22s %s\n' "${name}:" "$value"
		done
	fi

	if { kos_built || ko_installed || [ -e "/etc/modules-load.d/${MODNAME}.conf" ]; } &&
		! module_loaded; then
		printf '\n'
		warn "Configuration exists but ${MODNAME} is not loaded (kernel updated?). Run: sudo $0 install"
	fi
}

cmd_get() {
	[ $# -eq 1 ] || die "Usage: $0 get <setting>"
	local file
	file="$(feature_file "$1")" || die "Unknown setting '$1'. See: $0 help"
	[ -e "$file" ] || die "Setting '$1' is not available (is ${MODNAME} loaded and does your model expose it?)"
	say "$(cat "$file")"
}

cmd_set() {
	[ $# -eq 2 ] || die "Usage: $0 set <setting> <value>"
	local name="$1" value="$2" file
	file="$(feature_file "$name")" || die "Unknown setting '$name'. See: $0 help"
	[ -e "$file" ] || die "Setting '$name' is not available (is ${MODNAME} loaded and does your model expose it?)"
	validate_value "$name" "$value"
	# Members of the linuwu_sense group can write these files directly; only
	# escalate when the user has no access (e.g. root-only settings).
	if [ ! -w "$file" ]; then
		ensure_root "$@"
	fi
	printf '%s\n' "$value" > "$file"
	ok "${name} = $(cat "$file")"
}

usage() {
	cat <<EOF
${BOLD}linuwu-sense.sh${RESET} - manage the Linuwu Sense Acer WMI kernel module

${BOLD}Usage${RESET}
  $0 <command> [arguments]

${BOLD}Commands${RESET}
  install                 Build and install for the running kernel, and load it
  uninstall               Unload, remove the module and all configuration it added
  reinstall               uninstall followed by install
  reload                  Reload the module and re-apply permissions
  build                   Build the module only
  clean                   Remove build artifacts
  status                  Show module, service and setting state (no root needed)
  get <setting>           Print the current value of a setting
  set <setting> <value>   Change a setting (asks for sudo)

${BOLD}Settings${RESET}
  platform-profile     low-power|quiet|balanced|balanced-performance|performance
  fan-speed            <cpu>[,<gpu>]  0-100 (0 = auto)
  battery-limiter      0|1
  battery-calibration  0|1  (1 starts a full charge/drain cycle)
  usb-charging         0|10|20|30
  backlight-timeout    0|1
  boot-animation-sound 0|1
  lcd-override         0|1
  four-zone-mode       mode,speed,brightness,direction,r,g,b
  per-zone-mode        rrggbb,rrggbb,rrggbb,rrggbb,brightness

Examples:
  sudo $0 install
  $0 status
  sudo $0 set platform-profile performance
  sudo $0 set fan-speed 50,70
  $0 get battery-limiter
EOF
}

main() {
	local cmd="${1:-help}"
	[ $# -gt 0 ] && shift || true
	case "$cmd" in
		install)   cmd_install "$@" ;;
		uninstall|remove) cmd_uninstall "$@" ;;
		reinstall) cmd_uninstall "$@"; cmd_install "$@" ;;
		reload)    cmd_reload "$@" ;;
		build)     cmd_build ;;
		clean)     cmd_clean ;;
		status)    cmd_status ;;
		get)       cmd_get "$@" ;;
		set)       cmd_set "$@" ;;
		help|-h|--help) usage ;;
		*)         usage >&2; die "Unknown command '$cmd'" ;;
	esac
}

main "$@"

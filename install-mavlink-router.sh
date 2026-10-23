#!/usr/bin/env bash
# Automated MAVLink Router installation for Raspberry Pi OS / Debian Trixie.
# Fixed configuration: /dev/ttyACM0 at 57600 baud -> UDP 10.0.0.4:14550.
# Also enables a TCP server on port 5760 for Mission Planner.
set -Eeuo pipefail

SERIAL_DEVICE='/dev/ttyACM0'
SERIAL_BAUD='57600'
UDP_DESTINATION='10.0.0.4'
UDP_PORT='14550'
TCP_PORT='5760'
SOURCE_DIR='/opt/mavlink-router'
CONFIG_DIR='/etc/mavlink-router'

trap 'printf "\nERROR at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

if (( EUID != 0 )); then
    echo 'Run this installer with: sudo bash install-mavlink-router.sh' >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo 'This installer requires Raspberry Pi OS or Debian with apt-get.' >&2
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # Inform users when running on a different OS version; dependencies may differ.
    . /etc/os-release
    if [[ "${VERSION_CODENAME:-}" != 'trixie' ]]; then
        printf 'Warning: intended for Trixie; detected %s.\n' "${VERSION_CODENAME:-unknown}"
    fi
fi

echo '[1/7] Installing build dependencies...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates git meson ninja-build pkg-config gcc g++ \
    systemd systemd-dev
pkg-config --modversion systemd

echo '[2/7] Fetching MAVLink Router and MAVLink headers...'
install -d -m 0755 /opt
if [[ -d "$SOURCE_DIR/.git" ]]; then
    echo "Using existing source at $SOURCE_DIR"
elif [[ -e "$SOURCE_DIR" ]]; then
    echo "ERROR: $SOURCE_DIR exists but is not a Git repository; refusing to overwrite." >&2
    exit 1
else
    git clone --recurse-submodules \
        https://github.com/mavlink-router/mavlink-router.git "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" submodule sync --recursive
git -C "$SOURCE_DIR" submodule update --init --recursive
if [[ ! -d "$SOURCE_DIR/modules/mavlink_c_library_v2/ardupilotmega" ]]; then
    echo 'ERROR: Missing ardupilotmega MAVLink header directory.' >&2
    exit 1
fi

echo '[3/7] Building MAVLink Router...'
cd "$SOURCE_DIR"
# Delete only generated build output so reruns recover from incomplete Meson setups.
rm -rf "$SOURCE_DIR/build"
meson setup build . --buildtype=release
ninja -C build

echo '[4/7] Installing MAVLink Router and its packaged systemd service...'
ninja -C build install
command -v mavlink-routerd >/dev/null

echo '[5/7] Writing the fixed MAVLink Router configuration...'
install -d -m 0755 "$CONFIG_DIR"
if [[ -f "$CONFIG_DIR/main.conf" && ! -f "$CONFIG_DIR/main.conf.pre-installer" ]]; then
    cp -a "$CONFIG_DIR/main.conf" "$CONFIG_DIR/main.conf.pre-installer"
fi
cat > "$CONFIG_DIR/main.conf" <<CONF
[General]
TcpServerPort = $TCP_PORT
ReportStats = true
DebugLogLevel = info

[UartEndpoint flight_controller]
Device = $SERIAL_DEVICE
Baud = $SERIAL_BAUD
FlowControl = false

[UdpEndpoint ground_station]
Mode = Normal
Address = $UDP_DESTINATION
Port = $UDP_PORT
CONF
chmod 0644 "$CONFIG_DIR/main.conf"

echo '[6/7] Making startup resilient to delayed USB serial detection...'
# Don't edit the packaged service: use a persistent systemd override.
install -d -m 0755 /etc/systemd/system/mavlink-router.service.d
cat > /etc/systemd/system/mavlink-router.service.d/10-serial-retry.conf <<OVERRIDE
[Unit]
StartLimitIntervalSec=0

[Service]
ExecStartPre=/usr/bin/test -c $SERIAL_DEVICE
Restart=always
RestartSec=5s
OVERRIDE
chmod 0644 /etc/systemd/system/mavlink-router.service.d/10-serial-retry.conf

echo '[7/7] Enabling MAVLink Router at boot...'
systemctl daemon-reload
systemctl enable mavlink-router.service
# A missing adapter should not make the software install itself fail.
if [[ -c "$SERIAL_DEVICE" ]]; then
    systemctl restart mavlink-router.service
else
    echo "Serial device $SERIAL_DEVICE not present yet."
    echo 'Starting service anyway; systemd will retry until the adapter is detected.'
    systemctl restart mavlink-router.service || true
fi

printf '\nInstallation and configuration completed.\n'
printf '  Serial input : %s at %s baud\n' "$SERIAL_DEVICE" "$SERIAL_BAUD"
printf '  UDP output   : %s:%s\n' "$UDP_DESTINATION" "$UDP_PORT"
printf '  TCP listener : port %s\n' "$TCP_PORT"
printf '  Config       : %s/main.conf\n' "$CONFIG_DIR"
if systemctl is-active --quiet mavlink-router.service; then
    echo '  Service      : active'
else
    echo '  Service      : not active yet; check serial connection and logs'
fi
printf '\nDiagnostics:\n'
printf '  systemctl status mavlink-router --no-pager\n'
printf '  journalctl -u mavlink-router -n 50 --no-pager\n'
printf '  ss -ltnp | grep :5760\n'

#!/usr/bin/env bash
# Automated MAVLink Router installation for Raspberry Pi OS / Debian Trixie.
# Fixed configuration: MCP2221 USB-UART at 115200 baud -> UDP 10.0.0.4:14550.
# Also enables a TCP server on port 5760 for Mission Planner.
# Configures a static Ethernet IPv4 address: 10.0.2.<drone number>/8 (11-254).
set -Eeuo pipefail

SERIAL_DEVICE='/dev/serial/by-id/usb-Microchip_Technology_Inc._MCP2221_USB-I2C_UART_Combo-if00'
SERIAL_BAUD='115200'
UDP_DESTINATION='10.0.0.4'
UDP_PORT='14550'
TCP_PORT='5760'
SOURCE_DIR='/opt/mavlink-router'
CONFIG_DIR='/etc/mavlink-router'
DEFAULT_ETHERNET_CONNECTION='Wired connection 1'

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

# Collect and validate settings before changing the system.
if ! command -v nmcli >/dev/null 2>&1; then
    echo 'ERROR: NetworkManager (nmcli) is required to configure a static wired IP.' >&2
    echo 'Install/configure NetworkManager first; this script will not replace your network manager.' >&2
    exit 1
fi

while true; do
    read -r -p 'Enter drone number (11-254): ' DRONE_NUMBER
    if [[ "$DRONE_NUMBER" =~ ^[0-9]+$ ]] &&
       (( 10#$DRONE_NUMBER >= 11 && 10#$DRONE_NUMBER <= 254 )); then
        DRONE_NUMBER=$((10#$DRONE_NUMBER))
        break
    fi
    echo 'Invalid drone number. Enter a whole number from 11 to 254 (10 and below are reserved).'
done
STATIC_IP="10.0.2.${DRONE_NUMBER}"

printf 'NetworkManager wired connection name [%s]: ' "$DEFAULT_ETHERNET_CONNECTION"
read -r ETH_CONNECTION
ETH_CONNECTION=${ETH_CONNECTION:-$DEFAULT_ETHERNET_CONNECTION}
if ! nmcli -g connection.id connection show "$ETH_CONNECTION" >/dev/null 2>&1; then
    printf 'ERROR: NetworkManager connection "%s" does not exist.\n' "$ETH_CONNECTION" >&2
    echo 'Available connections:' >&2
    nmcli -f NAME,TYPE,DEVICE connection show >&2
    exit 1
fi
CONNECTION_TYPE=$(nmcli -g connection.type connection show "$ETH_CONNECTION")
if [[ "$CONNECTION_TYPE" != '802-3-ethernet' ]]; then
    printf 'ERROR: "%s" is not an Ethernet connection (type: %s).\n' "$ETH_CONNECTION" "$CONNECTION_TYPE" >&2
    exit 1
fi
printf 'Ethernet will use %s/8, DHCP disabled (connection: %s).\n' "$STATIC_IP" "$ETH_CONNECTION"
echo 'WARNING: Applying this change can disconnect an active SSH session.'

echo '[1/8] Installing build dependencies...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates git meson ninja-build pkg-config gcc g++ \
    systemd systemd-dev
pkg-config --modversion systemd

echo '[2/8] Fetching MAVLink Router and MAVLink headers...'
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

echo '[3/8] Building MAVLink Router...'
cd "$SOURCE_DIR"
# Delete only generated build output so reruns recover from incomplete Meson setups.
rm -rf "$SOURCE_DIR/build"
meson setup build . --buildtype=release
ninja -C build

echo '[4/8] Installing MAVLink Router and its packaged systemd service...'
ninja -C build install
command -v mavlink-routerd >/dev/null

echo '[5/8] Writing the fixed MAVLink Router configuration...'
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

echo '[6/8] Making startup resilient to delayed USB serial detection...'
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

echo '[7/8] Enabling MAVLink Router at boot...'
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

echo '[8/8] Configuring wired Ethernet with a static IP and no DHCP...'
# ipv4.addresses replaces existing addresses (do NOT use +ipv4.addresses).
# No IPv4 gateway: the Pi can continue using a separate Wi-Fi connection for Internet.
nmcli connection modify "$ETH_CONNECTION" \
    ipv4.method manual \
    ipv4.addresses "$STATIC_IP/8" \
    ipv4.gateway '' \
    ipv4.dns '' \
    ipv4.ignore-auto-dns yes \
    ipv6.method disabled \
    connection.autoconnect yes
# Reapply only when active; otherwise activate. SSH over this interface may drop.
ACTIVE_DEVICE=$(nmcli -g GENERAL.DEVICES connection show "$ETH_CONNECTION" | head -n 1)
if [[ -n "$ACTIVE_DEVICE" && "$ACTIVE_DEVICE" != '--' ]]; then
    nmcli device reapply "$ACTIVE_DEVICE" || nmcli connection up "$ETH_CONNECTION"
else
    nmcli connection up "$ETH_CONNECTION"
fi

printf '\nInstallation and configuration completed.\n'
printf '  Serial input : %s at %s baud\n' "$SERIAL_DEVICE" "$SERIAL_BAUD"
printf '  UDP output   : %s:%s\n' "$UDP_DESTINATION" "$UDP_PORT"
printf '  TCP listener : port %s\n' "$TCP_PORT"
printf '  Config       : %s/main.conf\n' "$CONFIG_DIR"
printf '  Ethernet IP  : %s/8 (DHCP disabled)\n' "$STATIC_IP"
printf '  Connection   : %s\n' "$ETH_CONNECTION"
if systemctl is-active --quiet mavlink-router.service; then
    echo '  Service      : active'
else
    echo '  Service      : not active yet; check serial connection and logs'
fi
printf '\nDiagnostics:\n'
printf '  systemctl status mavlink-router --no-pager\n'
printf '  journalctl -u mavlink-router -n 50 --no-pager\n'
printf '  ss -ltnp | grep :5760\n'
printf '  nmcli -f GENERAL,IP4 connection show \"%s\"\n' "$ETH_CONNECTION"

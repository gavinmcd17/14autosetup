#!/usr/bin/env bash
# Diagnose MCP2221A -> MAVLink Router -> UDP ground station on Raspberry Pi OS.
set -Eeuo pipefail

SERIAL_DEVICE="${SERIAL_DEVICE:-/dev/serial/by-id/usb-Microchip_Technology_Inc._MCP2221_USB-I2C_UART_Combo-if00}"
BAUD="${BAUD:-57600}"
GCS_IP="${GCS_IP:-10.0.0.4}"
GCS_PORT="${GCS_PORT:-14550}"
DURATION="${DURATION:-15}"
SERVICE="${SERVICE:-mavlink-router.service}"
OUTDIR="${OUTDIR:-$PWD/mavlink-diag-$(date +%Y%m%d-%H%M%S)}"
SERVICE_WAS_ACTIVE=0
STOPPED_BY_SCRIPT=0

log() { printf '\n[%s] %s\n' "$(date +%T)" "$*" | tee -a "$OUTDIR/summary.txt"; }
warn() { printf 'WARNING: %s\n' "$*" | tee -a "$OUTDIR/summary.txt"; }
restore() {
  if (( STOPPED_BY_SCRIPT )); then
    log 'Restoring MAVLink Router service (originally active).'
    sudo systemctl start "$SERVICE" || warn 'Could not restart MAVLink Router.'
  fi
}
mkdir -p "$OUTDIR"
trap restore EXIT
trap 'exit 130' INT TERM

log 'MAVLink connection diagnostics'
printf 'Serial: %s\nBaud: %s\nGCS: %s:%s\nDuration: %ss\nOutput: %s\n' "$SERIAL_DEVICE" "$BAUD" "$GCS_IP" "$GCS_PORT" "$DURATION" "$OUTDIR" | tee -a "$OUTDIR/summary.txt"

log '1. System and USB device information'
uname -a > "$OUTDIR/system.txt" 2>&1 || true
lsusb > "$OUTDIR/lsusb.txt" 2>&1 || true
(ls -la /dev/serial/by-id/; ls -la /dev/ttyACM*) > "$OUTDIR/serial-devices.txt" 2>&1 || true
if [[ ! -e "$SERIAL_DEVICE" ]]; then
  warn "Serial device not found: $SERIAL_DEVICE"
  warn 'Check serial-devices.txt and set SERIAL_DEVICE=/dev/ttyACM0 if appropriate.'
else
  log "Resolved serial device: $(readlink -f "$SERIAL_DEVICE")"
fi

log '2. Network and routing'
(ip -brief address; ip route; ip route get "$GCS_IP"; ping -c 2 -W 1 "$GCS_IP") > "$OUTDIR/network.txt" 2>&1 || true

log '3. Current router state, configuration and recent logs'
if systemctl is-active --quiet "$SERVICE"; then SERVICE_WAS_ACTIVE=1; fi
systemctl status "$SERVICE" --no-pager > "$OUTDIR/router-status-before.txt" 2>&1 || true
systemctl cat "$SERVICE" > "$OUTDIR/router-unit.txt" 2>&1 || true
sudo journalctl -u "$SERVICE" -b --no-pager -n 120 > "$OUTDIR/router-journal-before.txt" 2>&1 || true

log '4. Observe UDP forwarding while router is running'
if (( SERVICE_WAS_ACTIVE == 0 )); then
  warn 'Router is not currently running; skipping live router UDP check.'
elif command -v tcpdump >/dev/null 2>&1; then
  sudo timeout "${DURATION}s" tcpdump -ni any -tt -c 150 "udp and host $GCS_IP and port $GCS_PORT" > "$OUTDIR/udp-capture.txt" 2>&1 || true
  log "UDP capture saved; observed $(grep -c ' IP ' "$OUTDIR/udp-capture.txt" || true) packet lines."
else
  warn 'tcpdump not installed; install with: sudo apt install tcpdump'
fi

log '5. Exclusive serial test (temporarily stop router)'
if (( SERVICE_WAS_ACTIVE )); then
  sudo systemctl stop "$SERVICE"
  STOPPED_BY_SCRIPT=1
fi
if [[ ! -e "$SERIAL_DEVICE" ]]; then
  warn 'Skipping serial decode: device not present.'
else
  REAL_DEVICE="$(readlink -f "$SERIAL_DEVICE")"
  sudo fuser -v "$REAL_DEVICE" > "$OUTDIR/serial-users.txt" 2>&1 || true
  if command -v stty >/dev/null 2>&1; then
    sudo stty -F "$SERIAL_DEVICE" "$BAUD" raw -echo -crtscts || warn 'Unable to set serial line settings'
  fi

  log 'Collecting raw UART bytes (no output sent to flight controller)'
  sudo timeout "${DURATION}s" cat "$SERIAL_DEVICE" > "$OUTDIR/uart-raw.bin" 2> "$OUTDIR/uart-read-errors.txt" || true
  if command -v xxd >/dev/null 2>&1; then
    xxd -l 512 "$OUTDIR/uart-raw.bin" > "$OUTDIR/uart-hex.txt" || true
  else
    od -Ax -tx1 -N 512 "$OUTDIR/uart-raw.bin" > "$OUTDIR/uart-hex.txt" || true
  fi
  log "Raw UART bytes captured: $(wc -c < "$OUTDIR/uart-raw.bin")"

  log 'Checking captured data for valid MAVLink 1/2 frames and heartbeat'
  if python3 -c 'import pymavlink' >/dev/null 2>&1; then
    python3 - "$OUTDIR/uart-raw.bin" > "$OUTDIR/mavlink-decode.txt" 2>&1 <<'PY'
import sys
from collections import Counter
from pymavlink.dialects.v20 import ardupilotmega as mavlink
p = mavlink.MAVLink(None)
counts = Counter()
errors = 0
with open(sys.argv[1], 'rb') as f:
    while block := f.read(4096):
        for b in block:
            try:
                msg = p.parse_char(bytes([b]))
            except Exception:
                errors += 1
                continue
            if msg:
                counts[msg.get_type()] += 1
print('Decoded MAVLink frames:', sum(counts.values()))
print('Parser errors:', errors)
print('Message types:', dict(counts.most_common(30)))
print('Heartbeat count:', counts['HEARTBEAT'])
PY
    cat "$OUTDIR/mavlink-decode.txt" | tee -a "$OUTDIR/summary.txt"
  else
    warn 'pymavlink unavailable; raw bytes saved. Install with: sudo apt install python3-pymavlink (if available) or use a venv.'
  fi
fi

log '6. Finish and restore service'
log "Results saved to $OUTDIR"
log 'Review summary.txt, mavlink-decode.txt, uart-hex.txt, router-journal-before.txt, udp-capture.txt.'

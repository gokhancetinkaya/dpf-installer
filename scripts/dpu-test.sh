#!/usr/bin/env bash
# dpu-test.sh - Standalone BlueField-3 DPU hardware validation.
#
# Runs on a Linux test bench (e.g. a RHEL host) as root and prints a
# PASS/FAIL verdict per installed BlueField DPU:
#
#   1. PCIe presence, link width, and serial number (lspci)
#   2. NIC firmware initialization (dmesg: probe success vs error -110)
#   3. Port count and link status (sysfs netdevs, carrier, speed)
#   4. rshim availability and PCI mapping (when the rshim driver is loaded)
#   5. Optional (--reflash <bfb>): BFB push via bfb-install. The verdict is
#      derived from the boot-chain signatures (BL2 -> UEFI -> eMMC -> kernel):
#      "eMMC access fail" fails, a completed chain passes even if bfb-install
#      times out afterwards (the RHCOS BFB cannot finish installing without a
#      DPF cfg; that is expected on a standalone bench). The captured console
#      also yields the boot-ROM SKU lines (part number, DDR size, cores).
#      With --force the push also targets firmware-dead DPUs: it cannot
#      revive the NIC firmware, but a full boot chain isolates the failure
#      to the NIC side, which is exactly the evidence an RMA case needs.
#
# Non-destructive by default. --reflash overwrites the DPU's eMMC OS and
# needs bfb-install on the host (DOCA host tools).
#
# Exit code: 0 = every DPU passed, 1 = at least one failed or was unknown.
#
# Usage:
#   sudo ./dpu-test.sh
#   sudo ./dpu-test.sh --reflash                     # default BFB (see DEFAULT_BFB)
#   sudo ./dpu-test.sh --reflash /path/to/bundle.bfb # or an http(s) URL
#   sudo ./dpu-test.sh --reflash --force             # also push to firmware-dead DPUs
#                                                    # (ARM-side boot-chain test; cannot fix the NIC fw)
#
# Evidence for a failed DPU (RMA): the lines this tool prints plus, in
# --reflash mode, the captured console log under /tmp/dpu-test-*.
set -u

# Default BFB for --reflash: the same RHCOS-for-BlueField bundle the installer
# deploys. Keep in sync with BFB_URL in .env.example.
DEFAULT_BFB="https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/10.2.20260715-0/aarch64/rhcos-10.2.20260715-0-nvidiabluefield.aarch64.bfb"

REFLASH=0
REFLASH_FORCE=0
REFBFB=""
for arg in "$@"; do
  case "$arg" in
    --reflash) REFLASH=1 ;;
    --force) REFLASH_FORCE=1; REFLASH=1 ;;
    --*) echo "Usage: sudo $0 [--reflash [--force] [bfb-path-or-url]]" >&2; exit 2 ;;
    *) REFBFB="$arg" ;;
  esac
done
[[ -n "$REFBFB" ]] || REFBFB="$DEFAULT_BFB"
if (( REFLASH )); then
  command -v bfb-install >/dev/null 2>&1 || { echo "ERROR: bfb-install not found (the RHEL rshim package provides it)" >&2; exit 2; }
fi

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (dmesg and rshim access)" >&2; exit 2; }
command -v lspci >/dev/null 2>&1 || { echo "ERROR: lspci not found (pciutils)" >&2; exit 2; }

DMESG="$(dmesg 2>/dev/null || true)"

# The serial sits in the PCIe Vital Product Data. The [SN] line reads
# "[SN] Serial number: MT2410X00188", so the serial is its last token.
vpd_block() {
  lspci -vvv -s "$1" 2>/dev/null | awk '/Vital Product Data/{flag=1; next} flag{print; if(++n>9) exit}'
}

get_serial() {
  local block sn
  block="$(vpd_block "$1")"
  sn="$(grep '\[SN\]' <<<"$block" | awk '{print $NF}' | tr -d '[:space:]')"
  [[ -n "$sn" ]] || sn="$(grep -oE 'SN: *[A-Za-z0-9-]+' <<<"$block" | awk '{print $NF}')"
  printf '%s' "$sn"
}

get_product() {
  vpd_block "$1" | grep 'Product Name:' | sed 's/^[[:space:]]*Product Name:[[:space:]]*//' | cut -c1-60
}

# Set up rshim access (and bfb-install, which ships in the same package).
# RHEL's "rshim" package provides a userspace daemon that creates /dev/rshim*
# and the tmfifo interfaces. Two quirks are handled here:
#   - the stock systemd unit fails under SELinux enforcing (init_t cannot
#     open PCI sysfs resources), so the daemon is spawned directly from this
#     tool's unconfined root shell;
#   - the rshimN <-> PCI mapping is pinned in /etc/rshim.conf so attribution
#     is deterministic (only when the config is still at its commented-out
#     default; an existing mapping is never touched).
ensure_rshim() {
  local wrote_conf=0 i=0 slot n
  if ! grep -qE '^[^#[:space:]]' /etc/rshim.conf 2>/dev/null; then
    wrote_conf=1
  fi
  if [[ $wrote_conf -eq 0 ]] && ls -d /dev/rshim* >/dev/null 2>&1; then
    return 0
  fi
  echo "Setting up rshim (userspace daemon; the RHEL rshim package also provides bfb-install)..."
  if ! command -v rshim >/dev/null 2>&1; then
    if ! dnf install -y -q rshim >/dev/null 2>&1; then
      echo "  Note: could not install the rshim package (dnf failed). ARM-side and"
      echo "        reflash tests are skipped. Install it manually, or build"
      echo "        github.com/Mellanox/rshim."
      return 1
    fi
    echo "  Installed the rshim package."
  fi
  if [[ $wrote_conf -eq 1 ]]; then
    : >/etc/rshim.conf
    for slot in "${SLOTS[@]}"; do
      echo "rshim${i}  pcie-${slot}.1" >>/etc/rshim.conf
      i=$((i + 1))
    done
    echo "  Pinned the rshim <-> PCI mapping in /etc/rshim.conf."
  fi
  systemctl stop rshim >/dev/null 2>&1 || true
  pkill -x rshim >/dev/null 2>&1 || true
  sleep 1
  nohup /usr/sbin/rshim -f >/dev/null 2>&1 &
  n=0
  while (( n < 10 )); do
    if ls -d /dev/rshim* >/dev/null 2>&1; then
      echo "  rshim is up (/dev/rshim* and tmfifo interfaces)."
      echo "  Note: the daemon is spawned directly by this tool because the stock"
      echo "        systemd unit is confined by SELinux; re-run the tool after a reboot."
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  echo "  Note: the rshim daemon did not create /dev/rshim* (check journalctl)."
  echo "        ARM-side and reflash tests are skipped."
  return 1
}

# Map an rshim device (e.g. rshim0) to the DPU at PCI slot $1: via sysfs
# when the kernel module is used, or via the /etc/rshim.conf static mapping
# when the userspace daemon is used.
rshim_for_slot() {
  local r dev name
  for r in /sys/class/rshim/rshim*; do
    [[ -e "$r" ]] || continue
    dev="$(readlink -f "$r/device" 2>/dev/null || true)"
    if [[ "$dev" == *"$1"* ]]; then
      basename "$r"
      return 0
    fi
  done
  if [[ -f /etc/rshim.conf ]]; then
    name="$(awk -v slot="$1" '$2 == "pcie-" slot ".1" { print $1; exit }' /etc/rshim.conf 2>/dev/null)"
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  return 1
}

REFLASH_TMP=""
cleanup() { [[ -n "$REFLASH_TMP" && -f "$REFLASH_TMP" ]] && rm -f "$REFLASH_TMP"; }
trap cleanup EXIT

echo "==================================================================="
echo " BlueField DPU hardware validation  ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "==================================================================="

# One DPU per PCI slot (functions .0 = NIC, .1 = SoC management interface).
mapfile -t SLOTS < <(lspci -D -d 15b3: 2>/dev/null | grep -i bluefield | awk '{print $1}' | sed 's/\.[0-9a-f]*$//' | sort -u)

if [[ ${#SLOTS[@]} -eq 0 ]]; then
  echo "FAIL: no BlueField DPUs found on the PCIe bus."
  exit 1
fi

plain_nics=$(lspci -d 15b3: 2>/dev/null | grep -icv bluefield || true)
if (( plain_nics > 0 )); then
  echo "Note: ${plain_nics} Mellanox function(s) are not BlueField DPUs (plain"
  echo "      NICs such as ConnectX) and are skipped."
fi

RSHIM_OK=0
ensure_rshim && RSHIM_OK=1

if (( REFLASH )) && [[ $RSHIM_OK -eq 1 ]] && ! command -v bfb-install >/dev/null 2>&1; then
  echo "ERROR: bfb-install is still unavailable (the rshim package provides it)" >&2
  exit 2
fi
echo ""

OVERALL=0
declare -a SUM_SLOT=() SUM_VERDICT=() SUM_REASON=()

for slot in "${SLOTS[@]}"; do
  pf0="${slot}.0"
  mgmt="${slot}.1"

  echo "-------------------------------------------------------------------"
  serial="$(get_serial "$pf0")"
  [[ -n "$serial" ]] || serial="$(get_serial "$mgmt")"
  [[ -n "$serial" ]] || serial="unknown (query the host BMC)"
  product="$(get_product "$pf0")"
  echo "DPU ${slot}  (serial: ${serial})"
  [[ -n "$product" ]] && echo "  Product:           ${product}"
  echo "-------------------------------------------------------------------"

  # 1. PCIe link
  pcie_line="$(grep "mlx5_core ${pf0}:" <<<"$DMESG" | grep -m1 'available PCIe bandwidth' || true)"
  if [[ -n "$pcie_line" ]]; then
    echo "  PCIe:              ${pcie_line##*available }"
  else
    echo "  PCIe:              present (no bandwidth line in dmesg)"
  fi

  # 2. NIC firmware init verdict
  fw_dead_line="$(grep "mlx5_core ${pf0}:" <<<"$DMESG" | grep -m1 'failed with error' || true)"
  fw_ver_line="$(grep "mlx5_core ${pf0}:" <<<"$DMESG" | grep -m1 'firmware version' || true)"
  if [[ -n "$fw_dead_line" ]]; then
    echo "  NIC firmware:      FAILED"
    grep "mlx5_core ${pf0}:" <<<"$DMESG" | grep -E 'wait_fw_init|failed with error' | tail -2 | sed 's/^/     /'
    verdict="FAIL"
    reason="NIC firmware failed to initialize (probe error)"
  elif [[ -n "$fw_ver_line" ]]; then
    echo "  NIC firmware:      ok (${fw_ver_line##*version: })"
    verdict="PASS"
    reason="firmware initialized"
  else
    echo "  NIC firmware:      UNKNOWN (no mlx5_core messages; is the driver loaded?)"
    verdict="UNKNOWN"
    reason="no mlx5 evidence in dmesg"
  fi

  # 3. Ports and link
  netdevs="$(ls "/sys/bus/pci/devices/${pf0}/net/" 2>/dev/null || true)"
  port_count=$(wc -w <<<"$netdevs")
  port_note=""
  if [[ "$port_count" -eq 1 ]]; then
    port_note=" (single-port SKU: healthy hardware, but outside the DPF-supported model list)"
  elif [[ "$port_count" -ge 2 ]]; then
    port_note=" (dual-port)"
  fi
  echo "  Ports:             ${port_count}${port_note}"
  for if_name in $netdevs; do
    carrier="$(cat "/sys/class/net/${if_name}/carrier" 2>/dev/null || echo '?')"
    speed="$(cat "/sys/class/net/${if_name}/speed" 2>/dev/null || echo '?')"
    if [[ "$carrier" == "1" ]]; then
      echo "  Link ${if_name}:         up (${speed} Mb/s)"
    else
      echo "  Link ${if_name}:         down (no cable / no partner)"
    fi
  done

  # 4. rshim mapping
  rshim_dev=""
  if [[ $RSHIM_OK -eq 1 ]]; then
    if rshim_dev="$(rshim_for_slot "$slot")"; then
      echo "  rshim:             ${rshim_dev} (/dev/${rshim_dev})"
    else
      echo "  rshim:             no rshim device maps to this DPU"
    fi
  fi

  # 5. Optional BFB reflash (the definitive storage + boot-chain test)
  if (( REFLASH )); then
    if [[ -z "$rshim_dev" ]]; then
      echo "  Reflash:           SKIPPED (no rshim for this DPU)"
    elif [[ "$verdict" == "FAIL" && "$REFLASH_FORCE" != "1" ]]; then
      echo "  Reflash:           SKIPPED (dead NIC firmware; a reflash cannot fix it)"
      echo "     Use --reflash --force to test the ARM-side boot chain anyway."
    else
      if [[ "$verdict" == "FAIL" ]]; then
        echo "  Reflash:           forced on a firmware-dead DPU (ARM-side boot-chain test)"
      fi
      tag="/tmp/dpu-test-${slot//[:.]/_}"
      bfb_file=""
      if [[ "$REFBFB" == http://* || "$REFBFB" == https://* ]]; then
        REFLASH_TMP="${tag}.bfb"
        echo "  Reflash:           downloading BFB..."
        if curl -fLsk --retry 3 -o "$REFLASH_TMP" "$REFBFB"; then
          bfb_file="$REFLASH_TMP"
        else
          echo "  Reflash:           FAILED to download BFB"
          verdict="FAIL"; reason="BFB download failed"
          REFLASH_TMP=""
        fi
      else
        bfb_file="$REFBFB"
      fi
      if [[ -n "$bfb_file" ]]; then
        echo "  Reflash:           streaming BFB via ${rshim_dev} (push + boot chain)..."
        cat "/dev/${rshim_dev}/console" >"${tag}-console.log" 2>/dev/null &
        cat_pid=$!
        timeout 2400 bfb-install --bfb "$bfb_file" --rshim "$rshim_dev" >"${tag}-bfb-install.log" 2>&1 &
        bfb_pid=$!
        # Wait for a decisive boot-chain signature (or for bfb-install to
        # finish on its own). The hardware verdict does not require the OS
        # install to complete: the RHCOS BFB cannot finish without a DPF cfg
        # (it drops to emergency mode waiting for ignition), so once the
        # chain signature is in the log the result is known and the wait
        # ends instead of running out the full timeout.
        waited=0
        while kill -0 "$bfb_pid" 2>/dev/null && (( waited < 2400 )); do
          if grep -q 'eMMC access fail' "${tag}-bfb-install.log" "${tag}-console.log" 2>/dev/null; then
            break
          fi
          if grep -q 'exit Boot Service' "${tag}-bfb-install.log" "${tag}-console.log" 2>/dev/null; then
            sleep 90   # let the kernel boot for the record
            break
          fi
          sleep 10
          waited=$((waited + 10))
        done
        kill "$bfb_pid" 2>/dev/null || true
        wait "$bfb_pid" 2>/dev/null || true
        kill "$cat_pid" 2>/dev/null || true
        wait "$cat_pid" 2>/dev/null || true
        if grep -q 'eMMC access fail' "${tag}-bfb-install.log" "${tag}-console.log" 2>/dev/null; then
          echo "  Reflash:           FAILED - eMMC access failure on the DPU boot console"
          verdict="FAIL"; reason="eMMC failed during BFB install"
        elif grep -q 'exit Boot Service' "${tag}-bfb-install.log" "${tag}-console.log" 2>/dev/null; then
          echo "  Reflash:           PASSED - full boot chain verified (BL2 -> UEFI -> eMMC"
          echo "     probed -> kernel boot). The OS install itself does not complete"
          echo "     without a DPF cfg; that is expected on a standalone bench."
        elif grep -q 'boot mode (rshim)' "${tag}-bfb-install.log" "${tag}-console.log" 2>/dev/null; then
          echo "  Reflash:           FAILED - boot ROM engaged but the chain did not complete"
          verdict="FAIL"; reason="BFB boot chain stalled after BL2"
        else
          echo "  Reflash:           FAILED - the boot stream never engaged (no BL2 output)"
          verdict="FAIL"; reason="DPU never consumed the BFB stream"
        fi
        # The boot ROM prints the card's SKU (part number, DDR size, core
        # count, onboard NVMe) to the console while booting - the cleanest
        # source for those facts; the PCIe VPD does not carry them.
        sku_info="$(grep -aE 'Running as|Memory Available|Cores r0p|NVMe Device' "${tag}-console.log" 2>/dev/null | tr -d '\r' | head -6 || true)"
        if [[ -n "$sku_info" ]]; then
          echo "  Boot-ROM SKU (from the console log):"
          sed 's/^/     /' <<<"$sku_info"
        fi
        echo "  Reflash evidence:  ${tag}-console.log and ${tag}-bfb-install.log"
      fi
    fi
  fi

  echo "  VERDICT:           ${verdict} - ${reason}"
  echo ""
  SUM_SLOT+=("$slot"); SUM_VERDICT+=("$verdict"); SUM_REASON+=("$reason")
  [[ "$verdict" == "PASS" ]] || OVERALL=1
done

echo "==================================================================="
echo " SUMMARY"
echo "==================================================================="
for i in "${!SUM_SLOT[@]}"; do
  printf '  %-16s %-8s %s\n' "${SUM_SLOT[$i]}" "${SUM_VERDICT[$i]}" "${SUM_REASON[$i]}"
done
echo ""
if [[ $OVERALL -eq 0 ]]; then
  echo " RESULT: all BlueField DPUs passed."
else
  echo " RESULT: at least one DPU failed or is unknown. For a failed DPU, attach"
  echo "         this output (and the --reflash console log) to the RMA case."
fi
exit $OVERALL

#!/usr/bin/env bash
# Boot an existing Lambda64 image directly.
#
# A snapshotted image resumes: every thread, the desktop and the network stack
# come back from the image, so nothing is compiled and no host file server is
# needed.  That is the difference from `make hvf-arm64`, which exists to bring a
# cold image up for the first time.
#
# If you change something the guest then has to compile -- see
# docs/development/rebuild-matrix.md -- start `make run-file-server` as well.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

image="$repo_root/lambda64.image"
memory=4G
cpus=4
resolution=1280x800
accel=""
serial_log=""
monitor_sock=""
swank_port=4005
snapshot=false

usage() {
    cat <<'USAGE'
Usage: scripts/boot-image.sh [options]

  --image PATH        Image to boot (default: lambda64.image)
  --memory SIZE       Guest memory (default: 4G; below 4G stage four cannot run)
  --cpus N            vCPUs (default: 4; the ARM64 guest currently uses one)
  --resolution WxH    Framebuffer size (default: 1280x800)
  --accel NAME        hvf | kvm | tcg (default: hvf on Apple Silicon, else tcg)
  --serial-log PATH   Tee serial output to PATH as well as the terminal
  --monitor PATH      Expose the QEMU monitor on a unix socket at PATH
  --swank-port N      Host port forwarded to guest 4005 (default: 4005)
  --snapshot          Discard guest writes on exit (-snapshot); leaves the image
                      untouched, so the system cannot save its state
  -h, --help          This message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)       image=$2; shift 2 ;;
        --memory)      memory=$2; shift 2 ;;
        --cpus)        cpus=$2; shift 2 ;;
        --resolution)  resolution=$2; shift 2 ;;
        --accel)       accel=$2; shift 2 ;;
        --serial-log)  serial_log=$2; shift 2 ;;
        --monitor)     monitor_sock=$2; shift 2 ;;
        --swank-port)  swank_port=$2; shift 2 ;;
        --snapshot)    snapshot=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -f "$image" ]] || { echo "No such image: $image" >&2; exit 1; }
[[ -s "$image" ]] || { echo "Image is empty: $image" >&2; exit 1; }

if [[ -z "$accel" ]]; then
    if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then accel=hvf
    elif [[ -r /dev/kvm ]]; then accel=kvm
    else accel=tcg; fi
fi
case "$accel" in
    hvf|kvm) cpu_model=host ;;
    tcg)     cpu_model=max ;;
    *) echo "Unknown accelerator: $accel" >&2; exit 2 ;;
esac

# QEMU binds the forwarded port at startup, so a second instance fails here
# rather than somewhere confusing later.
if command -v lsof >/dev/null 2>&1 &&
   lsof -nP -iTCP:"$swank_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $swank_port is already in use -- another guest is probably running." >&2
    echo "Stop it, or pass --swank-port with a free port." >&2
    exit 1
fi

xres=${resolution%x*}
yres=${resolution#*x}

args=(
    -machine virt -accel "$accel" -cpu "$cpu_model"
    -name Lambda64-arm64
    -m "$memory" -smp "$cpus"
    -kernel "$repo_root/Lambda64/tools/kboot/kboot-generic-arm64.bin"
    -serial stdio
    -no-reboot
    -device "virtio-gpu-device,xres=$xres,yres=$yres"
    -device virtio-keyboard-device
    -device virtio-mouse-device
    -drive "if=none,file=$image,id=blk,format=raw"
    -device virtio-blk-device,drive=blk
    -netdev "user,id=vmnic,hostname=lambda64,hostfwd=tcp:127.0.0.1:$swank_port-:4005"
    -device virtio-net-device,netdev=vmnic
    -semihosting-config enable=on,target=native
)

if [[ -n "$monitor_sock" ]]; then
    rm -f "$monitor_sock"
    args+=(-monitor "unix:$monitor_sock,server,nowait")
else
    args+=(-monitor none)
fi

$snapshot && args+=(-snapshot)

echo "image       $image"
echo "accelerator $accel ($cpu_model)"
echo "guest       $memory, $cpus vCPU, $resolution"
echo "swank       localhost:$swank_port"
[[ -n "$monitor_sock" ]] && echo "monitor     $monitor_sock"
$snapshot && echo "writes      discarded on exit (--snapshot)"
echo

if [[ -n "$serial_log" ]]; then
    mkdir -p "$(dirname "$serial_log")"
    exec qemu-system-aarch64 "${args[@]}" 2>&1 | tee "$serial_log"
else
    exec qemu-system-aarch64 "${args[@]}"
fi

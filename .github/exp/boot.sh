#!/bin/bash
# boot.sh <disk.qcow2> <workdir> [ssh-port]: boot an OmniOS cloud image (or a
# layer on top of one) in QEMU/KVM and wait until root can log in with
# <workdir>/vmkey over ssh on 127.0.0.1:<ssh-port> (default 2222).
# A NoCloud seed CD gives cloud-init the key; the image's own cloud-init then
# makes fresh SSH host keys. SSH is forwarded on loopback only.
#
# Environment:
#   VM_CPUS        vCPUs (default 4: a standard GitHub Linux runner's count)
#   VM_MEM         MB of RAM (default 8192)
#   VM_DISK_CACHE  QEMU cache mode for <disk> (default writeback). A job's
#                  throwaway overlay can use "unsafe": guest flushes are
#                  ignored, so ZFS commits stop waiting for the host disk,
#                  and a host crash loses data that is thrown away anyway.
#                  Never use it for a disk that is kept, such as an image
#                  layer being built.
#
# QEMU options:
#   -machine pc,hpet=off,smm=off,vmport=off
#       no HPET: QEMU emulates it in userspace, so every guest access is a
#       VM exit; illumos then times with the TSC and the local APIC timer.
#       No System Management Mode and no VMware backdoor port, which this
#       guest never uses.
#   -cpu host,kvm=on,+hypervisor,l3-cache=on,migratable=no,+invtsc,pmu=off
#       the runner's CPU features. kvm=on and +hypervisor (QEMU's defaults,
#       spelled out) tell the guest it is a KVM guest. l3-cache=on reports
#       an L3 shared by the vCPUs, so the scheduler sees cores sharing a
#       cache. migratable=no allows host-only features, among them +invtsc,
#       which promises a constant-rate TSC the guest can use as its clock
#       (illumos has no kvmclock driver). pmu=off hides the performance
#       counters: some guests fault writing counter MSRs a runner's CPU
#       generation lacks.
#   -smp N,sockets=1,cores=N,threads=1
#       one socket of N cores, which QEMU 8.2 picks anyway; explicit so
#       l3-cache=on describes one shared cache.
#   -global kvm-pit.lost_tick_policy=delay
#       PIT ticks missed while the host is busy arrive late instead of
#       being dropped, so time kept in PIT ticks does not fall behind.
#   -object iothread + virtio-blk-pci,iothread=
#       disk I/O in its own thread, not QEMU's main loop. aio=io_uring.
#       discard=unmap,detect-zeroes=unmap keep the qcow2 sparse.
#   -nic user,model=e1000
#       deliberate: the image's vioif fails to map its BAR under QEMU's
#       virtio-net ("Failed to map CAP 1").
# Same as anyvm (vmactions) except the disk options; measured 2% faster on
# the same runner CPU model, within noise.
set -euo pipefail
disk=$1 work=$2 port=${3:-2222}
cpus=${VM_CPUS:-4} mem=${VM_MEM:-8192} cache=${VM_DISK_CACHE:-writeback}
cd "$work"
[ -f vmkey ] || ssh-keygen -q -t ed25519 -N '' -f vmkey
cat > user-data <<EOF
#cloud-config
disable_root: false
ssh_authorized_keys:
  - $(cat vmkey.pub)
EOF
printf 'instance-id: nut-ci-%s\nlocal-hostname: omnios\n' "$(date +%s%N)" > meta-data
cloud-localds seed.iso user-data meta-data
rm -f console.log
qemu-system-x86_64 -enable-kvm \
  -machine pc,hpet=off,smm=off,vmport=off \
  -cpu host,kvm=on,+hypervisor,l3-cache=on,migratable=no,+invtsc,pmu=off \
  -smp "$cpus,sockets=1,cores=$cpus,threads=1" -m "$mem" \
  -global kvm-pit.lost_tick_policy=delay \
  -display none -monitor none -serial file:console.log \
  -object iothread,id=io0 \
  -drive file="$disk",if=none,id=disk0,cache="$cache",aio=io_uring,discard=unmap,detect-zeroes=unmap \
  -device virtio-blk-pci,drive=disk0,iothread=io0 \
  -drive file=seed.iso,media=cdrom,readonly=on \
  -nic user,model=e1000,hostfwd=tcp:127.0.0.1:"$port"-:22 \
  > qemu.out 2>&1 < /dev/null &
echo $! > qemu.pid
for i in $(seq 1 60); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=5 -o LogLevel=ERROR -i vmkey -p "$port" root@127.0.0.1 true 2>/dev/null; then
    echo "boot.sh: ssh up after $((i * 5)) s"; exit 0
  fi
  kill -0 "$(cat qemu.pid)" 2>/dev/null || { echo "boot.sh: QEMU exited"; cat qemu.out; exit 1; }
  sleep 5
done
echo "boot.sh: no ssh after 300 s; console tail:"; tail -30 console.log | tr -d '\r'; exit 1

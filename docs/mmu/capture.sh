#!/usr/bin/env bash

# 在 mini-virt 的现有 build profile 中生成微测及调试日志
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)
cd "${REPO_ROOT}"
./vm/build-profile.sh require aarch64/mini-virt qemu/build
./vm/build-profile.sh require aarch64/mini-virt linux/build
out=qemu/build/mmu-probe
mkdir -p "${out}"
aarch64-linux-gnu-as -g -o "${out}/probe.o" "${SCRIPT_DIR}/probe.S"
aarch64-linux-gnu-ld -T "${SCRIPT_DIR}/probe.ld" -o "${out}/probe.elf" "${out}/probe.o"
aarch64-linux-gnu-objcopy -O binary "${out}/probe.elf" "${out}/probe.bin"
timeout 60s gdb -q -batch -x "${SCRIPT_DIR}/probe.gdb" --args \
    qemu/build/qemu-system-aarch64 \
    -machine mini-virt -accel tcg,thread=single -smp 2 -m 4G \
    -display none -serial none -monitor none \
    -kernel "${out}/probe.bin" \
    -dtb linux/build/arch/arm64/boot/dts/demo/mini-virt.dtb \
    -semihosting-config enable=on,target=native \
    -d in_asm,out_asm,op,int,trace:qemu_anon_ram_alloc,trace:memory_notdirty_write_access,trace:memory_notdirty_set_dirty \
    -D "${out}/combined.log" > "${out}/gdb.log" 2>&1
python3 "${SCRIPT_DIR}/decode-log.py" "${out}/combined.log" > "${out}/decoded.log"
rg -q 'MMU probe: PASS' "${out}/gdb.log"
rg -q 'exited normally' "${out}/gdb.log"
rg 'MMU probe: PASS|DATA HELPER TOTALS' "${out}/gdb.log"
if rg -q 'Python Exception|MMU probe: FAIL' "${out}/gdb.log"; then
    exit 1
fi

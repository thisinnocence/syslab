#!/bin/sh

# 通过 CPU hotplug 验证 CPU1 的 PSCI 上下电，结束时恢复双核在线
set -eu
CPU=/sys/devices/system/cpu
ONLINE="$CPU/cpu1/online"

fail()
{
    echo "psci test: FAIL: $*" >&2
    exit 1
}

[ -w "$ONLINE" ] || fail "cpu1/online unavailable (CONFIG_HOTPLUG_CPU)"
[ "$(cat "$CPU/present")" = "0-1" ] || fail "expected two present CPUs"
[ "$(cat "$CPU/online")" = "0-1" ] || fail "expected both CPUs online at boot"

# 测试失败或收到信号后也尝试恢复 CPU1，恢复失败必须返回非零
trap 'echo 1 > "$ONLINE" || exit 1' EXIT
trap 'exit 1' HUP INT TERM
for round in 1 2 3; do
    echo 0 > "$ONLINE"
    [ "$(cat "$ONLINE")" = "0" ] || fail "CPU1 did not go offline"
    [ "$(cat "$CPU/online")" = "0" ] || fail "CPU0 should remain online"
    [ "$(cat "$CPU/present")" = "0-1" ] || fail "CPU1 should remain present"
    echo "round $round: CPU1 offline; CPU0 online"
    echo 1 > "$ONLINE"
    [ "$(cat "$ONLINE")" = "1" ] || fail "CPU1 did not come online"
    [ "$(cat "$CPU/online")" = "0-1" ] || fail "expected two online CPUs"
    echo "round $round: CPU1 online"
done
trap - EXIT HUP INT TERM
echo "psci test: PASS"

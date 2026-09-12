set pagination off
set confirm off
set width 0
set print frame-arguments all
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass

python
import gdb
from pathlib import Path

# 从 repository root 启动 GDB，原样保存 bt，不拼接或改写栈帧
out = Path("/tmp/syslab-psci-gdb")
out.mkdir(exist_ok=True)

class Capture(gdb.Breakpoint):
    def __init__(self, location, name, condition=None, values=()):
        super().__init__(location)
        self.name = name
        self.values = values
        self.filter_expression = condition

    def stop(self):
        if self.filter_expression and not bool(gdb.parse_and_eval(self.filter_expression)):
            return False
        (out / (self.name + ".bt")).write_text(gdb.execute("bt", to_string=True))
        with (out / (self.name + ".state")).open("w") as stream:
            stream.write(gdb.execute("info threads", to_string=True))
            for expression in self.values:
                stream.write("(gdb) p " + expression + "\n")
                stream.write(gdb.execute("p " + expression, to_string=True))
        self.enabled = False
        return False

def source_line(path, token):
    lines = Path(path).read_text().splitlines()
    return str(Path(path).resolve()) + ":" + str(next(i for i, line in enumerate(lines, 1) if token in line))

Capture("do_cpu_reset", "01-primary-reset", "((CPUState *)opaque)->cpu_index == 0")
Capture("arm_set_cpu_on", "02-cpu-on", "cpuid == 1")
Capture("arm_set_cpu_on_async_work", "03-cpu-on-callback", "target_cpu_state->cpu_index == 1")
Capture(source_line("qemu/target/arm/arm-powerctl.c", "trace_arm_powerctl_cpu_on_complete"),
        "04-cpu-on-complete", "target_cpu_state->cpu_index == 1",
        ("target_cpu->power_state", "target_cpu_state->halted", "target_cpu->env.pc", "target_cpu->env.xregs[0]"))
Capture("helper_pre_smc", "05-cpu-off-smc", "env->xregs[0] == 0x84000002",
        ("env->pc", "env->xregs[0]", "env->xregs[1]"))
Capture("arm_cpu_do_interrupt", "06-cpu-off-interrupt",
        "cs->cpu_index == 1 && ((ARMCPU *)cs)->env.xregs[0] == 0x84000002",
        ("cs->exception_index", "((ARMCPU *)cs)->env.exception"))
Capture("arm_handle_psci_call", "07-cpu-off-dispatch", "cpu->env.xregs[0] == 0x84000002")
Capture("arm_set_cpu_off", "08-cpu-off", "cpuid == 1")
Capture("async_run_on_cpu", "09-cpu-off-async", "func == arm_set_cpu_off_async_work",
        ("cpu", "cpu->cpu_index", "func", "((ARMCPU *)cpu)->power_state"))
Capture("queue_work_on_cpu", "10-cpu-off-queue", "wi->func == arm_set_cpu_off_async_work",
        ("cpu", "wi", "*wi"))
Capture("arm_set_cpu_off_async_work", "11-cpu-off-callback", "target_cpu_state->cpu_index == 1",
        ("target_cpu_state", "((ARMCPU *)target_cpu_state)->power_state", "target_cpu_state->halted"))
Capture(source_line("qemu/target/arm/arm-powerctl.c", "trace_arm_powerctl_cpu_off_complete"),
        "12-cpu-off-complete", "target_cpu_state->cpu_index == 1",
        ("target_cpu->power_state", "target_cpu_state->halted", "target_cpu_state->exception_index"))
end
run

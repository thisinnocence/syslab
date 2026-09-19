/* mini-virt MMU 微测：代码恒等映射，数据使用非恒等映射 */
.section .text.boot, "ax"
.global _start
_start:
    b boot
    .long 0
    .quad 0x80000
    .quad image_end - _start
    .quad 0
    .quad 0, 0, 0
    .long 0x644d5241
    .long 0
boot:
    mrs x0, CurrentEL
    cmp x0, #8
    b.ne el1
    mov x0, #(1 << 31)
    msr hcr_el2, x0
    adr x0, el1
    msr elr_el2, x0
    mov x0, #0x3c5
    msr spsr_el2, x0
    eret
el1:
    adr x0, vectors
    msr vbar_el1, x0
    /* 三张 4 KiB 表，L1[1] 为代码，L1[2] 为数据 */
    adr x0, root
    adr x1, code_l2
    orr x1, x1, #3
    str x1, [x0, #8]
    adr x1, data_l2
    orr x1, x1, #3
    str x1, [x0, #16]
    adr x1, code_l2
    ldr x2, =0x40000701
    str x2, [x1]
    adr x1, data_l2
    ldr x2, =0x0060000041000701
    str x2, [x1]
    /* 同一 PA 的只读别名：AP=10，PXN=UXN=1 */
    ldr x2, =0x0060000041000781
    str x2, [x1, #8]
    msr ttbr0_el1, x0
    mov x0, #0xff
    msr mair_el1, x0
    ldr x0, =0x200803519
    msr tcr_el1, x0
    dsb sy
    tlbi vmalle1
    dsb sy
    isb
    mrs x0, sctlr_el1
    orr x0, x0, #1
    msr sctlr_el1, x0
    isb
    mov x1, #0x80000000
    mov x2, #4
.global probe_loop
probe_loop:
    ldr x3, [x1]
    add x3, x3, #1
    str x3, [x1]
    subs x2, x2, #1
    b.ne probe_loop
    cmp x3, #4
    b.ne fail
    mov x1, #0x80200000
    ldr x3, [x1]
    cmp x3, #4
    b.ne fail
.global probe_fault
probe_fault:
    str x3, [x1]
    /* handler 已检查 ESR/FAR，并跳过预期失败的 STR. */
    cmp x10, #1
    b.ne fail
    adr x1, pass_msg
    b report
fail:
    adr x2, exit_args
    mov x3, #1
    str x3, [x2, #8]
    adr x1, fail_msg
report:
    mov x0, #4
    hlt #0xf000
    adr x1, exit_args
    mov x0, #0x20
    hlt #0xf000
    b .
.balign 2048
vectors:
    .space 0x200
    b sync_handler
    .space 0x600 - 4
sync_handler:
    mrs x4, esr_el1
    ldr x5, =0x9600004e
    cmp x4, x5
    b.ne fail
    mrs x4, far_el1
    cmp x4, x1
    b.ne fail
    mrs x4, elr_el1
    add x4, x4, #4
    msr elr_el1, x4
    mov x10, #1
    eret
pass_msg: .asciz "MMU probe: PASS (4 increments, RO alias, EL1 permission fault)\n"
fail_msg: .asciz "MMU probe: FAIL\n"
.balign 8
exit_args: .quad 0x20026, 0
.ltorg
.balign 4096
root: .space 4096
code_l2: .space 4096
data_l2: .space 4096
image_end:

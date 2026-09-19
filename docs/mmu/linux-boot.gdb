set pagination off
set confirm off
set disable-randomization off
break sctlr_write if (value & 1) && !(env->cp15.sctlr_el[1] & 1)
commands
silent
printf "ENABLE pc=%#lx SCTLR(new)=%#lx TTBR0=%#lx TTBR1=%#lx TCR=%#lx\n", env->pc, value, env->cp15.ttbr0_el[1], env->cp15.ttbr1_el[1], env->cp15.tcr_el[1]
bt 4
disable 1
continue
end
break get_phys_addr_lpae if address > 0xffff000000000000
commands
silent
printf "HIGH VA address=%#lx PC=%#lx TTBR0=%#lx TTBR1=%#lx TCR=%#lx\n", address, env->pc, env->cp15.ttbr0_el[1], env->cp15.ttbr1_el[1], env->cp15.tcr_el[1]
bt 5
disable 2
continue
end
break get_phys_addr_lpae if address > 0xffff000000000000 && access_type == 2
commands
silent
printf "HIGH PC fetch=%#lx TTBR0=%#lx TTBR1=%#lx TCR=%#lx\n", address, env->cp15.ttbr0_el[1], env->cp15.ttbr1_el[1], env->cp15.tcr_el[1]
quit
end
run

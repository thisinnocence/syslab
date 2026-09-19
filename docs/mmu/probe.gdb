set pagination off
set confirm off
set print pretty off
set disable-randomization off
python
import gdb
counts = {}

def val(expr):
    return int(gdb.parse_and_eval(expr))

class Helpers(gdb.Breakpoint):
    def stop(self):
        addr = val('addr')
        if addr in (0x80000000, 0x80200000):
            key = (self.location, hex(addr))
            counts[key] = counts.get(key, 0) + 1
            print('HELPER', key, 'count', counts[key])
        return False

class Fill(gdb.Breakpoint):
    def stop(self):
        if val('address') in (0x80000000, 0x80200000):
            print('ARM FILL address=%#x type=%d idx=%d' %
                  (val('address'), val('access_type'), val('mmu_idx')))
            print(gdb.execute('bt 12', to_string=True))
        return False

class Filled(gdb.FinishBreakpoint):
    def __init__(self, cpu, idx, addr):
        super().__init__(internal=True)
        self.cpu, self.idx, self.addr = cpu, idx, addr
    def stop(self):
        gdb.execute('set $c = (CPUState *)%d' % self.cpu)
        n = val('sizeof($c->neg.tlb.f) / sizeof($c->neg.tlb.f[0])')
        gdb.execute('set $f = &$c->neg.tlb.f[%d]' % (n - 1 - self.idx))
        gdb.execute('set $e = (CPUTLBEntry *)((char *)$f->table + ((%d >> 5) & $f->mask))' % self.addr)
        print('FILLED VA=%#x' % self.addr)
        print(gdb.execute('p/x *$f', to_string=True))
        print(gdb.execute('p/x *$e', to_string=True))
        print(gdb.execute('p/x *(uint64_t *)(%d + $e->addend)' % self.addr, to_string=True))
        return False

class SetPage(gdb.Breakpoint):
    def stop(self):
        addr = val('addr')
        if addr in (0x80000000, 0x80200000):
            print('SET PAGE', gdb.execute('p/x *full', to_string=True))
            Filled(val('cpu'), val('mmu_idx'), addr)
        return False

class VictimDone(gdb.FinishBreakpoint):
    def stop(self):
        print('VICTIM HIT', self.return_value)
        return False

class Victim(gdb.Breakpoint):
    def stop(self):
        if val('page') in (0x80000000, 0x80200000):
            print('VICTIM LOOKUP page=%#x' % val('page'))
            VictimDone(internal=True)
        return False

class Walk(gdb.Breakpoint):
    def stop(self):
        # 只看数据映射所在 L1 entry 以及 L2 block descriptor
        if val('ptw->out_phys') in (0x40082010, 0x40084000, 0x40084008):
            print('PTW', gdb.execute('p/x *ptw', to_string=True))
            print(gdb.execute('x/gx ptw->out_host', to_string=True))
        return False

Helpers('helper_ldq_mmu', internal=True)
Helpers('helper_stq_mmu', internal=True)
Victim('victim_tlb_hit', internal=True)
Fill('arm_cpu_tlb_fill_align', internal=True)
SetPage('tlb_set_page_full', internal=True)
Walk('arm_ldq_ptw', internal=True)
end
run
python
print('DATA HELPER TOTALS', counts)
end
quit

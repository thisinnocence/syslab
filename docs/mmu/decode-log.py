#!/usr/bin/env python3
"""用 binutils 解码未配置 disassembler 的 QEMU 输出，保留原始地址"""
import pathlib
import re
import subprocess
import sys
import tempfile

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
i = 0
with tempfile.TemporaryDirectory() as directory:
    binary = pathlib.Path(directory) / 'code.bin'
    while i < len(lines):
        match = re.fullmatch(r'(0x[0-9a-f]+):\s*', lines[i])
        if match and i + 1 < len(lines) and lines[i + 1].startswith('OBJD-'):
            kind = lines[i + 1][5]
            data = bytearray()
            i += 1
            while i < len(lines) and lines[i].startswith('OBJD-' + kind + ':'):
                data.extend(bytes.fromhex(lines[i].split(':', 1)[1]))
                i += 1
            binary.write_bytes(data)
            cmd = (['objdump', '-m', 'i386:x86-64', '-M', 'intel'] if kind == 'H'
                   else ['aarch64-linux-gnu-objdump', '-m', 'aarch64'])
            result = subprocess.check_output(cmd + [
                '-D', '-b', 'binary', '--adjust-vma=' + match[1], str(binary)
            ], text=True)
            print(result.split('<.data>:\n', 1)[1].rstrip())
        else:
            print(lines[i])
            i += 1

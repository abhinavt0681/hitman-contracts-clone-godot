"""Disassembles the D3D9 vs_1_1 shaders embedded in HitmanContracts.exe (they keep their
FILE/LINE debug comments): python3 -I vsh_disasm.py EXE [NAME-SUBSTRING]"""
import struct, sys

OPS = {  # opcode: (name, number of source operands, has destination)
    0: ('nop', 0, False), 1: ('mov', 1, True), 2: ('add', 2, True), 3: ('sub', 2, True), 4: ('mad', 3, True),
    5: ('mul', 2, True), 6: ('rcp', 1, True), 7: ('rsq', 1, True), 8: ('dp3', 2, True), 9: ('dp4', 2, True),
    10: ('min', 2, True), 11: ('max', 2, True), 12: ('slt', 2, True), 13: ('sge', 2, True), 14: ('exp', 1, True),
    15: ('log', 1, True), 16: ('lit', 1, True), 17: ('dst', 2, True), 18: ('lrp', 3, True), 19: ('frc', 1, True),
    20: ('m4x4', 2, True), 21: ('m4x3', 2, True), 22: ('m3x4', 2, True), 23: ('m3x3', 2, True), 24: ('m3x2', 2, True),
    78: ('expp', 1, True), 79: ('logp', 1, True), 31: ('dcl', 0, True), 81: ('def', 0, True),
}
REG = {0: 'r', 1: 'v', 2: 'c', 3: 'a', 4: 'o', 5: 'oD', 6: 'oT', 7: 'oInput', 8: 'oT', 10: 'oColor', 11: 'oDepth'}
RAST = {0: 'oPos', 1: 'oFog', 2: 'oPts'}


def reg(tok):
    t = ((tok >> 28) & 7) | ((tok >> 8) & 0x18)
    n = tok & 0x7ff
    if t == 4:
        return RAST.get(n, f'oRast{n}')
    return f'{REG.get(t, f"t{t}")}{n}'


def dst(tok):
    mask = (tok >> 16) & 0xf
    m = ''.join(c for i, c in enumerate('xyzw') if mask & (1 << i))
    return reg(tok) + ('' if mask == 0xf else '.' + m)


def src(tok, rel=None):
    sw = (tok >> 16) & 0xff
    s = ''.join('xyzw'[(sw >> (2 * i)) & 3] for i in range(4))
    neg = '-' if ((tok >> 24) & 0xf) == 1 else ''
    r = reg(tok)
    if tok & 0x2000:  # relative addressing (a0.x)
        r = f'{r[0]}[a0.x + {tok & 0x7ff}]'
    s = '' if s == 'xyzw' else '.' + (s[0] if len(set(s)) == 1 else s)
    return neg + r + s


def disasm(words, at):
    out = []
    i = at + 1  # past the version token
    while i < len(words):
        tok = words[i]
        op = tok & 0xffff
        if tok == 0x0000ffff:
            out.append('end')
            return out, i + 1
        if op == 0xfffe:
            n = (tok >> 16) & 0x7fff
            text = struct.pack(f'<{n}I', *words[i + 1:i + 1 + n])
            if text.startswith(b'FILE'):
                out.append('; ' + text[4:].split(b'\0')[0].decode('latin1'))
            elif text.startswith(b'LINE'):
                pass
            i += 1 + n
            continue
        name, nsrc, has_dst = OPS.get(op, (f'op{op}', 0, False))
        if op == 81:  # def c#, 4 floats
            vals = struct.unpack('<4f', struct.pack('<4I', *words[i + 2:i + 6]))
            out.append(f'def {dst(words[i + 1])}, ' + ', '.join(f'{v:g}' for v in vals))
            i += 6
            continue
        ops = []
        j = i + 1
        if has_dst:
            ops.append(dst(words[j]))
            j += 1
        for _ in range(nsrc):
            ops.append(src(words[j]))
            j += 1
        out.append(f'{name} ' + ', '.join(ops))
        i = j
    return out, i


def main(path, want=''):
    data = open(path, 'rb').read()
    data = data[: len(data) // 4 * 4]
    for align in range(4):
        words = struct.unpack(f'<{(len(data) - align) // 4}I', data[align: align + (len(data) - align) // 4 * 4])
        for k, w in enumerate(words):
            if w != 0xfffe0101:
                continue
            lines, _ = disasm(words, k)
            name = next((l for l in lines if l.startswith('; ')), '; ?')
            if want.lower() in name.lower():
                print(f'==== {name[2:]} (word {k}, align {align})')
                print('\n'.join(lines))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else '')

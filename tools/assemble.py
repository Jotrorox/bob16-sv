#!/usr/bin/env python3
"""Corrected BOB-16 assembler. Architecture credit: misterbob/somerandomviolinkid.

Uses the upstream execution decoder, not the buggy upstream assembler.
Output: one 16-bit hexadecimal word per line for $readmemh.
"""
from __future__ import annotations
import argparse
import ast
from dataclasses import dataclass
from pathlib import Path
import re
import sys

class AssemblyError(ValueError):
    pass

@dataclass(frozen=True)
class Line:
    number: int
    address: int
    op: str
    args: tuple[str, ...]


def strip_comment(text: str) -> str:
    quote = None
    escaped = False
    for i, char in enumerate(text):
        if escaped:
            escaped = False
        elif char == '\\' and quote:
            escaped = True
        elif quote and char == quote:
            quote = None
        elif not quote and char in ('"', "'"):
            quote = char
        elif not quote and char == ';':
            return text[:i]
    return text


def number(text: str, fill: bool = False) -> int:
    s = text.strip()
    if s.startswith('#'):
        return int(s[1:], 10)
    unsigned = s.lstrip('+-').lower()
    if unsigned.startswith(('0x', '0b', '0o')):
        return int(s, 0)
    return int(s, 16 if fill else 10)


def string_words(text: str) -> list[int]:
    if text.startswith(('"', "'")):
        try:
            value = ast.literal_eval(text)
        except (ValueError, SyntaxError) as exc:
            raise AssemblyError('invalid quoted string') from exc
        if not isinstance(value, str):
            raise AssemblyError('.stringz requires a string')
    else:
        if len(text.split()) != 1:
            raise AssemblyError('quote strings containing spaces')
        value = text
    if any(ord(c) > 255 for c in value):
        raise AssemblyError('strings must contain only byte-valued characters (0..255)')
    return [ord(c) for c in value] + [0]


def reg(text: str) -> int:
    if not re.fullmatch(r'[rR][0-7]', text):
        raise AssemblyError(f'invalid register: {text}')
    return int(text[1])


def is_reg(text: str) -> bool:
    return bool(re.fullmatch(r'[rR][0-7]', text))


def signed_field(value: int, bits: int) -> int:
    lo, hi = -(1 << (bits-1)), (1 << (bits-1))-1
    if not lo <= value <= hi:
        raise AssemblyError(f'{value} is outside signed {bits}-bit range {lo}..{hi}')
    return value & ((1 << bits)-1)


def encode(line: Line, labels: dict[str, int]) -> list[int]:
    op, a, pc = line.op, line.args, line.address
    def count(*allowed: int) -> None:
        if len(a) not in allowed:
            raise AssemblyError(f'{op} expects {" or ".join(map(str, allowed))} operand(s)')
    def value(s: str, fill: bool = False) -> int:
        return labels[s] if s in labels else number(s, fill)
    def offset(s: str, bits: int) -> int:
        n = value(s)
        if s in labels:
            n = (n - ((pc + 1) & 0xffff)) & 0xffff
            if n & 0x8000:
                n -= 0x10000
        return signed_field(n, bits)
    if op == '.stringz':
        count(1)
        return string_words(a[0])
    if op == '.fill':
        count(1)
        n = value(a[0], fill=True)
        if not -32768 <= n <= 65535:
            raise AssemblyError('.fill value does not fit one 16-bit word')
        return [n & 0xffff]
    if op == '.space':
        count(1)
        return [0] * number(a[0])
    if op == 'nop':
        count(0)
        return [0]
    if op in ('add', 'and'):
        count(2, 3)
        word = (1 if op == 'add' else 2) << 12 | reg(a[0]) << 9
        if len(a) == 3:
            word |= reg(a[1]) << 4
            if is_reg(a[2]):
                word |= reg(a[2]) << 1
            else:
                word |= 1 << 7 | signed_field(value(a[2]), 4)
        elif is_reg(a[1]):
            word |= 2 << 7 | reg(a[1]) << 4
        else:
            word |= 3 << 7 | signed_field(value(a[1]), 7)
        return [word]
    if op == 'not':
        count(1, 2)
        return [0x3000 | reg(a[0]) << 9 | (0x100 if len(a) == 1 else reg(a[1]) << 5)]
    if op in ('ld', 'ldi', 'st', 'sti', 'lea'):
        count(2)
        opc = {'ld': 4, 'ldi': 5, 'st': 7, 'sti': 8, 'lea': 13}[op]
        return [opc << 12 | reg(a[0]) << 9 | offset(a[1], 9)]
    if op in ('ldr', 'str'):
        count(3)
        return [(6 if op == 'ldr' else 9) << 12 | reg(a[0]) << 9 |
                reg(a[1]) << 6 | signed_field(value(a[2]), 6)]
    if op == 'br':
        count(2)
        flags = a[0].lower()
        if not flags or any(c not in 'nzp' for c in flags) or len(set(flags)) != len(flags):
            raise AssemblyError('branch flags must be a non-repeated combination of n, z, p')
        mask = sum({'n': 4, 'z': 2, 'p': 1}[c] for c in flags)
        return [0xa000 | mask << 9 | offset(a[1], 9)]
    if op == 'jmp':
        count(1)
        return [0xb000 | reg(a[0]) << 9]
    if op == 'jsr':
        count(1)
        return [0xc000 | offset(a[0], 11)]
    if op == 'jsrr':
        count(1)
        return [0xc800 | reg(a[0]) << 8]
    if op == 'ret':
        count(0)
        return [0xe000]
    if op == 'trap':
        count(1)
        n = value(a[0])
        if not 0 <= n <= 3:
            raise AssemblyError('implemented trap vectors are 0..3')
        return [0xf000 | n << 8]
    raise AssemblyError(f'unknown instruction/directive: {op}')


def assemble(source: str, words: int = 4096) -> list[int]:
    if not 1 <= words <= 65536:
        raise AssemblyError('memory size must be 1..65536 words')
    labels: dict[str, int] = {}
    lines: list[Line] = []
    pc = 0
    for lineno, raw in enumerate(source.splitlines(), 1):
        try:
            text = strip_comment(raw).strip()
            while match := re.match(r'^([A-Za-z_][A-Za-z_0-9]*):', text):
                name = match.group(1)
                if name in labels:
                    raise AssemblyError(f'duplicate label: {name}')
                if not 0 <= pc < words:
                    raise AssemblyError('label outside memory')
                labels[name] = pc
                text = text[match.end():].strip()
            if not text:
                continue
            pieces = text.split(None, 1)
            op = pieces[0].lower()
            rest = pieces[1].strip() if len(pieces) == 2 else ''
            args = (rest,) if op == '.stringz' else tuple(rest.replace(',', ' ').split())
            if op == '.org':
                if len(args) != 1:
                    raise AssemblyError('.org expects one numeric address')
                pc = number(args[0])
                if not 0 <= pc < words:
                    raise AssemblyError('.org is outside configured memory')
                continue
            if op == '.stringz':
                length = len(string_words(rest))
            elif op == '.space':
                if len(args) != 1:
                    raise AssemblyError('.space expects one count')
                length = number(args[0])
                if not 0 <= length <= words:
                    raise AssemblyError('invalid .space count')
            else:
                length = 1
            if pc + length > words:
                raise AssemblyError('program exceeds configured memory')
            lines.append(Line(lineno, pc, op, args))
            pc += length
        except (ValueError, TypeError) as exc:
            raise AssemblyError(f'line {lineno}: {exc}') from exc
    image = [0] * words
    used: set[int] = set()
    for line in lines:
        try:
            for i, word in enumerate(encode(line, labels)):
                address = line.address + i
                if address in used:
                    raise AssemblyError(f'overlapping output at 0x{address:04x}')
                used.add(address)
                image[address] = word
        except (ValueError, TypeError, IndexError) as exc:
            raise AssemblyError(f'line {line.number}: {exc}') from exc
    return image


def write_hex(path: Path, image: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(f'{word:04x}\n' for word in image), encoding='ascii')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('-o', '--output', type=Path, required=True)
    parser.add_argument('--words', type=int, default=4096, help='RAM depth, default 4096 words')
    args = parser.parse_args()
    try:
        image = assemble(args.source.read_text(encoding='utf-8'), args.words)
        write_hex(args.output, image)
    except (OSError, AssemblyError) as exc:
        print(f'assembly failed: {exc}', file=sys.stderr)
        return 1
    print(f'{args.source} -> {args.output} ({len(image)} words)')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())

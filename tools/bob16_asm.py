#!/usr/bin/env python3
"""Standalone BOB-16 assembler; Python 3, standard library only.

Usage: python3 bob16_asm.py source.basm -o output.hex [--words 4096]
Architecture credit: misterbob / somerandomviolinkid.
Bare .fill numbers are hexadecimal; other bare numbers are decimal.
"""

import argparse
import re
import sys
from pathlib import Path

WHITESPACE = " \t\r\n\v\f"
PC_OPS = {"ld": 4, "ldi": 5, "st": 7, "sti": 8, "lea": 13}
ARITY = {
    ".fill": (1,), "nop": (0,), "ret": (0,), "add": (2, 3),
    "and": (2, 3), "not": (1, 2), "ld": (2,), "ldi": (2,),
    "st": (2,), "sti": (2,), "lea": (2,), "ldr": (3,), "str": (3,),
    "br": (2,), "jmp": (1,), "jsr": (1,), "jsrr": (1,), "trap": (1,),
}


def fail(message: str):
    raise ValueError(message)


def number(text: str, fill: bool = False) -> int:
    text = text.lstrip(WHITESPACE)
    if not text:
        fail("empty number string")
    decimal, sign = text.startswith("#"), 1
    if decimal:
        message, text, base = f"invalid decimal literal: {text}", text[1:], 10
    else:
        if text[0] in "+-":
            sign, text = (-1 if text[0] == "-" else 1), text[1:]
        base = {"0x": 16, "0b": 2, "0o": 8}.get(text[:2].lower())
        if base:
            text = text[2:]
        else:
            base = 16 if fill else 10
        message = f"invalid integer literal: {text}"
    digits = {2: "[01]+", 8: "[0-7]+", 10: "[0-9]+",
              16: "(?:0[xX])?[0-9a-fA-F]+"}[base]
    if not re.fullmatch(r"[ \t\r\n\v\f]*[+-]?" + digits, text):
        fail(message)
    try:
        return sign * int(text, base)
    except ValueError:
        fail(message)


def is_reg(text: str) -> bool:
    return re.fullmatch(r"[rR][0-7]", text) is not None


def reg(text: str) -> int:
    if not is_reg(text):
        fail(f"invalid register: {text}")
    return int(text[1])


def signed(value: int, bits: int) -> int:
    low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not low <= value <= high:
        fail(f"{value} is outside signed {bits}-bit range {low}..{high}")
    return value & ((1 << bits) - 1)


def strip_comment(line: str) -> str:
    quote, escaped = "", False
    for i, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\" and quote:
            escaped = True
        elif quote:
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char == ";":
            return line[:i].strip(WHITESPACE)
    return line.strip(WHITESPACE)


def stringz(text: str) -> list:
    if not text:
        fail(".stringz expects 1 operand(s)")
    if text[0] not in "\"'":
        if any(char in WHITESPACE for char in text):
            fail("quote strings containing spaces")
        return [ord(char) for char in text] + [0]
    quote, result, i = text[0], [], 1
    escapes = dict(zip("ntrabfv0", "\n\t\r\a\b\f\v\0"))
    while i < len(text) and text[i] != quote:
        char, i = text[i], i + 1
        if char == "\\":
            if i == len(text):
                fail("invalid quoted string")
            char, i = text[i], i + 1
            if char in "xX":
                digits = text[i:i + 2]
                if not re.fullmatch(r"[0-9a-fA-F]{2}", digits):
                    fail("invalid hex escape in string")
                char, i = chr(int(digits, 16)), i + 2
            else:
                char = escapes.get(char, char)
        result.append(ord(char))
    if i == len(text):
        fail("invalid quoted string")
    if text[i + 1:].strip(WHITESPACE):
        fail("trailing characters after quoted string")
    return result + [0]


def encode(op: str, args: list, pc: int, labels: dict) -> int:
    if op not in ARITY:
        fail(f"unknown instruction/directive: {op}")
    if len(args) not in ARITY[op]:
        counts = " or ".join(map(str, ARITY[op]))
        fail(f"{op} expects {counts} operand(s)")

    def value(token, fill=False):
        return labels[token] if token in labels else number(token, fill)

    def offset(token, bits):
        if token in labels:
            n = ((labels[token] - pc - 1 + 32768) & 0xffff) - 32768
        else:
            n = number(token)
        return signed(n, bits)

    if op == ".fill":
        n = value(args[0], True)
        if not -32768 <= n <= 65535:
            fail(".fill value does not fit one 16-bit word")
        return n & 0xffff
    if op in ("nop", "ret"):
        return 0 if op == "nop" else 0xe000
    if op in ("add", "and"):
        word = (0x1000 if op == "add" else 0x2000) | (reg(args[0]) << 9)
        rhs = args[-1]
        if len(args) == 3:
            word |= reg(args[1]) << 4
            operand = reg(rhs) << 1 if is_reg(rhs) else 0x80 | signed(value(rhs), 4)
        else:
            operand = 0x100 | (reg(rhs) << 4) if is_reg(rhs) else 0x180 | signed(value(rhs), 7)
        return word | operand
    if op == "not":
        return 0x3000 | (reg(args[0]) << 9) | (0x100 if len(args) == 1 else reg(args[1]) << 5)
    if op in PC_OPS:
        return (PC_OPS[op] << 12) | (reg(args[0]) << 9) | offset(args[1], 9)
    if op in ("ldr", "str"):
        return ((0x6000 if op == "ldr" else 0x9000) | (reg(args[0]) << 9)
                | (reg(args[1]) << 6) | signed(value(args[2]), 6))
    if op == "br":
        flags = args[0].lower()
        if not flags or len(set(flags)) != len(flags) or any(c not in "nzp" for c in flags):
            fail("branch flags must be a non-repeated combination of n, z, p")
        mask = sum({"n": 4, "z": 2, "p": 1}[c] for c in flags)
        return 0xa000 | (mask << 9) | offset(args[1], 9)
    if op == "jmp":
        return 0xb000 | (reg(args[0]) << 9)
    if op == "jsr":
        return 0xc000 | offset(args[0], 11)
    if op == "jsrr":
        return 0xc800 | (reg(args[0]) << 8)
    n = value(args[0])  # trap
    if not 0 <= n <= 3:
        fail("implemented trap vectors are 0..3")
    return 0xf000 | (n << 8)


def assemble(source: str, words: int = 4096) -> list:
    if not 1 <= words <= 65536:
        fail("memory size must be 1..65536 words")
    labels, program, pc = {}, [], 0

    # Pass 1: collect labels and determine instruction/data addresses.
    for lineno, line in enumerate(source.split("\0", 1)[0].split("\n"), 1):
        try:
            text = strip_comment(line)
            while True:
                match = re.match(r"([A-Za-z_][A-Za-z_0-9]*):", text)
                if not match:
                    break
                name = match[1]
                if pc >= words:
                    fail("label outside memory")
                if name in labels:
                    fail(f"duplicate label: {name}")
                labels[name] = pc
                text = text[match.end():].strip(WHITESPACE)
            if not text:
                continue
            parts = re.split(r"\s+", text, maxsplit=1, flags=re.ASCII)
            op, rest = parts[0].lower(), parts[1] if len(parts) > 1 else ""
            args = re.findall(r"[^, \t\r\n]+", rest)
            data = None
            if op == ".org":
                if len(args) != 1:
                    fail(".org expects one numeric address")
                pc = number(args[0])
                if not 0 <= pc < words:
                    fail(".org is outside configured memory")
                continue
            if op == ".space":
                if len(args) != 1:
                    fail(".space expects one count")
                count = number(args[0])
                if not 0 <= count <= words:
                    fail("invalid .space count")
                data = [0] * count
            elif op == ".stringz":
                data = stringz(rest)
            count = 1 if data is None else len(data)
            if pc + count > words:
                fail("program exceeds configured memory")
            program.append((lineno, pc, op, args, data))
            pc = (pc + count) & 0xffff
        except ValueError as exc:
            raise ValueError(f"line {lineno}: {exc}") from None

    # Pass 2: resolve forward references and reject overlapping output.
    image, used = [0] * words, bytearray(words)
    for lineno, pc, op, args, data in program:
        try:
            if data is None:
                data = [encode(op, args, pc, labels)]
            for address, word in enumerate(data, pc):
                if used[address]:
                    fail(f"overlapping output at 0x{address:04x}")
                image[address], used[address] = word, 1
        except ValueError as exc:
            raise ValueError(f"line {lineno}: {exc}") from None
    return image


def main() -> int:
    parser = argparse.ArgumentParser(description="Standalone BOB-16 assembler.")
    parser.add_argument("source", help="source .basm file")
    parser.add_argument("-o", "--output", required=True, help="destination .hex file")
    parser.add_argument("--words", type=int, default=4096, help="RAM depth, default 4096 words")
    args = parser.parse_args()
    try:
        # Preserve the C assembler's byte-oriented strings, including UTF-8 bytes.
        source = Path(args.source).read_bytes().decode("latin-1")
        image = assemble(source, args.words)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text("".join(f"{word:04x}\n" for word in image), encoding="ascii")
    except (OSError, ValueError) as exc:
        print(f"assembly failed: {exc}", file=sys.stderr)
        return 1
    print(f"{args.source} -> {args.output} ({args.words} words)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

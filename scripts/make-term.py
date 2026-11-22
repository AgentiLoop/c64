#!/usr/bin/env python3
"""Builds Resources/TERM.PRG, the small BASIC terminal for the user-port modem.
Usage: python3 scripts/make-term.py

Outside strings the source is plain BASIC (keywords in upper case). Inside strings, lower-case
letters become unshifted PETSCII and upper-case letters shifted PETSCII, so after CHR$(14)
(the upper/lower case character set) the text shows exactly as written here."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROGRAM = r'''
10 OPEN 5,2,0,CHR$(8):REM 1200 BAUD 8N1 ON THE USER PORT
20 POKE 53280,0:POKE 53281,0:PRINT CHR$(5);CHR$(147);CHR$(14);
30 PRINT "C64 Terminal - 1200 baud"
40 PRINT "Dial: atdt host:port   Hang up: +++ ath"
50 PRINT "Or pick a BBS in the Mac's Modem menu.":PRINT
60 PRINT#5,"AT";CHR$(13);
70 GET#5,A$:IF A$<>"" THEN PRINT A$;:GOTO 70
80 GET K$:IF K$<>"" THEN PRINT#5,K$;
90 GOTO 70
'''

TOKENS = ["END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ", "LET", "GOTO", "RUN", "IF",
          "RESTORE", "GOSUB", "RETURN", "REM", "STOP", "ON", "WAIT", "LOAD", "SAVE", "VERIFY", "DEF",
          "POKE", "PRINT#", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN", "CLOSE", "GET", "NEW",
          "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP", "+", "-", "*", "/", "^", "AND", "OR", ">",
          "=", "<", "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND", "LOG", "EXP", "COS", "SIN",
          "TAN", "ATN", "PEEK", "LEN", "STR$", "VAL", "ASC", "CHR$", "LEFT$", "RIGHT$", "MID$", "GO"]


def petscii(ch, in_string):
    c = ord(ch)
    if in_string and "a" <= ch <= "z":
        return c - 0x20
    if in_string and "A" <= ch <= "Z":
        return c + 0x80
    return c


def tokenize(text):
    out, i, quote, rem = [], 0, False, False
    while i < len(text):
        ch = text[i]
        if ch == '"':
            quote = not quote
        if not quote and not rem:
            for n, word in enumerate(TOKENS):
                if text.startswith(word, i):
                    out.append(0x80 + n)
                    i += len(word)
                    rem = word == "REM"
                    break
            else:
                out.append(petscii(ch, False))
                i += 1
            continue
        out.append(petscii(ch, quote))
        i += 1
    return out


def main():
    addr = 0x0801
    prg = [addr & 0xFF, addr >> 8]
    for line in PROGRAM.strip().splitlines():
        num, _, text = line.partition(" ")
        body = [int(num) & 0xFF, int(num) >> 8] + tokenize(text) + [0]
        addr += 2 + len(body)
        prg += [addr & 0xFF, addr >> 8] + body
    prg += [0, 0]
    os.makedirs(os.path.join(ROOT, "Resources"), exist_ok=True)
    with open(os.path.join(ROOT, "Resources", "TERM.PRG"), "wb") as f:
        f.write(bytes(prg))
    print(f"Wrote Resources/TERM.PRG ({len(prg)} bytes)")


if __name__ == "__main__":
    main()

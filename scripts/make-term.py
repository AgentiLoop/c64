#!/usr/bin/env python3
"""Builds Resources/TERM.PRG, the bundled terminal for the emulated modem.
Usage: python3 scripts/make-term.py

A small 6510 machine-code terminal (with a `10 SYS2061` BASIC line so RUN starts it) that works
with all three modem interfaces:
  0 = user port (KERNAL RS-232, 1200 baud)
  1 = SwiftLink at $DE00 (6551 on NMI, 38,400 baud)
  2 = Turbo232 at $DE00 (230,400 baud)
The app writes the interface number to CONFIG_ADDRESS ($0810) after loading, before RUN.
Received text is printed with the KERNAL screen editor (PETSCII colours and graphics work),
the cursor blinks while idle, F3 downloads a file with XMODEM (checksum) to drive 8, F1 switches between PETSCII and ASCII/ANSI, and F7 hangs up (+++, ATH).
ASCII/ANSI mode translates characters both ways (CP437 line drawing approximated), handles the ANSI
colour codes (SGR), clear screen, cursor positioning and moves, answers the cursor position
request (ESC[6n, how BBSes detect ANSI) and sends cursor keys as ANSI. Strings are written in normal ASCII:
lower-case letters show as lower case and upper-case as upper case (the terminal switches to the
upper/lower-case character set)."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_ADDRESS = 0x0810

OPS = {
    ("LDA", "imm"): 0xA9, ("LDA", "zp"): 0xA5, ("LDA", "abs"): 0xAD, ("LDA", "absx"): 0xBD, ("LDA", "indy"): 0xB1,
    ("STA", "zp"): 0x85, ("STA", "abs"): 0x8D, ("STA", "absx"): 0x9D, ("STA", "indy"): 0x91,
    ("LDX", "imm"): 0xA2, ("LDX", "zp"): 0xA6, ("LDX", "abs"): 0xAE,
    ("LDY", "imm"): 0xA0, ("LDY", "zp"): 0xA4, ("LDY", "absx"): 0xBC,
    ("STY", "zp"): 0x84,
    ("INC", "zp"): 0xE6, ("CMP", "imm"): 0xC9, ("CMP", "abs"): 0xCD, ("CPX", "zp"): 0xE4,
    ("ADC", "imm"): 0x69, ("SBC", "zp"): 0xE5, ("AND", "imm"): 0x29,
    ("BEQ", "rel"): 0xF0, ("BNE", "rel"): 0xD0, ("BCC", "rel"): 0x90, ("BCS", "rel"): 0xB0,
    ("JSR", "abs"): 0x20, ("JMP", "abs"): 0x4C, ("JMP", "ind"): 0x6C,
    ("RTS", "imp"): 0x60, ("RTI", "imp"): 0x40, ("PHA", "imp"): 0x48, ("PLA", "imp"): 0x68,
    ("TAX", "imp"): 0xAA, ("TXA", "imp"): 0x8A, ("SEI", "imp"): 0x78, ("CLI", "imp"): 0x58,
    ("SEC", "imp"): 0x38, ("CLC", "imp"): 0x18, ("INY", "imp"): 0xC8,
    ("ASL", "imp"): 0x0A, ("TAY", "imp"): 0xA8, ("DEX", "imp"): 0xCA,
    ("ADC", "abs"): 0x6D, ("SBC", "imm"): 0xE9, ("EOR", "imm"): 0x49,
    ("CPX", "imm"): 0xE0, ("CPX", "abs"): 0xEC, ("STX", "abs"): 0x8E, ("CMP", "absx"): 0xDD,
    ("BPL", "rel"): 0x10, ("BMI", "rel"): 0x30, ("INC", "abs"): 0xEE, ("INX", "imp"): 0xE8, ("TYA", "imp"): 0x98,
    ("DEC", "abs"): 0xCE, ("PHP", "imp"): 0x08, ("PLP", "imp"): 0x28, ("ADC", "absx"): 0x7D,
}
ONE_BYTE = {"imm", "zp", "indy", "rel"}


class Asm:
    """Just enough of a 6502 assembler: explicit addressing modes, labels, <lo / >hi."""

    def __init__(self, org):
        self.org, self.out, self.labels, self.fixups = org, [], {}, []

    @property
    def pc(self):
        return self.org + len(self.out)

    def label(self, name):
        self.labels[name] = self.pc

    def byte(self, *values):
        self.out += values

    def ref(self, arg):
        """A data byte holding the value of `arg` (e.g. ('<', 'label'))."""
        self.fixups.append((len(self.out), "imm", arg))
        self.out.append(0)

    def text(self, s):
        """ASCII → PETSCII for the upper/lower-case character set, zero-terminated."""
        for ch in s:
            c = ord(ch)
            if "a" <= ch <= "z":
                c -= 0x20
            elif "A" <= ch <= "Z":
                c += 0x80
            elif ch == "\n":
                c = 13
            self.out.append(c)
        self.out.append(0)

    def __call__(self, mnemonic, mode="imp", arg=None):
        self.out.append(OPS[(mnemonic, mode)])
        if mode == "imp":
            return
        self.fixups.append((len(self.out), mode, arg))
        self.out += [0] * (1 if mode in ONE_BYTE else 2)

    def value(self, arg):
        if isinstance(arg, int):
            return arg
        if isinstance(arg, tuple):
            v = self.value(arg[1])
            return v & 0xFF if arg[0] == "<" else v >> 8
        return self.labels[arg]

    def assemble(self):
        for pos, mode, arg in self.fixups:
            v = self.value(arg)
            if mode == "rel":
                offset = v - (self.org + pos + 1)
                assert -128 <= offset <= 127, f"branch to {arg} out of range"
                self.out[pos] = offset & 0xFF
            elif mode in ONE_BYTE:
                assert 0 <= v <= 0xFF, f"{arg} = {v:#x} does not fit in a byte"
                self.out[pos] = v
            else:
                self.out[pos], self.out[pos + 1] = v & 0xFF, v >> 8
        return [self.org & 0xFF, self.org >> 8] + self.out


SETLFS, SETNAM, OPEN, CHKIN, CHKOUT, CLRCHN, CHROUT, GETIN = (
    0xFFBA, 0xFFBD, 0xFFC0, 0xFFC6, 0xFFC9, 0xFFCC, 0xFFD2, 0xFFE4)
ACIA_DATA, ACIA_STATUS, ACIA_COMMAND, ACIA_CONTROL, T232_SPEED = 0xDE00, 0xDE01, 0xDE02, 0xDE03, 0xDE07
NMINV = 0x0318
HEAD, TAIL, STR = 0xFB, 0xFC, 0xFD      # free zero page: ring buffer indexes, string pointer
RXBUF = 0xC000                          # 256-byte receive ring buffer (SwiftLink)
QTSW, INSRT = 0xD4, 0xD8               # screen editor quote mode / insert count
PLOT = 0xFFF0
F1, F3 = 0x85, 0x86
CLOSE, STOP, ST = 0xFFC3, 0xFFE1, 0x90
SOH, EOT, ACK, NAK, CAN = 0x01, 0x04, 0x06, 0x15, 0x18
BLK, HELD, FNAME = 0xC100, 0xC200, 0xC280   # XMODEM block (131 bytes), block waiting to be written, file name
BLNSW, GDBLN, BLNON, PNT, PNTR, USER, GDCOL, JIFFY = 0xCC, 0xCE, 0xCF, 0xD1, 0xD3, 0xF3, 0x0287, 0xA2
CMD_ON, CMD_HOLD = 0x09, 0x01           # DTR + receive IRQ, with / without RTS
F7 = 0x88


# ANSI colours 30-37 (normal, then bold/bright) as PETSCII colour codes. Black is dark grey,
# because the screen is black.
ANSI_COLOURS = [0x97, 0x1C, 0x1E, 0x95, 0x1F, 0x9C, 0x9F, 0x9B,
                0x98, 0x96, 0x99, 0x9E, 0x9A, 0x9C, 0x9F, 0x05]


def ascii_to_petscii():
    """Received ASCII/CP437 byte → PETSCII to print (upper/lower-case set); 0 = ignore."""
    t = [0] * 256
    for c in range(0x20, 0x7F):
        t[c] = c
    for c in range(0x41, 0x5B):
        t[c] = c + 0x80                 # A-Z → shifted (upper case)
    for c in range(0x61, 0x7B):
        t[c] = c - 0x20                 # a-z → unshifted (lower case)
    t[0x5F] = 0xA4                      # _
    t[0x60] = 0x27                      # `
    t[0x7B], t[0x7C], t[0x7D], t[0x7E] = 0x5B, 0xDD, 0x5D, 0x2D   # { | } ~
    t[0x0D] = 0x0D                      # CR = new line, LF ignored
    t[0x08] = 0x9D                      # backspace = cursor left
    t[0x09] = 0x20
    t[0x0C] = 0x93                      # form feed = clear screen
    for c in range(0x80, 0x100):
        t[c] = 0x20
    for c in (0xB3, 0xBA):
        t[c] = 0xDD                     # │ ║
    for c in (0xC4, 0xCD):
        t[c] = 0xC0                     # ─ ═
    for c in list(range(0xB4, 0xBA)) + list(range(0xBB, 0xC0)) + list(range(0xC0, 0xC4)) + \
            list(range(0xC5, 0xCD)) + list(range(0xCE, 0xDB)):
        t[c] = 0xDB                     # corners and tees → ┼
    for c in (0xB0, 0xB1, 0xB2, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF):
        t[c] = 0xA6                     # shades and blocks → ▒
    t[0xF9] = t[0xFA] = 0x2E            # middle dots
    return t


def petscii_to_ascii():
    """Typed PETSCII key → ASCII to send; 0 = don't send."""
    t = [0] * 256
    for c in range(0x20, 0x41):
        t[c] = c
    for c in range(0x41, 0x5B):
        t[c] = c + 0x20                 # unshifted letters = lower case
    for c in range(0xC1, 0xDB):
        t[c] = c - 0x80                 # shifted letters = upper case
    t[0x5B], t[0x5C], t[0x5D], t[0x5E] = 0x5B, 0x5C, 0x5D, 0x5E
    t[0xA4] = 0x5F
    t[0x0D] = t[0x8D] = 0x0D
    t[0x14] = 0x08                      # DEL = backspace
    t[0x03] = 0x03                      # RUN/STOP = Ctrl-C
    return t


def build():
    a = Asm(0x0801)
    a.byte(0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00)   # 10 SYS2061
    a("JMP", "abs", "start")
    assert a.pc == CONFIG_ADDRESS
    a.label("iface"); a.byte(0)

    a.label("start")
    a("LDA", "abs", "iface"); a("CMP", "imm", 3); a("BCC", "rel", "valid")
    a("LDA", "imm", 0); a("STA", "abs", "iface")
    a.label("valid")
    a("LDA", "imm", 0); a("STA", "abs", 0xD020); a("STA", "abs", 0xD021)
    a("LDA", "imm", ("<", "s_banner")); a("LDY", "imm", (">", "s_banner")); a("JSR", "abs", "print")
    a("LDX", "abs", "iface")
    a("LDA", "absx", "t_lo"); a("LDY", "absx", "t_hi"); a("JSR", "abs", "print")
    a("LDA", "imm", ("<", "s_help")); a("LDY", "imm", (">", "s_help")); a("JSR", "abs", "print")
    a("LDA", "abs", "iface"); a("BNE", "rel", "swsetup")

    # User port: OPEN 2,2,0,CHR$(8) — 1200 baud, 8N1.
    a("LDA", "imm", 1); a("LDX", "imm", ("<", "rsname")); a("LDY", "imm", (">", "rsname")); a("JSR", "abs", SETNAM)
    a("LDA", "imm", 2); a("LDX", "imm", 2); a("LDY", "imm", 0); a("JSR", "abs", SETLFS); a("JSR", "abs", OPEN)
    a("JMP", "abs", "greet")

    # SwiftLink / Turbo232: own NMI handler, 6551 set up for 8N1.
    a.label("swsetup")
    a("SEI")
    a("LDA", "abs", NMINV); a("STA", "abs", "oldnmi"); a("LDA", "abs", NMINV + 1); a("STA", "abs", "oldnmi1")
    a("LDA", "imm", ("<", "nmi")); a("STA", "abs", NMINV); a("LDA", "imm", (">", "nmi")); a("STA", "abs", NMINV + 1)
    a("LDA", "imm", 0); a("STA", "zp", HEAD); a("STA", "zp", TAIL); a("STA", "abs", "paused")
    a("STA", "abs", ACIA_STATUS)                                  # programmed reset
    a("LDA", "abs", "iface"); a("CMP", "imm", 2); a("BEQ", "rel", "turbo")
    a("LDA", "imm", 0x1F); a("STA", "abs", ACIA_CONTROL)         # 19200 × 2 = 38,400
    a("JMP", "abs", "swcmd")
    a.label("turbo")
    a("LDA", "imm", 0x10); a("STA", "abs", ACIA_CONTROL)         # external clock → enhanced speed
    a("LDA", "imm", 0); a("STA", "abs", T232_SPEED)              # 230,400
    a.label("swcmd")
    a("LDA", "imm", CMD_ON); a("STA", "abs", ACIA_COMMAND)
    a("CLI")

    a.label("greet")                                              # "AT" (also sets the user-port speed)
    for ch in (0x41, 0x54, 13):
        a("LDA", "imm", ch); a("JSR", "abs", "xmit")

    a.label("loop")
    a("JSR", "abs", "recv"); a("BCS", "rel", "idle")
    a("PHA"); a("JSR", "abs", "curoff"); a("PLA"); a("JSR", "abs", "show")
    a("JMP", "abs", "loop")
    a.label("idle")
    a("LDA", "imm", 0); a("STA", "zp", BLNSW)                     # cursor blinks while waiting
    a("JSR", "abs", GETIN); a("BEQ", "rel", "loop")
    a("CMP", "imm", F7); a("BEQ", "rel", "hangup")
    a("CMP", "imm", F1); a("BEQ", "rel", "toggle")
    a("CMP", "imm", F3); a("BNE", "rel", "notf3"); a("JMP", "abs", "download")
    a.label("notf3")
    a("JSR", "abs", "sendkey"); a("JMP", "abs", "loop")

    a.label("toggle")                                             # F1: PETSCII <-> ASCII/ANSI
    a("JSR", "abs", "curoff")
    a("LDA", "abs", "mode"); a("EOR", "imm", 1); a("STA", "abs", "mode"); a("BEQ", "rel", "to_pet")
    a("LDA", "imm", 0); a("STA", "abs", "astate"); a("STA", "abs", "bold")
    a("LDA", "imm", 7); a("STA", "abs", "fg")
    a("LDA", "imm", ("<", "s_ascii")); a("LDY", "imm", (">", "s_ascii")); a("JSR", "abs", "print")
    a("JMP", "abs", "loop")
    a.label("to_pet")
    a("LDA", "imm", ("<", "s_pet")); a("LDY", "imm", (">", "s_pet")); a("JSR", "abs", "print")
    a("JMP", "abs", "loop")

    a.label("hangup")                                             # quiet, "+++", quiet, "ATH"
    a("JSR", "abs", "curoff")
    a("LDA", "imm", ("<", "s_hang")); a("LDY", "imm", (">", "s_hang")); a("JSR", "abs", "print")
    a("JSR", "abs", "wait")
    for ch in (0x2B, 0x2B, 0x2B):
        a("LDA", "imm", ch); a("JSR", "abs", "xmit")
    a("JSR", "abs", "wait")
    for ch in (0x41, 0x54, 0x48, 13):
        a("LDA", "imm", ch); a("JSR", "abs", "xmit")
    a("JMP", "abs", "loop")

    a.label("wait")                                               # about 1.3 seconds
    a("LDA", "zp", JIFFY); a("CLC"); a("ADC", "imm", 65); a("STA", "abs", "tmp")
    a.label("w1")
    a("LDA", "zp", JIFFY); a("CMP", "abs", "tmp")
    a("BNE", "rel", "w1")
    a("RTS")

    # recv: C clear and the byte in A, or C set when nothing is waiting.
    a.label("recv")
    a("LDA", "abs", "iface"); a("BNE", "rel", "srecv")
    # GETIN returns 0 both for "nothing" and for a received $00: a real byte moves the buffer start (RIDBS).
    # (GETIN has to be called even when the buffer is empty: it switches the KERNAL receiver on.)
    a("LDA", "abs", 0x029C); a("STA", "abs", "ridbs")
    a("LDX", "imm", 2); a("JSR", "abs", CHKIN); a("JSR", "abs", GETIN)
    a("PHA"); a("JSR", "abs", CLRCHN); a("PLA"); a("BNE", "rel", "rgot")
    a("LDX", "abs", 0x029C); a("CPX", "abs", "ridbs"); a("BEQ", "rel", "none")
    a.label("rgot")
    a("CLC"); a("RTS")
    a.label("none")
    a("SEC"); a("RTS")
    a.label("srecv")
    a("LDX", "zp", HEAD); a("CPX", "zp", TAIL); a("BEQ", "rel", "none")
    a("LDA", "absx", RXBUF); a("INC", "zp", HEAD); a("PHA")
    a("LDA", "abs", "paused"); a("BEQ", "rel", "sr2")
    a("LDA", "zp", TAIL); a("SEC"); a("SBC", "zp", HEAD); a("CMP", "imm", 50); a("BCS", "rel", "sr2")
    a("LDA", "imm", 0); a("STA", "abs", "paused")
    a("LDA", "imm", CMD_ON); a("STA", "abs", ACIA_COMMAND)         # RTS on again
    a.label("sr2")
    a("PLA"); a("CLC"); a("RTS")

    # xmit: send A.
    a.label("xmit")
    a("PHA"); a("LDA", "abs", "iface"); a("BNE", "rel", "sx")
    a("LDX", "imm", 2); a("JSR", "abs", CHKOUT); a("PLA"); a("JSR", "abs", CHROUT); a("JMP", "abs", CLRCHN)
    a.label("sx")
    a("LDA", "abs", ACIA_STATUS); a("AND", "imm", 0x10); a("BEQ", "rel", "sx")   # wait for TDRE
    a("PLA"); a("STA", "abs", ACIA_DATA); a("RTS")

    # NMI: ACIA receive → ring buffer; hold RTS when it is nearly full. Other NMIs (RESTORE) go to the KERNAL.
    a.label("nmi")
    a("PHA"); a("TXA"); a("PHA")
    a("LDA", "abs", ACIA_STATUS); a("AND", "imm", 0x08); a("BEQ", "rel", "notours")
    a("LDA", "abs", ACIA_DATA); a("LDX", "zp", TAIL); a("STA", "absx", RXBUF); a("INC", "zp", TAIL)
    a("LDA", "zp", TAIL); a("SEC"); a("SBC", "zp", HEAD); a("CMP", "imm", 200); a("BCC", "rel", "nret")
    a("LDA", "imm", CMD_HOLD); a("STA", "abs", ACIA_COMMAND); a("STA", "abs", "paused")
    a.label("nret")
    a("PLA"); a("TAX"); a("PLA"); a("RTI")
    a.label("notours")
    a("PLA"); a("TAX"); a("PLA"); a("JMP", "ind", "oldnmi")

    # curoff: stop the blinking cursor and put the character under it back.
    a.label("curoff")
    a("LDA", "zp", BLNSW); a("BNE", "rel", "co_done")
    a("SEI"); a("LDA", "imm", 1); a("STA", "zp", BLNSW)
    a("LDA", "zp", BLNON); a("BEQ", "rel", "co_cli")
    a("LDA", "imm", 0); a("STA", "zp", BLNON)
    a("LDY", "zp", PNTR); a("LDA", "zp", GDBLN); a("STA", "indy", PNT)
    a("LDA", "abs", GDCOL); a("STA", "indy", USER)
    a.label("co_cli")
    a("CLI")
    a.label("co_done")
    a("RTS")

    # show: print a received byte (PETSCII as is, or through the ASCII/ANSI decoder).
    a.label("show")
    a("LDX", "abs", "mode"); a("BNE", "rel", "ascii")
    a.label("out")                                                # CHROUT without quote/insert mode
    a("JSR", "abs", CHROUT); a("LDA", "imm", 0); a("STA", "zp", QTSW); a("STA", "zp", INSRT); a("RTS")
    a.label("ascii")
    a("LDX", "abs", "astate"); a("BNE", "rel", "escst")
    a("CMP", "imm", 27); a("BNE", "rel", "plain")
    a("LDA", "imm", 1); a("STA", "abs", "astate"); a("RTS")
    a.label("plain")
    a("TAX"); a("LDA", "absx", "intab"); a("BEQ", "rel", "noop"); a("JMP", "abs", "out")
    a.label("noop")
    a("RTS")
    a.label("escst")
    a("CPX", "imm", 1); a("BNE", "rel", "csi")
    a("CMP", "imm", 0x5B); a("BNE", "rel", "endesc")          # ESC [
    a("LDA", "imm", 2); a("STA", "abs", "astate")
    a("LDA", "imm", 0); a("STA", "abs", "nparams"); a("STA", "abs", "cur"); a("RTS")
    a.label("endesc")
    a("LDA", "imm", 0); a("STA", "abs", "astate"); a("RTS")
    a.label("csi")
    a("CMP", "imm", 0x30); a("BCC", "rel", "notdig"); a("CMP", "imm", 0x3A); a("BCS", "rel", "notdig")
    a("SEC"); a("SBC", "imm", 0x30); a("STA", "abs", "tmp2")      # cur = cur * 10 + digit
    a("LDA", "abs", "cur"); a("ASL"); a("ASL"); a("CLC"); a("ADC", "abs", "cur"); a("ASL")
    a("CLC"); a("ADC", "abs", "tmp2"); a("STA", "abs", "cur"); a("RTS")
    a.label("notdig")
    a("CMP", "imm", 0x3B); a("BNE", "rel", "notsemi")          # ;
    a("JMP", "abs", "pushp")
    a.label("notsemi")
    a("CMP", "imm", 0x40); a("BCC", "rel", "noop")              # ?, space…: ignored
    a("PHA"); a("JSR", "abs", "pushp")
    a("LDA", "imm", 0); a("STA", "abs", "astate"); a("PLA")
    a("CMP", "imm", 0x6D); a("BNE", "rel", "f_j"); a("JMP", "abs", "sgr")         # m
    a.label("f_j")
    a("CMP", "imm", 0x4A); a("BNE", "rel", "f_h")                                 # J
    a("LDA", "abs", "params"); a("CMP", "imm", 2); a("BNE", "rel", "noop")
    a("LDA", "imm", 0x93); a("JMP", "abs", "out")
    a.label("f_h")
    a("CMP", "imm", 0x6E); a("BNE", "rel", "f_h2"); a("JMP", "abs", "dsr")             # n
    a.label("f_h2")
    a("CMP", "imm", 0x48); a("BEQ", "rel", "cup"); a("CMP", "imm", 0x66); a("BEQ", "rel", "cup")   # H f
    a("CMP", "imm", 0x41); a("BCC", "rel", "noop"); a("CMP", "imm", 0x45); a("BCS", "rel", "noop")  # A-D
    a("SEC"); a("SBC", "imm", 0x41); a("TAX"); a("LDA", "absx", "movetab"); a("STA", "abs", "tmp2")
    a("LDA", "abs", "params"); a("BNE", "rel", "mv1"); a("LDA", "imm", 1)
    a.label("mv1")
    a("CMP", "imm", 41); a("BCC", "rel", "mv2"); a("LDA", "imm", 40)
    a.label("mv2")
    a("TAX")
    a.label("mvl")
    a("LDA", "abs", "tmp2"); a("JSR", "abs", CHROUT); a("DEX"); a("BNE", "rel", "mvl"); a("RTS")

    a.label("cup")                                                # ESC [ row ; col H  (1-based)
    a("LDA", "abs", "params"); a("JSR", "abs", "dec1"); a("CMP", "imm", 25); a("BCC", "rel", "rowok")
    a("LDA", "imm", 24)
    a.label("rowok")
    a("TAX")
    a("LDA", "abs", "nparams"); a("CMP", "imm", 2); a("BCC", "rel", "colz")
    a("LDA", "abs", "params1"); a("JSR", "abs", "dec1"); a("CMP", "imm", 40); a("BCC", "rel", "colok")
    a("LDA", "imm", 39); a("BNE", "rel", "colok")
    a.label("colz")
    a("LDA", "imm", 0)
    a.label("colok")
    a("TAY"); a("CLC"); a("JMP", "abs", PLOT)
    a.label("dec1")
    a("CMP", "imm", 0); a("BEQ", "rel", "d1r"); a("SEC"); a("SBC", "imm", 1)
    a.label("d1r")
    a("RTS")

    a.label("dsr")                                                # ESC [ 6 n → ESC [ row ; col R (ANSI detection)
    a("LDA", "abs", "params"); a("CMP", "imm", 6); a("BNE", "rel", "dsrx")
    a("SEC"); a("JSR", "abs", PLOT); a("STX", "abs", "drow"); a("TYA"); a("PHA")
    a("LDA", "imm", 27); a("JSR", "abs", "xmit"); a("LDA", "imm", 0x5B); a("JSR", "abs", "xmit")
    a("LDA", "abs", "drow"); a("JSR", "abs", "sendnum"); a("LDA", "imm", 0x3B); a("JSR", "abs", "xmit")
    a("PLA"); a("JSR", "abs", "sendnum"); a("LDA", "imm", 0x52); a("JMP", "abs", "xmit")
    a.label("dsrx")
    a("RTS")
    a.label("sendnum")                                            # send A+1 in decimal (1-99)
    a("CLC"); a("ADC", "imm", 1); a("LDX", "imm", 0)
    a.label("sn1")
    a("CMP", "imm", 10); a("BCC", "rel", "sn2"); a("SBC", "imm", 10); a("INX"); a("BNE", "rel", "sn1")
    a.label("sn2")
    a("PHA"); a("TXA"); a("BEQ", "rel", "sn3"); a("CLC"); a("ADC", "imm", 0x30); a("JSR", "abs", "xmit")
    a.label("sn3")
    a("PLA"); a("CLC"); a("ADC", "imm", 0x30); a("JMP", "abs", "xmit")

    a.label("pushp")                                              # end of a parameter
    a("LDX", "abs", "nparams"); a("CPX", "imm", 8); a("BCS", "rel", "pp2")
    a("LDA", "abs", "cur"); a("STA", "absx", "params"); a("INC", "abs", "nparams")
    a.label("pp2")
    a("LDA", "imm", 0); a("STA", "abs", "cur"); a("RTS")

    a.label("sgr")                                                # ESC [ … m: colours, bold, reverse
    a("LDX", "imm", 0)
    a.label("sgl")
    a("CPX", "abs", "nparams"); a("BCS", "rel", "sgdone")
    a("LDA", "absx", "params"); a("JSR", "abs", "sgr1"); a("INX"); a("JMP", "abs", "sgl")
    a.label("sgdone")
    a("RTS")
    a.label("sgr1")
    a("STX", "abs", "sgx")
    a("CMP", "imm", 0); a("BNE", "rel", "s1")
    a("LDA", "imm", 0); a("STA", "abs", "bold"); a("LDA", "imm", 7); a("STA", "abs", "fg")
    a("LDA", "imm", 0x92); a("JSR", "abs", CHROUT); a("JMP", "abs", "emitfg")
    a.label("s1")
    a("CMP", "imm", 1); a("BNE", "rel", "s22"); a("LDA", "imm", 1); a("STA", "abs", "bold"); a("JMP", "abs", "emitfg")
    a.label("s22")
    a("CMP", "imm", 22); a("BNE", "rel", "s7"); a("LDA", "imm", 0); a("STA", "abs", "bold"); a("JMP", "abs", "emitfg")
    a.label("s7")
    a("CMP", "imm", 7); a("BNE", "rel", "s27"); a("LDA", "imm", 0x12); a("JSR", "abs", CHROUT); a("JMP", "abs", "sret")
    a.label("s27")
    a("CMP", "imm", 27); a("BNE", "rel", "s39"); a("LDA", "imm", 0x92); a("JSR", "abs", CHROUT); a("JMP", "abs", "sret")
    a.label("s39")
    a("CMP", "imm", 39); a("BNE", "rel", "s30"); a("LDA", "imm", 7); a("STA", "abs", "fg"); a("JMP", "abs", "emitfg")
    a.label("s30")
    a("CMP", "imm", 30); a("BCC", "rel", "sret"); a("CMP", "imm", 38); a("BCS", "rel", "s90")
    a("SEC"); a("SBC", "imm", 30); a("STA", "abs", "fg"); a("JMP", "abs", "emitfg")
    a.label("s90")                                                # 90-97: bright colours
    a("CMP", "imm", 90); a("BCC", "rel", "sret"); a("CMP", "imm", 98); a("BCS", "rel", "sret")
    a("SEC"); a("SBC", "imm", 82); a("TAX"); a("LDA", "absx", "coltab"); a("JSR", "abs", CHROUT); a("JMP", "abs", "sret")
    a.label("emitfg")
    a("LDA", "abs", "bold"); a("BEQ", "rel", "ef1"); a("LDA", "imm", 8)
    a.label("ef1")
    a("CLC"); a("ADC", "abs", "fg"); a("TAX"); a("LDA", "absx", "coltab"); a("JSR", "abs", CHROUT)
    a.label("sret")
    a("LDX", "abs", "sgx"); a("RTS")

    # sendkey: send a typed key (translated to ASCII, cursor keys as ANSI, in ASCII mode).
    a.label("sendkey")
    a("LDX", "abs", "mode"); a("BNE", "rel", "skasc"); a("JMP", "abs", "xmit")
    a.label("skasc")
    a("LDX", "imm", 3)
    a.label("skc")
    a("CMP", "absx", "curkeys"); a("BEQ", "rel", "skcur"); a("DEX"); a("BPL", "rel", "skc")
    a("TAX"); a("LDA", "absx", "outtab"); a("BEQ", "rel", "skr"); a("JMP", "abs", "xmit")
    a.label("skr")
    a("RTS")
    a.label("skcur")
    a("STX", "abs", "skx")
    a("LDA", "imm", 27); a("JSR", "abs", "xmit"); a("LDA", "imm", 0x5B); a("JSR", "abs", "xmit")
    a("LDX", "abs", "skx"); a("LDA", "absx", "curletters"); a("JMP", "abs", "xmit")

    # F3: XMODEM (checksum, 128-byte blocks) download to a PRG file on drive 8. Each block is held
    # back until the next one arrives, so the padding ($1A) at the end of the last block can be dropped.
    def prt(label):
        a("LDA", "imm", ("<", label)); a("LDY", "imm", (">", label)); a("JSR", "abs", "print")
    a.label("download")
    a("JSR", "abs", "curoff")
    prt("s_dl")
    a("JSR", "abs", "readline")
    a("LDA", "abs", "fnlen"); a("BNE", "rel", "x_open")
    prt("s_cancel"); a("JMP", "abs", "loop")
    a.label("x_open")
    a("LDA", "abs", "fnlen"); a("LDX", "imm", FNAME & 0xFF); a("LDY", "imm", FNAME >> 8); a("JSR", "abs", SETNAM)
    a("LDA", "imm", 3); a("LDX", "imm", 8); a("LDY", "imm", 1); a("JSR", "abs", SETLFS); a("JSR", "abs", OPEN)
    a("PHP"); a("JSR", "abs", "rxon"); a("PLP")
    a("BCS", "rel", "x_operr")
    a("LDA", "zp", ST); a("BPL", "rel", "x_opok")
    a.label("x_operr")
    a("LDA", "imm", 3); a("JSR", "abs", CLOSE); a("JSR", "abs", "rxon")
    prt("s_nodrive"); a("JMP", "abs", "loop")
    a.label("x_opok")
    prt("s_wait")
    a("LDA", "imm", 1); a("STA", "abs", "expect")
    a("LDA", "imm", 0); a("STA", "abs", "held"); a("STA", "abs", "retries"); a("STA", "abs", "aborted")
    a("JSR", "abs", "purge")
    a("LDA", "imm", NAK); a("JSR", "abs", "xmit")
    a.label("x_next")
    a("LDA", "abs", "aborted"); a("BEQ", "rel", "x_n1"); a("JMP", "abs", "x_fail")
    a.label("x_n1")
    a("LDA", "imm", 180); a("STA", "abs", "tmo"); a("JSR", "abs", "getb"); a("BCC", "rel", "x_got")
    a("LDA", "abs", "aborted"); a("BEQ", "rel", "x_n2"); a("JMP", "abs", "x_fail")
    a.label("x_n2")
    a("INC", "abs", "retries"); a("LDA", "abs", "retries"); a("CMP", "imm", 10); a("BCC", "rel", "x_n3"); a("JMP", "abs", "x_fail")
    a.label("x_n3")
    a("LDA", "imm", NAK); a("JSR", "abs", "xmit"); a("JMP", "abs", "x_next")
    a.label("x_got")
    a("CMP", "imm", SOH); a("BEQ", "rel", "x_block")
    a("CMP", "imm", EOT); a("BNE", "rel", "x_g2"); a("JMP", "abs", "x_eot")
    a.label("x_g2")
    a("CMP", "imm", CAN); a("BNE", "rel", "x_next"); a("JMP", "abs", "x_cancel")
    a.label("x_block")
    a("LDA", "imm", 60); a("STA", "abs", "tmo"); a("LDA", "imm", 0); a("STA", "abs", "bidx")
    a.label("x_rd")
    a("JSR", "abs", "getb"); a("BCC", "rel", "x_rd2"); a("JMP", "abs", "x_bad")
    a.label("x_rd2")
    a("LDX", "abs", "bidx"); a("STA", "absx", BLK); a("INX"); a("STX", "abs", "bidx"); a("CPX", "imm", 131)
    a("BNE", "rel", "x_rd")
    a("LDA", "abs", BLK); a("CLC"); a("ADC", "abs", BLK + 1); a("CMP", "imm", 0xFF); a("BNE", "rel", "x_badj")
    a("LDA", "imm", 0); a("LDX", "imm", 2)
    a.label("x_sum")
    a("CLC"); a("ADC", "absx", BLK); a("INX"); a("CPX", "imm", 130); a("BNE", "rel", "x_sum")
    a("CMP", "abs", BLK + 130); a("BNE", "rel", "x_badj")
    a("LDA", "abs", BLK); a("CMP", "abs", "expect"); a("BEQ", "rel", "x_new")
    a("CLC"); a("ADC", "imm", 1); a("CMP", "abs", "expect"); a("BEQ", "rel", "x_ack")   # repeated block
    a("JMP", "abs", "x_fail")
    a.label("x_badj")
    a("JMP", "abs", "x_bad")
    a.label("x_new")
    a("JSR", "abs", "flushheld")
    a("LDX", "imm", 0)
    a.label("x_cp")
    a("LDA", "absx", BLK + 2); a("STA", "absx", HELD); a("INX"); a("CPX", "imm", 128); a("BNE", "rel", "x_cp")
    a("LDA", "imm", 1); a("STA", "abs", "held")
    a("INC", "abs", "expect"); a("LDA", "imm", 0); a("STA", "abs", "retries")
    a("LDA", "imm", 0x23); a("JSR", "abs", "out")                # "#" per block
    a.label("x_ack")
    a("LDA", "imm", ACK); a("JSR", "abs", "xmit"); a("JMP", "abs", "x_next")
    a.label("x_bad")
    a("LDA", "abs", "aborted"); a("BEQ", "rel", "x_b1"); a("JMP", "abs", "x_fail")
    a.label("x_b1")
    a("JSR", "abs", "purge")
    a("INC", "abs", "retries"); a("LDA", "abs", "retries"); a("CMP", "imm", 10); a("BCC", "rel", "x_b2"); a("JMP", "abs", "x_fail")
    a.label("x_b2")
    a("LDA", "imm", NAK); a("JSR", "abs", "xmit"); a("JMP", "abs", "x_next")
    a.label("x_eot")
    a("LDA", "imm", ACK); a("JSR", "abs", "xmit")
    a("JSR", "abs", "flushlast")
    a("LDA", "imm", 3); a("JSR", "abs", CLOSE); a("JSR", "abs", "rxon")
    prt("s_done"); a("JMP", "abs", "loop")
    a.label("x_fail")                                             # tell the sender to stop
    for _ in range(3):
        a("LDA", "imm", CAN); a("JSR", "abs", "xmit")
    a.label("x_cancel")
    a("LDA", "imm", 3); a("JSR", "abs", CLOSE); a("JSR", "abs", "rxon")
    prt("s_cancel"); a("JMP", "abs", "loop")

    a.label("flushheld")                                          # write the held block (128 bytes)
    a("LDA", "abs", "held"); a("BEQ", "rel", "fh_r")
    a("LDA", "imm", 128); a("STA", "abs", "wlen"); a("JMP", "abs", "writeheld")
    a.label("fh_r")
    a("RTS")
    a.label("flushlast")                                          # write it without the trailing $1A padding
    a("LDA", "abs", "held"); a("BEQ", "rel", "fh_r")
    a("LDX", "imm", 128)
    a.label("fl1")
    a("LDA", "absx", HELD - 1); a("CMP", "imm", 0x1A); a("BNE", "rel", "fl2"); a("DEX"); a("BNE", "rel", "fl1")
    a.label("fl2")
    a("STX", "abs", "wlen")
    a.label("writeheld")
    a("LDA", "abs", "wlen"); a("BEQ", "rel", "fh_r")
    a("LDX", "imm", 3); a("JSR", "abs", CHKOUT)
    a("LDA", "imm", 0); a("STA", "abs", "widx")
    a.label("wh1")
    a("LDX", "abs", "widx"); a("LDA", "absx", HELD); a("JSR", "abs", CHROUT)
    a("INC", "abs", "widx"); a("LDA", "abs", "widx"); a("CMP", "abs", "wlen"); a("BNE", "rel", "wh1")
    a("JSR", "abs", CLRCHN); a("LDA", "imm", 0); a("STA", "abs", "held")
    # Disk access switches KERNAL RS-232 receive off ($F0A4); switch it back on (user port only).
    a.label("rxon")
    a("LDA", "abs", "iface"); a("BNE", "rel", "rxr")
    a("SEI"); a("JSR", "abs", 0xEF7E); a("CLI")                   # KERNAL: wait for the next start bit
    a.label("rxr")
    a("RTS")

    a.label("getb")                                               # byte within `tmo` jiffies: C clear + A, else C set
    a("LDA", "zp", JIFFY); a("CLC"); a("ADC", "abs", "tmo"); a("STA", "abs", "tend")
    a.label("gb1")
    a("JSR", "abs", "recv"); a("BCC", "rel", "gbr")
    a("JSR", "abs", STOP); a("BNE", "rel", "gb2")
    a("LDA", "imm", 1); a("STA", "abs", "aborted"); a("SEC"); a("RTS")
    a.label("gb2")
    a("LDA", "zp", JIFFY); a("CMP", "abs", "tend"); a("BNE", "rel", "gb1"); a("SEC")
    a.label("gbr")
    a("RTS")
    a.label("purge")                                              # skip input until a second of quiet
    a("LDA", "imm", 60); a("STA", "abs", "tmo")
    a.label("pu1")
    a("JSR", "abs", "getb"); a("BCC", "rel", "pu1"); a("RTS")

    a.label("readline")                                           # file name from the keyboard (max 16)
    a("LDA", "imm", 0); a("STA", "abs", "fnlen")
    a.label("rl1")
    a("LDA", "imm", 0); a("STA", "zp", BLNSW); a("JSR", "abs", GETIN); a("BEQ", "rel", "rl1")
    a("PHA"); a("JSR", "abs", "curoff"); a("PLA")
    a("CMP", "imm", 13); a("BEQ", "rel", "rl_done")
    a("CMP", "imm", 0x14); a("BEQ", "rel", "rl_del")
    a("CMP", "imm", 0x20); a("BCC", "rel", "rl1")
    a("LDX", "abs", "fnlen"); a("CPX", "imm", 16); a("BCS", "rel", "rl1")
    a("STA", "absx", FNAME); a("INC", "abs", "fnlen"); a("JSR", "abs", "out"); a("JMP", "abs", "rl1")
    a.label("rl_del")
    a("LDX", "abs", "fnlen"); a("BEQ", "rel", "rl1"); a("DEC", "abs", "fnlen")
    a("LDA", "imm", 0x14); a("JSR", "abs", CHROUT); a("JMP", "abs", "rl1")
    a.label("rl_done")
    a("LDA", "imm", 13); a("JMP", "abs", CHROUT)

    a.label("print")
    a("STA", "zp", STR); a("STY", "zp", STR + 1)
    a("LDY", "imm", 0)
    a.label("pl")
    a("LDA", "indy", STR); a("BEQ", "rel", "pd"); a("JSR", "abs", CHROUT); a("INY"); a("BNE", "rel", "pl")
    a.label("pd")
    a("RTS")

    a.label("mode"); a.byte(0)
    a.label("astate"); a.byte(0)
    a.label("cur"); a.byte(0)
    a.label("nparams"); a.byte(0)
    a.label("params"); a.byte(0); a.label("params1"); a.byte(0, 0, 0, 0, 0, 0, 0)
    a.label("tmp2"); a.byte(0)
    a.label("fg"); a.byte(7)
    a.label("bold"); a.byte(0)
    a.label("sgx"); a.byte(0)
    a.label("skx"); a.byte(0)
    a.label("drow"); a.byte(0)
    a.label("movetab"); a.byte(0x91, 0x11, 0x1D, 0x9D)          # ESC[A up, B down, C right, D left
    a.label("curkeys"); a.byte(0x91, 0x11, 0x1D, 0x9D)
    a.label("curletters"); a.byte(0x41, 0x42, 0x43, 0x44)
    a.label("coltab"); a.byte(*ANSI_COLOURS)
    a.label("intab"); a.byte(*ascii_to_petscii())
    a.label("outtab"); a.byte(*petscii_to_ascii())
    for v in ("expect", "held", "retries", "aborted", "tmo", "tend", "bidx", "widx", "wlen", "fnlen"):
        a.label(v); a.byte(0)
    a.label("ridbs"); a.byte(0)
    a.label("tmp"); a.byte(0)
    a.label("paused"); a.byte(0)
    a.label("oldnmi"); a.byte(0x47); a.label("oldnmi1"); a.byte(0xFE)
    a.label("rsname"); a.byte(0x08)
    a.label("t_lo"); [a.ref(("<", s)) for s in ("s_up", "s_sl", "s_tb")]
    a.label("t_hi"); [a.ref((">", s)) for s in ("s_up", "s_sl", "s_tb")]
    a.label("s_banner"); a.text("\x93\x0e\x05C64 Terminal\r\r")
    a.label("s_up"); a.text("User Port, 1200 baud\r")
    a.label("s_sl"); a.text("SwiftLink $DE00, 38400 baud\r")
    a.label("s_tb"); a.text("Turbo232 $DE00, 230400 baud\r")
    a.label("s_help"); a.text("Dial: atdt host:port  (or use the Mac's\rModem menu).  F1 ASCII/ANSI,\rF3 download (XMODEM to drive 8), F7 hangs up.\r\r")
    a.label("s_dl"); a.text("\rXMODEM download, file name: ")
    a.label("s_wait"); a.text("Start the upload now (STOP cancels).\r")
    a.label("s_done"); a.text("\rDownload complete.\r")
    a.label("s_cancel"); a.text("\rTransfer cancelled.\r")
    a.label("s_nodrive"); a.text("\rCan't open the file on drive 8.\r")
    a.label("s_ascii"); a.text("\x0e\x9b\r(ASCII/ANSI mode, F1 = PETSCII)\r")
    a.label("s_pet"); a.text("\x05\r(PETSCII mode, F1 = ASCII/ANSI)\r")
    a.label("s_hang"); a.text("\r(hanging up...)\r")
    return a.assemble()


def main():
    prg = build()
    os.makedirs(os.path.join(ROOT, "Resources"), exist_ok=True)
    with open(os.path.join(ROOT, "Resources", "TERM.PRG"), "wb") as f:
        f.write(bytes(prg))
    print(f"Wrote Resources/TERM.PRG ({len(prg)} bytes)")


if __name__ == "__main__":
    main()

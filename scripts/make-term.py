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
the cursor blinks while idle, and F7 hangs up (+++, ATH). Strings are written in normal ASCII:
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
BLNSW, GDBLN, BLNON, PNT, PNTR, USER, GDCOL, JIFFY = 0xCC, 0xCE, 0xCF, 0xD1, 0xD3, 0xF3, 0x0287, 0xA2
CMD_ON, CMD_HOLD = 0x09, 0x01           # DTR + receive IRQ, with / without RTS
F7 = 0x88


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
    a("PHA"); a("JSR", "abs", "curoff"); a("PLA"); a("JSR", "abs", CHROUT)
    a("JMP", "abs", "loop")
    a.label("idle")
    a("LDA", "imm", 0); a("STA", "zp", BLNSW)                     # cursor blinks while waiting
    a("JSR", "abs", GETIN); a("BEQ", "rel", "loop")
    a("CMP", "imm", F7); a("BEQ", "rel", "hangup")
    a("JSR", "abs", "xmit"); a("JMP", "abs", "loop")

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
    a("LDX", "imm", 2); a("JSR", "abs", CHKIN); a("JSR", "abs", GETIN)
    a("PHA"); a("JSR", "abs", CLRCHN); a("PLA"); a("BEQ", "rel", "none")
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

    a.label("print")
    a("STA", "zp", STR); a("STY", "zp", STR + 1)
    a("LDY", "imm", 0)
    a.label("pl")
    a("LDA", "indy", STR); a("BEQ", "rel", "pd"); a("JSR", "abs", CHROUT); a("INY"); a("BNE", "rel", "pl")
    a.label("pd")
    a("RTS")

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
    a.label("s_help"); a.text("Dial: atdt host:port  (or use the Mac's\rModem menu).  F7 hangs up.\r\r")
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

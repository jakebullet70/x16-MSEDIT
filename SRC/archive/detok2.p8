; DETOK2 - drives basdet.detok() directly, with no UI, and times it.
;
; Two jobs:
;   1. reproduce the "write failed - disk full?" that the interactive build hit, with the
;      prompts taken out of the picture so the worker is the only thing under test;
;   2. measure how long the prog8 detokenizer takes on a real program, for comparison
;      with the BASLOAD build (12:11 interpreted, 1:51 GPC-compiled on PAINT16C).
;
; Timing is the jiffy clock, 60 a second, same source as the BASLOAD build's TI - so the
; numbers are directly comparable and both are EMULATED time, not host wall clock.
;
; Build:  build.bat archive\detok2.p8      Run with PAINT16C.PRG in the cwd.

%import textio
%import diskio
%import basdet
%zeropage basicsafe

main {
    sub start() {
        txt.print("detok2 - prog8 detokenizer, timed\n\n")

        uword t0 = cbm.RDTIM16()
        ubyte err = basdet.detok("paint16c.prg", "p2.bas")
        uword t1 = cbm.RDTIM16()

        txt.print("lines done : ")
        txt.print_uw(basdet.lines_done)
        txt.nl()
        txt.print("load addr  : $")
        txt.print_uwhex(basdet.load_addr, false)
        txt.nl()
        txt.print("result     : ")
        txt.print_ub(err)
        txt.print("  ")
        txt.print(basdet.err_text(err))
        txt.nl()
        txt.print("dos status : ")
        txt.print(diskio.status())
        txt.nl()

        uword jiff = t1 - t0
        txt.print("\njiffies    : ")
        txt.print_uw(jiff)
        txt.print("\ntime       : ")
        txt.print_uw(jiff / 60)
        txt.print(".")
        txt.print_uw((jiff % 60) * 100 / 60)
        txt.print(" seconds\n")

        txt.print("\nDETOK2-END\n")
    }
}

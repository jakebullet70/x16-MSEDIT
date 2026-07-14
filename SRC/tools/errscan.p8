; errscan.p8 -- spike: scan the text screen for a BASLOAD "ERROR ... :<line>" report.
;
; Reads the screen one row at a time, but only the FIRST 5 COLUMNS of each, looking
; for the literal "ERROR" that BASLOAD prints when a .basl source fails to tokenize,
; e.g.:   ERROR: LABEL NOT FOUND IN DIR.BASL:19
; On the first match it reads the END of that same row to pull out the line number
; (the decimal digits after the final ':') and stops scanning.
;
; This proves the read-back EDIT wants: after a File>Run BASLOAD hand-off that errors,
; the reloaded editor can bounce the cursor to the offending source line. See the
; edit-basload-run notes and edit.p8's chain_to_basload / restore_run_state.
;
; ---- How to test (in the emulator, at the BASIC READY prompt) ----
;   BASLOAD "DIR.BASL"      -> prints  ERROR: LABEL NOT FOUND IN DIR.BASL:19
;   LOAD "ERRSCAN.PRG"      (device 8 = the -fsroot run\ folder)
;   RUN                     -> prints  found ERROR on row N, line = 19
; prog8 does not clear the screen at startup, so the BASLOAD error is still on
; screen to be scanned. Build:  run.bat errscan.p8   (stages errscan.prg into run\).

%import textio

main {
    ; What we test cols 0..4 of each row against. getchr() returns the raw VERA SCREEN CODE,
    ; where a letter is its 1-based position (E=5, R=18, O=15) in BOTH the upper/gfx and the
    ; lowercase PETSCII charsets - so these codes match "ERROR" or "error" either way. Do NOT
    ; compare against a "ERROR" string literal: prog8 encodes that in PETSCII ($C5..=197..),
    ; which never equals the screen code (5..). (That was the bug the folded-in version hit.)
    ubyte[5] NEEDLE = [5, 18, 18, 15, 18]       ; screen codes for E R R O R
    const ubyte NLEN = 5

    sub start() {
        ; scan BEFORE printing anything, so our own output can't scroll the error away
        ubyte rows = txt.height()
        ubyte cols = txt.width()
        ubyte hit_row = 255                 ; row the ERROR was found on (255 = none)
        uword line_no = 0

        ubyte row
        for row in 0 to rows - 1 {
            if row_is_error(row) {
                hit_row = row
                line_no = trailing_number(row, cols)
                break                       ; stop reading at the first ERROR line
            }
        }

        txt.nl()
        if hit_row == 255 {
            txt.print("no ERROR line on screen.\n")
            txt.print("run BASLOAD on DIR.BASL first, then RUN this.\n")
        } else {
            txt.print("found ERROR on row ")
            txt.print_ub(hit_row)
            if line_no == 0 {
                txt.print(" (no line number)\n")
            } else {
                txt.print(", line = ")
                txt.print_uw(line_no)
                txt.nl()
            }
        }

        txt.print("press a key.\n")
        while cbm.GETIN2() == 0 {
            ; hold the result on screen (returning to BASIC warm-starts it)
        }
    }

    sub row_is_error(ubyte row) -> bool {
        ; true if the first 5 columns of `row` are the screen codes for ERROR (case insensitive)
        ubyte c
        for c in 0 to NLEN - 1 {
            if txt.getchr(c, row) != NEEDLE[c]
                return false
        }
        return true
    }

    sub trailing_number(ubyte row, ubyte cols) -> uword {
        ; the number lives at the end of the line, after the last ':' (BASLOAD prints
        ; "...<file>:<line>"). Find the final colon, then read the decimal run after it.
        ; digits '0'..'9' and ':' sit at their ASCII codes ($30..$3A) in the screen-code
        ; table too, so getchr() values compare directly.
        ubyte last_colon = 255
        ubyte c
        for c in 0 to cols - 1 {
            if txt.getchr(c, row) == ':'
                last_colon = c
        }
        if last_colon == 255
            return 0                        ; no colon -> no line number

        uword n = 0
        bool any = false
        c = last_colon + 1
        while c < cols {
            ubyte d = txt.getchr(c, row)
            if d < '0' or d > '9'
                break
            n = n * 10 + (d - '0')
            any = true
            c++
        }
        if not any
            return 0
        return n
    }
}

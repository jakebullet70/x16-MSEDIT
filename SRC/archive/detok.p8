; DETOK - stand-alone BASIC detokenizer for the Commander X16.
;
; Prompts for a tokenized BASIC .PRG, writes it back out as readable .BAS text, and
; returns to BASIC. Nothing here knows the file format: all of that lives in basdet.p8,
; which this module drives through detok() / err_text() and a per-line progress hook.
; The split is deliberate - basdet makes no screen calls at all, so it can later be
; dropped into EDIT as an overlay without dragging any UI along.
;
; Not wired into EDIT: no chain-load, no ed.run state file, no EDIT.CFG dependency.
; It runs from the cwd with plain default colours and hands the machine back in the
; screen mode and charset it was launched in.
;
; Names are taken as typed and used bare in the current directory - the output is
; delete-then-created there (see basdet.detok for why an absolute path will not do).

%import textio
%import strings
%import diskio
%import basdet
%zeropage basicsafe

main {
    ; colour bytes are (background << 4) | foreground - dark grey body, light blue title
    ; bar, yellow accents. Same family as EDIT's XFMGR palette, just not shared with it.
    const ubyte CL_BODY = $bf           ; bg 11 dark grey / fg 15 light grey
    const ubyte CL_BAR  = $e0           ; bg 14 light blue / fg 0 black
    const ubyte CL_ACC  = $b7           ; yellow on dark grey - labels, filenames
    const ubyte CL_OK   = $bd           ; light green - success
    const ubyte CL_ERR  = $ba           ; light red - failures

    const ubyte R_SRC   = 6             ; label rows; each input happens on the row BELOW its
    const ubyte R_DST   = 9             ; label, at column 0 - the KERNAL's line input reads the
    const ubyte R_STAT  = 13            ; whole logical line, so a prompt must not share it
    const ubyte R_RESULT = 15

    str srcname = "?" * 40              ; as typed
    str dstname = "?" * 40              ; as typed, or the derived default
    str defname = "?" * 40              ; "<source minus extension>.bas"

    ubyte SCR_W, SCR_H
    ubyte saved_mode
    ubyte saved_charset

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        saved_charset = cx16.get_charset()      ; captured BEFORE set_screen_mode's CINT resets it
        cx16.set_screen_mode($01)               ; 80x30
        SCR_W = txt.width()
        SCR_H = txt.height()
        txt.lowercase()

        txt.color2(15, 11)
        txt.clear_screen()
        title_bar()
        put_at(2, 3, "Reads a tokenized BASIC program and writes it back out as text.")

        if not ask_names()
            goto done
        if not confirm_overwrite()
            goto done
        run_job()

done:
        put_at(2, SCR_H - 2, "Press any key...")
        void wait_key()
        leave()
    }

    ; ---- screen ----

    sub title_bar() {
        ubyte i
        for i in 0 to SCR_W - 1 {
            txt.setchr(i, 0, ' ')
            txt.setclr(i, 0, CL_BAR)
        }
        txt.color2(0, 14)
        txt.plot(2, 0)
        txt.print("DETOK - BASIC detokenizer")
        txt.plot(SCR_W - 16, 0)
        txt.print("Commander X16")
        txt.color2(15, 11)
    }

    sub put_at(ubyte col, ubyte row, str s) {
        txt.plot(col, row)
        txt.print(s)
    }

    sub put_col(ubyte col, ubyte row, str s, ubyte fg) {
        txt.color2(fg, 11)
        put_at(col, row, s)
        txt.color2(15, 11)
    }

    sub clear_row(ubyte row) {
        ubyte i
        for i in 0 to SCR_W - 1 {
            txt.setchr(i, row, ' ')
            txt.setclr(i, row, CL_BODY)
        }
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    ; ---- name entry ----

    sub ask_names() -> bool {
        put_col(2, R_SRC, "Tokenized BASIC file to read:", 7)
        txt.plot(0, R_SRC + 1)
        if txt.input_chars(&srcname) == 0 {
            put_col(2, R_RESULT, "Cancelled - no file name given.", 10)
            return false
        }

        make_default(srcname, defname)
        put_col(2, R_DST, "Text file to write", 7)
        txt.plot(21, R_DST)
        txt.print("(Enter for ")
        txt.color2(7, 11)
        txt.print(defname)
        txt.color2(15, 11)
        txt.print("):")
        txt.plot(0, R_DST + 1)
        if txt.input_chars(&dstname) == 0
            void strings.copy(defname, dstname)
        return true
    }

    sub make_default(uword src, uword dst) {
        ; "<source>.PRG" -> "<source>.bas"; a name with no extension just gets ".bas"
        ; appended. Lower-case literals encode to PETSCII that the host FS stores as
        ; upper-case, which is what the rest of the toolchain writes.
        void strings.copy(src, dst)
        uword n = strings.length(dst)
        uword i = n
        while i != 0 {
            i--
            if @(dst + i) == '/'
                break                   ; a dot in a directory name is not an extension
            if @(dst + i) == '.' {
                n = i
                break
            }
        }
        void strings.copy(".bas", dst + n)
    }

    sub confirm_overwrite() -> bool {
        if not diskio.exists(dstname) {
            void diskio.status()        ; clear FILE NOT FOUND so the drive LED settles
            return true
        }
        put_col(2, R_STAT, "That file already exists. Overwrite? (Y/N)", 10)
        repeat {
            ubyte k = wait_key()
            if k == 'y' or k == 'Y' {
                clear_row(R_STAT)
                return true
            }
            if k == 'n' or k == 'N' or k == 27 {
                clear_row(R_STAT)
                put_col(2, R_RESULT, "Cancelled - existing file left alone.", 10)
                return false
            }
        }
    }

    ; ---- the run ----

    sub progress() {
        ; basdet calls this once per line written. Repainting on every line would cost more
        ; than the detokenizing does, so only every 8th line reaches the screen.
        if (basdet.lines_done & 7) == 0 {
            txt.plot(14, R_STAT)
            txt.print_uw(basdet.lines_done)
        }
    }

    sub run_job() {
        put_col(2, R_STAT, "Lines done:", 7)
        basdet.tick_cb = &progress
        ubyte err = basdet.detok(srcname, dstname)
        basdet.tick_cb = 0

        txt.plot(14, R_STAT)            ; final count, in case the last tick was skipped
        txt.print_uw(basdet.lines_done)

        if err == basdet.ERR_OK {
            txt.color2(13, 11)
            txt.plot(2, R_RESULT)
            txt.print("Done - ")
            txt.print_uw(basdet.lines_done)
            txt.print(" lines written to ")
            txt.print(dstname)
            txt.color2(15, 11)
            txt.plot(2, R_RESULT + 1)
            txt.print("Load address was $")
            txt.print_uwhex(basdet.load_addr, false)
        } else {
            put_col(2, R_RESULT, "Failed: ", 10)
            txt.color2(10, 11)
            txt.print(basdet.err_text(err))
            txt.color2(15, 11)
            if basdet.lines_done != 0 {
                txt.plot(2, R_RESULT + 1)
                txt.print("Partial output was left in ")
                txt.print(dstname)
            }
        }
    }

    sub leave() {
        ; hand the machine back the way we found it, then let BASIC have the screen
        cx16.set_screen_mode(saved_mode)
        if saved_charset >= 1 and saved_charset <= 3
            cx16.screen_set_charset(saved_charset, 0)
        txt.color2(1, 6)                ; stock BASIC colours
        txt.chrout($93)                 ; clear screen, cursor home
    }
}

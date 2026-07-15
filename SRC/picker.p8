; picker - EDIT's Open/View file picker, in a HIRAM bank overlay (PICKER_BANK).
;
; Compiled as a %output library headerless blob (org $A000), renamed picker.ovl by build.bat, loaded
; into its reserved HIRAM bank at startup via diskio.loadlib and called from EDIT via `extsub @bank`.
; Moving the picker here reclaims its code from EDIT's scarce low RAM.
;
; THE FILE-LIST RECORDS LIVE IN THEIR OWN DEDICATED BANK (RECORDS_BANK), not in this one. An overlay
; executing at $A000 cannot map a second bank into $A000 to reach data - that would swap out the
; running code - so main provides tiny bank-switch helpers (rec_peek/rec_read/rec_write/rec_move) that
; run from LOW RAM (which stays mapped when the HIRAM bank flips). main passes their addresses in via
; picker_setup(); we call them through 1-instruction `jmp (ptr)` trampolines (do_peek/... below).
; Reads/writes stage through main's low-RAM `recstage` buffer, whose address we also get. Because the
; records get a whole 8KB bank to themselves, the Open list caps at ~157 files (FILE_CAP).
;
; SELF-CONTAINED otherwise (like misc.ovl / tview.ovl): the drawing helpers here are this overlay's
; own copies of edit.p8's, and it imports its own diskio for the directory listing. Colours come from
; the theme id the caller passes.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = pick, $A006 = picker_setup.
;
; Call contract:
;   picker_setup(peekfn, readfn, writefn, movefn, stage)  - once after load; wires the bank helpers
;   pick(dest, theme_id, blkptr) -> ubyte                 - run the modal picker
;     dest    (@R0): low-RAM buffer for the chosen filename (NUL-terminated) - written on a file pick
;     theme_id(@R1): EDIT's current theme, so we paint in its colours
;     blkptr  (@R2): low-RAM byte the chosen file's block-size hint is written to (for the load blink)
;     returns 1 if a file was chosen (dest + @blkptr filled), 0 if cancelled (Esc/Stop).
; The caller keeps the screen in its text mode and repaints (full_redraw) after we return.

%import textio
%import diskio
%import strings
%import theme
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; KEEP THIS BLOCK FREE OF INITIALIZED VARIABLES (the %jmptable gotcha): a module-level initialized
    ; var is emitted BEFORE the code and would shove the jump table off its fixed offsets. Inline
    ; literals inside subs are fine.
    %jmptable ( main.pick, main.picker_setup )

    const ubyte SPACE_SC = sc:' '
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'

    ; records: [type][name up to 49 + NUL][blocks @ -1], FNREC bytes each, in RECORDS_BANK at WINBASE.
    const ubyte FNREC    = 52           ; bytes/record (must match edit.p8 REC_STAGE_LEN)
    const uword WINBASE  = $a000        ; records start at the base of the RECORDS_BANK window
    const ubyte FILE_CAP = 157          ; 8192 / FNREC, floored; the Open-list capacity (own 8KB bank)

    ; bank-switch plumbing, wired by picker_setup() (UNINITIALIZED -> BSS, safe for the jmptable)
    uword p_peek, p_read, p_write, p_move   ; addresses of main's rec_* low-RAM helpers
    uword g_stage                           ; address of main's low-RAM recstage buffer (FNREC bytes)
    ubyte file_count
    ubyte SCR_W, SCR_H

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do.
    }

    sub picker_setup(uword peekfn @R0, uword readfn @R1, uword writefn @R2, uword movefn @R3, uword stage @R4) {
        ; wire main's low-RAM bank-switch helpers + stage buffer. Called once, right after load.
        p_peek  = peekfn
        p_read  = readfn
        p_write = writefn
        p_move  = movefn
        g_stage = stage
    }

    ; --- trampolines: tail-jump into main's low-RAM helpers (args already in cx16.r0..r2). main's
    ; --- rts returns straight to our caller. The read is done from low RAM, so flipping the HIRAM
    ; --- bank in there does not swap out THIS overlay's code.
    asmsub do_peek(uword winaddr @R0) -> ubyte @A {
        %asm {{
            jmp  (p8b_main.p8v_p_peek)
        }}
    }
    asmsub do_read(uword winaddr @R0, ubyte nb @R1) {
        %asm {{
            jmp  (p8b_main.p8v_p_read)
        }}
    }
    asmsub do_write(uword winaddr @R0, ubyte nb @R1) {
        %asm {{
            jmp  (p8b_main.p8v_p_write)
        }}
    }
    asmsub do_move(uword dstwin @R0, uword srcwin @R1, ubyte nb @R2) {
        %asm {{
            jmp  (p8b_main.p8v_p_move)
        }}
    }

    ; ------------------------------------------------------------------ public entry

    sub pick(uword dest @R0, ubyte theme_id @R1, uword blkptr @R2) -> ubyte {
        ; consume @R0/@R1/@R2 FIRST - diskio/strings calls below clobber cx16.r0-r3
        uword destp = dest
        ubyte tid   = theme_id
        uword blkp  = blkptr
        theme.apply(tid)
        SCR_W = txt.width()
        SCR_H = txt.height()

        scan_files()                            ; scan_files always adds ".." first, so file_count >= 1

        ubyte w = 44
        if SCR_W < 80
            w = SCR_W - 2
        ubyte x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte y0 = 2
        ubyte y1 = SCR_H - 3
        if SCR_W >= 80 {                ; 80-col: make the popup 2 rows shorter (1 trimmed each end)
            y0++
            y1--
        }
        ubyte rows = y1 - y0 - 1             ; visible file rows
        ubyte namew = w - 5                  ; name field (marker col + 1 right margin)
        ubyte cursor = 0
        ubyte top = 0
        ubyte nav_depth = 0                  ; sub-dirs descended below the start dir
        uword rw
        ubyte i
        ubyte is_dir                         ; type + size pulled out of the chosen record on Enter
        ubyte blk
        ; draw the static frame, title and footer ONCE - only the file list is repainted as the
        ; cursor moves (redrawing the title each key caused header flicker)
        draw_box_frame(x0, y0, x1, y1)
        if x1 + 1 < SCR_W and y1 + 1 < SCR_H
            draw_box_shadow(x0, y0, x1, y1)
        put_str_at(x0 + (w - 10) / 2, y0, " Open File ")
        set_color_run(x0 + (w - 10) / 2, x0 + (w - 10) / 2 + 10, y0, theme.CB_BOX)
        put_str_at(x0 + (w - 11) / 2, y1, " Esc to exit ")
        set_color_run(x0 + (w - 11) / 2, x0 + (w - 11) / 2 + 12, y1, theme.CB_BOX)
        repeat {
            if cursor < top
                top = cursor
            if cursor >= top + rows
                top = cursor - rows + 1
            ubyte r
            for r in 0 to rows - 1 {
                ubyte rr = y0 + 1 + r
                set_color_run(x0 + 1, x1 - 1, rr, theme.CB_BOX)   ; clear the row (colour + chars)
                ubyte cc
                for cc in x0 + 1 to x1 - 1
                    txt.setchr(cc, rr, SPACE_SC)
                ubyte idx = top + r
                if idx < file_count {
                    do_read(WINBASE + (idx as uword) * FNREC, FNREC)   ; record -> the low-RAM stage
                    if @(g_stage) != 0                          ; directory: "/" marker
                        txt.setchr(x0 + 2, rr, sc:'/')
                    put_mem_trunc(x0 + 3, rr, g_stage + 1, namew)
                    if idx == cursor
                        set_color_run(x0 + 1, x1 - 1, rr, theme.CB_SEL)
                }
            }
            if top != 0
                txt.setchr(x1 - 1, y0 + 1, sc:'^')
            if top + rows < file_count
                txt.setchr(x1 - 1, y1 - 1, sc:'v')
            ubyte k = wait_key()
            when k {
                145 -> {                        ; up
                    if cursor != 0
                        cursor--
                }
                17 -> {                         ; down
                    if cursor + 1 < file_count
                        cursor++
                }
                130 -> {                        ; PgUp
                    if cursor < rows
                        cursor = 0
                    else
                        cursor -= rows
                }
                2 -> {                          ; PgDn
                    cursor += rows
                    if cursor >= file_count
                        cursor = file_count - 1
                }
                19 -> cursor = 0                ; Home
                4 -> cursor = file_count - 1    ; End
                13 -> {                         ; Enter: open file, or enter directory
                    do_read(WINBASE + (cursor as uword) * FNREC, FNREC)   ; chosen record -> stage
                    i = 0
                    while @(g_stage + 1 + i) != 0 {  ; copy the name out to the caller's low-RAM buffer
                        @(destp + i) = @(g_stage + 1 + i)
                        i++
                    }
                    @(destp + i) = 0
                    is_dir = @(g_stage)
                    blk = @(g_stage + FNREC - 1)     ; size hint for the load blink
                    if is_dir != 0 {           ; directory -> chdir + rescan, stay open
                        diskio.chdir(destp)
                        ; track depth so a later cancel can restore the start dir. ".." goes up
                        ; (one less deep, floored at 0); a named dir goes down.
                        if @(destp) == '.' and @(destp + 1) == '.' and @(destp + 2) == 0 {
                            if nav_depth != 0
                                nav_depth--
                        } else {
                            nav_depth++
                        }
                        scan_files()
                        cursor = 0
                        top = 0
                    } else {
                        @(blkp) = blk
                        return 1                ; file -> destp holds the chosen name
                    }
                }
                27, 3 -> {                      ; cancel: climb back to the start dir
                    repeat nav_depth
                        diskio.chdir("..")
                    return 0
                }
            }
        }
    }

    ; ------------------------------------------------------------------ record store (in RECORDS_BANK)

    sub add_entry(ubyte etype, uword nameptr, uword blocks) {
        ; build one record in the low-RAM stage buffer, then write it to the records bank
        if file_count >= FILE_CAP
            return
        @(g_stage) = etype
        ubyte i = 0
        while i < FNREC - 3 and @(nameptr + i) != 0 {   ; reserve the last byte for blocks
            @(g_stage + 1 + i) = @(nameptr + i)
            i++
        }
        @(g_stage + 1 + i) = 0
        ubyte bb = 255                          ; 255 blocks (~64KB+) saturates to "large"
        if blocks < 256
            bb = lsb(blocks)
        @(g_stage + FNREC - 1) = bb
        do_write(WINBASE + (file_count as uword) * FNREC, FNREC)
        file_count++
    }

    sub sort_dirs_first() {
        ; stable insertion sort so directory records sort before files; ".." (index 0) stays at top.
        ; The stashed record rides in the low-RAM stage buffer across the inner shift loop, which only
        ; uses do_peek (a byte read) and do_move (a within-bank slot copy) - neither touches the stage.
        if file_count < 2
            return
        ubyte i
        for i in 1 to file_count - 1 {
            uword reci = WINBASE + (i as uword) * FNREC
            ubyte keyi = 1                       ; file=1, dir=0 (dirs sort first)
            if do_peek(reci) != 0
                keyi = 0
            do_read(reci, FNREC)                 ; stash record i in the stage buffer
            ubyte j = i
            while j != 0 {
                uword recp = WINBASE + ((j - 1) as uword) * FNREC
                ubyte keyp = 1
                if do_peek(recp) != 0
                    keyp = 0
                if keyp <= keyi                  ; predecessor already <= -> stable stop
                    break
                do_move(WINBASE + (j as uword) * FNREC, recp, FNREC)   ; records[j] = records[j-1]
                j--
            }
            do_write(WINBASE + (j as uword) * FNREC, FNREC)   ; records[j] = the stashed record
        }
    }

    sub scan_files() {
        ; fill the record region with the current directory's entries: a ".." (go up) entry first,
        ; then sub-directories and files. '.'-prefixed entries from the listing are skipped.
        file_count = 0
        add_entry(1, "..", 0)
        if not diskio.lf_start_list("*")
            return
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue
            ubyte etype = 0
            if diskio.list_filetype == "dir"
                etype = 1
            add_entry(etype, &diskio.list_filename, diskio.list_blocks)
            if file_count >= FILE_CAP
                break
        }
        diskio.lf_end_list()
        sort_dirs_first()                        ; group directories above files
    }

    ; ------------------------------------------------------------------ drawing (copies of edit.p8's)

    sub put_str_at(ubyte col, ubyte row, str s) {
        ubyte i = 0
        while s[i] != 0 {
            txt.setchr(col + i, row, txt.petscii2scr(s[i]))
            i++
        }
    }

    sub put_mem_trunc(ubyte col, ubyte row, uword ptr, ubyte maxw) {
        ; draw a NUL-terminated PETSCII string from RAM, truncated to maxw cells
        ubyte i = 0
        while i < maxw and @(ptr + i) != 0 {
            txt.setchr(col + i, row, txt.petscii2scr(@(ptr + i)))
            i++
        }
    }

    sub set_color_run(ubyte c0, ubyte c1, ubyte row, ubyte color) {
        ubyte c
        for c in c0 to c1
            txt.setclr(c, row, color)
    }

    sub draw_box_frame(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ubyte r
        ubyte c
        for r in y0 to y1 {
            set_color_run(x0, x1, r, theme.CB_BOX)
            for c in x0 to x1
                txt.setchr(c, r, SPACE_SC)
        }
        txt.setchr(x0, y0, SC_TL)
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        for c in x0 + 1 to x1 - 1 {
            txt.setchr(c, y0, SC_H)
            txt.setchr(c, y1, SC_H)
        }
        for r in y0 + 1 to y1 - 1 {
            txt.setchr(x0, r, SC_V)
            txt.setchr(x1, r, SC_V)
        }
        set_color_run(x0, x1, y0, theme.CB_BORDER)
        set_color_run(x0, x1, y1, theme.CB_BORDER)
        for r in y0 + 1 to y1 - 1 {
            txt.setclr(x0, r, theme.CB_BORDER)
            txt.setclr(x1, r, theme.CB_BORDER)
        }
    }

    sub draw_box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ubyte c
        ubyte r
        if y1 + 1 < SCR_H
            for c in x0 + 1 to x1 + 1
                if c < SCR_W
                    txt.setclr(c, y1 + 1, theme.CB_SHADOW)
        if x1 + 1 < SCR_W
            for r in y0 + 1 to y1
                txt.setclr(x1 + 1, r, theme.CB_SHADOW)
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }
}

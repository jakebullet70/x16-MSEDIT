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
    %jmptable ( main.pick, main.picker_setup, main.del_sym )

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
    bool  hide_dirs                     ; footer toggles (BSS; reset at the top of each pick() call).
    bool  basl_only                     ; hide_dirs = skip sub-dirs; basl_only = only BASLOAD source files
    bool  basl_avail                    ; caller's Dev-menu-shown flag: hide the Basl filter when Dev is off
    ubyte[64] symname                   ; del_sym: the current *.SYM victim, copied out of the listing
                                        ; before lf_end_list, then handed to diskio.delete

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
        basl_avail = (tid & $80) != 0           ; bit7 of theme_id carries EDIT's Dev-menu-shown flag
        tid &= $7f                              ; (the Basl filter is a Dev feature - it rides with the menu)
        theme.apply(tid)
        SCR_W = txt.width()
        SCR_H = txt.height()
        ; hide_dirs / basl_only PERSIST between popups (module BSS, zeroed once at overlay load): the view
        ; you left is the view you get back this session. Only force Basl off when the Dev feature is
        ; unavailable, so a filter that can't be shown can't silently keep filtering.
        if not basl_avail
            basl_only = false

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
        ubyte first_row = y0 + 2             ; first file row: one blank pad row below the title bar
        ubyte rows = y1 - y0 - 3             ; visible file rows (one blank pad row above the footer too)
        ubyte namew = w - 5                  ; name field (marker col + 1 right margin)
        ubyte cursor = 0
        ubyte top = 0
        ubyte prev_cursor = 0                ; last painted cursor / top - lets us repaint only what changed
        ubyte prev_top = 0
        bool  full = true                    ; force a full list paint on the first pass (and after rescans)
        ubyte nav_depth = 0                  ; sub-dirs descended below the start dir
        ubyte i
        ubyte is_dir                         ; type + size pulled out of the chosen record on Enter
        ubyte blk
        ; draw the static frame, title and footer ONCE - only the file list is repainted as the
        ; cursor moves (redrawing the title each key caused header flicker)
        draw_box_frame(x0, y0, x1, y1)
        if x1 + 1 < SCR_W and y1 + 1 < SCR_H
            draw_box_shadow(x0, y0, x1, y1)
        draw_title_bar(x0, x1, y0, " Open File ")   ; solid header bar (About/XFMGR style)
        draw_footer(x0, x1, y1)                      ; solid footer bar with the action + toggle hotkeys
        repeat {
            if cursor < top
                top = cursor
            if cursor >= top + rows
                top = cursor - rows + 1
            if top != prev_top
                full = true                         ; the window scrolled - every row's content shifts
            if full {
                ubyte r
                for r in 0 to rows - 1
                    paint_row(r, x0, x1, first_row, top, cursor, namew)
            } else {                                ; no scroll: repaint only the de-selected + new cursor row
                paint_row(prev_cursor - top, x0, x1, first_row, top, cursor, namew)
                if cursor != prev_cursor
                    paint_row(cursor - top, x0, x1, first_row, top, cursor, namew)
            }
            if top != 0                             ; scroll hints ride the first / last visible file row
                txt.setchr(x1 - 1, first_row, sc:'^')
            if top + rows < file_count
                txt.setchr(x1 - 1, first_row + rows - 1, sc:'v')
            prev_cursor = cursor
            prev_top = top
            full = false
            ubyte k = wait_key()
            if k >= $c1 and k <= $da            ; fold SHIFTed letters so D/F/B match either case
                k -= $80
            when k {
                'f' -> {                        ; toggle Hide Dirs, then rescan with the new filter
                    hide_dirs = not hide_dirs
                    scan_files()
                    cursor = 0
                    top = 0
                    full = true                 ; list content changed - repaint every row
                    draw_footer(x0, x1, y1)
                }
                'b' -> {                        ; toggle BASLOAD-only files (a Dev feature)
                    if basl_avail {
                        basl_only = not basl_only
                        scan_files()
                        cursor = 0
                        top = 0
                        full = true
                        draw_footer(x0, x1, y1)
                    }
                }
                'd' -> {                        ; delete the highlighted FILE (dirs and ".." are skipped)
                    do_read(WINBASE + (cursor as uword) * FNREC, FNREC)
                    if @(g_stage) == 0 {        ; type 0 = a file
                        i = 0
                        while @(g_stage + 1 + i) != 0 {   ; name -> caller buffer as delete/display scratch
                            @(destp + i) = @(g_stage + 1 + i)
                            i++
                        }
                        @(destp + i) = 0
                        if confirm_delete(x0, x1, y1, destp) {
                            diskio.delete(destp)
                            void diskio.status()            ; clear the channel (LED / stale error)
                            scan_files()
                            if cursor >= file_count
                                cursor = file_count - 1
                            top = 0
                            full = true                     ; a file vanished - repaint every row
                        }
                        draw_footer(x0, x1, y1)             ; restore the footer the confirm overwrote
                    }
                }
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
                        full = true             ; new directory listing - repaint every row
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

    ; ------------------------------------------------------------------ Delete-all-SYM (Dev menu)

    sub del_sym(ubyte theme_id @R0) -> ubyte {
        ; Dev menu > Delete all SYM files. The WHOLE feature runs in-bank - scan, delete and report all
        ; paint on the status row here - so main keeps only a thin caller (the cheapest low-RAM overlay
        ; pattern). By request there is NO confirm: selecting the item deletes straight away. Enumerate-
        ; then-delete ONE file per pass: find the first *.SYM, close the listing, delete it, rescan.
        ; diskio won't delete during an open listing (the picker's own 'd' closes first too), and a
        ; fresh scan each pass stays correct as files vanish. The 255 cap guards a silent-fail delete
        ; from looping forever. Returns the count deleted.
        theme.apply(theme_id)
        SCR_W = txt.width()
        SCR_H = txt.height()
        ubyte srow = SCR_H - 1

        ubyte count = 0
        repeat {
            bool found = false
            if diskio.lf_start_list("*") {
                while diskio.lf_next_entry() {
                    if diskio.list_filetype == "dir"
                        continue
                    if ends_ci(&diskio.list_filename, ".sym") {
                        ubyte i = 0
                        while diskio.list_filename[i] != 0 and i < len(symname) - 1 {
                            symname[i] = diskio.list_filename[i]
                            i++
                        }
                        symname[i] = 0
                        found = true
                        break                       ; close the listing before deleting
                    }
                }
                diskio.lf_end_list()
            }
            if not found
                break
            diskio.delete(&symname)
            void diskio.status()                    ; clear the channel (LED / stale error)
            count++
            if count == 255
                break
        }

        report_del(srow, count)
        sys.wait(90)                                ; hold the result ~1.5s before main restores the footer
        return count
    }

    sub report_del(ubyte row, ubyte count) {
        ubyte c
        for c in 0 to SCR_W - 1
            txt.setchr(c, row, SPACE_SC)
        if count == 0 {
            put_str_at(1, row, "No .SYM files found")
        } else {
            ubyte col = put_num(1, row, count)
            if count == 1
                put_str_at(col, row, " .SYM file deleted")
            else
                put_str_at(col, row, " .SYM files deleted")
        }
        set_color_run(0, SCR_W - 1, row, theme.CB_BAR)
    }

    sub put_num(ubyte col, ubyte row, ubyte n) -> ubyte {
        ; print n (0..255) left-aligned as decimal at (col,row); return the column past the last digit
        ubyte h = n / 100
        ubyte t = n / 10 % 10
        if h != 0 {
            txt.setchr(col, row, txt.petscii2scr('0' + h))
            col++
        }
        if h != 0 or t != 0 {
            txt.setchr(col, row, txt.petscii2scr('0' + t))
            col++
        }
        txt.setchr(col, row, txt.petscii2scr('0' + n % 10))
        return col + 1
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
            if etype != 0 {
                if hide_dirs
                    continue                     ; Hide Dirs: skip sub-directories ("../" was added above)
            } else {
                if basl_only and not is_basl(&diskio.list_filename)
                    continue                     ; Basl only: skip non-BASLOAD files
            }
            add_entry(etype, &diskio.list_filename, diskio.list_blocks)
            if file_count >= FILE_CAP
                break
        }
        diskio.lf_end_list()
        sort_dirs_first()                        ; group directories above files
    }

    ; ------------------------------------------------------------------ filter / footer / confirm

    sub fold(ubyte b) -> ubyte {
        ; PETSCII uppercase $C1-$DA -> $41-$5A, so extension matching is case-insensitive
        if b >= $c1 and b <= $da
            return b - $80
        return b
    }

    sub ends_ci(uword name, str suffix) -> bool {
        ; true if NUL-terminated `name` ends with `suffix`, folding letters to one case
        ubyte nl = 0
        while @(name + nl) != 0
            nl++
        ubyte sl = lsb(strings.length(suffix))
        if sl > nl
            return false
        ubyte i = 0
        while i < sl {
            if fold(@(name + nl - sl + i)) != fold(suffix[i])
                return false
            i++
        }
        return true
    }

    sub is_basl(uword name) -> bool {
        ; the BASLOAD source extensions (same set as edit.p8's has_basic_ext)
        return ends_ci(name, ".bas") or ends_ci(name, ".basl") or ends_ci(name, ".bl") or ends_ci(name, ".bas.txt")
    }

    sub draw_title_bar(ubyte x0, ubyte x1, ubyte row, str title) {
        ; solid title bar across the top border (mirrors misc.ovl's About box): fill the interior with
        ; spaces, centre the title, colour the whole run CB_BAR so it reads as one bar, not text on a line.
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SPACE_SC)
        ubyte tlen = lsb(strings.length(title))
        put_str_at(x0 + 1 + (x1 - x0 - 1 - tlen) / 2, row, title)
        set_color_run(x0 + 1, x1 - 1, row, theme.CB_BAR)
    }

    sub draw_footer(ubyte x0, ubyte x1, ubyte y1) {
        ; solid footer bar with the action + toggle hotkeys (reads hide_dirs / basl_only). Each hotkey is
        ; the highlighted FIRST letter of its word - Del / Folders / Basl - not a separate key prefix.
        ; Toggle state shows On/Off: Folders:On = sub-folders shown, Basl:On = only BASLOAD files listed.
        ; The Basl filter is a Dev feature: when EDIT's Dev menu is off (basl_avail=false) it is omitted.
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, y1, SPACE_SC)
        ubyte tw = 21                              ; "Del  Folders:XXX  Esc"
        if basl_avail
            tw = 31                                ; ...plus "  Basl:XXX"
        ubyte w = x1 - x0 + 1
        ubyte fs = x0 + (w - tw) / 2               ; centre the bar text
        put_str_at(fs, y1, "Del  Folders:")
        if hide_dirs
            put_str_at(fs + 13, y1, "Off")
        else
            put_str_at(fs + 13, y1, "On ")
        ubyte escoff = fs + 16
        if basl_avail {
            put_str_at(fs + 16, y1, "  BASL:")
            if basl_only
                put_str_at(fs + 23, y1, "On ")
            else
                put_str_at(fs + 23, y1, "Off")
            escoff = fs + 26
        }
        put_str_at(escoff, y1, "  Esc")
        set_color_run(x0 + 1, x1 - 1, y1, theme.CB_BAR)     ; whole interior = one solid bar
        ubyte acc = (theme.CB_BAR & $f0) | theme.ACCEL_FG   ; highlight D(el) / F(olders) [ / B(asl) ]
        txt.setclr(fs, y1, acc)
        txt.setclr(fs + 5, y1, acc)
        if basl_avail
            txt.setclr(fs + 18, y1, acc)
    }

    sub confirm_delete(ubyte x0, ubyte x1, ubyte y1, uword name) -> bool {
        ; "Del <name>? Y/N" on the footer bar; y = delete, anything else = keep
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, y1, SPACE_SC)
        ubyte fs = x0 + 2
        put_str_at(fs, y1, "Del ")
        ubyte nw = x1 - x0 - 12                     ; leave room for "Del " + "? Y/N"
        put_mem_trunc(fs + 4, y1, name, nw)
        ubyte nl = 0
        while @(name + nl) != 0 and nl < nw
            nl++
        put_str_at(fs + 4 + nl, y1, "? Y/N")
        set_color_run(x0 + 1, x1 - 1, y1, theme.CB_BAR)
        repeat {
            ubyte k = wait_key()
            if k == 27 or k == 3
                return false
            if k >= $c1 and k <= $da
                k -= $80
            if k == 'y'
                return true
            if k == 'n'
                return false
        }
    }

    ; ------------------------------------------------------------------ drawing (copies of edit.p8's)

    sub paint_row(ubyte r, ubyte x0, ubyte x1, ubyte first_row, ubyte top, ubyte cursor, ubyte namew) {
        ; paint one visible file row (relative index r): clear it, draw entry top+r (blank past the end of
        ; the list), and invert it when it is the cursor row. The picker repaints only the rows that change.
        ubyte rr = first_row + r
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

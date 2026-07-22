; menus - EDIT's dropdown-menu item labels + text renderer, in MENUS_BANK.
;
; draw_item() was the single biggest sub in edit.p8 (~1.1KB): a when/when of inline menu-item label
; literals. The labels are pure text (drawn to the screen, never touching the document arena), so
; they move out of EDIT's scarce low RAM into this banked overlay. Main keeps ALL the dropdown
; control, colouring, layout, accelerators and dispatch - it just calls mnu_item() to paint each
; item's text, exactly where its old local draw_item did.
;
; Compiled as a %output library headerless blob (org $A000), renamed menus.ovl by build.bat, loaded
; into its reserved HIRAM bank at startup via diskio.loadlib and called via `extsub @bank`. Unlike
; the About/viewer/picker overlays this one is NOT optional: without it the dropdowns paint blank
; (the menu bar, accelerators and shortcut keys still work). It ships beside edit.prg like misc.ovl.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = mnu_item.
; KEEP main's block free of initialized vars (the %jmptable gotcha) - labels are inline in the sub.

%import textio
%import diskio          ; for the .EDIT.SESSION per-folder session engine (edsess_op) hosted here
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    %jmptable ( main.mnu_item, main.mnu_bar, main.msg_text, main.edsess_op, main.mnu_mode, main.mnu_accel )

    ; static screen geometry, mirrored from edit.p8 (consts allocate no storage, so they don't
    ; disturb the %jmptable offsets the way an initialized var would).
    const ubyte SCR_W = 80
    const ubyte NMENU = 6
    const ubyte NDOCS = 3

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do.
    }

    sub mnu_mode(ubyte col @R0, ubyte row @R1, ubyte ovr @R2, ubyte caps @R3) -> ubyte {
        ; Paint the footer's INS/OVR indicator, plus CAPS when software Caps Lock is on. Moved out of
        ; main's draw_status into this overlay to reclaim scarce low RAM (put_str_at calls + string
        ; literals are costly there). ovr = overwrite mode, caps = software Caps Lock on (0/non-0).
        ; Returns the column just past the field so main can guard its centred "Total lines" block.
        if ovr != 0
            put_str_at(col, row, "  OVR")
        else
            put_str_at(col, row, "  INS")
        col += 5
        if caps != 0 {
            put_str_at(col, row, " CAPS")
            col += 5
        }
        return col
    }

    sub mnu_accel(ubyte which @R0, ubyte active @R1, ubyte arg @R2, ubyte showdev @R3) -> ubyte {
        ; Dropdown accelerator tables, hosted beside the labels so they leave main's low RAM.
        ; which 0: arg = a folded letter ($41-$5A, PETSCII lowercase = the char-literal encoding) ->
        ;          the item index the accelerator activates, else 255.
        ; which 1: arg = item index -> the accelerator letter's column offset within the label (for
        ;          highlighting), else 0.
        ; showdev = theme.show_dev (this overlay has no theme copy); the Help/Dev rows depend on it.
        ; These MUST stay in lock-step with mnu_item's labels below - a wrong offset mis-highlights.
        if which == 0 {
            when active {
                0 -> when arg { 'n' -> return 0   'o' -> return 1   'w' -> return 2   's' -> return 3   'a' -> return 4   'v' -> return 5   'c' -> return 6   'l' -> return 7   'x' -> return 8 }
                1 -> when arg { 'u' -> return 0   'r' -> return 1   't' -> return 2   'c' -> return 3   'p' -> return 4   'd' -> return 5   'i' -> return 6   'm' -> return 7   'n' -> return 8   'w' -> return 9 }
                2 -> when arg { 'f' -> return 0   'n' -> return 1   'r' -> return 2   'g' -> return 3 }
                3 -> when arg { 'r' -> return 0   'b' -> return 1   'd' -> return 2   't' -> return 3   'c' -> return 4   'u' -> return 5   'f' -> return 6   's' -> return 7   'l' -> return 8 }
                4 -> when arg { 'n' -> return 0   'a' -> return 1   'b' -> return 2   'c' -> return 3 }   ; Window: Next/A/B/C
                else -> {                        ; Help. Dev shown: H/B/T/C/A -> 0/1/2/3/4. Dev hidden: H/C/A -> 0/1/2
                    if showdev != 0 {
                        when arg { 'h' -> return 0   'b' -> return 1   't' -> return 2   'c' -> return 3   'a' -> return 4 }
                    } else {
                        when arg { 'h' -> return 0   'c' -> return 1   'a' -> return 2 }
                    }
                }
            }
            return 255
        } else {
            when active {
                0 -> when arg { 2 -> return 3   4 -> return 5   5 -> return 2   7 -> return 1   8 -> return 1 }   ; View 'w'@3, Save As 'A'@5, Save All 'v'@2, Close All 'l'@1, Exit 'x'@1
                1 -> when arg { 2 -> return 2   6 -> return 4   8 -> return 8 }   ; Cut 'T'@2, Duplicate 'i'@4, Move Down 'n'@8
                2 -> when arg { 1 -> return 5 }                       ; Find Next 'N'@5
                3 -> when arg { 1 -> return 5   6 -> return 15 }      ; Make Backup 'B'@5, Session file 'f'@15
                5 -> {                                               ; Help: Hints-Tips 'T'@6 (Dev-only row)
                    if showdev != 0 and arg == 2
                        return 6
                }
            }
            return 0
        }
    }

    sub mnu_item(ubyte active @R0, ubyte i @R1, ubyte col @R2, ubyte row @R3, ubyte flags @R4) {
        ; paint dropdown item `i` of menu `active` at (col,row). TEXT ONLY - the caller (main's
        ; draw_dropdown_item) laid the row colour first and re-colours the accelerator afterwards.
        ; flags: bit0 = word-wrap on, bit1 = syntax-colour on, bit2 = line-numbers on (the 3 toggles),
        ; bit3 = Dev menu shown (when clear, the Help menu drops BASLOAD + Hints-Tips and rows compact up),
        ; bit4 = a .EDIT.SESSION exists in this folder (Dev item shows Delete vs Create Session file).
        when active {
            0 -> {                          ; File
                when i {
                    0 -> put_str_at(col, row, "New        Ctrl+N")
                    1 -> put_str_at(col, row, "Open...    Ctrl+O")
                    2 -> put_str_at(col, row, "View...")
                    3 -> put_str_at(col, row, "Save       F2")
                    4 -> put_str_at(col, row, "Save As...")
                    5 -> put_str_at(col, row, "Save All")
                    6 -> put_str_at(col, row, "Close")
                    7 -> put_str_at(col, row, "Close All")
                    else -> put_str_at(col, row, "Exit")
                }
            }
            1 -> {                          ; Edit
                when i {
                    0 -> put_str_at(col, row, "Undo         Ctrl+Z")
                    1 -> put_str_at(col, row, "Redo         Ctrl+U")
                    2 -> put_str_at(col, row, "Cut Line     Ctrl+X")
                    3 -> put_str_at(col, row, "Copy         Ctrl+C")
                    4 -> put_str_at(col, row, "Paste        Ctrl+V/F4")
                    5 -> put_str_at(col, row, "Delete Line  Ctrl+E")
                    6 -> put_str_at(col, row, "Duplicate Line")
                    7 -> put_str_at(col, row, "Move Up      Ctrl+Up")
                    8 -> put_str_at(col, row, "Move Down    Ctrl+Dn")
                    else -> {
                        if (flags & 1) != 0
                            put_str_at(col, row, "Word Wrap    On ")
                        else
                            put_str_at(col, row, "Word Wrap    Off")
                    }
                }
            }
            2 -> {                          ; Search
                when i {
                    0 -> put_str_at(col, row, "Find...     Ctrl+F/F6")
                    1 -> put_str_at(col, row, "Find Next   Ctrl+G")
                    2 -> put_str_at(col, row, "Replace...  Ctrl+R/F8")
                    else -> put_str_at(col, row, "Go to Line  Ctrl+J")
                }
            }
            3 -> {                          ; Dev
                when i {
                    0 -> put_str_at(col, row, "Run BASLOAD  F5")
                    1 -> put_str_at(col, row, "Make Backup")
                    2 -> put_str_at(col, row, "Delete all SYM files")
                    3 -> put_str_at(col, row, "Toggle Comment  Ctrl+L")
                    4 -> put_str_at(col, row, "Comment Block   Ctrl+K")
                    5 -> put_str_at(col, row, "Uncomment Block Ctrl+W")
                    6 -> {                              ; bit4 = a .EDIT.SESSION exists in this folder
                        if (flags & 16) != 0
                            put_str_at(col, row, "Delete Session file")
                        else
                            put_str_at(col, row, "Create Session file")
                    }
                    7 -> {
                        if (flags & 2) != 0
                            put_str_at(col, row, "Syntax Color On ")
                        else
                            put_str_at(col, row, "Syntax Color Off")
                    }
                    else -> {
                        if (flags & 4) != 0
                            put_str_at(col, row, "Line Numbers On ")
                        else
                            put_str_at(col, row, "Line Numbers Off")
                    }
                }
            }
            else -> {                       ; Help
                ubyte hi = i
                if (flags & 8) == 0 and hi >= 1     ; Dev hidden -> skip BASLOAD (1) + Hints-Tips (2)
                    hi += 2
                when hi {
                    0 -> put_str_at(col, row, "Help...    F1")
                    1 -> put_str_at(col, row, "BASLOAD...")
                    2 -> put_str_at(col, row, "Hints-Tips")
                    3 -> put_str_at(col, row, "Config...")
                    else -> put_str_at(col, row, "About")
                }
            }
        }
    }

    sub put_str_at(ubyte col, ubyte row, str s) {
        ; identical to edit.p8's: write screen codes straight to VRAM, no cursor move / scroll.
        ubyte i = 0
        while s[i] != 0 {
            txt.setchr(col + i, row, txt.petscii2scr(s[i]))
            i++
        }
    }

    sub mnu_bar(uword ctxp @R0) {
        ; Repaint EDIT's top menu bar (row 0): bar fill, the six titles, the active-menu highlight,
        ; the accelerator letters, and the right-hand filename + A/B/C document indicator. Moved here
        ; from main's draw_menubar/draw_filename_title to reclaim scarce low RAM - it is pure screen
        ; painting (never touches the document arena). Everything dynamic arrives in a 9-byte context
        ; that main packs, because the theme COLOURS are runtime values and this overlay has its own,
        ; unrelated copy of theme; passing them keeps a custom palette correct here.
        ;   ctx: 0 active(255=none)  1 flags(b0 show_dev, b1 modified)  2 CB_BAR  3 CB_MENUSEL
        ;        4 ACCEL_FG  5 active_slot  6 slot_modified bits  7..8 filename pointer
        ubyte active  = @(ctxp)
        ubyte flags   = @(ctxp + 1)
        ubyte cbar    = @(ctxp + 2)
        ubyte cmensel = @(ctxp + 3)
        ubyte accel   = @(ctxp + 4)
        ubyte aslot   = @(ctxp + 5)
        ubyte smbits  = @(ctxp + 6)
        uword fnp     = peekw(ctxp + 7)
        bool showdev  = (flags & 1) != 0

        ; bar fill
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setclr(c, 0, cbar)
            txt.setchr(c, 0, $20)
        }
        ; titles at their fixed columns (menu_col = 1,7,13,21,26,34 in edit.p8)
        put_str_at(1,  0, "File")
        put_str_at(7,  0, "Edit")
        put_str_at(13, 0, "Search")
        if showdev
            put_str_at(21, 0, "Dev")            ; hidden when show_dev is off
        put_str_at(26, 0, "Window")
        put_str_at(34, 0, "Help")

        ; right end: filename immediately left of the A/B/C active-document indicator
        ubyte abc_col = SCR_W - NDOCS - 1
        put_str_at(abc_col, 0, "ABC")
        ubyte d
        for d in 0 to NDOCS - 1 {
            if d == aslot
                txt.setclr(abc_col + d, 0, cmensel)
            else if (smbits & (1 << d)) != 0       ; inactive doc with unsaved edits -> accent
                txt.setclr(abc_col + d, 0, (cbar & $f0) | accel)
        }
        ubyte fl = 0
        while @(fnp + fl) != 0
            fl++
        ubyte extra = 0
        if (flags & 2) != 0
            extra = 2
        bool useunt = fl == 0
        ubyte dl = fl
        if useunt
            dl = 8                              ; length of "untitled"
        ; drawn only if it clears the "Help" title (col 34 + len 4 = 38); guard the ubyte underflow
        if abc_col >= dl + extra + 1 {
            ubyte startcol = abc_col - dl - extra - 1
            if startcol >= 38 {
                if useunt
                    put_str_at(startcol, 0, "untitled")
                else {
                    ubyte j = 0
                    while @(fnp + j) != 0 {
                        txt.setchr(startcol + j, 0, txt.petscii2scr(@(fnp + j)))
                        j++
                    }
                }
                if (flags & 2) != 0
                    put_str_at(startcol + dl, 0, " *")
            }
        }

        ; active-menu highlight (whole title), then the accelerator letter on top
        if active != 255 {
            ubyte a0 = mcol(active)
            ubyte al = mlen(active)
            for c in a0 to a0 + al - 1
                txt.setclr(c, 0, cmensel)
        }
        ubyte mi
        for mi in 0 to NMENU - 1 {
            if showdev or mi != 3 {
                ubyte base = cbar
                if mi == active
                    base = cmensel
                txt.setclr(mcol(mi), 0, (base & $f0) | accel)
            }
        }
    }

    sub mcol(ubyte i) -> ubyte {
        when i {
            0 -> return 1
            1 -> return 7
            2 -> return 13
            3 -> return 21
            4 -> return 26
            else -> return 34
        }
    }

    sub mlen(ubyte i) -> ubyte {
        when i {
            0 -> return 4
            1 -> return 4
            2 -> return 6
            3 -> return 3
            4 -> return 6
            else -> return 4
        }
    }

    sub msg_text(ubyte id @R0, uword dest @R1) {
        ; Copy the id-th cold status-bar message into the caller's low-RAM `dest` buffer (>= 35 B).
        ; These are user-facing toasts/prompts that never run in a hot loop, so the text lives in this
        ; overlay's string pool instead of EDIT's scarce low RAM; main's msg(id) wrapper hands them to
        ; notify()/flash_notify()/put_str_at() unchanged. The IDs are the ABI - keep this `when` in
        ; lock-step with edit.p8's MSG_* constants (same order). The literals sit in this bank (mapped
        ; for the JSRFAR); dest is low RAM (always mapped), so a plain byte copy is correct.
        uword s
        when id {
            0  -> s = "Session issue, starting fresh."
            1  -> s = "File too big - not loaded"
            2  -> s = "Cannot open file"
            3  -> s = "Save cancelled"
            4  -> s = "All documents already saved"
            5  -> s = "Backup failed"
            6  -> s = "Backup saved"
            7  -> s = "Wrapped to top"
            8  -> s = "No search term - use Find first"
            9  -> s = "Clipboard empty"
            10 -> s = "Nothing to undo"
            11 -> s = "Nothing to redo"
            12 -> s = "Backing up..."
            13 -> s = "Document full - save now"
            14 -> s = "Line copied"
            15 -> s = "Save changes? Y/N  (Esc=Cancel)"
            16 -> s = "Overwrite existing file? Y/N"
            17 -> s = "Open or save a file first"
            else -> s = "Replace?  Yes  No  All  Esc"        ; id 18
        }
        ubyte i = 0
        while @(s + i) != 0 {
            @(dest + i) = @(s + i)
            i++
        }
        @(dest + i) = 0
    }

    ; ---------- .EDIT.SESSION per-folder session engine (Dev menu) ----------
    ; Hosted here (not picker.ovl - that bank was full) because menus.ovl had the room. The engine does
    ; the .EDIT.SESSION file I/O with diskio, but drives MAIN's own session dispatcher (ses_svc) + pointer
    ; table (SES_PTRS) for the slot load/save/activate work - the same generic ops the ed.run engine uses.
    ; main hands us &ses_svc + &SES_PTRS per call. The op numbers + P_* indices mirror edit.p8's ses_svc
    ; `when` and SES_PTRS order (only the subset used here). P_CUR_COL is an entry edit.p8 appended to
    ; SES_PTRS just for this feature. edsess_op is the jmptable's 4th entry -> $A00C, called via extsub.
    ;
    ; FILE FORMAT (.EDIT.SESSION, lowercase source literal -> uppercase on disk, see install.p8:29):
    ;   5   header  'e','d','s', 1 (version), active_slot
    ;   then per slot 0..2:  [namelen:1]  and if namelen>0:  name[namelen], row_lo, row_hi, col
    ; namelen 0 = empty slot. cursor row/col restore where you left off; the active slot is made current.
    ; NO clipboard/search/undo (that is ed.run's job) and NO force-save.
    const ubyte OP_BEGIN_W   = 0        ; commit_editbuf() + save_ctx(active)
    const ubyte OP_SAVE_CTX  = 1
    const ubyte OP_LOAD_CTX  = 2        ; scatter slot's context + point storage at it
    const ubyte OP_ACTIVATE  = 3        ; load_ctx(slot) + reload editbuf from its cur_row
    const ubyte OP_BLANK     = 4
    const ubyte OP_LOAD_FILE = 6        ; edoc.load_file(filename) -> r0L (0 = missing)
    const ubyte OP_UNDO_INIT = 7        ; undo_clear() + g_group=0 + recompute_gutter()
    const ubyte OP_SYNTAX    = 16       ; apply_syntax_mode(filename): colour + gutter by extension
    const ubyte P_ACT       = 0
    const ubyte P_MOD       = 1
    const ubyte P_FILENAME  = 2
    const ubyte P_CUR_ROW   = 10
    const ubyte P_TOP_LINE  = 11
    const ubyte P_LINECOUNT = 13
    const ubyte P_SELA      = 14
    const ubyte P_SELC      = 15
    const ubyte P_DIRTY     = 16
    const ubyte P_TEXTROWS  = 19
    const ubyte P_CUR_COL   = 26        ; appended to SES_PTRS by edit.p8 for .EDIT.SESSION
    const ubyte ES_NDOCS    = 3
    const ubyte ES_NAMEW    = 64        ; per-slot name field width within es_names

    ; all UNINITIALIZED (BSS tail) so the %jmptable offsets stay put
    uword es_svc, es_ptrs               ; main's &ses_svc / &SES_PTRS, wired per call
    ubyte es_act
    ubyte[5]   es_hdr                   ; small header / length / row-col file-I/O scratch
    ubyte[192] es_names                 ; 3 slots * ES_NAMEW: NUL-terminated filename read from the file
    uword[3]   es_row                   ; per-slot cursor row
    ubyte[3]   es_col                   ; per-slot cursor column

    sub esp(ubyte i) -> uword {
        return peekw(es_ptrs + (i as uword) * 2)        ; address of main global #i
    }
    sub esop0(ubyte op) {
        cx16.r0L = op
        void call(es_svc)
    }
    sub esop1(ubyte op, ubyte a) {
        cx16.r1L = a
        cx16.r0L = op
        void call(es_svc)
    }
    sub esopr(ubyte op) -> ubyte {
        cx16.r0L = op
        void call(es_svc)
        return cx16.r0L
    }

    sub edsess_op(ubyte op @R0, uword svc @R1, uword ptrs @R2) -> ubyte {
        ; op: 0 = exists?, 1 = delete, 2 = restore (load onto the fresh slots), 3 = write (snapshot).
        ; svc/ptrs are main's &ses_svc / &SES_PTRS (pass 0 for the file-only ops 0 and 1).
        ubyte o = op
        es_svc  = svc
        es_ptrs = ptrs
        when o {
            0 -> {
                if diskio.exists(".edit.session")
                    return 1
                return 0
            }
            1 -> {
                diskio.delete(".edit.session")
                void diskio.status()
                return 0
            }
            2 -> return es_restore()
            else -> {
                es_write()
                return 0
            }
        }
    }

    sub es_write() {
        ; Snapshot the three slots' {name, cursor} + the active slot into .EDIT.SESSION. No force-save
        ; and no untitled spill (unlike ed.run): main's exit save-prompt has already run, so a titled
        ; doc is on disk and an untitled slot is simply written empty. The write channel stays open the
        ; whole time - none of the ops here touch a disk file (context work is CLIP_BANK only; OP_ACTIVATE
        ; reloads editbuf from the arena, not disk), so there is no second-open clash.
        esop0(OP_BEGIN_W)                       ; commit the live line + freeze the active context
        ubyte act = @(esp(P_ACT))
        if not diskio.f_open_w(".edit.session")
            return
        es_hdr[0] = 'e'
        es_hdr[1] = 'd'
        es_hdr[2] = 's'
        es_hdr[3] = 1                           ; format version
        es_hdr[4] = act
        void diskio.f_write(&es_hdr, 5)
        ubyte s
        for s in 0 to ES_NDOCS - 1 {
            esop1(OP_LOAD_CTX, s)               ; slot s's name + cursor -> main's live globals
            uword fnp = esp(P_FILENAME)
            ubyte nl = 0
            while @(fnp + nl) != 0 and nl < ES_NAMEW - 1
                nl++
            es_hdr[0] = nl
            void diskio.f_write(&es_hdr, 1)
            if nl != 0 {
                void diskio.f_write(fnp, nl as uword)       ; name straight from main's low-RAM filename
                uword row = peekw(esp(P_CUR_ROW))
                es_hdr[0] = lsb(row)
                es_hdr[1] = msb(row)
                es_hdr[2] = @(esp(P_CUR_COL))
                void diskio.f_write(&es_hdr, 3)
            }
        }
        esop1(OP_ACTIVATE, act)                 ; the load_ctx walk left editbuf on another slot
        diskio.f_close_w()
    }

    sub es_restore() -> ubyte {
        ; Load the workspace .EDIT.SESSION describes onto the (already blank) A/B/C slots. Read EVERY
        ; record and CLOSE the file FIRST, then load the documents: OP_LOAD_FILE reopens the read channel,
        ; which would clobber our still-open .EDIT.SESSION handle (same order ed.run's ses_restore uses).
        if not diskio.f_open(".edit.session")
            return 0
        if diskio.f_read(&es_hdr, 5) != 5 {
            diskio.f_close()
            return 0
        }
        if es_hdr[0] != 'e' or es_hdr[1] != 'd' or es_hdr[2] != 's' or es_hdr[3] != 1 {
            diskio.f_close()                    ; not ours / wrong version -> leave the fresh slots as-is
            return 0
        }
        es_act = es_hdr[4]
        ubyte s
        uword nb                                ; slot s's name buffer base (hoisted - prog8 has no block scope)
        for s in 0 to ES_NDOCS - 1 {
            nb = &es_names + (s as uword) * ES_NAMEW
            @(nb) = 0                           ; default: empty slot
            es_row[s] = 0
            es_col[s] = 0
            if diskio.f_read(&es_hdr, 1) != 1
                break                           ; truncated -> stop; remaining slots stay empty
            ubyte nl = es_hdr[0]
            if nl == 0
                continue
            if nl > ES_NAMEW - 1
                nl = ES_NAMEW - 1
            if diskio.f_read(nb, nl as uword) != nl
                break
            @(nb + nl) = 0
            if diskio.f_read(&es_hdr, 3) != 3
                break
            es_row[s] = (es_hdr[0] as uword) | ((es_hdr[1] as uword) << 8)
            es_col[s] = es_hdr[2]
        }
        diskio.f_close()                        ; done reading - do NOT delete (.EDIT.SESSION persists)

        for s in 0 to ES_NDOCS - 1 {
            nb = &es_names + (s as uword) * ES_NAMEW
            if @(nb) == 0
                continue                        ; empty slot -> keep the blank doc init_doc_slots made
            esop1(OP_LOAD_CTX, s)               ; point storage at slot s (its context is blank)
            uword fnp = esp(P_FILENAME)
            ubyte i = 0
            while @(nb + i) != 0 {
                @(fnp + i) = @(nb + i)          ; name -> main's filename
                i++
            }
            @(fnp + i) = 0
            if esopr(OP_LOAD_FILE) == 0 {       ; moved/deleted since -> keep the slot blank
                esop0(OP_BLANK)
                esop1(OP_SAVE_CTX, s)
                continue
            }
            esop0(OP_SYNTAX)                    ; colour + gutter by extension (before UNDO_INIT's gutter refit)
            esop0(OP_UNDO_INIT)                 ; the reload reset the arena - drop the stale undo rings
            uword lc = peekw(esp(P_LINECOUNT))
            uword row = es_row[s]
            if row >= lc                        ; the file may have shrunk since we saved
                row = lc - 1
            pokew(esp(P_CUR_ROW), row)
            @(esp(P_CUR_COL)) = es_col[s]
            pokew(esp(P_TOP_LINE), 0)           ; pull the cursor onto screen
            uword trows = @(esp(P_TEXTROWS)) as uword
            if row >= trows
                pokew(esp(P_TOP_LINE), row - trows + 1)
            @(esp(P_SELA)) = 0                  ; a selection across a reload refers to a stale document
            @(esp(P_SELC)) = 0
            @(esp(P_DIRTY)) = 0
            @(esp(P_MOD)) = 0
            esop1(OP_SAVE_CTX, s)
        }
        if es_act >= ES_NDOCS
            es_act = 0
        @(esp(P_ACT)) = es_act                  ; restore which slot was active...
        esop1(OP_ACTIVATE, es_act)              ; ...and bring it up (context + editbuf)
        return 1
    }
}

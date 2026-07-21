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
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    %jmptable ( main.mnu_item, main.mnu_bar, main.msg_text )

    ; static screen geometry, mirrored from edit.p8 (consts allocate no storage, so they don't
    ; disturb the %jmptable offsets the way an initialized var would).
    const ubyte SCR_W = 80
    const ubyte NMENU = 6
    const ubyte NDOCS = 3

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do.
    }

    sub mnu_item(ubyte active @R0, ubyte i @R1, ubyte col @R2, ubyte row @R3, ubyte flags @R4) {
        ; paint dropdown item `i` of menu `active` at (col,row). TEXT ONLY - the caller (main's
        ; draw_dropdown_item) laid the row colour first and re-colours the accelerator afterwards.
        ; flags: bit0 = word-wrap on, bit1 = syntax-colour on, bit2 = line-numbers on (the 3 toggles),
        ; bit3 = Dev menu shown (when clear, the Help menu drops BASLOAD + Hints-Tips and rows compact up).
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
                    2 -> put_str_at(col, row, "Toggle Comment  Ctrl+L")
                    3 -> put_str_at(col, row, "Comment Block   Ctrl+K")
                    4 -> put_str_at(col, row, "Uncomment Block Ctrl+W")
                    5 -> {
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
}

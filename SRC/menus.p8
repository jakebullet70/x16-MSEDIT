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

    %jmptable ( main.mnu_item )

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do.
    }

    sub mnu_item(ubyte active @R0, ubyte i @R1, ubyte col @R2, ubyte row @R3, ubyte flags @R4) {
        ; paint dropdown item `i` of menu `active` at (col,row). TEXT ONLY - the caller (main's
        ; draw_dropdown_item) laid the row colour first and re-colours the accelerator afterwards.
        ; flags: bit0 = word-wrap on, bit1 = syntax-colour on, bit2 = line-numbers on (the 3 toggles),
        ; bit3 = Dev menu shown (when clear, the Help menu drops BASLOAD and its rows compact up).
        when active {
            0 -> {                          ; File
                when i {
                    0 -> put_str_at(col, row, "New        Ctrl+N")
                    1 -> put_str_at(col, row, "Open...    Ctrl+O")
                    2 -> put_str_at(col, row, "View...")
                    3 -> put_str_at(col, row, "Save       F2")
                    4 -> put_str_at(col, row, "Save As...")
                    5 -> put_str_at(col, row, "Save All")
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
                if (flags & 8) == 0 and hi >= 1     ; Dev hidden -> skip BASLOAD (logical index 1)
                    hi++
                when hi {
                    0 -> put_str_at(col, row, "Help...    F1")
                    1 -> put_str_at(col, row, "BASLOAD...")
                    2 -> put_str_at(col, row, "Config...")
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
}

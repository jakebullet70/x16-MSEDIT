; help - EDIT's Keyboard Map and About screens, run from a HIRAM bank overlay (HELP_BANK).
;
; Compiled as a %output library headerless blob (org $A000), renamed help.ovl by build.bat, loaded
; into its reserved HIRAM bank at startup via diskio.loadlib and called from EDIT via `extsub @bank`.
; These two screens are COLD (user-triggered, never in the edit loop) but expensive: ~850 bytes of
; literal text plus their draw code. EDIT has well under 1KB of low RAM to spare, so they live here.
;
; SELF-CONTAINED by design. An overlay cannot call back into main's subs (separate compilation
; units), so the drawing helpers below are the overlay's own copies of edit.p8's - main keeps its
; originals, which it still uses everywhere else. Colours are NOT shared either: the overlay imports
; theme.p8 and gets its own set of the colour vars, and the caller passes the theme ID so a
; theme.apply() here paints them the same as main's. That means zero main-RAM cost for the coupling:
; the whole contract is three numbers in R0-R2.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = help_keymap, $A006 = help_about.
;
; The caller repaints the editor (full_redraw) after we return - we only draw the box and block
; until a key.

%import textio
%import strings
%import theme
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; KEEP THIS BLOCK FREE OF INITIALIZED VARIABLES (the %jmptable gotcha, learned in XFMGR2):
    ; a module-level initialized var is emitted BEFORE the code and would shove the jump table off
    ; its fixed offsets. The screen text below is all inline literals inside subs - those are fine;
    ; it is only main's init-data that moves the table.
    %jmptable ( main.help_keymap, main.help_about )

    const ubyte SPACE_SC = sc:' '
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'
    const ubyte SC_VR = sc:'├'
    const ubyte SC_VL = sc:'┤'

    ubyte SCR_W, SCR_H                  ; UNINITIALIZED -> BSS tail, safe for the jmptable
    ubyte km_keyc                       ; left key column (set per width)
    ubyte km_desc                       ; left description column
    ubyte km_keyc2                      ; right key column   (80-col two-column layout)
    ubyte km_desc2                      ; right description column

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do - the
        ; screen size is read per call (EDIT can't change modes, but this costs nothing).
    }

    ; ------------------------------------------------------------------ public entries

    sub help_keymap(ubyte theme_id @R0) {
        enter(theme_id)
        ; wide 80-col box uses two columns of bindings; 40-col falls back to a single column.
        ubyte x0, x1, y1, bw, fcol
        if SCR_W >= 80 {
            bw = 68
            x0 = (SCR_W - bw) / 2       ; centred wide box, top at row 5
            x1 = x0 + bw - 1
            y1 = 23
            km_keyc  = x0 + 3           ; left column: keys at +3, descriptions at +16
            km_desc  = x0 + 16
            km_keyc2 = x0 + 37          ; right column: keys at +37, descriptions at +50
            km_desc2 = x0 + 50
            draw_box_frame(x0, 5, x1, y1)
            draw_box_shadow(x0, 5, x1, y1)
            draw_box_title(x0, x1, 5, " Keyboard Map ")
            km_row ( 7, "Arrows",       "Move cursor")
            km_row ( 8, "Ctrl+Lt/Rt",   "Jump a word")
            km_row ( 9, "Home / End",   "Start/end of line")
            km_row (10, "PgUp / PgDn",  "Page up / down")
            km_row (11, "Shift+arrows", "Select text")
            km_row (12, "Tab",          "Insert 4 spaces")
            km_row (13, "Ctrl+Up/Dn",   "Move line up/down")
            km_row (14, "Ctrl+K",       "Delete line")
            km_row2( 7, "Ctrl+C / X",   "Copy / Cut")
            km_row2( 8, "Ctrl+V / F4",  "Paste")
            km_row2( 9, "Ctrl+Z",       "Undo")
            km_row2(10, "Ctrl+U",       "Redo")
            km_row2(11, "Ctrl+F / F6",  "Find")
            km_row2(12, "Ctrl+G / F3",  "Find next")
            km_row2(13, "Ctrl+R / F8",  "Replace")
            km_row2(14, "Ctrl+N / O",   "New / Open")
            km_row2(15, "F2 / F1",      "Save / About")
            draw_box_sep(x0, x1, 16)                           ; ---- Run a BASIC file via BASLOAD ----
            km_row(18, "F5", "Save & run current file thru BASLOAD")
            km_row(19, "F8", "After BASLOAD, at BASIC READY: return to EDITOR")
            put_str_at(x0 + 3, 21, "Emulator eats Ctrl+F/R/V - use F6/F8/F4")
        } else {
            bw = 38
            x0 = (SCR_W - bw) / 2
            x1 = x0 + bw - 1
            y1 = 29
            km_keyc = x0 + 2
            km_desc = x0 + 17
            draw_box_frame(x0, 3, x1, y1)                      ; shadow omitted: runs off the 40-col edge
            draw_box_title(x0, x1, 3, " Keyboard Map ")
            km_row ( 5, "Arrows",       "Move cursor")
            km_row ( 6, "Ctrl+Lt/Rt",   "Jump a word")
            km_row ( 7, "Home / End",   "Start/end line")
            km_row ( 8, "PgUp / PgDn",  "Page up/down")
            km_row ( 9, "Shift+arrows", "Select text")
            km_row (10, "Tab",          "Insert 4 spaces")
            km_row (11, "Ctrl+Up/Dn",   "Move line up/dn")
            km_row (12, "Ctrl+K",       "Delete line")
            km_row (13, "Ctrl+C / X",   "Copy / Cut")
            km_row (14, "Ctrl+V / F4",  "Paste")
            km_row (15, "Ctrl+Z",       "Undo")
            km_row (16, "Ctrl+U",       "Redo")
            km_row (17, "Ctrl+F / F6",  "Find")
            km_row (18, "Ctrl+G / F3",  "Find next")
            km_row (19, "Ctrl+R / F8",  "Replace")
            km_row (20, "Ctrl+N / O",   "New / Open")
            km_row (21, "F2 / F1",      "Save / About")
            draw_box_sep(x0, x1, 23)                           ; ---- BASLOAD ----
            km_row(24, "F5", "Run file thru BASLOAD")
            km_row(25, "F8", "Return back to EDIT")
            put_str_at(x0 + 2, 27, "Emu eats Ctrl+F/R/V")
        }
        fcol = x0 + (bw - 15) / 2
        put_str_at(fcol, y1, " Press any key ")                ; hint on the bottom frame
        set_color_run(fcol, fcol + 14, y1, theme.CB_BOX)       ; white hint on the dark-grey frame
        void wait_key()
    }

    sub help_about(ubyte theme_id @R0, uword build @R1, ubyte emu @R2) {
        ; build = EDIT's BUILD_NUM (the version reads v0.9.<build>); emu != 0 -> running emulated.
        ; Both come from main: the overlay has no way to read main's consts, and passing them keeps
        ; the build number in ONE place (edit.p8, where syncbuild.ps1 bumps it).
        enter(theme_id)
        const ubyte w = 34
        ubyte x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte tx = x0 + 3
        draw_box_frame(x0, 9, x1, 18)
        draw_box_shadow(x0, 9, x1, 18)
        draw_box_title(x0, x1, 9, " About ")                   ; XFMGR-style solid title bar
        put_str_at(tx, 11, "EDIT  -  X16 Text Editor")
        put_str_at(tx, 12, "Text stored in banked RAM")
        if emu != 0
            put_str_at(tx, 13, "Running on:  Emulator")
        else
            put_str_at(tx, 13, "Running on:  Hardware")
        put_str_at(tx, 15,     "(c)sadLogic 2026 v0.9.")       ; version = v0.9.<build>
        void put_uw_at(tx + 22, 15, build)                     ; 22 = len("(c)sadLogic 2026 v0.9.")
        put_str_at(tx, 16,     "Open Source! play, have fun!")
        ubyte fcol = x0 + (w - 13) / 2
        put_str_at(fcol, 18, " Press any key ")
        set_color_run(fcol, fcol + 14, 18, theme.CB_BOX)
        void wait_key()
    }

    sub enter(ubyte theme_id) {
        ; paint the overlay's own colour vars the same as main's, and pick up the screen size
        theme.apply(theme_id)
        SCR_W = txt.width()
        SCR_H = txt.height()
    }

    ; ------------------------------------------------------------------ drawing (copies of edit.p8's)

    sub km_row(ubyte row, str keys, str desc) {
        put_str_at(km_keyc, row, keys)
        put_str_at(km_desc, row, desc)
    }

    sub km_row2(ubyte row, str keys, str desc) {
        put_str_at(km_keyc2, row, keys)
        put_str_at(km_desc2, row, desc)
    }

    sub put_str_at(ubyte col, ubyte row, str s) {
        ubyte i = 0
        while s[i] != 0 {
            txt.setchr(col + i, row, txt.petscii2scr(s[i]))
            i++
        }
    }

    sub put_uw_at(ubyte col, ubyte row, uword value) -> ubyte {
        ubyte[5] ds
        ubyte n = 0
        if value == 0 {
            ds[0] = '0'
            n = 1
        } else {
            while value != 0 {
                ds[n] = '0' + lsb(value % 10)
                value /= 10
                n++
            }
        }
        ubyte c = col
        ubyte i = n
        while i > 0 {
            i--
            txt.setchr(c, row, txt.petscii2scr(ds[i]))
            c++
        }
        return c
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

    sub draw_box_title(ubyte x0, ubyte x1, ubyte row, str title) {
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SPACE_SC)
        ubyte tlen = lsb(strings.length(title))
        put_str_at(x0 + 1 + (x1 - x0 - 1 - tlen) / 2, row, title)
        set_color_run(x0 + 1, x1 - 1, row, theme.CB_BAR)
    }

    sub draw_box_sep(ubyte x0, ubyte x1, ubyte row) {
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SC_H)
        txt.setchr(x0, row, SC_VR)
        txt.setchr(x1, row, SC_VL)
        set_color_run(x0, x1, row, theme.CB_BORDER)
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

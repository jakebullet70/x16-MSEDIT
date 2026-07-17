; misc - EDIT's miscellaneous banked-overlay screens (currently just About), in MISC_BANK.
;
; Compiled as a %output library headerless blob (org $A000), renamed misc.ovl by build.bat, loaded
; into its reserved HIRAM bank at startup via diskio.loadlib and called from EDIT via `extsub @bank`.
; The About box is COLD (user-triggered) and carries a chunk of literal text + its box-draw code,
; so it lives here in banked RAM rather than EDIT's scarce low RAM. Named "misc" (like XFMGR2's
; miscutil.ovl) as the home for small cold overlay screens as more are added.
;
; (The Keyboard Map used to live here too; it is now shipped as a text file, edit.md, shown
; in the tview.ovl viewer - so the key list is editable data instead of hand-drawn code.)
;
; SELF-CONTAINED by design. An overlay cannot call back into main's subs (separate compilation
; units), so the drawing helpers below are the overlay's own copies of edit.p8's. Colours are NOT
; shared either: the overlay imports theme.p8 and gets its own set of the colour vars, and the caller
; passes the theme ID so theme.apply() here paints them the same as main's.
;
; Also hosts ovl_prompt: the modal status-row TEXT INPUT (Save-As / Find / Replace / Go-to). It is
; cold (only runs while a dialog is open, JSRFAR once per prompt - the key loop stays IN the overlay)
; and was ~200 B of edit.p8's scarce low RAM. All its data (prompt string, dest buffer, ww_on flag)
; lives in main's low RAM, which stays mapped when bank 10 is at $A000, so the overlay reads/writes it
; directly through the pointers the caller passes - no callback trampolines needed.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = help_about, $A006 = ovl_prompt.
;
; The caller repaints the editor (full_redraw) after we return - we only draw the box/prompt and
; block until a key.

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
    %jmptable ( main.help_about, main.ovl_prompt )

    const ubyte SPACE_SC = sc:' '
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'

    ubyte SCR_W, SCR_H                  ; UNINITIALIZED -> BSS tail, safe for the jmptable

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. Nothing else to do.
    }

    ; ------------------------------------------------------------------ public entry

    sub help_about(ubyte theme_id @R0, uword build @R1, ubyte emu @R2) {
        ; build = EDIT's BUILD_NUM (the version reads v0.9.<build>); emu != 0 -> running emulated.
        ; Both come from main: the overlay has no way to read main's consts, and passing them keeps
        ; the build number in ONE place (edit.p8, where syncbuild.ps1 bumps it).
        theme.apply(theme_id)              ; paint in EDIT's current scheme (our own theme.p8 copy)
        SCR_W = txt.width()
        SCR_H = txt.height()
        const ubyte w = 46                 ; box width (was 34: +12 wider)
        ubyte x0 = 1                        ; centre horizontally; the guard keeps x0 sane on a 40-col
        if SCR_W > w + 1                    ; screen where the wide box can't fit (would underflow)
            x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte tx = x0 + 3
        const ubyte y0 = 8                  ; box top/bottom rows (was 9..18 = 10 tall; now 8..21 = 14, +4)
        const ubyte y1 = 21
        draw_box_frame(x0, y0, x1, y1)
        draw_box_shadow(x0, y0, x1, y1)
        draw_box_title(x0, x1, y0, " About ")                  ; XFMGR-style solid title bar
        put_str_at(tx, 10, "EDIT - X16 Text Editor & BASLOAD IDE")
        put_str_at(tx, 12, "A DOS EDIT-style text editor for")
        put_str_at(tx, 13, "the Commander X16, with live BASIC")
        put_str_at(tx, 14, "syntax colouring and F5 BASLOAD run.")
        if emu != 0
            put_str_at(tx, 16, "Running on:  Emulator")
        else
            put_str_at(tx, 16, "Running on:  Hardware")
        put_str_at(tx, 17,     "Version:     v0.9.")            ; version = v0.9.<build>
        void put_uw_at(tx + 18, 17, build)                     ; 18 = len("Version:     v0.9.")
        put_str_at(tx, 19,     "(c) sadLogic 2026  -  Open Source")
        ;put_str_at(tx, 20,     "Play, have fun!")
        ubyte fcol = x0 + (w - 15) / 2                          ; centre " Press any key " (15 wide)
        put_str_at(fcol, y1, " Press any key ")
        set_color_run(fcol, fcol + 14, y1, theme.CB_BOX)
        void wait_key()
    }

    sub ovl_prompt(uword promptmsg @R0, uword dest @R1, ubyte maxlen @R2, ubyte flags @R3,
                   ubyte theme_id @R4, uword wwptr @R5) -> ubyte {
        ; Modal text input on the status row - the moved-out body of edit.p8's prompt_str. Returns 1 on
        ; Enter (0 if empty and not allow_empty), 0 on Esc/Stop. Pre-fills from whatever dest holds.
        ;   flags bit0 = allow_empty, bit1 = ww_hint (show/toggle the whole-word label).
        ;   wwptr -> main's ww_on byte: read to draw the label, written on Commodore+W (bit0 toggle).
        ; promptmsg/dest/wwptr all point into main's low RAM (stays mapped under bank 10) - read direct.
        theme.apply(theme_id)                   ; our own theme.p8 copy, painted to match main
        SCR_W = txt.width()
        SCR_H = txt.height()
        ubyte statusrow = SCR_H - 1
        bool allow_empty = (flags & 1) != 0
        bool ww_hint     = (flags & 2) != 0
        bar_fill(statusrow, $21)                 ; one red flash so the prompt draws the eye
        put_str_at(1, statusrow, promptmsg)
        sys.wait(18)                             ; ~0.3s (was flash_status in main)
        bar_fill(statusrow, theme.CB_BAR)        ; settle to the normal bar
        put_str_at(1, statusrow, promptmsg)
        if ww_hint
            draw_ww_label(statusrow, wwptr)
        ubyte base = lsb(strings.length(promptmsg)) + 2
        ubyte n = 0                              ; pre-fill length: scan dest up to maxlen
        while n < maxlen and @(dest + n) != 0
            n++
        repeat {
            ubyte c = base
            ubyte i = 0
            while i < n {
                txt.setchr(c, statusrow, txt.petscii2scr(@(dest + i)))
                c++
                i++
            }
            txt.setchr(c, statusrow, SPACE_SC)
            txt.setclr(c, statusrow, theme.CB_CUR)
            ubyte k = wait_key()
            txt.setclr(c, statusrow, theme.CB_BAR)
            when k {
                13 -> {
                    @(dest + n) = 0
                    if allow_empty
                        return 1
                    if n != 0
                        return 1
                    return 0
                }
                27, 3 -> {
                    @(dest) = 0
                    return 0
                }
                20 -> {
                    if n > 0 {
                        n--
                        txt.setchr(base + n, statusrow, SPACE_SC)
                    }
                }
                179 -> {                         ; Commodore+W (ALT+W): toggle whole-word live
                    if ww_hint {                 ; (search prompts only; 179 = alt_letter['w'])
                        @(wwptr) ^= 1            ; flip main's ww_on (bool stored 0/1)
                        draw_ww_label(statusrow, wwptr)
                    }
                }
                else -> {
                    if n < maxlen and k >= 32 and k <= 126 {
                        @(dest + n) = k
                        n++
                    }
                }
            }
        }
    }

    ; ------------------------------------------------------------------ drawing (copies of edit.p8's)

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

    sub bar_fill(ubyte row, ubyte color) {
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setclr(c, row, color)
            txt.setchr(c, row, SPACE_SC)
        }
    }

    sub draw_ww_label(ubyte statusrow, uword wwptr) {
        ; whole-word On/Off indicator with the W accelerator highlighted (the live=true form of
        ; edit.p8's draw_ww_label - the only form the input prompts use).
        ubyte c = SCR_W - 16                    ; "Whole Word  Off" = 15 chars + a 1-col right margin
        if @(wwptr) != 0
            put_str_at(c, statusrow, "Whole Word  On ")
        else
            put_str_at(c, statusrow, "Whole Word  Off")
        txt.setclr(c, statusrow, (theme.CB_BAR & $f0) | theme.ACCEL_FG)
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

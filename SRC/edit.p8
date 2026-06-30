; EDIT - a basic full-screen text editor for the Commander X16 (like MS-DOS EDIT).
;
;   * 80x30 text screen: menu bar (row 0), text area, status bar (bottom row)
;   * MS-Edit style dropdown menus (File / Help), opened with ALT or Esc
;   * the document text lives in BANKED RAM via the edoc/xarena storage layer
;   * core editing: type, Enter, Backspace, arrows, Home, PgUp/PgDn, Tab
;   * File: New, Open, Save, Save As, Exit  (with save-changes prompts)
;
; PETSCII is used internally (keyboard + screen); files on disk are plain ASCII
; (edoc converts on load/save). Lines are stored from a RAM editbuf and committed
; back to banked RAM only when the cursor leaves the line; Save defrags by writing
; to disk then reloading.

%import textio
%import strings
%import edoc
%import xarena
%import emudbg
%import diskio                          ; directory listing for the Open file picker
%zeropage basicsafe
; skip prog8's system re-init (IOINIT/RESTOR/CINT) so the screen mode the machine booted
; in (e.g. BASIC "SCREEN 3" = 40x30) survives into start() and can be adopted. CINT would
; otherwise reset VERA to the 80-col default before our code runs. (We are launched from
; BASIC, which has already done IOINIT/RESTOR, so skipping the re-init is safe here.)
%option no_sysinit

main {
    const ubyte TEXT_TOP   = 1          ; first text-area row (row 0 is the menu bar)
    const ubyte NMENU      = 4
    const ubyte MOD_ALT    = $02        ; kbdbuf_get_modifiers bit
    const ubyte MENU_KEY   = 200        ; synthetic key: open the menu bar

    ; colour bytes for setclr (high nibble = bg, low nibble = fg; X16 default palette)
    const ubyte COL_FG  = 1             ; white  (clear_screen / chrout colour)
    const ubyte COL_BG  = 6             ; blue
    const ubyte CB_BODY = $61           ; blue bg, white fg   (edit area)
    const ubyte CB_BAR  = $f0           ; lt-grey bg, black fg (bars + popups)
    const ubyte CB_SEL  = $6f           ; blue bg, white fg   (highlighted item)
    const ubyte CB_CUR  = $16           ; white bg, blue fg   (text cursor cell)
    const ubyte CB_MARK = $30           ; cyan bg, black fg   (selected text)
    const ubyte CB_SHADOW = $00         ; black bg, black fg  (popup drop-shadow)
    const ubyte MOD_SHIFT = $01         ; kbdbuf_get_modifiers shift bit
    const ubyte MOD_CTRL  = $04         ; kbdbuf_get_modifiers ctrl bit

    const ubyte SPACE_SC = sc:' '
    ; box-drawing SCREENCODES (drawn with setchr - never moves the cursor)
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'

    ; runtime screen geometry (queried after the mode switch)
    ubyte SCR_W, SCR_H, TEXT_ROWS, STATUS_ROW
    ubyte saved_mode

    ; document/cursor/view state
    str filename = "?" * 40
    str fnbuf    = "?" * 42             ; input scratch for prompts
    str savebuf  = "?" * 44             ; "@:" + filename for overwrite
    str untitled = "untitled"
    ubyte[256] editbuf                  ; the line under the cursor (raw PETSCII)
    ubyte[256] tmpbuf                   ; scratch for rendering / line joins
    ubyte cur_len                       ; length of editbuf
    uword cur_row, top_line             ; cursor line / first visible line
    ubyte cur_col, left_col             ; cursor column / first visible column
    bool cur_dirty                      ; editbuf differs from its stored record
    bool modified                       ; document changed since last save
    bool g_running
    bool alt_was                        ; ALT held on the previous poll (edge detect)
    ubyte g_mod                         ; modifier byte captured when the last key was read
    bool g_emu                          ; true if running under the x16emu emulator

    ; --- keys the x16emu emulator intercepts before they reach the program ---
    ; Verified with Help>Key Probe under x16emu r49: the emulator eats
    ;   Ctrl+V -> paste host clipboard   (delivers the pasted chars, not code 22)
    ;   Ctrl+F -> toggle fullscreen      (delivers nothing, code 0)
    ;   Ctrl+R -> RESET the machine      (reboots to BASIC - very destructive!)
    ; All other Ctrl shortcuts EDIT uses (C/X/K/G/N/O) pass through fine. Because
    ; an intercepted keystroke never reaches us, we cannot "unbind" it - instead
    ; the three affected actions (paste/find/replace) get function-key aliases
    ; (F4/F6/F8) that pass through on BOTH emulator and hardware. The Ctrl keys
    ; stay bound for real hardware. g_emu (emudbg.is_emulator()) records the
    ; environment; the F-key aliases are unconditional so no per-env branch is
    ; needed. (XFMGR2 saw the same class of issue with Ctrl-D / Ctrl-S.)

    ; text selection (Shift+cursor). The anchor is fixed; the cursor is the moving end.
    bool sel_active
    uword anc_row
    ubyte anc_col
    uword s_row, e_row                  ; normalized selection start/end (set by sel_norm)
    ubyte s_col, e_col

    ; search / replace
    str find_term = "?" * 40            ; current search term
    str repl_term = "?" * 40            ; current replacement
    ubyte[256] workbuf                  ; scratch for building a replaced line
    uword found_row                     ; result of the last find
    ubyte found_col
    uword g_repl_count                  ; replacements committed in replace_all
    ubyte g_line_repls                  ; replacements made in the current line

    ; clipboard - holds either one whole line (clip_line=true, paste as a new line)
    ; or selected text (clip_line=false, paste inline; may contain $0D line breaks)
    uword clipbuf = memory("clip", 1024, 0)
    uword clip_len
    bool clip_has
    bool clip_line

    ; file-picker popup: directory entries copied verbatim from diskio's listing into
    ; a flat slab (FNREC bytes per record, NUL-terminated name) for the Open dialog.
    const ubyte FILE_CAP = 128          ; max entries shown
    const ubyte FNREC    = 32           ; bytes per record (name up to 31 + NUL)
    uword filelist = memory("flist", 4096, 0)   ; FILE_CAP * FNREC
    ubyte file_count
    str startdir = "?" * 82             ; working dir at startup (restored on exit); diskio MAX_PATH_LEN=80

    ubyte[NMENU] menu_col = [2, 9, 16, 25]   ; start column of each top-menu title
    ubyte[NMENU] menu_len = [4, 4, 6, 4]     ; File, Edit, Search, Help

    const ubyte ACCEL_FG = 2                 ; red - accelerator-letter highlight fg
    ; ALT is the Commodore key, so ALT+letter arrives as a graphics code $A1..$BF (161..191);
    ; this maps each (indexed by code-161) back to its base letter. 0 = not a letter.
    ; (verbatim from sibling XFMGR2; e.g. ALT+F=187, ALT+E=177, ALT+S=174, ALT+H=180)
    ubyte[31] alt_letter = [
        'k','i','t', 0 ,'g', 0 ,'m', 0 , 0 ,'n','q','d','z','s','p',
        'a','e','r','w','h','j','l','y','u','o', 0 ,'f','c','x','v','b' ]

    sub menu_for_letter(ubyte letter) -> ubyte {
        ; top-menu accelerator: F/E/S/H -> menu index 0..3, else 255
        when letter {
            'f' -> return 0
            'e' -> return 1
            's' -> return 2
            'h' -> return 3
        }
        return 255
    }

    sub item_accel(ubyte active, ubyte key) -> ubyte {
        ; dropdown item accelerator: a folded letter -> item index, else 255
        when active {
            0 -> when key { 'n' -> return 0   'o' -> return 1   's' -> return 2   'a' -> return 3   'x' -> return 4 }
            1 -> when key { 't' -> return 0   'c' -> return 1   'p' -> return 2   'd' -> return 3 }
            2 -> when key { 'f' -> return 0   'n' -> return 1   'r' -> return 2 }
            else -> when key { 'k' -> return 0   'a' -> return 1 }
        }
        return 255
    }

    sub accel_off(ubyte active, ubyte i) -> ubyte {
        ; column offset of the accelerator letter within an item label (for highlighting)
        when active {
            0 -> when i { 3 -> return 5   4 -> return 1 }       ; Save As 'A'@5, Exit 'x'@1
            1 -> when i { 0 -> return 2 }                       ; Cut 'T'@2
            2 -> when i { 1 -> return 5 }                       ; Find Next 'N'@5
        }
        return 0
    }

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        ; adopt the column width the machine booted in: 40-col -> 40x30, else 80x30.
        ; both normalize to a 30-row layout; the UI lays itself out from SCR_W/SCR_H below.
        ; NOTE: use the booted MODE byte, not txt.width() - at startup conio still reports
        ; its 80-col default even when VERA is in a 40-col mode. X16 40-col text modes are
        ; $02 (40x60), $03 (40x30), $04 (40x15).
        if saved_mode >= $02 and saved_mode <= $04
            cx16.set_screen_mode($03)           ; 40x30
        else
            cx16.set_screen_mode($01)           ; 80x30
        SCR_W = txt.width()
        SCR_H = txt.height()
        TEXT_ROWS  = SCR_H - 2
        STATUS_ROW = SCR_H - 1
        txt.lowercase()

        g_emu = emudbg.is_emulator()    ; remember the runtime environment
        xarena.detect_banks()           ; clamp banked storage to the RAM actually installed
        find_term[0] = 0                ; the "?"*N buffers start non-empty; clear them
        repl_term[0] = 0
        clip_has = false
        ; remember the working directory so we can restore it on exit (the file picker
        ; may chdir away). curdir() needs X16 DOS R42+; 0 = unsupported/error -> skip.
        startdir[0] = 0
        cx16.r1 = diskio.curdir()
        if cx16.r1 != 0
            void strings.copy(cx16.r1, startdir)
        new_document()
        full_redraw()
        g_running = true
        while g_running {
            ubyte k = get_editor_key()
            editor_key(k)
        }

        if startdir[0] != 0             ; restore the working dir we started in
            diskio.chdir(startdir)
        txt.color2(COL_FG, COL_BG)
        txt.clear_screen()
        cx16.set_screen_mode(saved_mode)
        txt.print("edit done.\n")
    }

    ; ---------- low-level drawing helpers ----------

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

    sub draw_box_frame(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ubyte r
        ubyte c
        for r in y0 to y1 {
            set_color_run(x0, x1, r, CB_BAR)
            for c in x0 to x1                   ; blank interior so text behind doesn't bleed through
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
    }

    sub draw_box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ; classic drop shadow: darken the cells one row below and one column to
        ; the right of the box (colour only - the glyphs behind go black-on-black)
        ubyte c
        ubyte r
        if y1 + 1 < SCR_H
            for c in x0 + 1 to x1 + 1
                if c < SCR_W
                    txt.setclr(c, y1 + 1, CB_SHADOW)
        if x1 + 1 < SCR_W
            for r in y0 + 1 to y1
                txt.setclr(x1 + 1, r, CB_SHADOW)
    }

    ; ---------- text-area rendering ----------

    sub draw_text_row(ubyte r) {
        ; paint one screen row: characters, body colour, selection highlight, cursor cell
        ubyte sy = TEXT_TOP + r
        uword idx = top_line + r
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setchr(c, sy, SPACE_SC)
            txt.setclr(c, sy, CB_BODY)
        }
        ubyte blen = 0
        if idx < edoc.line_count {
            uword bufptr
            if idx == cur_row {
                bufptr = &editbuf
                blen = cur_len
            } else {
                blen = edoc.load(idx, &tmpbuf)
                bufptr = &tmpbuf
            }
            ubyte sc_i = 0
            while sc_i < SCR_W {
                uword srcidx = left_col
                srcidx += sc_i
                if srcidx >= blen
                    break
                txt.setchr(sc_i, sy, txt.petscii2scr(@(bufptr + srcidx)))
                sc_i++
            }
        }
        ; selection highlight: cells whose doc column is in [c0, c1) on this row
        if sel_active {
            sel_norm()
            if idx >= s_row and idx <= e_row {
                ubyte c0 = 0
                if idx == s_row
                    c0 = s_col
                uword c1 = blen             ; whole rest of line for non-end rows
                if idx == e_row
                    c1 = e_col
                ubyte sccol = 0
                while sccol < SCR_W {
                    uword dcol = left_col
                    dcol += sccol
                    if dcol >= c1
                        break
                    if dcol >= c0
                        txt.setclr(sccol, sy, CB_MARK)
                    sccol++
                }
            }
        }
        ; cursor cell
        if idx == cur_row and cur_col >= left_col {
            ubyte ccol = cur_col - left_col
            if ccol < SCR_W
                txt.setclr(ccol, sy, CB_CUR)
        }
    }

    sub draw_all_text() {
        ubyte r
        for r in 0 to TEXT_ROWS - 1
            draw_text_row(r)
    }

    sub draw_doc_line() {
        draw_text_row(lsb(cur_row - top_line))
    }

    sub sel_norm() {
        ; order the anchor and the cursor into (s_row,s_col) <= (e_row,e_col)
        if anc_row < cur_row or (anc_row == cur_row and anc_col <= cur_col) {
            s_row = anc_row
            s_col = anc_col
            e_row = cur_row
            e_col = cur_col
        } else {
            s_row = cur_row
            s_col = cur_col
            e_row = anc_row
            e_col = anc_col
        }
    }

    sub ensure_visible() -> bool {
        bool s = false
        if cur_row < top_line {
            top_line = cur_row
            s = true
        } else if cur_row >= top_line + TEXT_ROWS {
            top_line = cur_row - TEXT_ROWS + 1
            s = true
        }
        if cur_col < left_col {
            left_col = cur_col
            s = true
        } else if cur_col >= left_col + SCR_W {
            left_col = cur_col - SCR_W + 1
            s = true
        }
        return s
    }

    sub place_cursor() {
        ; no-op: the cursor cell is now painted by draw_text_row. Kept so the many
        ; existing call sites still compile; they always repaint the affected row(s).
    }

    sub redraw_after_move() {
        ; a move can change the cursor row, the old cursor row, and the selection,
        ; so repaint the whole text area (cheap enough at human key rates)
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    ; ---------- menu bar / status bar ----------

    sub draw_filename_title() {
        ubyte fl = lsb(strings.length(filename))
        ubyte extra = 0
        if modified
            extra = 2
        ubyte dl = fl
        if fl == 0
            dl = lsb(strings.length(untitled))
        ubyte startcol = SCR_W - dl - extra - 1
        ; don't overwrite the menu titles when the bar is narrow (40-col)
        if startcol < menu_col[NMENU - 1] + menu_len[NMENU - 1]
            return
        if fl == 0
            put_str_at(startcol, 0, untitled)
        else
            put_str_at(startcol, 0, filename)
        if modified
            put_str_at(startcol + dl, 0, " *")
    }

    sub draw_menubar(ubyte active) {
        bar_fill(0, CB_BAR)
        put_str_at(menu_col[0], 0, "File")
        put_str_at(menu_col[1], 0, "Edit")
        put_str_at(menu_col[2], 0, "Search")
        put_str_at(menu_col[3], 0, "Help")
        draw_filename_title()
        if active != 255 {
            ubyte x
            for x in menu_col[active] to menu_col[active] + menu_len[active] - 1
                txt.setclr(x, 0, CB_SEL)
        }
        ; highlight each title's accelerator letter (F/E/S/H, always the first char)
        ubyte mi
        for mi in 0 to NMENU - 1 {
            ubyte base = CB_BAR
            if mi == active
                base = CB_SEL
            txt.setclr(menu_col[mi], 0, (base & $f0) | ACCEL_FG)
        }
    }

    sub draw_status() {
        bar_fill(STATUS_ROW, CB_BAR)
        ubyte col = 1
        put_str_at(col, STATUS_ROW, "Line ")
        col += 5
        col = put_uw_at(col, STATUS_ROW, cur_row + 1)
        put_str_at(col, STATUS_ROW, "  Col ")
        col += 6
        col = put_uw_at(col, STATUS_ROW, cur_col + 1)
        if modified {
            put_str_at(col, STATUS_ROW, " *")
            col += 2
        }
        ; right-side menu hint (short form when narrow)
        ubyte hint_col
        if SCR_W >= 80 {
            hint_col = SCR_W - 13
            put_str_at(hint_col, STATUS_ROW, "Esc/Alt=Menu")
        } else {
            hint_col = SCR_W - 9
            put_str_at(hint_col, STATUS_ROW, "Alt=Menu")
        }
        ; document / banked-RAM usage - only if it fits between cursor info and the hint
        ubyte stats = col + 2
        if stats + 24 < hint_col {
            put_str_at(stats, STATUS_ROW, "Lines ")
            col = put_uw_at(stats + 6, STATUS_ROW, edoc.line_count)
            put_str_at(col, STATUS_ROW, "  Banks ")
            col = put_uw_at(col + 8, STATUS_ROW, xarena.high_bank)
            put_str_at(col, STATUS_ROW, "/")
            void put_uw_at(col + 1, STATUS_ROW, xarena.max_bank)
        }
    }

    sub full_redraw() {
        txt.color2(COL_FG, COL_BG)
        txt.clear_screen()
        draw_menubar(255)
        draw_all_text()
        draw_status()
        place_cursor()
    }

    ; ---------- input ----------

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub get_editor_key() -> ubyte {
        ; like wait_key, but ALT released with no key returns the synthetic MENU_KEY.
        ; We wait for ALT *release* (not press) so an Alt+letter chord delivers its letter
        ; (a graphics code 161-191) to us as a menu accelerator instead of opening File.
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0 {
                g_mod = cx16.kbdbuf_get_modifiers()
                alt_was = false             ; a key consumed the ALT chord (if any)
                return k
            }
            ubyte hold = cx16.kbdbuf_get_modifiers()
            if (hold & MOD_ALT) != 0 {
                alt_was = true              ; ALT held - wait to see if a letter follows
            } else {
                if alt_was {                ; ALT released with no key -> open File menu
                    alt_was = false
                    return MENU_KEY
                }
            }
        }
    }

    sub prompt_str(str promptmsg, uword dest, ubyte maxlen, bool allow_empty) -> bool {
        ; modal text input on the status row. Enter -> true (false if empty and not
        ; allow_empty); Esc/Stop -> false. Pre-fills with whatever is already in dest.
        bar_fill(STATUS_ROW, CB_BAR)
        put_str_at(1, STATUS_ROW, promptmsg)
        ubyte base = lsb(strings.length(promptmsg)) + 2
        ubyte n = 0                          ; pre-fill length: scan dest up to maxlen
        while n < maxlen and @(dest + n) != 0
            n++
        repeat {
            ubyte c = base
            ubyte i = 0
            while i < n {
                txt.setchr(c, STATUS_ROW, txt.petscii2scr(@(dest + i)))
                c++
                i++
            }
            txt.setchr(c, STATUS_ROW, SPACE_SC)
            txt.setclr(c, STATUS_ROW, CB_CUR)
            ubyte k = wait_key()
            txt.setclr(c, STATUS_ROW, CB_BAR)
            when k {
                13 -> {
                    @(dest + n) = 0
                    if allow_empty
                        return true
                    return n != 0
                }
                27, 3 -> {
                    @(dest) = 0
                    return false
                }
                20 -> {
                    if n > 0 {
                        n--
                        txt.setchr(base + n, STATUS_ROW, SPACE_SC)
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

    sub confirm_save() -> ubyte {
        ; 0 = don't save, 1 = save, 2 = cancel
        bar_fill(STATUS_ROW, CB_BAR)
        put_str_at(1, STATUS_ROW, "Save changes? Y/N  (Esc=Cancel)")
        repeat {
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            when k {
                'y' -> return 1
                'n' -> return 0
                27, 3 -> return 2
            }
        }
    }

    sub notify(str m) {
        bar_fill(STATUS_ROW, CB_BAR)
        put_str_at(1, STATUS_ROW, m)
        sys.wait(60)
    }

    ; ---------- dropdown menus ----------

    sub draw_item(ubyte active, ubyte i, ubyte col, ubyte row) {
        when active {
            0 -> {                          ; File
                when i {
                    0 -> put_str_at(col, row, "New        Ctrl+N")
                    1 -> put_str_at(col, row, "Open...    Ctrl+O")
                    2 -> put_str_at(col, row, "Save       F2")
                    3 -> put_str_at(col, row, "Save As...")
                    else -> put_str_at(col, row, "Exit")
                }
            }
            1 -> {                          ; Edit
                when i {
                    0 -> put_str_at(col, row, "Cut Line     Ctrl+X")
                    1 -> put_str_at(col, row, "Copy         Ctrl+C")
                    2 -> put_str_at(col, row, "Paste        Ctrl+V/F4")
                    else -> put_str_at(col, row, "Delete Line  Ctrl+K")
                }
            }
            2 -> {                          ; Search
                when i {
                    0 -> put_str_at(col, row, "Find...     Ctrl+F/F6")
                    1 -> put_str_at(col, row, "Find Next   Ctrl+G")
                    else -> put_str_at(col, row, "Replace...  Ctrl+R/F8")
                }
            }
            else -> {                       ; Help
                when i {
                    0 -> put_str_at(col, row, "Keyboard...")
                    else -> put_str_at(col, row, "About      F1")
                }
            }
        }
    }

    sub draw_dropdown(ubyte active, ubyte x0, ubyte y0, ubyte x1, ubyte y1, ubyte n, ubyte sel) {
        draw_box_frame(x0, y0, x1, y1)
        ubyte i
        for i in 0 to n - 1 {
            ubyte row = y0 + 1 + i
            ubyte base = CB_BAR
            set_color_run(x0 + 1, x1 - 1, row, CB_BAR)
            draw_item(active, i, x0 + 2, row)
            if i == sel {
                set_color_run(x0 + 1, x1 - 1, row, CB_SEL)
                base = CB_SEL
            }
            ; recolour just the accelerator letter (keep the row's bg) - drawn last so it
            ; survives the selection fill
            txt.setclr(x0 + 2 + accel_off(active, i), row, (base & $f0) | ACCEL_FG)
        }
    }

    sub run_dropdown(ubyte active) -> ubyte {
        ; returns the chosen item index, or 255=esc, 254=prev menu, 253=next menu
        ubyte n = 2
        ubyte boxw = 13                     ; Help ("About      F1")
        when active {
            0 -> { n = 5  boxw = 17 }       ; File ("Open...    Ctrl+O")
            1 -> { n = 4  boxw = 22 }       ; Edit ("Paste        Ctrl+V/F4")
            2 -> { n = 3  boxw = 21 }       ; Search ("Replace...  Ctrl+R/F8")
        }
        ubyte x0 = menu_col[active] - 1
        ubyte y0 = 1
        ubyte x1 = x0 + boxw + 3
        if x1 > SCR_W - 1 {                 ; shift left so the box stays on screen (40-col)
            ubyte over = x1 - (SCR_W - 1)
            x0 -= over
            x1 = SCR_W - 1
        }
        ubyte y1 = y0 + n + 1
        ubyte sel = 0
        repeat {
            draw_dropdown(active, x0, y0, x1, y1, n, sel)
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            ubyte acc = item_accel(active, k)   ; letter accelerator activates the item
            if acc != 255
                return acc
            when k {
                27, 3 -> return 255
                17 -> {
                    sel++
                    if sel >= n
                        sel = 0
                }
                145 -> {
                    if sel == 0
                        sel = n - 1
                    else
                        sel--
                }
                157, '[' -> return 254
                29, ']' -> return 253
                13, ' ' -> return sel
            }
        }
    }

    sub menu_dispatch(ubyte active, ubyte choice) {
        when active {
            0 -> {                          ; File
                when choice {
                    0 -> act_new()
                    1 -> act_open()
                    2 -> void save_now()
                    3 -> act_save_as()
                    else -> act_exit()
                }
            }
            1 -> {                          ; Edit
                when choice {
                    0 -> op_cut()
                    1 -> op_copy()
                    2 -> op_paste()
                    else -> op_delete_line()
                }
            }
            2 -> {                          ; Search
                when choice {
                    0 -> act_find()
                    1 -> act_find_next()
                    else -> act_replace()
                }
            }
            else -> {                       ; Help
                when choice {
                    0 -> act_keymap()
                    else -> act_about()
                }
            }
        }
    }

    sub menu_mode_loop(ubyte active) {
        repeat {
            full_redraw()               ; erase any previously-open dropdown (chars + colour)
            draw_menubar(active)
            ubyte choice = run_dropdown(active)
            when choice {
                255 -> {
                    full_redraw()
                    return
                }
                254 -> {
                    if active == 0
                        active = NMENU - 1
                    else
                        active--
                }
                253 -> {
                    active++
                    if active >= NMENU
                        active = 0
                }
                else -> {
                    full_redraw()
                    menu_dispatch(active, choice)
                    full_redraw()
                    return
                }
            }
        }
    }

    ; ---------- File / Help actions ----------

    sub new_document() {
        edoc.init()
        void edoc.append(&editbuf, 0)       ; start with one empty line
        filename[0] = 0
        modified = false
        cur_row = 0
        cur_col = 0
        top_line = 0
        left_col = 0
        cur_len = edoc.load(0, &editbuf)
        cur_dirty = false
    }

    sub act_new() {
        if modified {
            ubyte r = confirm_save()
            if r == 2
                return
            if r == 1 {
                if not save_now()
                    return
            }
        }
        new_document()
        full_redraw()                   ; repaint (needed when invoked via hotkey)
    }

    ; ---------- file-picker popup (Open) ----------

    sub add_entry(ubyte etype, uword nameptr) {
        ; append one slab record: [type byte][name + NUL]. type 0 = file, 1 = dir.
        ; name copied verbatim (truncated) so the bytes round-trip back to diskio.
        if file_count >= FILE_CAP
            return
        uword rec = filelist + (file_count as uword) * FNREC
        @(rec) = etype
        ubyte i = 0
        while i < FNREC - 2 and @(nameptr + i) != 0 {
            @(rec + 1 + i) = @(nameptr + i)
            i++
        }
        @(rec + 1 + i) = 0
        file_count++
    }

    sub copy_rec_slot(uword src, uword dst) {
        ; copy one FNREC-byte record (non-overlapping slots) - hand-rolled to avoid the
        ; sys.memcopy overlap hazard, though here the slots never overlap
        ubyte i
        for i in 0 to FNREC - 1
            @(dst + i) = @(src + i)
    }

    sub sort_dirs_first() {
        ; stable insertion sort so directory records sort before files; ".." (the first
        ; dir, index 0) therefore stays at the very top. Sorts the slab records in place.
        if file_count < 2
            return
        ubyte i
        for i in 1 to file_count - 1 {
            uword reci = filelist + (i as uword) * FNREC
            ubyte keyi = 1                       ; file=1, dir=0 (dirs sort first)
            if @(reci) != 0
                keyi = 0
            copy_rec_slot(reci, &tmpbuf)         ; stash record i
            ubyte j = i
            while j != 0 {
                uword recp = filelist + ((j - 1) as uword) * FNREC
                ubyte keyp = 1
                if @(recp) != 0
                    keyp = 0
                if keyp <= keyi                  ; predecessor already <= -> stable stop
                    break
                copy_rec_slot(recp, filelist + (j as uword) * FNREC)
                j--
            }
            copy_rec_slot(&tmpbuf, filelist + (j as uword) * FNREC)
        }
    }

    sub scan_files() {
        ; fill the filelist slab with the current directory's entries: a ".." (go up)
        ; entry first, then sub-directories and files. '.'-prefixed entries from the
        ; listing (incl. its own . / ..) are skipped; we synthesize our own "..".
        file_count = 0
        add_entry(1, "..")
        if not diskio.lf_start_list("*")
            return
        while diskio.lf_next_entry() {
            if diskio.list_filename[0] == '.'
                continue
            ubyte etype = 0
            if diskio.list_filetype == "dir"
                etype = 1
            add_entry(etype, &diskio.list_filename)
            if file_count >= FILE_CAP
                break
        }
        diskio.lf_end_list()
        sort_dirs_first()                        ; group directories above files
    }

    sub put_mem_trunc(ubyte col, ubyte row, uword ptr, ubyte maxw) {
        ; draw a NUL-terminated PETSCII string from RAM, truncated to maxw cells
        ubyte i = 0
        while i < maxw and @(ptr + i) != 0 {
            txt.setchr(col + i, row, txt.petscii2scr(@(ptr + i)))
            i++
        }
    }

    sub pick_file(uword dest) -> bool {
        ; modal scrollable list of the directory's files. Enter -> copy the chosen
        ; name to dest and return true; Esc/Stop -> false. Empty dir -> false.
        scan_files()
        if file_count == 0 {
            notify("No files in directory")
            return false
        }
        ubyte w = 44
        if SCR_W < 80
            w = SCR_W - 2
        ubyte x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte y0 = 2
        ubyte y1 = SCR_H - 3
        ubyte rows = y1 - y0 - 1             ; visible file rows
        ubyte namew = w - 5                  ; name field (marker col + 1 right margin)
        ubyte cursor = 0
        ubyte top = 0
        ubyte nav_depth = 0                  ; sub-dirs descended below the start dir
        uword rec
        ubyte i
        repeat {
            if cursor < top
                top = cursor
            if cursor >= top + rows
                top = cursor - rows + 1
            draw_box_frame(x0, y0, x1, y1)
            if x1 + 1 < SCR_W and y1 + 1 < SCR_H
                draw_box_shadow(x0, y0, x1, y1)
            put_str_at(x0 + (w - 9) / 2, y0, "Open File")
            put_str_at(x0 + (w - 11) / 2, y1, "Esc to exit")
            ubyte r
            for r in 0 to rows - 1 {
                ubyte idx = top + r
                if idx < file_count {
                    rec = filelist + (idx as uword) * FNREC
                    if @(rec) != 0                          ; directory: "/" marker
                        txt.setchr(x0 + 2, y0 + 1 + r, sc:'/')
                    put_mem_trunc(x0 + 3, y0 + 1 + r, rec + 1, namew)
                    if idx == cursor
                        set_color_run(x0 + 1, x1 - 1, y0 + 1 + r, CB_SEL)
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
                    rec = filelist + (cursor as uword) * FNREC
                    i = 0
                    while @(rec + 1 + i) != 0 {  ; copy the name out (dest = scratch)
                        @(dest + i) = @(rec + 1 + i)
                        i++
                    }
                    @(dest + i) = 0
                    if @(rec) != 0 {            ; directory -> chdir + rescan, stay open
                        diskio.chdir(dest)
                        ; track depth so a later cancel can restore the start dir. ".."
                        ; goes up (one less deep, floored at 0); a named dir goes down.
                        if @(dest) == '.' and @(dest + 1) == '.' and @(dest + 2) == 0 {
                            if nav_depth != 0
                                nav_depth--
                        } else {
                            nav_depth++
                        }
                        scan_files()
                        cursor = 0
                        top = 0
                    } else {
                        return true             ; file -> dest holds the chosen name
                    }
                }
                27, 3 -> {                      ; cancel: climb back to the start dir
                    repeat nav_depth
                        diskio.chdir("..")
                    return false
                }
            }
        }
    }

    sub act_open() {
        if modified {
            ubyte r = confirm_save()
            if r == 2
                return
            if r == 1 {
                if not save_now()
                    return
            }
        }
        fnbuf[0] = 0
        if not pick_file(&fnbuf) {
            full_redraw()
            return
        }
        if edoc.load_file(fnbuf) {
            void strings.copy(fnbuf, filename)
            cur_row = 0
            cur_col = 0
            top_line = 0
            left_col = 0
            cur_len = edoc.load(0, &editbuf)
            cur_dirty = false
            modified = false
        } else {
            notify("Cannot open file")
        }
        full_redraw()                   ; repaint (needed when invoked via hotkey)
    }

    sub do_save(str name) -> bool {
        commit_editbuf()
        savebuf[0] = '@'
        savebuf[1] = ':'
        void strings.copy(name, &savebuf + 2)
        if not edoc.save_file(savebuf) {
            notify("Save error")
            return false
        }
        modified = false
        ; free compaction: write to disk, then reload into a fresh arena
        if edoc.load_file(name) {
            if cur_row >= edoc.line_count
                cur_row = edoc.line_count - 1
            cur_len = edoc.load(cur_row, &editbuf)
            cur_dirty = false
        }
        notify("Saved")
        return true
    }

    sub save_now() -> bool {
        if filename[0] == 0 {
            fnbuf[0] = 0
            if not prompt_str("Save as:", &fnbuf, 38, false)
                return false
            void strings.copy(fnbuf, filename)
        }
        return do_save(filename)
    }

    sub act_save_as() {
        fnbuf[0] = 0
        if not prompt_str("Save as:", &fnbuf, 38, false)
            return
        void strings.copy(fnbuf, filename)
        void do_save(filename)
    }

    sub act_exit() {
        if modified {
            ubyte r = confirm_save()
            if r == 2
                return
            if r == 1 {
                if not save_now()
                    return
            }
        }
        g_running = false
    }

    sub act_about() {
        const ubyte w = 34
        ubyte x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte tx = x0 + 3
        draw_box_frame(x0, 9, x1, 18)
        draw_box_shadow(x0, 9, x1, 18)
        put_str_at(x0 + (w - 5) / 2, 9, "About")            ; title on the top frame
        put_str_at(tx, 11, "EDIT  -  X16 Text Editor")
        put_str_at(tx, 12, "Text stored in banked RAM")
        if g_emu
            put_str_at(tx, 13, "Running on:  Emulator")
        else
            put_str_at(tx, 13, "Running on:  Hardware")
        put_str_at(tx, 14,     "(c)sadLogic 2026 V0.9.0")
        put_str_at(x0 + (w - 13) / 2, 18, "Press any key")  ; hint on the bottom frame
        void wait_key()
        full_redraw()
    }

    ubyte km_keyc                       ; key column (set by act_keymap per width)
    ubyte km_desc                       ; description column

    sub km_row(ubyte row, str keys, str desc) {
        put_str_at(km_keyc, row, keys)
        put_str_at(km_desc, row, desc)
    }

    sub act_keymap() {
        ; geometry: wide (80-col) box vs compact box that fits in 40 cols
        ubyte x0, x1
        if SCR_W >= 80 {
            x0 = 18  x1 = 61
            km_keyc = x0 + 3
            km_desc = x0 + 20
        } else {
            x0 = (SCR_W - 38) / 2
            x1 = x0 + 37
            km_keyc = x0 + 2
            km_desc = x0 + 18
        }
        draw_box_frame(x0, 3, x1, 25)
        if SCR_W >= 80                  ; shadow would run off the right edge in 40-col
            draw_box_shadow(x0, 3, x1, 25)
        put_str_at(x0 + (x1 - x0 - 11) / 2, 4, "Keyboard Map")
        km_row( 5, "Arrows",          "Move cursor")
        km_row( 6, "Ctrl + Lt/Rt",    "Jump a word")
        km_row( 7, "Home / End",      "Start/end of line")
        km_row( 8, "PgUp / PgDn",     "Page up / down")
        km_row( 9, "Shift + arrows",  "Select text")
        km_row(10, "Tab",             "Insert 4 spaces")
        km_row(12, "Ctrl+C / Ctrl+X", "Copy / Cut")
        km_row(13, "Ctrl+V / F4",     "Paste")
        km_row(14, "Ctrl+K",          "Delete line")
        km_row(16, "Ctrl+F / F6",     "Find")
        km_row(17, "Ctrl+G / F3",     "Find next")
        km_row(18, "Ctrl+R / F8",     "Replace")
        km_row(20, "Ctrl+N / Ctrl+O", "New / Open")
        km_row(21, "F2 / F1",         "Save / About")
        if SCR_W >= 80
            put_str_at(20, 23, "Emulator eats Ctrl+F/R/V - use F6/F8/F4")
        else
            put_str_at(km_keyc, 23, "Emu eats Ctrl+F/R/V")
        void wait_key()
        full_redraw()
    }

    ; ----- Key Probe diagnostic: disabled (removed from the Help menu). Kept here,
    ; ----- commented out, in case the raw-keycode/modifier readout is needed again.
    ; ----- To re-enable: uncomment both subs and restore the Help menu's 3rd item
    ; -----   (item count, draw_item, item_accel, accel_off, menu_dispatch).
    ; sub probe_byte(ubyte col, ubyte row, ubyte v) {
    ;     ; print a 0..255 value left-aligned in a 3-cell field (blank the field first)
    ;     put_str_at(col, row, "   ")
    ;     void put_uw_at(col, row, v)
    ; }
    ;
    ; sub act_keyprobe() {
    ;     ; live key diagnostic: shows the raw GETIN code of the last key plus the
    ;     ; current modifier byte. Because the modifier readout updates even when no
    ;     ; key arrives, combos the emulator swallows (e.g. Ctrl+Shift+arrow) show up
    ;     ; as "modifiers change but no new key code" - that is the override, exposed.
    ;     const ubyte w = 38
    ;     ubyte x0 = (SCR_W - w) / 2
    ;     ubyte x1 = x0 + w - 1
    ;     ubyte tx = x0 + 3
    ;     draw_box_frame(x0, 7, x1, 20)
    ;     draw_box_shadow(x0, 7, x1, 20)
    ;     put_str_at(x0 + (w - 9) / 2, 8, "Key Probe")
    ;     put_str_at(tx, 10, "Last key code:")
    ;     put_str_at(tx, 12, "Modifier byte:")
    ;     put_str_at(tx, 13, "Shift=   Ctrl=   Alt=")
    ;     put_str_at(tx, 17, "Press keys to test.")
    ;     put_str_at(tx, 18, "Press Esc twice to exit.")
    ;     ubyte prev = 0
    ;     ubyte last = 0
    ;     repeat {
    ;         ubyte m = cx16.kbdbuf_get_modifiers()
    ;         ubyte k = cbm.GETIN2()
    ;         if k != 0 {
    ;             if k == 27 and prev == 27
    ;                 break
    ;             prev = k
    ;             last = k
    ;         }
    ;         probe_byte(x0 + 18, 10, last)
    ;         probe_byte(x0 + 18, 12, m)
    ;         ubyte b = 0
    ;         if (m & MOD_SHIFT) != 0
    ;             b = 1
    ;         void put_uw_at(x0 + 9, 13, b)
    ;         b = 0
    ;         if (m & MOD_CTRL) != 0
    ;             b = 1
    ;         void put_uw_at(x0 + 17, 13, b)
    ;         b = 0
    ;         if (m & MOD_ALT) != 0
    ;             b = 1
    ;         void put_uw_at(x0 + 24, 13, b)
    ;     }
    ;     full_redraw()
    ; }

    ; ---------- search / replace ----------

    sub fold(ubyte b) -> ubyte {
        ; case-fold a PETSCII letter to lowercase ($C1-$DA upper -> $41-$5A lower)
        if b >= $c1 and b <= $da
            return b - $80
        return b
    }

    sub line_match(uword src, ubyte at, ubyte tlen) -> bool {
        ; does find_term (length tlen) match src starting at offset `at`? (case-insensitive)
        ubyte j = 0
        while j < tlen {
            if fold(@(src + at + j)) != fold(find_term[j])
                return false
            j++
        }
        return true
    }

    sub find_in_line(uword buf, ubyte blen, ubyte from, ubyte tlen) -> ubyte {
        ; first column >= from where find_term occurs in buf, or 255 if none
        if tlen == 0 or blen < tlen
            return 255
        ubyte i = from
        while i + tlen <= blen {
            if line_match(buf, i, tlen)
                return i
            i++
        }
        return 255
    }

    sub find_from(uword row, ubyte col) -> bool {
        ; search the document from (row, col) forward; on a hit set found_row/found_col
        ubyte tlen = lsb(strings.length(find_term))
        if tlen == 0
            return false
        uword r = row
        ubyte startcol = col
        while r < edoc.line_count {
            ubyte llen = edoc.load(r, &tmpbuf)
            ubyte hit = find_in_line(&tmpbuf, llen, startcol, tlen)
            if hit != 255 {
                found_row = r
                found_col = hit
                return true
            }
            r++
            startcol = 0
        }
        return false
    }

    sub goto_found() {
        cur_row = found_row
        cur_col = found_col
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        void ensure_visible()
        draw_all_text()
        place_cursor()
        draw_status()
    }

    sub act_find() {
        if not prompt_str("Find:", &find_term, 38, false)
            return
        commit_editbuf()
        if find_from(cur_row, cur_col)
            goto_found()
        else
            notify("Not found")
    }

    sub act_find_next() {
        if find_term[0] == 0 {
            notify("No search term - use Find first")
            return
        }
        commit_editbuf()
        if find_from(cur_row, cur_col + 1)
            goto_found()
        else
            notify("Not found")
    }

    sub replace_line(uword src, ubyte slen) -> ubyte {
        ; build the replaced line into workbuf; return new length, or 255 on overflow.
        ; counts replacements made into g_line_repls.
        ubyte tlen = lsb(strings.length(find_term))
        ubyte rlen = lsb(strings.length(repl_term))
        g_line_repls = 0
        ubyte o = 0
        ubyte i = 0
        while i < slen {
            if i + tlen <= slen and line_match(src, i, tlen) {
                ubyte k = 0
                while k < rlen {
                    if o >= edoc.MAX_LEN
                        return 255
                    workbuf[o] = repl_term[k]
                    o++
                    k++
                }
                i += tlen
                g_line_repls++
            } else {
                if o >= edoc.MAX_LEN
                    return 255
                workbuf[o] = @(src + i)
                o++
                i++
            }
        }
        return o
    }

    sub act_replace() {
        if not prompt_str("Find:", &find_term, 38, false)
            return
        if not prompt_str("Replace with:", &repl_term, 38, true)    ; empty = delete
            return
        commit_editbuf()
        g_repl_count = 0
        uword r = 0
        while r < edoc.line_count {
            ubyte llen = edoc.load(r, &tmpbuf)
            ubyte nl = replace_line(&tmpbuf, llen)
            if nl != 255 and g_line_repls != 0 {
                void edoc.commit(r, &workbuf, nl)
                g_repl_count += g_line_repls
            }
            r++
        }
        if cur_row >= edoc.line_count
            cur_row = edoc.line_count - 1
        cur_len = edoc.load(cur_row, &editbuf)
        clamp_col()
        cur_dirty = false
        if g_repl_count != 0
            modified = true
        full_redraw()
        bar_fill(STATUS_ROW, CB_BAR)
        put_str_at(1, STATUS_ROW, "Replaced ")
        void put_uw_at(10, STATUS_ROW, g_repl_count)
        sys.wait(80)
    }

    ; ---------- selection delete / clipboard (Edit menu + Ctrl shortcuts) ----------

    sub delete_selection() {
        ; remove the selected text; cursor ends at the selection start
        commit_editbuf()
        sel_norm()
        if s_row == e_row {
            ubyte llen = edoc.load(s_row, &tmpbuf)
            ubyte o = s_col
            ubyte i = e_col
            while i < llen {
                tmpbuf[o] = tmpbuf[i]
                o++
                i++
            }
            void edoc.commit(s_row, &tmpbuf, o)
        } else {
            ubyte slen = edoc.load(s_row, &tmpbuf)     ; keep [0, s_col)
            ubyte n0 = 0
            while n0 < s_col and n0 < slen {
                workbuf[n0] = tmpbuf[n0]
                n0++
            }
            ubyte elen = edoc.load(e_row, &tmpbuf)     ; append [e_col, elen)
            ubyte j = e_col
            while j < elen and n0 < edoc.MAX_LEN {
                workbuf[n0] = tmpbuf[j]
                n0++
                j++
            }
            void edoc.commit(s_row, &workbuf, n0)
            uword delcount = e_row - s_row             ; remove the lines in between + end
            uword z = 0
            while z < delcount {
                edoc.delete_line(s_row + 1)
                z++
            }
        }
        cur_row = s_row
        cur_col = s_col
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        sel_active = false
        modified = true
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    sub copy_selection() {
        ; copy the selected text into the clipboard (with $0D between lines)
        commit_editbuf()
        sel_norm()
        uword o = 0
        ubyte i
        if s_row == e_row {
            ubyte llen = edoc.load(s_row, &tmpbuf)
            i = s_col
            while i < e_col and i < llen {
                @(clipbuf + o) = tmpbuf[i]
                o++
                i++
            }
        } else {
            ubyte slen = edoc.load(s_row, &tmpbuf)
            i = s_col
            while i < slen and o < 1023 {
                @(clipbuf + o) = tmpbuf[i]
                o++
                i++
            }
            @(clipbuf + o) = 13
            o++
            uword r = s_row + 1
            while r < e_row {
                ubyte ml = edoc.load(r, &tmpbuf)
                ubyte j = 0
                while j < ml and o < 1023 {
                    @(clipbuf + o) = tmpbuf[j]
                    o++
                    j++
                }
                @(clipbuf + o) = 13
                o++
                r++
            }
            ubyte elen = edoc.load(e_row, &tmpbuf)
            ubyte k2 = 0
            while k2 < e_col and k2 < elen and o < 1023 {
                @(clipbuf + o) = tmpbuf[k2]
                o++
                k2++
            }
        }
        clip_len = o
        clip_has = true
        clip_line = false
    }

    sub copy_current_line() {
         ubyte i = 0
        while i < cur_len {
            @(clipbuf + i) = editbuf[i]
            i++
        }
        clip_len = cur_len
        clip_has = true
        clip_line = true
    }

    sub op_copy() {
        if sel_active {
            copy_selection()
            sel_active = false
            draw_all_text()
            notify("Copied")
        } else {
            copy_current_line()
            notify("Line copied")
        }
    }

    sub op_cut() {
        if sel_active {
            copy_selection()
            delete_selection()
        } else {
            copy_current_line()
            op_delete_line()
        }
    }

    sub op_delete_line() {
        commit_editbuf()
        if edoc.line_count <= 1 {
            cur_len = 0                          ; clear the only line, keep one empty line
            void edoc.commit(0, &editbuf, 0)
            cur_col = 0
        } else {
            edoc.delete_line(cur_row)
            if cur_row >= edoc.line_count
                cur_row = edoc.line_count - 1
            cur_len = edoc.load(cur_row, &editbuf)
            cur_col = 0
        }
        cur_dirty = false
        sel_active = false
        modified = true
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    sub do_split() -> bool {
        ; split the current line at the cursor (like Enter, but no redraw); cursor
        ; moves to the start of the new (right-hand) line
        ubyte rlen = cur_len - cur_col
        if not edoc.commit(cur_row, &editbuf, cur_col)
            return false
        if not edoc.insert_line(cur_row + 1)
            return false
        void edoc.commit(cur_row + 1, &editbuf + cur_col, rlen)
        cur_row++
        cur_col = 0
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        return true
    }

    sub op_paste() {
        if not clip_has {
            notify("Clipboard empty")
            return
        }
        if sel_active
            delete_selection()
        commit_editbuf()
        if clip_line {
            ; whole-line clipboard: insert it as a new line below the cursor
            if not edoc.insert_line(cur_row + 1) {
                notify("Document full - save now")
                return
            }
            ubyte bi = 0
            while bi < lsb(clip_len) {
                tmpbuf[bi] = @(clipbuf + bi)
                bi++
            }
            void edoc.commit(cur_row + 1, &tmpbuf, lsb(clip_len))
            cur_row++
            cur_col = 0
            cur_len = edoc.load(cur_row, &editbuf)
            cur_dirty = false
        } else {
            ; selection clipboard: insert inline at the cursor, splitting on $0D
            uword pi = 0
            while pi < clip_len {
                ubyte ch = @(clipbuf + pi)
                pi++
                if ch == 13 {
                    if not do_split()
                        break
                } else if cur_len < edoc.MAX_LEN {
                    ubyte j = cur_len
                    while j > cur_col {
                        editbuf[j] = editbuf[j - 1]
                        j--
                    }
                    editbuf[cur_col] = ch
                    cur_len++
                    cur_col++
                }
            }
            cur_dirty = true
        }
        modified = true
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    ; ---------- editbuf <-> document ----------

    sub commit_editbuf() {
        if cur_dirty {
            if not edoc.commit(cur_row, &editbuf, cur_len)
                notify("Document full - save now")
            cur_dirty = false
        }
    }

    sub goto_row(uword nr) {
        commit_editbuf()
        cur_row = nr
        cur_len = edoc.load(nr, &editbuf)
        cur_dirty = false
    }

    sub clamp_col() {
        if cur_col > cur_len
            cur_col = cur_len
    }

    ; ---------- navigation ----------

    sub ed_up() {
        if cur_row > 0 {
            goto_row(cur_row - 1)
            clamp_col()
            redraw_after_move()
        }
    }

    sub ed_down() {
        if cur_row + 1 < edoc.line_count {
            goto_row(cur_row + 1)
            clamp_col()
            redraw_after_move()
        }
    }

    sub ed_left() {
        if cur_col > 0 {
            cur_col--
        } else if cur_row > 0 {
            goto_row(cur_row - 1)
            cur_col = cur_len
        }
        redraw_after_move()
    }

    sub ed_right() {
        if cur_col < cur_len {
            cur_col++
        } else if cur_row + 1 < edoc.line_count {
            goto_row(cur_row + 1)
            cur_col = 0
        }
        redraw_after_move()
    }

    sub ed_word_right() {
        ; jump to the start of the next word (skip the current word run, then
        ; the spaces after it); wrap to the next line at end of line
        if cur_col >= cur_len {
            ed_right()
            return
        }
        while cur_col < cur_len and editbuf[cur_col] != ' '
            cur_col++
        while cur_col < cur_len and editbuf[cur_col] == ' '
            cur_col++
        redraw_after_move()
    }

    sub ed_word_left() {
        ; jump to the start of the current/previous word (skip spaces left,
        ; then the word run); wrap to the previous line at start of line
        if cur_col == 0 {
            ed_left()
            return
        }
        while cur_col > 0 and editbuf[cur_col - 1] == ' '
            cur_col--
        while cur_col > 0 and editbuf[cur_col - 1] != ' '
            cur_col--
        redraw_after_move()
    }

    sub ed_home() {
        cur_col = 0
        redraw_after_move()
    }

    sub ed_end() {
        cur_col = cur_len
        redraw_after_move()
    }

    sub ed_delete() {
        ; forward delete: remove the char at the cursor, or join the next line
        ubyte i
        if cur_col < cur_len {
            i = cur_col
            while i + 1 < cur_len {
                editbuf[i] = editbuf[i + 1]
                i++
            }
            cur_len--
            cur_dirty = true
            modified = true
            if ensure_visible()
                draw_all_text()
            else
                draw_doc_line()
            place_cursor()
            draw_status()
        } else if cur_row + 1 < edoc.line_count {
            ubyte nlen = edoc.load(cur_row + 1, &tmpbuf)
            i = 0
            while i < nlen and cur_len < edoc.MAX_LEN {
                editbuf[cur_len] = tmpbuf[i]
                cur_len++
                i++
            }
            edoc.delete_line(cur_row + 1)
            cur_dirty = true
            modified = true
            void ensure_visible()
            draw_all_text()
            place_cursor()
            draw_status()
        }
    }

    sub ed_pgdn() {
        uword nr = cur_row + TEXT_ROWS
        if nr >= edoc.line_count
            nr = edoc.line_count - 1
        goto_row(nr)
        clamp_col()
        redraw_after_move()
    }

    sub ed_pgup() {
        uword nr = 0
        if cur_row > TEXT_ROWS
            nr = cur_row - TEXT_ROWS
        goto_row(nr)
        clamp_col()
        redraw_after_move()
    }

    sub ed_tab() {
        ubyte spaces = 4 - (cur_col & 3)
        repeat spaces
            ed_insert(' ')
    }

    ; ---------- editing ----------

    sub ed_insert(ubyte k) {
        if cur_len >= edoc.MAX_LEN
            return
        ubyte i = cur_len
        while i > cur_col {
            editbuf[i] = editbuf[i - 1]
            i--
        }
        editbuf[cur_col] = k
        cur_len++
        cur_col++
        cur_dirty = true
        modified = true
        if ensure_visible()
            draw_all_text()
        else
            draw_doc_line()
        place_cursor()
        draw_status()
    }

    sub ed_backspace() {
        if cur_col > 0 {
            ubyte i = cur_col - 1
            while i + 1 < cur_len {
                editbuf[i] = editbuf[i + 1]
                i++
            }
            cur_len--
            cur_col--
            cur_dirty = true
            modified = true
            if ensure_visible()
                draw_all_text()
            else
                draw_doc_line()
            place_cursor()
            draw_status()
        } else if cur_row > 0 {
            ed_join_prev()
        }
    }

    sub ed_join_prev() {
        ; merge the current line onto the end of the previous one
        ubyte joincol = edoc.get_len(cur_row - 1)
        ubyte plen = edoc.load(cur_row - 1, &tmpbuf)
        ubyte i = 0
        while i < cur_len and plen < edoc.MAX_LEN {
            tmpbuf[plen] = editbuf[i]
            plen++
            i++
        }
        void edoc.commit(cur_row - 1, &tmpbuf, plen)
        edoc.delete_line(cur_row)
        cur_row--
        cur_len = edoc.load(cur_row, &editbuf)
        cur_col = joincol
        cur_dirty = false
        modified = true
        void ensure_visible()
        draw_all_text()
        place_cursor()
        draw_status()
    }

    sub ed_enter() {
        ; split the current line at the cursor into two lines
        ubyte rlen = cur_len - cur_col
        if not edoc.commit(cur_row, &editbuf, cur_col) {
            notify("Document full - save now")
            return
        }
        if not edoc.insert_line(cur_row + 1) {
            notify("Document full - save now")
            return
        }
        void edoc.commit(cur_row + 1, &editbuf + cur_col, rlen)
        cur_row++
        cur_col = 0
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        modified = true
        void ensure_visible()
        draw_all_text()
        place_cursor()
        draw_status()
    }

    ; ---------- key dispatch ----------

    sub editor_key(ubyte k) {
        ; ALT+letter (Commodore-key graphics codes 161..191) opens that menu directly;
        ; intercept before the text-insert path below (which accepts k>=160). Other ALT
        ; combos are swallowed so they don't insert a graphics char.
        if k >= 161 and k <= 191 {
            ubyte m = menu_for_letter(alt_letter[k - 161])
            if m != 255
                menu_mode_loop(m)
            return
        }
        ; selection management: Shift+cursor extends the selection, any other
        ; cursor-movement key collapses it
        when k {
            17, 145, 29, 157, 19, 4, 2, 130 -> {
                if (g_mod & MOD_SHIFT) != 0 {
                    if not sel_active {
                        anc_row = cur_row
                        anc_col = cur_col
                        sel_active = true
                    }
                } else {
                    sel_active = false
                }
            }
        }
        when k {
            27, MENU_KEY -> menu_mode_loop(0)
            13 -> {
                if sel_active
                    delete_selection()
                ed_enter()
            }
            20 -> {
                if sel_active
                    delete_selection()
                else
                    ed_backspace()
            }
            17 -> ed_down()
            145 -> ed_up()
            29 -> {                          ; Right arrow (Ctrl = jump word right)
                if (g_mod & MOD_CTRL) != 0
                    ed_word_right()
                else
                    ed_right()
            }
            157 -> {                         ; Left arrow (Ctrl = jump word left)
                if (g_mod & MOD_CTRL) != 0
                    ed_word_left()
                else
                    ed_left()
            }
            19 -> ed_home()
            4 -> ed_end()                   ; End key
            25 -> {                         ; forward Delete key
                if sel_active
                    delete_selection()
                else
                    ed_delete()
            }
            2 -> ed_pgdn()
            130 -> ed_pgup()
            9 -> ed_tab()
            ; ---- shortcut hotkeys (Ctrl+letter arrive as control codes 1..26) ----
            ; x16emu STEALS Ctrl+V (paste), Ctrl+F (fullscreen) and Ctrl+R (reset!)
            ; before they reach us (verified via Help>Key Probe). So those three
            ; actions get function-key aliases that pass through on both emulator
            ; and real hardware: F4=paste, F6=find, F8=replace. The Ctrl keys stay
            ; bound too, for muscle memory on real hardware where they work.
            3 -> op_copy()                  ; Ctrl+C  copy (selection or line)
            24 -> op_cut()                  ; Ctrl+X  cut (selection or line)
            22, 138 -> op_paste()           ; Ctrl+V / F4  paste
            11 -> op_delete_line()          ; Ctrl+K  delete line
            6, 139 -> act_find()            ; Ctrl+F / F6  find
            7, 134 -> act_find_next()       ; Ctrl+G / F3  find next
            18, 140 -> act_replace()        ; Ctrl+R / F8  replace
            14 -> act_new()                 ; Ctrl+N  new
            15 -> act_open()                ; Ctrl+O  open
            137 -> void save_now()          ; F2  save
            133 -> act_about()              ; F1  help
            else -> {
                if (k >= 32 and k <= 126) or (k >= 160) {
                    if sel_active
                        delete_selection()
                    ed_insert(k)
                }
            }
        }
    }
}

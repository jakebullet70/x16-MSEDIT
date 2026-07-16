; EDCFG - the settings program for EDIT.
;
; A separate .prg (MSEDIT/EDCFG.PRG) rather than a dialog inside edit.prg: EDIT has well under 1KB of
; low RAM left, and the settings screen is expected to grow. EDIT's Help>Config saves the document,
; writes ed.run (name + cursor line) and chain-loads this program; on exit we chain-load EDIT back,
; which restores the document from ed.run with the new settings applied.
;
; The settings themselves live in SRC/theme.p8 (shared with EDIT), persisted as MSEDIT/edit.cfg.
; WRITING that file is this program's job alone - EDIT only reads it, which keeps diskio's write
; path (f_open_w/f_write) out of EDIT's low RAM entirely.
;
; UI: the settings are grouped under non-selectable section headers (GUI, Editor). One row per
; setting. Up/Down picks a setting row (headers are skipped - they are never highlighted),
; Left/Right changes its value (applied LIVE - the whole screen repaints in the new colours). F10
; writes the settings and returns to EDIT; Esc returns without writing. No save prompt here - EDIT
; already asks about the DOCUMENT on the way in, and a second prompt on the way out was one too many.
; Adding a setting = one more row (its SET_ROW entry + draw arm) plus its var in theme.p8.
;
; Screen: forces 80x30 (the settings rows assume the width) and puts the machine back in whatever
; mode it booted in before handing control to BASIC.

%import textio
%import strings
%import theme
%import diskio
%zeropage basicsafe

main {
    const ubyte NSET = 4                ; number of setting rows (grows as settings are added)
    ubyte[4] SET_ROW = [7, 8, 10, 11]   ; GUI: Color scheme@7, Dev menu@8 (hdr row 6); Editor: Tab@10, Comment@11 (hdr row 9)

    str edprog = "edit.prg"             ; EDIT, chain-loaded on the way out; theme.path_to()
                                        ; prefixes the install folder from the root ED launcher
    ubyte[24] cfg_line                  ; cfg write buffer ("theme=N\r tab=W\r ...")
    str savename = "?" * 48             ; scratch: builds the chdir target (progdir minus trailing slash)

    ubyte SCR_W, SCR_H
    ubyte saved_mode                    ; screen mode we were launched in; restored on the way out
    ubyte sel = 0                       ; highlighted setting row
    ubyte orig                          ; the theme we opened with - "dirty" is current != orig

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        cx16.set_screen_mode($01)       ; 80x30 - the setting rows are laid out for the wide screen
        SCR_W = txt.width()
        SCR_H = txt.height()
        txt.lowercase()

        orig = theme.cfg_read()         ; the saved scheme (cwd is EDIT's fsroot)
        theme.apply(orig)

        repeat {
            draw_all()
            ubyte k = wait_key()
            when k {
                17 -> {                             ; cursor down
                    sel++
                    if sel >= NSET
                        sel = 0
                }
                145 -> {                            ; cursor up
                    if sel == 0
                        sel = NSET - 1
                    else
                        sel--
                }
                29, ' ' -> change(true)             ; cursor right / space: next value
                157 -> change(false)                ; cursor left: previous value
                21 -> {                             ; F10 ($15): write the settings, back to EDIT
                    if not cfg_write(theme.current) {
                        put_str_at(2, SCR_H - 3, "could not write the settings file!")
                        void wait_key()
                    }
                    leave()
                    return
                }
                27, 3 -> {                          ; Esc: back to EDIT, cfg untouched
                    theme.apply(orig)               ; hand EDIT back the scheme that is actually saved
                    leave()
                    return
                }
            }
        }
    }

    sub change(bool forward) {
        ; adjust the highlighted setting. One `when` arm per setting row.
        when sel {
            0 -> {                                  ; colour scheme: wrap through the presets
                ubyte id = theme.current
                if forward {
                    id++
                    if id > theme.LAST
                        id = theme.FIRST
                } else {
                    if id <= theme.FIRST
                        id = theme.LAST
                    else
                        id--
                }
                theme.apply(id)                     ; live preview - draw_all() repaints in the new colours
            }
            1 -> {                                  ; Dev menu: toggle Shown <-> Hidden
                theme.show_dev = not theme.show_dev
            }
            2 -> {                                  ; tab width: clamp within MIN_TAB..MAX_TAB
                if forward {
                    if theme.tab_width < theme.MAX_TAB
                        theme.tab_width++
                } else {
                    if theme.tab_width > theme.MIN_TAB
                        theme.tab_width--
                }
            }
            3 -> {                                  ; comment insert point: toggle Column 0 <-> Indent
                if theme.cmt_indent == 0
                    theme.cmt_indent = 1
                else
                    theme.cmt_indent = 0
            }
        }
    }

    sub cfg_write(ubyte id) -> bool {
        ; Overwrite the cfg with one "key=<value>\r" line per setting. Kept in step with
        ; theme.cfg_read()'s parser - same keys, same order.
        ;
        ; Host-FS overwrite is finicky: f_open_w's ",w" open does NOT truncate an existing file, and a
        ; scratch / "@:" replace addressed by an ABSOLUTE path silently no-ops - so the stale file
        ; survives and the write fails (or lands past leftover bytes). The one sequence that works is
        ; exactly what the installer's copy_one does: chdir into the folder, delete the BARE name, then
        ; create it fresh. We restore the cwd afterwards (chdir back to the fsroot root) because the
        ; chain-load into EDIT reads ed.run / the /ed launcher from there.
        bool moved = theme.progdir[0] != 0          ; empty progdir = cfg is already in the cwd
        if moved {
            void strings.copy(theme.progdir, savename)   ; "/msedit/" -> strip the trailing slash
            ubyte pl = lsb(strings.length(savename))
            if pl > 1 and savename[pl - 1] == '/'
                savename[pl - 1] = 0
            diskio.chdir(savename)                  ; cd /msedit
        }
        diskio.delete(theme.CFG_FILE)               ; remove the old "edit.cfg" (bare name, in the cwd)
        void diskio.status()                        ; drop FILE NOT FOUND if it wasn't there (LED blink)
        bool ok = false
        if diskio.f_open_w(theme.CFG_FILE) {        ; create fresh - bare name, no "@:" / no path
            ubyte n = 0
            n = append_kv(n, "theme=", id)
            n = append_kv(n, "tab=", theme.tab_width)
            n = append_kv(n, "cmt=", theme.cmt_indent)
            ubyte dv = 0
            if theme.show_dev
                dv = 1
            n = append_kv(n, "dev=", dv)                ; 1 = show Dev menu, 0 = hide
            ok = diskio.f_write(cfg_line, n)
            diskio.f_close_w()
        }
        if moved
            diskio.chdir("/")                       ; back to the fsroot root (ed.run + /ed live there)
        return ok
    }

    ; append "key<digit>\r" to cfg_line at offset n, return the new offset.
    ; values here are single-digit (theme 1..3, tab 1..8), which keeps this trivial.
    sub append_kv(ubyte n, str key, ubyte value) -> ubyte {
        ubyte j = 0
        while key[j] != 0 {
            cfg_line[n] = key[j]
            n++
            j++
        }
        cfg_line[n] = '0' + value
        n++
        cfg_line[n] = 13
        n++
        return n
    }

    sub leave() {
        ; chain-load EDIT: print the LOAD line, then feed CR + RUN + CR through the keyboard queue so
        ; BASIC re-reads it. Same hand-off EDIT used to get here (edit.p8 chain_load).
        cx16.set_screen_mode(saved_mode)            ; put the machine back the way we found it
        txt.color2(1, 6)                            ; hand it back in stock BASIC colours
        txt.chrout($93)                             ; clear screen, cursor home
        txt.nl()
        txt.print("load")
        txt.chrout($22)
        txt.print(theme.path_to(edprog))
        txt.chrout($22)
        txt.chrout($91)                             ; cursor up x2 -> back onto the LOAD line
        txt.chrout($91)
        cx16.kbdbuf_clear()
        cx16.kbdbuf_put($0d)
        cx16.kbdbuf_put('r')
        cx16.kbdbuf_put('u')
        cx16.kbdbuf_put('n')
        cx16.kbdbuf_put($0d)
    }

    ; ---------- drawing ----------

    sub draw_all() {
        txt.color2(theme.COL_FG, theme.COL_BG)
        txt.clear_screen()

        bar_fill(0, theme.CB_BAR)
        put_str_at(2, 0, "EDIT  Settings")
        set_color_run(2, 15, 0, theme.CB_BAR)

        put_str_at(2, 3, "Left/Right changes the highlighted setting.")
        set_color_run(0, SCR_W - 1, 3, theme.CB_BODY)

        draw_header(6, "GUI")                       ; colour scheme lives under this
        draw_header(9, "Editor")                    ; tab width + comments live under this

        ubyte i
        for i in 0 to NSET - 1 {
            ubyte row = SET_ROW[i]
            when i {
                0 -> {
                    put_str_at(4, row, "Color scheme")
                    put_str_at(20, row, theme.NAMES[theme.current - 1])
                }
                1 -> {
                    put_str_at(4, row, "Dev menu")
                    if theme.show_dev
                        put_str_at(20, row, "Shown  ")        ; Dev appears in EDIT's menu bar
                    else
                        put_str_at(20, row, "Hidden ")        ; Dev hidden (its hotkeys still work)
                }
                2 -> {
                    put_str_at(4, row, "Tab width")
                    txt.plot(20, row)
                    txt.print_ub(theme.tab_width)            ; 1..8 -> single digit
                    txt.print(" spaces ")
                }
                3 -> {
                    put_str_at(4, row, "Comment at")
                    if theme.cmt_indent == 0
                        put_str_at(20, row, "Column 0    ")   ; REM at the line start
                    else
                        put_str_at(20, row, "Indentation ")   ; REM after the leading spaces
                }
            }
            ubyte c = theme.CB_BODY
            if i == sel
                c = theme.CB_SEL                    ; highlight the whole row, like EDIT's pickers
            set_color_run(2, SCR_W - 3, row, c)
        }

        bar_fill(SCR_H - 1, theme.CB_BAR)
        put_str_at(2, SCR_H - 1, "Up/Dn Pick   Lt/Rt Change   F10 Save+Exit   Esc Cancel")
        set_color_run(2, 58, SCR_H - 1, theme.CB_BAR)
    }

    sub draw_header(ubyte row, str s) {
        ; non-selectable section label. A short highlight chip at col 2 (never a full-width run, so it
        ; can't be mistaken for a selected setting row) sets it apart from the indented settings below.
        put_str_at(2, row, s)
        set_color_run(2, 2 + strings.length(s) - 1, row, theme.CB_MENUSEL)
    }

    sub put_str_at(ubyte col, ubyte row, str s) {
        txt.plot(col, row)
        txt.print(s)
    }

    sub set_color_run(ubyte c0, ubyte c1, ubyte row, ubyte color) {
        ubyte c
        for c in c0 to c1 {
            if c < SCR_W
                txt.setclr(c, row, color)
        }
    }

    sub bar_fill(ubyte row, ubyte color) {
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, color)
        }
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }
}

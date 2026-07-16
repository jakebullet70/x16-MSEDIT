; EDIT - a basic full-screen text editor for the Commander X16 (like MS-DOS EDIT).
;
;   * 80x30 text screen: menu bar (row 0), text area, status bar (bottom row)
;   * MS-Edit style dropdown menus (File / Edit / Search / Dev / Help), opened with ALT or Esc
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
%import theme                           ; colour scheme (Classic / X16 / Light) + edit.cfg
%import syntax                          ; BASIC syntax colouring (per-column colour classifier)
%zeropage basicsafe
; skip prog8's system re-init (IOINIT/RESTOR/CINT) so the screen mode the machine booted
; in (e.g. BASIC "SCREEN 3" = 40x30) survives into start() and can be adopted. CINT would
; otherwise reset VERA to the 80-col default before our code runs. (We are launched from
; BASIC, which has already done IOINIT/RESTOR, so skipping the re-init is safe here.)
%option no_sysinit

main {
    const ubyte TEXT_TOP   = 1          ; first text-area row (row 0 is the menu bar)
    const ubyte NMENU      = 5
    const ubyte MOD_ALT    = $02        ; kbdbuf_get_modifiers bit
    const ubyte MENU_KEY   = 200        ; synthetic key: open the menu bar
    const uword BUILD_NUM  = 146         ; version's build segment: About shows "v0.9.<BUILD_NUM>".
                                        ; build.bat's build-sync step AUTO-INCREMENTS this (and README's
                                        ; "Version 0.9.N") by 1 on every compile - do not hand-edit.

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
    const ubyte SC_VR = sc:'├'          ; left tee  - divider junction on the box's left edge
    const ubyte SC_VL = sc:'┤'          ; right tee - divider junction on the box's right edge

    ; runtime screen geometry (queried after the mode switch)
    ubyte SCR_W, SCR_H, TEXT_ROWS, STATUS_ROW
    ubyte md_boxbot                     ; bottom screen row of the last-drawn menu dropdown, so
                                        ; closing/switching a menu can repaint just that band
    ubyte saved_mode                    ; screen mode to restore on exit
    ubyte saved_charset                 ; pre-launch charset (1=ISO 2=upper/gfx 3=lower); restored on exit
    ubyte saved_color                   ; pre-launch text colour; restored on exit

    ; document/cursor/view state
    str filename = "?" * 40
    str fnbuf    = "?" * 42             ; input scratch for prompts
    str savebuf  = "?" * 44             ; "@:" + filename for overwrite
    str bakname  = "?" * 44             ; "<name>.bak" built by act_make_backup
    str untitled = "untitled"
    bool run_basload = false            ; F5 armed the BASLOAD hand-off; the start() tail chains to it
    bool run_config = false             ; Help>Config armed the hand-off to the EDCFG settings program
    str cfgprog = "edcfg.prg"           ; the settings program; theme.path_to() prefixes the
                                        ; install folder (read out of the root ED launcher)
    str runstate = "ed.run"             ; restart-state file at the fsroot: doc name + cursor line
    uword basload_err_line = 0          ; line# scraped off the boot screen's BASLOAD error (0 = none)
    ubyte[80] berr                      ; the full BASLOAD error line (screen codes) scraped off the boot screen
    ubyte berr_len = 0                  ; length of berr (0 = no error captured)
    ubyte[5] retkey = [$5e, $2f, $45, $44, $0d]  ; F8 return macro: up-arrow "/ED" + CR -> reloads EDIT
    ubyte[99] fksnap                             ; snapshot of all 9 KERNAL fkey macros, restored verbatim on exit
    ubyte[256] editbuf                  ; the line under the cursor (raw PETSCII)
    ubyte[256] tmpbuf                   ; scratch for rendering / line joins
    ubyte[256] hlcol                    ; per-column syntax colour for the row being drawn
    uword g_wbuf                        ; scratch: pointer to the line buffer last resolved for wrap math
    bool hl_on = false                  ; syntax colouring: default OFF, auto-on by extension on open
                                        ; (has_basic_ext / .md); toggle in the Edit menu
    const ubyte HL_BASIC = 0            ; hl_mode values: which classifier hl_on drives
    const ubyte HL_MD    = 1
    ubyte hl_mode = HL_BASIC            ; set from the file extension on open (see apply_syntax_mode)
    bool ww_on = false                  ; search "whole word only": default OFF, toggle in Search menu
    bool ln_on = false                  ; line-number gutter: default OFF, toggle in the Edit menu
    ubyte gutter_w = 0                  ; current gutter width in columns (0 = off); text starts here
    bool wrap_on = false                ; soft word-wrap (display only): default OFF, Edit-menu toggle
    ubyte top_seg = 0                   ; column where the top visible visual-row starts within top_line
    ubyte cur_len                       ; length of editbuf
    uword cur_row, top_line             ; cursor line / first visible line
    uword prev_cur_row                  ; doc row that currently shows the cursor highlight
    ubyte cur_col, left_col             ; cursor column / first visible column
    bool cur_dirty                      ; editbuf differs from its stored record
    bool modified                       ; document changed since last save
    bool ovr_mode                       ; false = insert (default), true = overwrite (Insert key)
    bool spr_ok                         ; the insert-mode underline cursor sprite is set up and usable
    bool g_running
    bool g_redrawn                      ; set by full_redraw(); lets the menu skip a redundant repaint
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
    bool sel_cleared                    ; set when a plain cursor key just collapsed a selection, so the
                                        ; next redraw_after_move() does ONE full repaint to erase the old
                                        ; highlight (the partial-redraw path only touches the cursor rows)
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
    uword g_repl_count                  ; replacements committed in the last Replace run

    ; clipboard - holds either one whole line (clip_line=true, paste as a new line)
    ; or selected text (clip_line=false, paste inline; may contain $0D line breaks).
    ; OVERLAY: clipbuf lives in its own banked-RAM bank (CLIP_BANK), not scarce low RAM. It
    ; is modal (only copy/paste touch it) and fits one 8KB window. Every access maps the bank
    ; first (cx16.push_rambank .. pop_rambank); edoc.load/commit calls nested inside stay
    ; correct because push/pop is a CPU-stack LIFO that restores CLIP_BANK when they return.
    const ubyte CLIP_BANK = edoc.ARENA_FIRST_BANK + 1       ; overlay bank 7 for the 1KB clipboard
    const uword clipbuf   = xarena.WIN_START                ; $A000 within CLIP_BANK
    uword clip_len
    bool clip_has
    bool clip_line

    ; ---------- undo / redo (per-line snapshots kept in banked RAM) ----------
    const ubyte UNDO_DEPTH = 32
    const ubyte OP_REPLACE = 1          ; line content changed; snapshot = old content
    const ubyte OP_ADDLINE = 2          ; a line was inserted; apply => delete it (no snapshot)
    const ubyte OP_DELLINE = 3          ; a line was deleted; snapshot = its old content
    ; two parallel-array rings (undo=u_*, redo=d_*). Snapshot bytes live in the xarena and
    ; leak until Save's edoc.reset() compaction - the same model edoc uses for line records.
    ubyte[UNDO_DEPTH] u_op
    uword[UNDO_DEPTH] u_row
    uword[UNDO_DEPTH] u_grp
    ubyte[UNDO_DEPTH] u_bnk
    uword[UNDO_DEPTH] u_off
    ubyte u_sp
    ubyte[UNDO_DEPTH] d_op
    uword[UNDO_DEPTH] d_row
    uword[UNDO_DEPTH] d_grp
    ubyte[UNDO_DEPTH] d_bnk
    uword[UNDO_DEPTH] d_off
    ubyte d_sp
    uword g_group                       ; monotonically increasing action-group id

    ; CODE OVERLAY: the Open/View file picker (picker.ovl) in reserved bank 6. Its directory-record
    ; store lives in a SEPARATE dedicated bank (RECORDS_BANK) - an overlay running at $A000 can't map a
    ; second bank into $A000 to reach data, so the four rec_* helpers below run from LOW RAM (which
    ; stays mapped when the HIRAM bank flips) and do the banked access; the overlay calls them through
    ; jmp-(ptr) trampolines, staging bytes through recstage. Giving the records their own 8KB bank
    ; lifts the Open list to ~157 files. Same loadlib + extsub @bank pattern as misc.ovl / tview.ovl.
    ;   picker_setup(peek, read, write, move, stage)  - wire the bank helpers, once after load
    ;   pick(dest, theme_id, blkptr) -> 1 if a file was chosen (dest + @blkptr filled), 0 if cancelled.
    const ubyte PICKER_BANK  = edoc.ARENA_FIRST_BANK       ; overlay bank 6 for picker.ovl
    const ubyte RECORDS_BANK = edoc.ARENA_FIRST_BANK + 4   ; bank 10: the picker's file-list records
    const ubyte REC_STAGE_LEN = 52                         ; bytes/record - MUST match picker.p8 FNREC
    extsub @bank 6 $A000 = picker_init()
    extsub @bank 6 $A003 = pick(uword dest @R0, ubyte theme_id @R1, uword blkptr @R2) -> ubyte @A
    extsub @bank 6 $A006 = picker_setup(uword peekfn @R0, uword readfn @R1, uword writefn @R2, uword movefn @R3, uword stage @R4)
    bool picker_ok                      ; picker.ovl loaded OK -> the Open/View picker is available
    str  pickerovl = "picker.ovl"
    ubyte[REC_STAGE_LEN] recstage       ; low-RAM staging buffer for one record (rec_read/rec_write)

    ; CODE OVERLAY: the About screen lives in misc.ovl, loaded into MISC_BANK (bank 8) at startup.
    ; It is cold (user-triggered) but carries literal text + its box-draw code, so it runs from
    ; banked RAM rather than EDIT's scarce low RAM. `extsub @bank 8` wraps each call in a JSRFAR
    ; that maps the bank around it. $A000 is the library init; $A003 = About (misc.p8's %jmptable).
    ;
    ; The overlay cannot see main's symbols, so it carries its OWN copy of theme.p8 and the box
    ; helpers: we pass the theme id, the build number and the emulator flag and it paints to match.
    const ubyte MISC_BANK = edoc.ARENA_FIRST_BANK + 2       ; overlay bank 8 for misc.ovl
    extsub @bank 8 $A000 = misc_init()
    extsub @bank 8 $A003 = ovl_about(ubyte theme_id @R0, uword build @R1, ubyte emu @R2)
    bool misc_ok                        ; misc.ovl loaded OK -> the About screen is available
    str  miscovl = "misc.ovl"

    ; CODE OVERLAY: the read-only text/hex file viewer (tview.ovl) in its own reserved bank 9.
    ; Used by Help > Keyboard (views the shipped edit.md) and File > View (any picked file). Same
    ; loadlib + extsub @bank pattern as misc.ovl; it carries its own theme.p8 copy, so we pass the
    ; theme id and it paints in EDIT's colours. $A003 = view_file(nameptr, theme_id).
    const ubyte TVIEW_BANK = edoc.ARENA_FIRST_BANK + 3      ; overlay bank 9 for tview.ovl
    extsub @bank 9 $A000 = tview_init()
    extsub @bank 9 $A003 = ovl_view(uword nameptr @R0, ubyte theme_id @R1)
    bool tview_ok                       ; tview.ovl loaded OK -> the viewer is available
    str  tviewovl = "tview.ovl"

    ; CODE OVERLAY: the dropdown-menu item labels + renderer (menus.ovl) in reserved bank 11. The old
    ; local draw_item (~1.1KB of inline label literals) moved here to reclaim low RAM; main keeps all
    ; the dropdown control/colour/layout/dispatch and just calls mnu_item() to paint each item's text.
    ; NOT optional: without it dropdowns paint blank (bar/accelerators/shortcut keys still work).
    ; flags bit0 = wrap_on, bit1 = hl_on, bit2 = ln_on (the three toggle-label states).
    const ubyte MENUS_BANK = edoc.ARENA_FIRST_BANK + 5      ; overlay bank 11 for menus.ovl
    extsub @bank 11 $A000 = menus_init()
    extsub @bank 11 $A003 = mnu_item(ubyte active @R0, ubyte i @R1, ubyte col @R2, ubyte row @R3, ubyte flags @R4)
    bool menus_ok                       ; menus.ovl loaded OK -> dropdown item labels are available
    str  menusovl = "menus.ovl"
    str  keysfile = "edit.md"           ; the help / Keyboard Map text file, viewed by Help > Keyboard
    str  basloadhlp = "basload.md"      ; the BASLOAD guide, viewed by Help > BASLOAD
    ubyte pick_blocks                   ; size (clamped blocks) of the file last chosen by the picker
    str startdir = "?" * 82             ; working dir at startup (restored on exit); diskio MAX_PATH_LEN=80

    ubyte[NMENU] menu_col = [2, 9, 16, 25, 31]   ; start column of each top-menu title
    ubyte[NMENU] menu_len = [4, 4, 6, 3, 4]       ; File, Edit, Search, Dev, Help

    ; ALT is the Commodore key, so ALT+letter arrives as a graphics code $A1..$BF (161..191);
    ; this maps each (indexed by code-161) back to its base letter. 0 = not a letter.
    ; (verbatim from sibling XFMGR2; e.g. ALT+F=187, ALT+E=177, ALT+S=174, ALT+H=180)
    ubyte[31] alt_letter = [
        'k','i','t', 0 ,'g', 0 ,'m', 0 , 0 ,'n','q','d','z','s','p',
        'a','e','r','w','h','j','l','y','u','o', 0 ,'f','c','x','v','b' ]

    sub menu_for_letter(ubyte letter) -> ubyte {
        ; top-menu accelerator: F/E/S/D/H -> menu index 0..4, else 255
        when letter {
            'f' -> return 0
            'e' -> return 1
            's' -> return 2
            'd' -> {                        ; Alt+D opens Dev only when it is shown
                if theme.show_dev
                    return 3
                return 255
            }
            'h' -> return 4
        }
        return 255
    }

    sub item_accel(ubyte active, ubyte key) -> ubyte {
        ; dropdown item accelerator: a folded letter -> item index, else 255
        when active {
            0 -> when key { 'n' -> return 0   'o' -> return 1   'v' -> return 2   's' -> return 3   'a' -> return 4   'x' -> return 5 }
            1 -> when key { 'u' -> return 0   'r' -> return 1   't' -> return 2   'c' -> return 3   'p' -> return 4   'd' -> return 5   'i' -> return 6   'm' -> return 7   'n' -> return 8   'w' -> return 9 }
            2 -> when key { 'f' -> return 0   'n' -> return 1   'r' -> return 2   'g' -> return 3 }
            3 -> when key { 'r' -> return 0   'b' -> return 1   't' -> return 2   'c' -> return 3   'u' -> return 4   's' -> return 5   'l' -> return 6 }
            else -> {                        ; Help. Dev shown: H/B/C/A -> 0/1/2/3. Dev hidden (no BASLOAD): H/C/A -> 0/1/2
                if theme.show_dev {
                    when key { 'h' -> return 0   'b' -> return 1   'c' -> return 2   'a' -> return 3 }
                } else {
                    when key { 'h' -> return 0   'c' -> return 1   'a' -> return 2 }
                }
            }
        }
        return 255
    }

    sub accel_off(ubyte active, ubyte i) -> ubyte {
        ; column offset of the accelerator letter within an item label (for highlighting)
        when active {
            0 -> when i { 4 -> return 5   5 -> return 1 }       ; Save As 'A'@5, Exit 'x'@1 (New/Open/View/Save 'N/O/V/S'@0 default)
            1 -> when i { 2 -> return 2   6 -> return 4   8 -> return 8 }   ; Cut 'T'@2, Duplicate 'i'@4, Move Down 'n'@8 (Move Up 'M'@0 default)
            2 -> when i { 1 -> return 5 }                       ; Find Next 'N'@5
            3 -> when i { 1 -> return 5 }                       ; Dev: Make Backup 'B'@5 (Run BASLOAD 'R'@0 default)
        }
        return 0
    }

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        scan_basload_error(cx16.r0L, cx16.r0H)  ; read the still-intact boot screen (X=width,Y=height) for a
                                                ; BASLOAD error line BEFORE the mode switch below wipes it
        snapshot_machine_state()                ; capture charset + text colour while still in the booted mode
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
        sys.disable_caseswitch()        ; lock the charset in lowercase - Shift+Commodore can't
                                        ; flip the whole display to uppercase mid-edit (as in XFMGR2)

        g_emu = emudbg.is_emulator()    ; remember the runtime environment
        xarena.detect_banks()           ; clamp banked storage to the RAM actually installed
        xarena.first_bank = edoc.ARENA_FIRST_BANK + 6   ; +6 past the reserved banks: picker.ovl (6), clipboard (7), misc.ovl (8), tview.ovl (9), picker records (10), menus.ovl (11)
        find_term[0] = 0                ; the "?"*N buffers start non-empty; clear them
        repl_term[0] = 0
        clip_has = false
        ; remember the working directory so we can restore it on exit (the file picker
        ; may chdir away). curdir() needs X16 DOS R42+; 0 = unsupported/error -> skip.
        startdir[0] = 0
        cx16.r1 = diskio.curdir()
        if cx16.r1 != 0
            void strings.copy(cx16.r1, startdir)
        theme.apply(theme.cfg_read())   ; colour scheme from the install folder's edit.cfg (missing -> Classic).
                                        ; Read here, while the cwd is still the fsroot we launched in - theme's
                                        ; paths are relative to it and it does no chdir of its own.
        if not theme.show_dev
            menu_col[4] = menu_col[3]    ; Dev menu hidden -> slide Help left into Dev's slot (no bar gap).
                                        ; show_dev is fixed for the session (only EDCFG changes it), so this
                                        ; one-time column overwrite is safe; Dev(3) is then never drawn/opened.

        ; load the misc overlay (About) into its reserved bank, from the install folder (same place
        ; edit.cfg came from - we are still in the launch cwd). A missing misc.ovl is not fatal:
        ; misc_ok stays false and About says so instead of jumping into empty RAM.
        cx16.push_rambank(MISC_BANK)
        misc_ok = diskio.loadlib(theme.path_to(miscovl), $a000) != 0
        cx16.pop_rambank()
        if misc_ok
            misc_init()                 ; extsub @bank 8: clears the overlay's in-bank BSS, ONCE
        else
            void diskio.status()         ; drop the FILE NOT FOUND (else the activity LED blinks)

        ; ...and the text/hex viewer overlay into its bank (same pattern). Missing tview.ovl is not
        ; fatal: tview_ok stays false and Help>Keyboard / File>View report it instead of jumping in.
        cx16.push_rambank(TVIEW_BANK)
        tview_ok = diskio.loadlib(theme.path_to(tviewovl), $a000) != 0
        cx16.pop_rambank()
        if tview_ok
            tview_init()                ; extsub @bank 9: clears the overlay's in-bank BSS, ONCE
        else
            void diskio.status()

        ; ...and the Open/View file picker overlay into its bank (bank 6, same pattern). Missing
        ; picker.ovl is not fatal: picker_ok stays false and File>Open / File>View report it.
        cx16.push_rambank(PICKER_BANK)
        picker_ok = diskio.loadlib(theme.path_to(pickerovl), $a000) != 0
        cx16.pop_rambank()
        if picker_ok {
            picker_init()               ; extsub @bank 6: clears the overlay's in-bank BSS, ONCE
            picker_setup(&rec_peek, &rec_read, &rec_write, &rec_move, &recstage)  ; wire the bank helpers
        } else
            void diskio.status()

        ; ...and the dropdown-menu label overlay into its bank (bank 11, same pattern). Missing
        ; menus.ovl is not fatal but degrades the UI: dropdowns paint blank; the bar + shortcuts work.
        cx16.push_rambank(MENUS_BANK)
        menus_ok = diskio.loadlib(theme.path_to(menusovl), $a000) != 0
        cx16.pop_rambank()
        if menus_ok
            menus_init()                ; extsub @bank 11: clears the overlay's in-bank BSS, ONCE
        else
            void diskio.status()
        bool reloaded = restore_run_state()
        if not reloaded {               ; fresh launch (no BASLOAD reload pending):
            snapshot_fkeys()            ;   capture the user's real fkeys before we ever hijack F8
            new_document()
        }                               ; (on reload, restore_run_state loaded the snapshot from ed.run)
        cursor_sprite_setup()                   ; the insert-mode underline cursor sprite (theme+mode set)
        full_redraw()
        if reloaded and berr_len != 0           ; the Run BASLOAD came back with an error; show the full
            show_basload_error()                ; error on the bar (cursor's already on the line it named)
        g_running = true
        while g_running {
            ubyte k = get_editor_key()
            editor_key(k)
        }

        if startdir[0] != 0             ; restore the working dir we started in
            diskio.chdir(startdir)
        cursor_sprite_off()                     ; don't leave our cursor sprite on for the next program
        txt.clear_screen()
        cx16.set_screen_mode(saved_mode)        ; restore the original screen mode
        restore_machine_state()                 ; re-apply the user's charset + text colour (CINT reset them)
        txt.clear_screen()                      ; clean screen in the restored charset/colours before sign-off
        if run_config {
            chain_load(theme.path_to(cfgprog))  ; hand off to EDCFG; it reloads EDIT (and ed.run) on exit
        } else if run_basload {
            chain_to_basload(filename)          ; hand off to BASLOAD; F8 stays armed for the return
        } else {
            restore_fkeys()                     ; put all fkeys back as the user had them (un-hijacks F8)
            txt.print("bye!\n")
        }
    }

    sub snapshot_machine_state() {
        ; capture the user's charset + text colour BEFORE we switch screen mode, so exit can
        ; put them back (set_screen_mode's CINT resets both to X16 defaults). Read while STILL
        ; in the booted screen mode. (pattern from sibling XFMGR2's snapshot_machine_state)
        saved_charset = cx16.get_charset()          ; 1=ISO 2=PETSCII upper/gfx 3=PETSCII lower (0=unknown)
        ; text colour = the colour matrix at the cursor cell. MUST use txt.getclr, not a hand-
        ; computed VERA address (the text matrix has a fixed 256-byte row stride, so row*width*2
        ; is wrong for row>0). High nibble = bg, low nibble = fg.
        ubyte cx_col
        ubyte cx_row
        cx_col, cx_row = txt.get_cursor()
        saved_color = txt.getclr(cx_col, cx_row)
    }

    sub restore_machine_state() {
        ; re-apply the charset + text colour captured at startup (the set_screen_mode call on
        ; exit already reset them to X16 defaults via its CINT).
        sys.enable_caseswitch()                             ; unlock the case switch we locked at startup
        if saved_charset >= 1 and saved_charset <= 3
            cx16.screen_set_charset(saved_charset, 0)       ; 0 ptr = built-in ROM charset
        if saved_color != 0                                 ; 0 = black-on-black -> skip a bad read
            txt.color2(saved_color & 15, saved_color >> 4)  ; low nibble = fg, high nibble = bg
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
            set_color_run(x0, x1, r, theme.CB_BOX)    ; dark-grey interior
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
        ; recolour the frame perimeter light-blue (XFMGR box borders); interior stays dark grey
        set_color_run(x0, x1, y0, theme.CB_BORDER)
        set_color_run(x0, x1, y1, theme.CB_BORDER)
        for r in y0 + 1 to y1 - 1 {
            txt.setclr(x0, r, theme.CB_BORDER)
            txt.setclr(x1, r, theme.CB_BORDER)
        }
    }

    sub draw_box_title(ubyte x0, ubyte x1, ubyte row, str title) {
        ; XFMGR-style solid title bar: blank the top border row, centre the title, and colour the
        ; whole span white-on-light-blue (theme.CB_BAR) - a raised "title bar" instead of a title floating
        ; on the frame line. The 3D look comes from the box's drop shadow (draw_box_shadow) beneath.
        ; Mirrors XFMGR2's uiutil.do_box_header.
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SPACE_SC)
        ubyte tlen = lsb(strings.length(title))
        put_str_at(x0 + 1 + (x1 - x0 - 1 - tlen) / 2, row, title)
        set_color_run(x0 + 1, x1 - 1, row, theme.CB_BAR)
    }

    sub draw_menu_sep(ubyte x0, ubyte x1, ubyte row) {
        ; a horizontal divider row across a dropdown's interior, tee'd into both side rails.
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SC_H)
        txt.setchr(x0, row, SC_VR)
        txt.setchr(x1, row, SC_VL)
        set_color_run(x0, x1, row, theme.CB_BAR)      ; match the recoloured frame glyphs
    }

    sub draw_box_sep(ubyte x0, ubyte x1, ubyte row) {
        ; a soft section rule inside a box: like draw_menu_sep but coloured in the frame colour
        ; (thin light-blue line on the dark interior) instead of the bold white-on-blue bar.
        ubyte c
        for c in x0 + 1 to x1 - 1
            txt.setchr(c, row, SC_H)
        txt.setchr(x0, row, SC_VR)
        txt.setchr(x1, row, SC_VL)
        set_color_run(x0, x1, row, theme.CB_BORDER)
    }

    sub draw_box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ; drop shadow one row below and one column right of the box: just recolour those cells to a
        ; soft solid grey (theme.CB_SHADOW). The grey is in the *background* nibble, so the cell fills grey
        ; with no glyph - visible against EDIT's black text area without a shade character.
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

    ; ---------- text-area rendering ----------

    sub recompute_gutter() {
        ; set gutter_w from the line count: min 3 digits so 1-999 lines get a roomy gutter,
        ; widening past 999, plus one separator column. 0 when the feature is off.
        if not ln_on {
            gutter_w = 0
            return
        }
        ubyte digits = 3
        uword t = edoc.line_count
        while t >= 1000 {
            digits++
            t /= 10
        }
        gutter_w = digits + 1
    }

    sub draw_gutter(ubyte r) {
        draw_gutter_dl(r, top_line + r, true)
    }

    sub draw_gutter_dl(ubyte r, uword idx, bool shownum) {
        ; paint the gutter strip for screen row r showing doc line `idx`. shownum=false blanks the
        ; number (used for soft-wrap continuation rows, which share the line above's number).
        if gutter_w == 0
            return
        ubyte sy = TEXT_TOP + r
        ubyte gcol = theme.CB_GUTTER
        if idx == cur_row
            gcol = theme.CB_GUTTER_CUR
        ubyte c
        for c in 0 to gutter_w - 1 {                 ; dark-grey strip; last col is the separator
            txt.setchr(c, sy, SPACE_SC)
            txt.setclr(c, sy, gcol)
        }
        if not shownum or idx >= edoc.line_count
            return                                   ; continuation row / past EOF -> blank gutter
        uword n = idx + 1                            ; 1-based line number, right-aligned
        ubyte pos = gutter_w - 2                     ; rightmost digit (gutter_w-1 = separator)
        repeat {
            txt.setchr(pos, sy, txt.petscii2scr('0' + lsb(n % 10)))
            n /= 10
            if n == 0 or pos == 0
                break
            pos--
        }
    }

    sub wrap_next(uword buf, ubyte llen, ubyte start, ubyte w) -> ubyte {
        ; soft-wrap: given the segment beginning at column `start`, return where it ends / the next
        ; segment begins. Segment = buf[start .. result). result==llen means it's the last segment.
        if w == 0 or start + w >= llen
            return llen                              ; the rest fits on one visual row
        ubyte i = start + w                          ; hard-break point (exclusive)
        while i > start {
            i--
            if @(buf + i) == ' '
                return i + 1                         ; break after the last space in the window
        }
        return start + w                            ; a single word wider than the row -> hard break
    }

    sub seg_start_of(uword buf, ubyte llen, ubyte col, ubyte w) -> ubyte {
        ; column where the wrap-segment CONTAINING `col` begins (col may equal llen = at end)
        ubyte s = 0
        repeat {
            ubyte e = wrap_next(buf, llen, s, w)
            if col < e or e >= llen
                return s
            s = e
        }
    }

    sub seg_last_start(uword buf, ubyte llen, ubyte w) -> ubyte {
        ; column where the final wrap-segment of the line begins
        ubyte s = 0
        repeat {
            ubyte e = wrap_next(buf, llen, s, w)
            if e >= llen
                return s
            s = e
        }
    }

    sub seg_prev_start(uword buf, ubyte llen, ubyte segstart, ubyte w) -> ubyte {
        ; column where the wrap-segment immediately BEFORE the one at `segstart` begins
        ubyte s = 0
        repeat {
            ubyte e = wrap_next(buf, llen, s, w)
            if e >= segstart
                return s
            s = e
        }
    }

    sub draw_text_row(ubyte r) {
        ; paint one screen row: line-number gutter, characters, body colour, selection, cursor
        ubyte sy = TEXT_TOP + r
        uword idx = top_line + r
        ; resolve this row's source line once (the cursor row uses the live editbuf)
        ubyte blen = 0
        uword bufptr = 0
        if idx < edoc.line_count {
            if idx == cur_row {
                bufptr = &editbuf
                blen = cur_len
            } else {
                blen = edoc.load(idx, &tmpbuf)
                bufptr = &tmpbuf
            }
        }
        ; syntax colouring: classify the whole line once into hlcol[] (one colour per doc
        ; column), then the cell loop reads it. Display-only; selection/cursor still override.
        if hl_on and blen != 0
            run_syntax(bufptr, blen)
        draw_gutter(r)                          ; line-number strip in cols [0, gutter_w)
        ; single pass: each text cell (screen col gutter_w+c) gets its char + colour
        ubyte textw = SCR_W - gutter_w
        ubyte c
        for c in 0 to textw - 1 {
            uword srcidx = (left_col as uword) + c
            ubyte ch = SPACE_SC
            ubyte col = theme.CB_BODY
            if srcidx < blen {
                ch = txt.petscii2scr(@(bufptr + srcidx))
                if hl_on
                    col = hlcol[lsb(srcidx)]        ; srcidx < blen <= 250, fits a byte index
            }
            if idx == cur_row
                col = (col & $0f) | (theme.CB_BAND & $f0)   ; current-line band: theme bg, keep the fg
            txt.setchr(gutter_w + c, sy, ch)
            txt.setclr(gutter_w + c, sy, col)
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
                while sccol < textw {
                    uword dcol = left_col
                    dcol += sccol
                    if dcol >= c1
                        break
                    if dcol >= c0
                        txt.setclr(gutter_w + sccol, sy, theme.CB_MARK)
                    sccol++
                }
            }
        }
        ; cursor cell: OVERTYPE (or no sprite) = reverse-block; INSERT = left blank, the underline
        ; sprite marks it instead (so insert and overtype look different)
        if idx == cur_row and cur_col >= left_col and (ovr_mode or not spr_ok) {
            ubyte ccol = cur_col - left_col
            if ccol < textw
                txt.setclr(gutter_w + ccol, sy, theme.CB_CUR)
        }
    }

    sub draw_all_text() {
        recompute_gutter()              ; pick up a toggle or a line-count digit-width change
        if wrap_on {
            draw_all_text_wrapped()
            return
        }
        ubyte r
        for r in 0 to TEXT_ROWS - 1
            draw_text_row(r)
        prev_cur_row = cur_row          ; a full repaint freshly draws the cursor at cur_row
    }

    sub draw_wrapped_row(ubyte r, uword dl, ubyte cstart, ubyte cend, bool shownum) {
        ; draw doc line `dl`'s slice [cstart, cend) on screen row r (soft-wrap visual row)
        ubyte sy = TEXT_TOP + r
        ubyte blen = 0
        uword bufptr = 0
        if dl < edoc.line_count {
            if dl == cur_row {
                bufptr = &editbuf
                blen = cur_len
            } else {
                blen = edoc.load(dl, &tmpbuf)
                bufptr = &tmpbuf
            }
        }
        if hl_on and blen != 0
            run_syntax(bufptr, blen)
        draw_gutter_dl(r, dl, shownum)
        ubyte textw = SCR_W - gutter_w
        ubyte c
        for c in 0 to textw - 1 {
            ubyte srcidx = cstart + c
            ubyte ch = SPACE_SC
            ubyte col = theme.CB_BODY
            if srcidx < cend {
                ch = txt.petscii2scr(@(bufptr + srcidx))
                if hl_on
                    col = hlcol[srcidx]
            }
            if dl == cur_row
                col = (col & $0f) | $b0
            txt.setchr(gutter_w + c, sy, ch)
            txt.setclr(gutter_w + c, sy, col)
        }
        if sel_active {
            sel_norm()
            if dl >= s_row and dl <= e_row {
                ubyte c0 = 0
                if dl == s_row
                    c0 = s_col
                ubyte c1 = blen                     ; whole rest of line for non-end rows
                if dl == e_row
                    c1 = e_col
                ubyte cc = 0
                while cc < textw {
                    ubyte dcol = cstart + cc
                    if dcol >= cend or dcol >= c1
                        break
                    if dcol >= c0
                        txt.setclr(gutter_w + cc, sy, theme.CB_MARK)
                    cc++
                }
            }
        }
        if dl == cur_row and cur_col >= cstart {
            bool oncur = cur_col < cend
            if cur_col == cend and cend >= blen
                oncur = true                        ; cursor at the very end of the last segment
            if oncur {
                ubyte ccol = cur_col - cstart
                if ccol < textw
                    txt.setclr(gutter_w + ccol, sy, theme.CB_CUR)
            }
        }
    }

    sub draw_all_text_wrapped() {
        ubyte textw = SCR_W - gutter_w
        ubyte r = 0
        uword dl = top_line
        ubyte seg = top_seg
        while r < TEXT_ROWS {
            if dl >= edoc.line_count {
                draw_wrapped_row(r, dl, 0, 0, true)     ; blank row past end-of-document
                r++
            } else {
                uword b
                ubyte llen
                if dl == cur_row {
                    b = &editbuf
                    llen = cur_len
                } else {
                    b = &tmpbuf
                    llen = edoc.load(dl, &tmpbuf)
                }
                ubyte segend = wrap_next(b, llen, seg, textw)
                draw_wrapped_row(r, dl, seg, segend, seg == 0)
                r++
                if segend >= llen {
                    dl++
                    seg = 0
                } else {
                    seg = segend
                }
            }
        }
        prev_cur_row = cur_row
    }

    sub draw_gutter_all() {
        ; refresh every visible row's line number - used after a VRAM vertical scroll, which
        ; shifts the text correctly but carries the old (now wrong) gutter numbers along with it
        if gutter_w == 0
            return
        ubyte r
        for r in 0 to TEXT_ROWS - 1
            draw_gutter(r)
    }

    sub vram_copy_row(ubyte src_sy, ubyte dst_sy) {
        ; copy one whole screen row (SCR_W cells x 2 bytes) within VRAM using VERA's two
        ; data ports: port0 reads the source, port1 writes the destination, both auto-
        ; incrementing. Far cheaper than re-emitting the row through conio. The text map is
        ; 256 bytes per row; its base is decoded from VERA_L1_MAPBASE (bit7 -> VRAM bank).
        ubyte bnk = cx16.VERA_L1_MAPBASE >> 7
        uword mb = (cx16.VERA_L1_MAPBASE & $7f) as uword
        mb <<= 9                                    ; map base, bits 15:9
        uword src = mb + (src_sy as uword) * 256
        uword dst = mb + (dst_sy as uword) * 256
        cx16.VERA_CTRL = 0                          ; ADDRSEL 0 -> set ADDR0 (source)
        cx16.VERA_ADDR_L = lsb(src)
        cx16.VERA_ADDR_M = msb(src)
        cx16.VERA_ADDR_H = %00010000 | bnk          ; auto-increment by 1, bank bit
        cx16.VERA_CTRL = 1                          ; ADDRSEL 1 -> set ADDR1 (destination)
        cx16.VERA_ADDR_L = lsb(dst)
        cx16.VERA_ADDR_M = msb(dst)
        cx16.VERA_ADDR_H = %00010000 | bnk
        ubyte c
        for c in 0 to SCR_W - 1 {
            cx16.VERA_DATA1 = cx16.VERA_DATA0       ; char  (DATA0 uses ADDR0, DATA1 ADDR1)
            cx16.VERA_DATA1 = cx16.VERA_DATA0       ; colour
        }
        cx16.VERA_CTRL = 0                          ; leave ADDRSEL at conio's default
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

    sub line_buf_len(uword dl) -> ubyte {
        ; resolve doc line dl for wrap math: cursor line -> live editbuf, else tmpbuf. sets g_wbuf.
        if dl == cur_row {
            g_wbuf = &editbuf
            return cur_len
        }
        g_wbuf = &tmpbuf
        return edoc.load(dl, &tmpbuf)
    }

    sub retreat_top() {
        ; move (top_line, top_seg) back by one visual row
        ubyte textw = SCR_W - gutter_w
        ubyte llen
        if top_seg != 0 {
            llen = line_buf_len(top_line)
            top_seg = seg_prev_start(g_wbuf, llen, top_seg, textw)
        } else if top_line != 0 {
            top_line--
            llen = line_buf_len(top_line)
            top_seg = seg_last_start(g_wbuf, llen, textw)
        }
    }

    sub ensure_visible_wrap() {
        ; keep the cursor's visual row on screen by moving (top_line, top_seg)
        ubyte textw = SCR_W - gutter_w
        ubyte cseg = seg_start_of(&editbuf, cur_len, cur_col, textw)   ; cursor line = editbuf
        if cur_row < top_line or (cur_row == top_line and cseg < top_seg) {
            top_line = cur_row                  ; cursor above the top -> pin it to the top row
            top_seg = cseg
            return
        }
        uword dl = top_line                     ; is it already within [top, top+TEXT_ROWS)?
        ubyte seg = top_seg
        ubyte rows = 0
        while rows < TEXT_ROWS {
            if dl == cur_row and seg == cseg
                return                          ; visible
            if dl >= edoc.line_count
                break
            ubyte llen = line_buf_len(dl)
            ubyte e = wrap_next(g_wbuf, llen, seg, textw)
            if e >= llen {
                dl++
                seg = 0
            } else {
                seg = e
            }
            rows++
        }
        top_line = cur_row                      ; below the bottom -> put cursor on the last row
        top_seg = cseg
        ubyte k = 0
        while k < TEXT_ROWS - 1 {
            retreat_top()
            k++
        }
    }

    sub set_col_in_seg(ubyte tstart, ubyte scol, uword buf, ubyte llen, ubyte w) {
        ; place the cursor `scol` columns into the segment starting at `tstart`, clamped so it
        ; stays on that visual row
        ubyte tend = wrap_next(buf, llen, tstart, w)
        ubyte maxc = tend - 1
        if tend >= llen
            maxc = llen                         ; last segment: cursor may sit at the very end
        ubyte nc = tstart + scol
        if nc > maxc
            nc = maxc
        cur_col = nc
    }

    sub ed_up_wrap() {
        ubyte textw = SCR_W - gutter_w
        ubyte cseg = seg_start_of(&editbuf, cur_len, cur_col, textw)
        ubyte scol = cur_col - cseg
        ubyte tstart
        if cseg != 0 {
            tstart = seg_prev_start(&editbuf, cur_len, cseg, textw)
            set_col_in_seg(tstart, scol, &editbuf, cur_len, textw)
            redraw_after_move()
        } else if cur_row != 0 {
            goto_row(cur_row - 1)               ; commits editbuf + loads the previous line
            tstart = seg_last_start(&editbuf, cur_len, textw)
            set_col_in_seg(tstart, scol, &editbuf, cur_len, textw)
            redraw_after_move()
        }
    }

    sub ed_down_wrap() {
        ubyte textw = SCR_W - gutter_w
        ubyte cseg = seg_start_of(&editbuf, cur_len, cur_col, textw)
        ubyte scol = cur_col - cseg
        ubyte cend = wrap_next(&editbuf, cur_len, cseg, textw)
        if cend < cur_len {
            set_col_in_seg(cend, scol, &editbuf, cur_len, textw)
            redraw_after_move()
        } else if cur_row + 1 < edoc.line_count {
            goto_row(cur_row + 1)
            set_col_in_seg(0, scol, &editbuf, cur_len, textw)
            redraw_after_move()
        }
    }

    sub ensure_visible() -> bool {
        if wrap_on {
            ensure_visible_wrap()               ; wrap: adjust the visual top and force a full repaint
            return true
        }
        bool s = false
        if cur_row < top_line {
            top_line = cur_row
            s = true
        } else if cur_row >= top_line + TEXT_ROWS {
            top_line = cur_row - TEXT_ROWS + 1
            s = true
        }
        ubyte textw = SCR_W - gutter_w          ; usable text width (gutter eats the left edge)
        if cur_col < left_col {
            left_col = cur_col
            s = true
        } else if cur_col >= left_col + textw {
            left_col = cur_col - textw + 1
            s = true
        }
        return s
    }

    sub place_cursor() {
        ; no-op: the cursor cell is now painted by draw_text_row. Kept so the many
        ; existing call sites still compile; they always repaint the affected row(s).
    }

    ; ---------- insert-mode underline cursor (VERA sprite) ----------
    ; The X16 text layer is one screencode + one colour per 8x8 cell, so a sub-cell underline is
    ; impossible in the cell itself. Instead a single VERA sprite floats above the text as the
    ; INSERT-mode underline; OVERTYPE keeps the reverse-block cell (drawn in draw_text_row), so only
    ; one sprite shape is needed. The sprite lives above layer 1 (Z=3), so it must be HIDDEN whenever
    ; a menu/dialog is open (done in wait_key) and repositioned before each editor keypress
    ; (get_editor_key). Position is in tile space (col*8, row*8): VERA scales sprites together with
    ; the text layer, so this aligns in both 80x30 and 40x30.
    const uword CURS_VADDR = $0000          ; sprite bitmap: VRAM bank 1 -> $10000 (8x8 4bpp = 32 bytes)
    const uword CURS_ATTR  = $fc00          ; sprite 0 attributes: VRAM bank 1 -> $1FC00

    sub curs_color_index() -> ubyte {
        ; a palette index that reads on the theme's field: dark on the Light (white) field, else bright
        if theme.current == 3
            return 11                       ; dark grey on white
        return 7                            ; yellow on the dark-grey / blue fields
    }

    sub cursor_sprite_setup() {
        ; upload the underline bitmap (bottom 2 of 8 rows filled) + configure sprite 0, then enable
        ; sprites globally. Runs once, after the theme and screen mode are set.
        ubyte ci = curs_color_index()
        ubyte fill = (ci << 4) | ci         ; a 4bpp byte = two filled pixels of colour ci
        ubyte i
        for i in 0 to 31 {
            ubyte v = 0
            if i >= 24                       ; bytes 24..31 = tile rows 6..7 = the underline
                v = fill
            cx16.vpoke(1, CURS_VADDR + i, v)
        }
        cx16.vpoke(1, CURS_ATTR + 0, $00)   ; data addr>>5 = $10000>>5 = $800 -> lo $00 ...
        cx16.vpoke(1, CURS_ATTR + 1, $08)   ; ... hi nibble $8, mode bit7=0 (4bpp)
        cx16.vpoke(1, CURS_ATTR + 6, $00)   ; Z=0: start hidden
        cx16.vpoke(1, CURS_ATTR + 7, $00)   ; 8x8, palette offset 0
        cx16.VERA_CTRL = cx16.VERA_CTRL & %11111101     ; DCSEL=0 so DC_VIDEO is addressable
        cx16.VERA_DC_VIDEO = cx16.VERA_DC_VIDEO | %01000000   ; sprites enable
        spr_ok = true
    }

    sub cursor_sprite_off() {
        if spr_ok
            cx16.vpoke(1, CURS_ATTR + 6, $00)           ; Z=0 -> disabled
    }

    sub cursor_update() {
        ; reposition + show the insert underline; hide it in overtype / wrap / off-screen (all of which
        ; fall back to the reverse-block cell painted by draw_text_row / draw_wrapped_row)
        if not spr_ok
            return
        if ovr_mode or wrap_on {
            cursor_sprite_off()
            return
        }
        if cur_row < top_line or cur_row >= top_line + TEXT_ROWS or cur_col < left_col {
            cursor_sprite_off()
            return
        }
        ubyte scol = gutter_w + lsb(cur_col - left_col)
        if scol >= SCR_W {
            cursor_sprite_off()
            return
        }
        ubyte srow = TEXT_TOP + lsb(cur_row - top_line)
        uword px = (scol as uword) << 3
        uword py = (srow as uword) << 3
        cx16.vpoke(1, CURS_ATTR + 2, lsb(px))
        cx16.vpoke(1, CURS_ATTR + 3, msb(px))
        cx16.vpoke(1, CURS_ATTR + 4, lsb(py))
        cx16.vpoke(1, CURS_ATTR + 5, msb(py))
        cx16.vpoke(1, CURS_ATTR + 6, $0c)               ; Z=3 -> in front of layer 1
    }

    sub redraw_after_move() {
        ; Repaint after a cursor move as cheaply as the move allows:
        ;   * selection active        -> full repaint (the highlight spans many rows)
        ;   * no scroll                -> repaint only the old + new cursor rows
        ;   * scrolled by exactly 1    -> shift the text window in VRAM, repaint 1-2 rows
        ;   * scrolled further (PgUp/Dn)-> full repaint
        bool force_full = sel_cleared           ; a selection was just collapsed -> repaint every row once
        sel_cleared = false
        if wrap_on {
            ensure_visible_wrap()               ; soft-wrap forces a full repaint (segments shift)
            draw_all_text()
            draw_status()
            return
        }
        uword old_top = top_line
        ubyte old_left = left_col
        bool scrolled = ensure_visible()
        if sel_active or force_full or left_col != old_left {
            ; selection spans rows (or was just cleared), or a horizontal scroll changed every row
            draw_all_text()
            draw_status()
            return
        }
        if not scrolled {
            if prev_cur_row >= top_line and prev_cur_row < top_line + TEXT_ROWS
                draw_text_row(lsb(prev_cur_row - top_line))
            draw_text_row(lsb(cur_row - top_line))
            prev_cur_row = cur_row
            draw_status()
            return
        }
        if top_line == old_top + 1 {
            ; scrolled down one: text content moves up a row (copy rows 1..n-1 -> 0..n-2)
            ubyte r
            for r in 0 to TEXT_ROWS - 2
                vram_copy_row(TEXT_TOP + r + 1, TEXT_TOP + r)
            draw_text_row(TEXT_ROWS - 1)                ; new bottom row (holds the cursor)
            if prev_cur_row >= top_line and prev_cur_row < top_line + TEXT_ROWS
                draw_text_row(lsb(prev_cur_row - top_line))   ; clear the old cursor cell
        } else if old_top == top_line + 1 {
            ; scrolled up one: text content moves down a row (copy bottom-up to avoid clobber)
            ubyte rd = TEXT_ROWS - 1
            while rd != 0 {
                vram_copy_row(TEXT_TOP + rd - 1, TEXT_TOP + rd)
                rd--
            }
            draw_text_row(0)                            ; new top row (holds the cursor)
            if prev_cur_row >= top_line and prev_cur_row < top_line + TEXT_ROWS
                draw_text_row(lsb(prev_cur_row - top_line))
        } else {
            draw_all_text()
        }
        draw_gutter_all()               ; the VRAM shift carried stale line numbers; refresh them
        prev_cur_row = cur_row
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
        bar_fill(0, theme.CB_BAR)
        put_str_at(menu_col[0], 0, "File")
        put_str_at(menu_col[1], 0, "Edit")
        put_str_at(menu_col[2], 0, "Search")
        if theme.show_dev
            put_str_at(menu_col[3], 0, "Dev")      ; hidden when show_dev is off (Help sits at its column)
        put_str_at(menu_col[4], 0, "Help")
        draw_filename_title()
        if active != 255 {
            ubyte x
            for x in menu_col[active] to menu_col[active] + menu_len[active] - 1
                txt.setclr(x, 0, theme.CB_MENUSEL)
        }
        ; highlight each title's accelerator letter (F/E/S/D/H, always the first char); skip Dev if hidden
        ubyte mi
        for mi in 0 to NMENU - 1 {
            if theme.show_dev or mi != 3 {
                ubyte base = theme.CB_BAR
                if mi == active
                    base = theme.CB_MENUSEL
                txt.setclr(menu_col[mi], 0, (base & $f0) | theme.ACCEL_FG)
            }
        }
    }

    sub draw_status() {
        bar_fill(STATUS_ROW, theme.CB_BAR)
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
        if ovr_mode
            put_str_at(col, STATUS_ROW, "  OVR")
        else
            put_str_at(col, STATUS_ROW, "  INS")
        col += 5
        ; right-side menu hint (short form when narrow)
        ubyte hint_col
        if SCR_W >= 80 {
            hint_col = SCR_W - 13
            put_str_at(hint_col, STATUS_ROW, "Esc/Alt=Menu")
        } else {
            hint_col = SCR_W - 9
            put_str_at(hint_col, STATUS_ROW, "Alt=Menu")
        }
        ; document line count, centered on the bar (drawn only if it clears the cursor
        ; info on the left and the menu hint on the right)
        uword lc = edoc.line_count
        ubyte digits = 1
        uword t = lc
        while t >= 10 {
            digits++
            t /= 10
        }
        ubyte lwidth = 12 + digits          ; "Total Lines " + the number
        ubyte lstart = (SCR_W - lwidth) / 2
        if lstart > col + 1 and lstart + lwidth < hint_col {
            put_str_at(lstart, STATUS_ROW, "Total Lines ")
            void put_uw_at(lstart + 12, STATUS_ROW, lc)
        }
    }

    sub full_redraw() {
        txt.color2(theme.COL_FG, theme.COL_BG)
        txt.clear_screen()
        draw_menubar(255)
        draw_all_text()
        draw_status()
        place_cursor()
        g_redrawn = true                ; tell menu_mode_loop the screen is already restored
    }

    ; ---------- input ----------

    sub wait_key() -> ubyte {
        cursor_sprite_off()                 ; modal loops (menus/dialogs) run here: hide the editor cursor
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
        cursor_update()                 ; the editor is idle here: position + show the insert underline
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

    sub draw_ww_label(bool live) {
        ; whole-word indicator on the right of the search bar.
        ;  live=true  : the toggle shown on the Find/Replace INPUT prompts - always shows the
        ;               On/Off state and highlights the W (Commodore+W flips it, top-menu style).
        ;  live=false : a read-only reminder on the Replace? bar - drawn only when it's on.
        if live {
            ubyte c = SCR_W - 16            ; "Whole Word  Off" = 15 chars + a 1-col right margin
            if ww_on
                put_str_at(c, STATUS_ROW, "Whole Word  On ")
            else
                put_str_at(c, STATUS_ROW, "Whole Word  Off")
            txt.setclr(c, STATUS_ROW, (theme.CB_BAR & $f0) | theme.ACCEL_FG)   ; highlight the W accelerator
        } else {
            if not ww_on
                return
            put_str_at(SCR_W - 11, STATUS_ROW, "Whole Word")       ; 10 chars + a 1-col right margin
        }
    }

    sub prompt_str(str promptmsg, uword dest, ubyte maxlen, bool allow_empty, bool ww_hint) -> bool {
        ; modal text input on the status row. Enter -> true (false if empty and not
        ; allow_empty); Esc/Stop -> false. Pre-fills with whatever is already in dest.
        ; ww_hint: show the whole-word toggle on the bar and let Commodore+W flip it live.
        flash_status(promptmsg)                 ; one red flash so the prompt draws the eye
        bar_fill(STATUS_ROW, theme.CB_BAR)
        put_str_at(1, STATUS_ROW, promptmsg)
        if ww_hint
            draw_ww_label(true)
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
            txt.setclr(c, STATUS_ROW, theme.CB_CUR)
            ubyte k = wait_key()
            txt.setclr(c, STATUS_ROW, theme.CB_BAR)
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
                179 -> {                         ; Commodore+W (ALT+W): toggle whole-word live
                    if ww_hint {                 ; (search prompts only; 179 = alt_letter['w'])
                        ww_on = not ww_on
                        draw_ww_label(true)
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

    sub flash_status(str m) {
        ; one bright-red attention flash of a status-row prompt, so it isn't missed on the thin
        ; bottom bar; the caller then draws it normally (theme.CB_BAR) and it stays readable.
        bar_fill(STATUS_ROW, $21)                       ; red bg, white fg
        put_str_at(1, STATUS_ROW, m)
        sys.wait(18)                                    ; ~0.3s
    }

    sub confirm_save() -> ubyte {
        ; 0 = don't save, 1 = save, 2 = cancel. Flash the prompt so it isn't missed on the status
        ; row - users overlooked the silent bar and thought Open did nothing.
        flash_status("Save changes? Y/N  (Esc=Cancel)")
        bar_fill(STATUS_ROW, theme.CB_BAR)                    ; settle to the normal bar, stays readable
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

    sub confirm_overwrite(str name) -> bool {
        ; true = OK to write. If the file already exists, flash a prompt and require Y to proceed.
        if not diskio.exists(name)
            return true
        flash_status("Overwrite existing file? Y/N")
        bar_fill(STATUS_ROW, theme.CB_BAR)
        put_str_at(1, STATUS_ROW, "Overwrite existing file? Y/N")
        repeat {
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            when k {
                'y' -> return true
                'n', 27, 3 -> return false
            }
        }
    }

    sub status_msg(str m) {
        ; paint a transient message on the status bar with NO delay - used for progress
        ; hints ("Saving..."/"Loading...") right before a slow operation that will repaint
        bar_fill(STATUS_ROW, theme.CB_BAR)
        put_str_at(1, STATUS_ROW, m)
    }

    sub notify(str m) {
        status_msg(m)
        sys.wait(60)
    }

    sub flash_notify(str m) {
        ; like notify, but RESTORES the normal footer afterward instead of leaving the message on the
        ; bar. A short red flash grabs the eye, the message holds briefly on the normal bar, then
        ; draw_status() repaints the Line/Col/INS footer. Used for transient outcomes (e.g. "Save
        ; cancelled") that happen back in the editor, where nothing else would repaint the bar.
        flash_status(m)                     ; ~0.3s red attention flash
        status_msg(m)                       ; hold it readable on the normal bar
        sys.wait(45)
        draw_status()                       ; restore the footer bar
    }

    sub blink_phases(uword sz) -> ubyte {
        ; map an approximate size (256-byte blocks) to a blink length:
        ; small -> ~0.5s (2 phases), medium -> ~1.1s (4), large -> ~1.6s (6)
        if sz < 16
            return 1
        if sz < 64
            return 4
        return 6
    }

    sub notify_blink(str m, ubyte phases) {
        ; bold, impossible-to-miss status-bar flash: invert the WHOLE line between bright
        ; red and white `phases` times (16 jiffies each). Announces a save/load; the phase
        ; count scales with file size so tiny files don't blink for long.
        ubyte i
        for i in 0 to phases - 1 {
            ubyte col = $21                 ; red bg, white fg
            if (i & 1) != 0
                col = $12                   ; white bg, red fg  (hard invert each phase)
            bar_fill(STATUS_ROW, col)
            put_str_at(1, STATUS_ROW, m)
            sys.wait(16)
        }
        status_msg(m)                       ; end static and readable on the normal bar
    }

    ; ---------- dropdown menus ----------

    sub menu_flags() -> ubyte {
        ; pack the states menus.ovl needs for its dynamic item labels:
        ; bit0 = word wrap, bit1 = syntax colour, bit2 = line numbers, bit3 = Dev menu shown
        ; (when Dev is hidden, the Help menu also drops its BASLOAD item and compacts).
        ubyte f = 0
        if wrap_on
            f |= 1
        if hl_on
            f |= 2
        if ln_on
            f |= 4
        if theme.show_dev
            f |= 8
        return f
    }

    sub help_logical(ubyte i) -> ubyte {
        ; map a DISPLAYED Help-menu row to its logical action index. When Dev is hidden the BASLOAD
        ; item (logical index 1) is removed, so displayed rows 1.. shift up past it.
        if not theme.show_dev and i >= 1
            return i + 1
        return i
    }

    sub dropdown_row(ubyte active, ubyte i) -> ubyte {
        ; screen row of dropdown item `i` (items below the group divider shift down one)
        ubyte row = 2 + i                       ; y0 is always 1, so first item is row 2
        ubyte dsep = menu_divider(active)
        if dsep != 255 and i > dsep
            row++
        return row
    }

    sub draw_dropdown_item(ubyte active, ubyte x0, ubyte x1, ubyte i, ubyte sel) {
        ; paint ONE dropdown item row in its current selected/unselected state. Used both by the
        ; full draw and by the up/down navigation, which repaints only the two rows that change.
        ubyte row = dropdown_row(active, i)
        ubyte base = theme.CB_BAR
        set_color_run(x0 + 1, x1 - 1, row, theme.CB_BAR)
        if menus_ok
            mnu_item(active, i, x0 + 2, row, menu_flags())      ; item label text lives in menus.ovl
        if i == sel {
            set_color_run(x0 + 1, x1 - 1, row, theme.CB_MENUSEL)   ; selected row: reverse so it pops
            base = theme.CB_MENUSEL
        }
        ; recolour just the accelerator letter (keep the row's bg) - drawn last so it
        ; survives the selection fill
        txt.setclr(x0 + 2 + accel_off(active, i), row, (base & $f0) | theme.ACCEL_FG)
    }

    sub draw_dropdown(ubyte active, ubyte x0, ubyte y0, ubyte x1, ubyte y1, ubyte n, ubyte sel) {
        draw_box_frame(x0, y0, x1, y1)
        ; the dropdown shares the top bar's light-blue background; recolour the whole box so
        ; the frame glyphs become white on light blue and items match the menu bar.
        ubyte fr
        for fr in y0 to y1
            set_color_run(x0, x1, fr, theme.CB_BAR)
        ubyte dsep = menu_divider(active)       ; item index a divider follows (255 = no divider)
        ubyte i
        for i in 0 to n - 1 {
            draw_dropdown_item(active, x0, x1, i, sel)
            if dsep != 255 and i == dsep         ; draw the divider row just under item `dsep`
                draw_menu_sep(x0, x1, dropdown_row(active, i) + 1)
        }
    }

    sub menu_divider(ubyte active) -> ubyte {
        ; the dropdown-item index that a horizontal divider follows, grouping the menu (255 = none).
        when active {
            1 -> return 8       ; Edit: line ops (Undo..Move Down) | display toggle (Word Wrap)
            3 -> return 4       ; Dev:  actions (Run BASLOAD, Make Backup, comment ops) | view toggles (Syntax, Line#)
        }
        return 255
    }

    sub run_dropdown(ubyte active) -> ubyte {
        ; returns the chosen item index, or 255=esc, 254=prev menu, 253=next menu
        ubyte n = 4
        ubyte boxw = 13                     ; Help ("Help... F1/BASLOAD.../Config.../About")
        when active {
            0 -> { n = 6  boxw = 17 }       ; File ("Open...    Ctrl+O")
            1 -> { n = 10  boxw = 22 }      ; Edit ("Paste        Ctrl+V/F4")
            2 -> { n = 4  boxw = 21 }       ; Search ("Replace...  Ctrl+R/F8")
            3 -> { n = 7  boxw = 22 }       ; Dev ("Uncomment Block Ctrl+W")
        }
        if active == 4 and not theme.show_dev
            n = 3                           ; Dev hidden -> Help drops BASLOAD, leaving Help/Config/About
        ubyte x0 = menu_col[active] - 1
        ubyte y0 = 1
        ubyte x1 = x0 + boxw + 3
        if x1 > SCR_W - 1 {                 ; shift left so the box stays on screen (40-col)
            ubyte over = x1 - (SCR_W - 1)
            x0 -= over
            x1 = SCR_W - 1
        }
        ubyte y1 = y0 + n + 1
        if menu_divider(active) != 255      ; a divider row adds one to the box height (Edit, Dev)
            y1++
        md_boxbot = y1                      ; remember the box extent so it can be erased cheaply
        ubyte sel = 0
        ubyte old                           ; prog8 has no block scope - hoist the nav scratch
        draw_dropdown(active, x0, y0, x1, y1, n, sel)   ; full box once; navigation patches 2 rows
        repeat {
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            ubyte acc = item_accel(active, k)   ; letter accelerator activates the item
            if acc != 255
                return acc
            when k {
                27, 3 -> return 255
                17 -> {
                    old = sel
                    sel++
                    if sel >= n
                        sel = 0
                    draw_dropdown_item(active, x0, x1, old, sel)   ; only the two changed rows repaint
                    draw_dropdown_item(active, x0, x1, sel, sel)
                }
                145 -> {
                    old = sel
                    if sel == 0
                        sel = n - 1
                    else
                        sel--
                    draw_dropdown_item(active, x0, x1, old, sel)
                    draw_dropdown_item(active, x0, x1, sel, sel)
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
                    2 -> act_view()
                    3 -> void save_now()
                    4 -> act_save_as()
                    else -> act_exit()
                }
            }
            1 -> {                          ; Edit
                when choice {
                    0 -> do_undo()
                    1 -> do_redo()
                    2 -> op_cut()
                    3 -> op_copy()
                    4 -> op_paste()
                    5 -> op_delete_line()
                    6 -> op_dup_line()
                    7 -> op_move_line(false)
                    8 -> op_move_line(true)
                    else -> {                   ; toggle soft word-wrap
                        wrap_on = not wrap_on
                        left_col = 0            ; wrap ignores horizontal scroll
                        top_seg = 0             ; start the top line at its first segment
                    }
                }
            }
            2 -> {                          ; Search
                when choice {
                    0 -> act_find()
                    1 -> act_find_next()
                    2 -> act_replace()
                    else -> act_goto()
                }
            }
            3 -> {                          ; Dev
                when choice {
                    0 -> act_run_basload()
                    1 -> act_make_backup()
                    2 -> comment_apply(0)       ; toggle REM comment on the current line
                    3 -> comment_apply(1)       ; comment the selected block (add REM)
                    4 -> comment_apply(2)       ; uncomment the selected block (strip REM)
                    5 -> hl_on = not hl_on      ; toggle syntax colouring (menu_mode_loop repaints)
                    else -> ln_on = not ln_on   ; toggle the line-number gutter (repaints on close)
                }
            }
            else -> {                       ; Help (choice is a displayed row; map past a hidden BASLOAD)
                when help_logical(choice) {
                    0 -> act_keymap()
                    1 -> act_basload_help()
                    2 -> act_config()
                    else -> act_about()
                }
            }
        }
    }

    sub erase_dropdown(ubyte active) {
        ; erase the last-drawn dropdown by repainting ONLY the menu bar (row 0) and the text
        ; rows the box covered (screen rows TEXT_TOP..md_boxbot) - far cheaper than full_redraw's
        ; clear + 28-row repaint. `active` = the title to highlight (255 = none, i.e. menu closed).
        draw_menubar(active)
        ubyte last = md_boxbot
        if last > STATUS_ROW - 1                ; never touch the status bar
            last = STATUS_ROW - 1
        ubyte sy = TEXT_TOP
        while sy <= last {
            draw_text_row(sy - TEXT_TOP)
            sy++
        }
    }

    sub menu_mode_loop(ubyte active) {
        bool first = true
        repeat {
            if first {
                draw_menubar(active)    ; first open: draw over the current screen - no clear
                first = false
            } else {
                erase_dropdown(active)  ; switching menus: wipe the old dropdown, highlight the new
            }
            ubyte choice = run_dropdown(active)
            when choice {
                255 -> {
                    erase_dropdown(255) ; close: wipe the dropdown + un-highlight the menu bar
                    return
                }
                254 -> {                            ; prev menu (skips a hidden Dev)
                    repeat {
                        if active == 0
                            active = NMENU - 1
                        else
                            active--
                        if theme.show_dev or active != 3
                            break
                    }
                }
                253 -> {                            ; next menu (skips a hidden Dev)
                    repeat {
                        active++
                        if active >= NMENU
                            active = 0
                        if theme.show_dev or active != 3
                            break
                    }
                }
                else -> {
                    erase_dropdown(255)         ; wipe the dropdown before running the action
                    g_redrawn = false
                    menu_dispatch(active, choice)
                    if not g_redrawn            ; skip if the action already did its own full_redraw
                        full_redraw()           ; else restore (the action may have drawn a dialog/prompt)
                    return
                }
            }
        }
    }

    ; ---------- File / Help actions ----------

    sub new_document() {
        edoc.init()
        undo_clear()                        ; the arena was reset - old snapshots are gone
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

    ; ---------- picker record bank helpers (called from picker.ovl via jmp-(ptr) trampolines) ----------
    ; These run from LOW RAM, so flipping the HIRAM bank to RECORDS_BANK does not swap out the caller
    ; (the picker overlay, which is in a different bank). The overlay passes window addresses ($A000+off)
    ; and stages record bytes through recstage. push/pop restores whatever bank was mapped on entry
    ; (the picker overlay's bank), so control returns to it correctly.
    sub rec_peek(uword winaddr @R0) -> ubyte {
        uword wa = winaddr
        cx16.push_rambank(RECORDS_BANK)
        ubyte v = @(wa)
        cx16.pop_rambank()
        return v
    }
    sub rec_read(uword winaddr @R0, ubyte nb @R1) {
        uword wa = winaddr
        ubyte n = nb
        cx16.push_rambank(RECORDS_BANK)
        ubyte i
        for i in 0 to n - 1
            recstage[i] = @(wa + i)
        cx16.pop_rambank()
    }
    sub rec_write(uword winaddr @R0, ubyte nb @R1) {
        uword wa = winaddr
        ubyte n = nb
        cx16.push_rambank(RECORDS_BANK)
        ubyte i
        for i in 0 to n - 1
            @(wa + i) = recstage[i]
        cx16.pop_rambank()
    }
    sub rec_move(uword dstwin @R0, uword srcwin @R1, ubyte nb @R2) {
        uword dw = dstwin
        uword sw = srcwin
        ubyte n = nb                        ; sort's slots never overlap -> ascending copy is safe
        cx16.push_rambank(RECORDS_BANK)
        ubyte i
        for i in 0 to n - 1
            @(dw + i) = @(sw + i)
        cx16.pop_rambank()
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
        if not picker_ok {
            flash_status("picker.ovl not found in the program folder")
            return
        }
        cursor_sprite_off()             ; the overlay owns the screen: hide our cursor sprite
        if pick(&fnbuf, theme.current, &pick_blocks) == 0 {
            full_redraw()
            return
        }
        full_redraw()                   ; hide the Open popup before the load blink
        notify_blink("Loading...", blink_phases(pick_blocks as uword))  ; flash scaled to file size
        undo_clear()                        ; fresh document -> old snapshots are invalid
        if edoc.load_file(fnbuf) {
            void strings.copy(fnbuf, filename)
            apply_syntax_mode(fnbuf)        ; colour + gutter by extension (BASIC / .md / plain)
            cur_row = 0
            cur_col = 0
            top_line = 0
            left_col = 0
            cur_len = edoc.load(0, &editbuf)
            cur_dirty = false
            modified = false
        } else if edoc.line_count > 0 {
            ; the file opened but ran past the MAX_LINES limit (load_file truncates and
            ; sets oom). Show the lines that fit, but DON'T adopt the filename - that way
            ; a later Save prompts for a new name instead of overwriting the big original.
            filename[0] = 0
            apply_syntax_mode(fnbuf)        ; still colour by the picked name's extension
            cur_row = 0
            cur_col = 0
            top_line = 0
            left_col = 0
            cur_len = edoc.load(0, &editbuf)
            cur_dirty = false
            modified = false
            notify("File too big: first 10000 lines shown")
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
        ; flash scaled to document size (~6 lines per 256-byte block) before the disk write
        notify_blink("Saving...", blink_phases(edoc.line_count / 6))
        if not edoc.save_file(savebuf) {
            notify("Save error")
            return false
        }
        modified = false
        ; NOTE: we deliberately do NOT reload/compact here. The old code reset the arena after
        ; saving to reclaim leaked line slots, but that invalidated every undo snapshot. Keeping
        ; the arena intact lets undo/redo survive a Save (standard editor behaviour). The document
        ; is already correct in memory, so nothing needs reloading; leaked slots are still
        ; reclaimed the next time the document is replaced (New / Open both reset the arena).
        notify("Saved")                     ; static confirmation (the blink ran on "Saving...")
        return true
    }

    sub save_now() -> bool {
        if filename[0] == 0 {
            fnbuf[0] = 0
            ; prompt_str returns false on Esc/Stop AND on Enter with a blank line (allow_empty=false);
            ; either way the save is cancelled. Announce it so the empty status bar doesn't read as a
            ; silent no-op. The fnbuf[0]==0 re-check is belt-and-braces against an empty name slipping
            ; through to do_save (which would fail the write).
            if not prompt_str("Save as:", &fnbuf, 38, false, false) or fnbuf[0] == 0 {
                flash_notify("Save cancelled")
                return false
            }
            if not confirm_overwrite(fnbuf)     ; new name -> guard against clobbering a file
                return false
            void strings.copy(fnbuf, filename)
        }
        return do_save(filename)
    }

    sub act_save_as() {
        fnbuf[0] = 0
        if not prompt_str("Save as:", &fnbuf, 38, false, false) or fnbuf[0] == 0 {
            notify("Save cancelled")            ; Esc or Enter-on-blank-line -> cancel, with feedback
            return
        }
        if not confirm_overwrite(fnbuf)         ; guard against clobbering an existing file
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
        g_redrawn = true                ; we're quitting - skip the menu's post-action screen repaint
    }

    sub act_make_backup() {
        ; write the current document to a sibling "<name>.bak" (extension replaced, or appended if
        ; the name has none). Backs up what is loaded in the editor - including unsaved edits - and
        ; deliberately leaves the document's own modified/saved state untouched: the .bak is a side
        ; copy, not a Save. An existing .bak triggers a Y/N overwrite prompt.
        if filename[0] == 0 {
            flash_status("Open or save a file first")
            bar_fill(STATUS_ROW, theme.CB_BAR)
            put_str_at(1, STATUS_ROW, "Open or save a file first")
            void wait_key()
            return
        }
        ; bakname = filename with everything from the last '.' replaced by ".bak"
        void strings.copy(filename, bakname)
        ubyte cut = 255
        ubyte i = 0
        while bakname[i] != 0 {
            if bakname[i] == '.'
                cut = i
            i++
        }
        if cut == 255
            cut = i                             ; no extension -> append ".bak" at the end
        void strings.copy(".bak", &bakname + cut)

        if not confirm_overwrite(bakname)       ; existing .bak -> require Y before clobbering it
            return

        commit_editbuf()
        savebuf[0] = '@'                        ; "@:" = overwrite if it already exists
        savebuf[1] = ':'
        void strings.copy(bakname, &savebuf + 2)
        notify_blink("Backing up...", blink_phases(edoc.line_count / 6))
        if not edoc.save_file(savebuf) {
            notify("Backup failed")
            return
        }
        notify("Backup saved")                  ; modified state left as-is on purpose
    }

    sub act_run_basload() {
        ; save the document, then hand off to the ROM BASLOAD tool (arming SHIFT+RUN to reload EDIT).
        if filename[0] == 0 or modified {
            if not save_now()                   ; BASLOAD reads the source from disk
                return
        }
        write_run_state()                       ; remember doc + cursor line for the return trip
        arm_return_key()                        ; F8 -> reload EDIT via the DOS wedge
        run_basload = true
        g_running = false                       ; leave the main loop; start()'s tail hands off
        g_redrawn = true                        ; skip the menu's redraw - chain_to_basload clears anyway
    }

    sub act_config() {
        ; Help>Config: hand off to the separate settings program (MSEDIT/EDCFG.PRG). Same trip as
        ; Run BASLOAD: the document is saved and its name + cursor line go into ed.run, EDCFG writes
        ; the settings and then chain-loads EDIT again, which restores the document from ed.run with
        ; the new settings applied. Settings live OUTSIDE edit.prg so they can grow without eating
        ; EDIT's scarce low RAM.
        ; The trip through EDCFG reloads EDIT, so the document survives only via disk + ed.run. Ask
        ; rather than silently saving: Y saves and comes back to it, N goes to the settings and drops
        ; the unsaved edits, Esc stays in the editor. A fresh untitled document with no edits has
        ; nothing to preserve, so it just goes straight through.
        bool keep = filename[0] != 0            ; a named file is worth restoring even if unmodified
        if modified {
            ubyte r = confirm_save()
            if r == 2
                return                          ; cancelled -> stay in the editor
            if r == 1 {
                if not save_now()
                    return                      ; the save itself was cancelled (Save As, overwrite...)
                keep = true
            } else {
                keep = false                    ; discarding the edits: don't reopen a stale document
            }
        }
        if keep
            write_run_state()                   ; document + cursor line for the return trip
        run_config = true
        g_running = false                       ; leave the main loop; start()'s tail chains out
        g_redrawn = true
    }

    sub chain_load(str prog) {
        ; LOAD + RUN a .prg from BASIC's REPL: print the LOAD line on screen, then feed CR + RUN + CR
        ; through the keyboard queue so BASIC re-reads the printed line. Same dance as chain_to_basload
        ; (and the same one the /ED launcher performs), just for an arbitrary program.
        txt.chrout($93)                         ; clear screen, cursor home
        txt.nl()
        txt.print("load")
        txt.chrout($22)                         ; "
        txt.print(prog)
        txt.chrout($22)
        txt.chrout($91)                         ; cursor up x2 -> back onto the LOAD line
        txt.chrout($91)
        cx16.kbdbuf_clear()
        cx16.kbdbuf_put($0d)                    ; CR: submit the on-screen LOAD line
        cx16.kbdbuf_put('r')
        cx16.kbdbuf_put('u')
        cx16.kbdbuf_put('n')
        cx16.kbdbuf_put($0d)                    ; RUN + CR
    }

    sub arm_return_key() {
        ; reprogram F8 (KERNAL pfkey key 8) to the DOS-wedge command that reloads EDIT.
        ; macro `retkey` = up-arrow "/ED" + CR; persists in the KERNAL editor across the run.
        ; (F8, not SHIFT+RUN: RUN/STOP is an awkward key to press -- the emulator maps it to
        ;  host Pause, which most keyboards block. pfkey only programs F1-F8 and SHIFT+RUN.)
        cx16.r0 = &retkey
        %asm {{
            ldx  #8                 ; key number 8 = F8
            ldy  #5                 ; macro length (bytes)
            lda  #7                 ; EXTAPI_pfkey
            jsr  cx16.extapi
        }}
    }

    sub snapshot_fkeys() {
        ; capture all 9 KERNAL fkey macros (fkeytb = 99 bytes at $A80E, RAM bank 0 / KVARS) so a
        ; normal exit can put them back exactly as the user had them. pfkey only writes one slot, so
        ; we read the table directly. See SRC/fktest.p8 and docs/x16/kernal-r49/cbm/editor.s.
        cx16.r0 = &fksnap
        %asm {{
            php
            sei
            lda  $00                ; save the current RAM bank
            pha
            stz  $00                ; select RAM bank 0 (KVARS)
            ldy  #0
_snl:       lda  $a80e,y            ; fkeytb -> fksnap
            sta  (cx16.r0),y
            iny
            cpy  #99
            bne  _snl
            pla
            sta  $00                ; restore the RAM bank
            plp
        }}
    }

    sub restore_fkeys() {
        ; write the snapshot back into fkeytb -- un-hijacks F8 and restores any custom macros the
        ; user had, verbatim (not just F8's default). The pfkey hijack otherwise persists to power-cycle.
        cx16.r0 = &fksnap
        %asm {{
            php
            sei
            lda  $00
            pha
            stz  $00                ; RAM bank 0 (KVARS)
            ldy  #0
_rsl:       lda  (cx16.r0),y        ; fksnap -> fkeytb
            sta  $a80e,y
            iny
            cpy  #99
            bne  _rsl
            pla
            sta  $00
            plp
        }}
    }

    sub chain_to_basload(str name) {
        ; print `BASLOAD"name"` on screen, then feed CR + RUN + CR through the 10-byte keyboard
        ; queue so BASIC re-reads the line and runs the tokenized program (see XFMGR chain_run).
        txt.chrout($93)                         ; clear screen, cursor home
        txt.plot(7, 0)                         ; reminder starts at COL 10 of the top row: when EDIT exits,
        txt.print("*press f8 to return to edit*") ; BASIC prints "READY." at row 0 col 0 (6 chars) and would
                                                ; clobber the front of the reminder - the col-10 offset keeps
                                                ; it clear of that, with a small gap. The inject dance below
                                                ; is the ORIGINAL, unchanged: it homes, drops to row 1 and
                                                ; puts the BASLOAD command there. Row 1 is a separate logical
                                                ; line (the reminder doesn't wrap), so the RETURN inject reads
                                                ; ONLY the command, never the reminder. nl()/cursor-up are
                                                ; used (NOT plot) - a raw plot leaves the screen editor in a
                                                ; state where the injected RETURN fails to read the line.
        txt.plot(0, 0)                          ; home for the unchanged dance (cursor rides over the reminder)
        txt.nl()                                ; -> row 1
        txt.print("basload")                    ; command on row 1, exactly as before - inject re-reads this
        txt.chrout($22)                         ; "
        txt.print(name)
        txt.chrout($22)
        txt.chrout($91)                         ; cursor up x2 -> back onto the BASLOAD line
        txt.chrout($91)
        cx16.kbdbuf_clear()
        cx16.kbdbuf_put($0d)                    ; CR: submit the on-screen BASLOAD line
        cx16.kbdbuf_put('r')
        cx16.kbdbuf_put('u')
        cx16.kbdbuf_put('n')
        cx16.kbdbuf_put($0d)                    ; RUN + CR
    }

    sub write_run_state() {
        ; file = document name + CR + cursor row (lo/hi) + the 99-byte fkey snapshot. The snapshot
        ; rides along so the *original* (pre-hijack) fkeys survive the BASLOAD reload; restore_run_state
        ; reads it back into fksnap on the next launch. Read back by restore_run_state.
        if not diskio.f_open_w(runstate)
            return
        void diskio.f_write(filename, strings.length(filename))
        tmpbuf[0] = 13                          ; CR separator
        tmpbuf[1] = lsb(cur_row)
        tmpbuf[2] = msb(cur_row)
        void diskio.f_write(&tmpbuf, 3)
        void diskio.f_write(&fksnap, 99)        ; carry the fkey snapshot across the reload
        diskio.f_close_w()
    }

    sub restore_run_state() -> bool {
        ; if the restart-state file exists (from a BASLOAD hand-off), reopen that document at the
        ; saved cursor line and consume the file. Returns true if it reopened a document.
        if not diskio.f_open(runstate)
            return false
        uword n = diskio.f_read(&tmpbuf, 255)
        diskio.f_close()
        diskio.delete(runstate)                 ; one-shot
        if n < 3
            return false
        ubyte i = 0
        while i < n and tmpbuf[i] != 13         ; filename runs up to the CR separator
            i++
        if i == 0 or i + 2 >= n                 ; no name, or the 2 line bytes are missing
            return false
        ubyte j = 0
        while j < i {                           ; copy the name into fnbuf, NUL-terminated
            fnbuf[j] = tmpbuf[j]
            j++
        }
        fnbuf[i] = 0
        uword line = mkword(tmpbuf[i+2], tmpbuf[i+1])   ; hi, lo
        ubyte fk = i + 3                        ; the fkey snapshot follows the lo/hi line bytes
        if fk + 99 <= n {                       ; new-format state file carries all 9 fkey macros
            ubyte f = 0
            while f < 99 {
                fksnap[f] = tmpbuf[fk + f]
                f++
            }
        } else {
            snapshot_fkeys()                    ; old/short file: fall back to the live table
        }
        if not edoc.load_file(fnbuf)
            return false
        void strings.copy(fnbuf, filename)
        apply_syntax_mode(fnbuf)                ; colour + gutter by extension (BASIC / .md / plain)
        if basload_err_line != 0                ; a BASLOAD error scraped off the boot screen wins over the
            line = basload_err_line - 1         ; saved cursor: jump to it. BASLOAD line#s are 1-based.
        if line >= edoc.line_count
            line = edoc.line_count - 1
        cur_row = line
        cur_col = 0
        left_col = 0
        top_line = 0
        if cur_row >= TEXT_ROWS                 ; scroll so the cursor line is on screen
            top_line = cur_row - TEXT_ROWS + 1
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        modified = false
        return true
    }

    ; ---- BASLOAD error read-back: scrape the failing source line off the boot screen ----
    ; After File>Run BASLOAD (F5) hands off and BASLOAD prints e.g.
    ;   ERROR: LABEL NOT FOUND IN DIR.BASL:19
    ; the F8 reload comes straight back into start() with that text still on the (not-yet-
    ; cleared) screen. We read the screen one row at a time, only the first 5 columns, for
    ; "ERROR"; on a hit we pull the line number off the END of that row and let
    ; restore_run_state park the cursor on it. (Proven standalone in SRC/errscan.p8.)
    ;
    ; The match is done in SCREEN-CODE space, NOT against a "ERROR" string literal: getchr()
    ; returns raw VERA screen codes, and prog8 encodes a string literal in PETSCII (uppercase
    ; A-Z -> $C1..$DA), so "ERROR"[0] would be $C5=197 while the screen cell holds screen code
    ; 5 - they never compare equal. Screen codes for a letter are its 1-based position (E=5,
    ; R=18, O=15) and are identical in the upper/gfx and lowercase PETSCII charsets, so ERRSC
    ; matches "ERROR" or "error" either way. (This was the actual bug: see the emu dump.)
    ubyte[5] ERRSC = [5, 18, 18, 15, 18]        ; screen codes for E R R O R (== e r r o r)

    sub scan_basload_error(ubyte width, ubyte height) {
        ; sets basload_err_line to the number BASLOAD reported (0 if none), and captures the full
        ; error line into berr[] for display. Must run before start() switches mode (which clears).
        basload_err_line = 0
        berr_len = 0
        ubyte row
        for row in 0 to height - 1 {
            if row_is_error(row) {
                basload_err_line = trailing_number(row, width)
                capture_err_row(row, width)
                return                          ; stop at the first ERROR line (BASLOAD prints one)
            }
        }
    }

    sub capture_err_row(ubyte row, ubyte width) {
        ; copy the whole ERROR line (trailing spaces trimmed) into berr[] as screen codes, for later
        ; display on the status bar. The boot screen is the upper/gfx charset, where letters are
        ; codes 1..26; the editor runs the lowercase charset (txt.lowercase), where 1..26 are
        ; lowercase - so shift letters into the 65..90 uppercase slots to keep the UPPERCASE look.
        ubyte last = 0
        ubyte c
        for c in 0 to width - 1 {
            if txt.getchr(c, row) != SPACE_SC
                last = c                        ; remember the last non-blank column
        }
        ubyte n = last + 1
        if n > len(berr)
            n = len(berr)
        c = 0
        while c < n {
            ubyte s = txt.getchr(c, row)
            if s >= 1 and s <= 26
                s += 64                         ; letter -> lowercase-charset uppercase slot
            berr[c] = s
            c++
        }
        berr_len = n
    }

    sub row_is_error(ubyte row) -> bool {
        ; true if the first 5 columns of `row` are the screen codes for ERROR (case insensitive)
        ubyte c
        for c in 0 to 4 {
            if txt.getchr(c, row) != ERRSC[c]
                return false
        }
        return true
    }

    sub trailing_number(ubyte row, ubyte width) -> uword {
        ; the number trails the LAST ':' on the row (BASLOAD prints "...<file>:<line>", and an
        ; earlier ':' follows "ERROR"). Digits '0'..'9' and ':' sit at their ASCII codes in the
        ; screen-code table too, so getchr() values compare directly.
        ubyte last_colon = 255
        ubyte c
        for c in 0 to width - 1 {
            if txt.getchr(c, row) == ':'
                last_colon = c
        }
        if last_colon == 255
            return 0                            ; no colon -> no line number
        uword num = 0
        bool any = false
        c = last_colon + 1
        while c < width {
            ubyte d = txt.getchr(c, row)
            if d < '0' or d > '9'
                break
            num = num * 10 + (d - '0')
            any = true
            c++
        }
        if not any
            return 0
        return num
    }

    sub show_basload_error() {
        ; one red attention flash + the FULL BASLOAD error line on the status bar (the cursor is
        ; already parked on the line it named). Flashed, not silent - a quiet status line gets missed.
        show_err_bar($21)                       ; red bg, white fg
        sys.wait(30)                            ; ~0.5s
        show_err_bar(theme.CB_BAR)                     ; settle to the normal bar; the message stays readable
    }

    sub show_err_bar(ubyte color) {
        bar_fill(STATUS_ROW, color)
        ; blit the captured BASLOAD error line (screen codes) starting at col 1, clipped to the bar
        ubyte n = berr_len
        if n > SCR_W - 1
            n = SCR_W - 1
        ubyte c = 0
        while c < n {
            txt.setchr(1 + c, STATUS_ROW, berr[c])
            c++
        }
    }

    ; The About screen lives in misc.ovl (MISC_BANK) - see the extsub block near the top. What is
    ; left here is the hand-off: pass the overlay the theme (so it paints in the current colours),
    ; the build number and the emulator flag, which it has no way to read out of main. The overlay
    ; blocks on a key; we repaint the editor after.

    sub act_about() {
        if not misc_ok {
            flash_status("misc.ovl not found in the program folder")
            return
        }
        cursor_sprite_off()                     ; the overlay owns the screen: hide our cursor sprite
        ovl_about(theme.current, BUILD_NUM, g_emu as ubyte)
        full_redraw()
    }

    sub act_keymap() {
        ; the Keyboard Map is a shipped text file (edit.md) shown in the viewer, so the key list is
        ; editable data instead of hand-drawn code.
        view_help(keysfile)
    }

    sub act_basload_help() {
        ; the BASLOAD guide (basload.md), shown in the same viewer as the Keyboard Map
        view_help(basloadhlp)
    }

    sub view_help(str fname) {
        ; open a shipped help text file (in the install folder) read-only in the viewer
        if not tview_ok {
            flash_status("help viewer needs tview.ovl + the .md file")
            return
        }
        cursor_sprite_off()                     ; the overlay owns the screen: hide our cursor sprite
        ovl_view(theme.path_to(fname), theme.current)
        full_redraw()
    }

    sub act_view() {
        ; File > View: pick a file and show it read-only in the viewer, without loading it into the
        ; document (so it side-steps the document size limit for a quick look at a big file).
        if not tview_ok {
            flash_status("tview.ovl not found in the program folder")
            return
        }
        if not picker_ok {
            flash_status("picker.ovl not found in the program folder")
            return
        }
        fnbuf[0] = 0
        cursor_sprite_off()                     ; both overlays own the screen: hide our cursor sprite
        if pick(&fnbuf, theme.current, &pick_blocks) == 0 {
            full_redraw()
            return
        }
        ovl_view(&fnbuf, theme.current)
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

    sub is_word_char(ubyte b) -> bool {
        ; a "word" byte for whole-word search: a digit or a letter (either PETSCII case).
        ; 0 (used as the "past the line edge" sentinel) folds to nothing -> not a word char.
        if b >= '0' and b <= '9'
            return true
        ubyte f = fold(b)                   ; $C1-$DA -> $41-$5A, letters land in 'a'..'z'
        return f >= 'a' and f <= 'z'
    }

    sub ends_with_ci(uword name, uword suffix) -> bool {
        ; case-insensitive (PETSCII fold) test: does `name` end with `suffix`?
        ubyte nl = lsb(strings.length(name))
        ubyte sl = lsb(strings.length(suffix))
        if sl > nl
            return false
        uword np = name + nl - sl
        ubyte i = 0
        while i < sl {
            if fold(@(np + i)) != fold(@(suffix + i))
                return false
            i++
        }
        return true
    }

    sub has_basic_ext(uword name) -> bool {
        ; the BASIC source extensions that should auto-enable syntax colouring on load
        return ends_with_ci(name, ".bas") or ends_with_ci(name, ".basl") or ends_with_ci(name, ".bl") or ends_with_ci(name, ".bas.txt")
    }

    sub run_syntax(uword buf, ubyte blen) {
        ; classify one line into hlcol[] with the classifier hl_mode selected on open.
        if hl_mode == HL_MD
            syntax.classify_md(buf, blen, &hlcol)
        else
            syntax.classify(buf, blen, &hlcol)
    }

    sub apply_syntax_mode(uword name) {
        ; pick the syntax mode from the file's extension: BASIC source, Markdown, or none. Also
        ; drives the line-number gutter - on for BASIC (lines are referenced), off for Markdown prose.
        if has_basic_ext(name) {
            hl_on = true
            hl_mode = HL_BASIC
            ln_on = true
        } else if ends_with_ci(name, ".md") {
            hl_on = true
            hl_mode = HL_MD
            ln_on = false
        } else {
            hl_on = false
            hl_mode = HL_BASIC
            ln_on = false
        }
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
            if line_match(buf, i, tlen) {
                if not ww_on
                    return i
                ; whole-word: the match must be bounded by non-word bytes on both sides
                ; (0 = past the line edge, treated as a boundary by is_word_char)
                ubyte lc = 0
                if i != 0
                    lc = @(buf + i - 1)
                ubyte rc = 0
                if i + tlen != blen
                    rc = @(buf + i + tlen)
                if not is_word_char(lc) and not is_word_char(rc)
                    return i
            }
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

    sub find_wrap(uword row, ubyte col) -> ubyte {
        ; forward search from (row,col); if nothing there, wrap and search from the top.
        ; returns 0 = not found, 1 = found ahead, 2 = found after wrapping to the top.
        if find_from(row, col)
            return 1
        if find_from(0, 0)
            return 2
        return 0
    }

    sub goto_found() {
        ; jump to the match AND highlight it as a selection. Anchor at the match END, cursor at the
        ; match START: the highlight spans [found_col, found_col+tlen) either way (sel_norm orders
        ; them), and leaving the cursor at the start keeps act_find_next's "find_wrap(.., cur_col+1)"
        ; continuation finding the next occurrence correctly, incl. adjacent ones.
        ubyte tlen = lsb(strings.length(find_term))
        anc_row = found_row
        anc_col = found_col + tlen
        cur_row = found_row
        cur_col = found_col
        sel_active = true
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        void ensure_visible()
        draw_all_text()
        place_cursor()
        draw_status()
    }

    sub sel_to_find() {
        ; If a SINGLE-LINE selection is active, copy the highlighted text into find_term so the
        ; Find / Replace prompt opens pre-filled with it (select code, hit Find, search for it).
        ; Multi-line selections are left alone - a search term is one line - so find_term keeps its
        ; previous value. The selection is consumed (cleared) so the located match highlights cleanly
        ; instead of leaving a stale highlight spanning the old anchor to the new cursor.
        if not sel_active
            return
        sel_norm()
        if s_row != e_row or e_col <= s_col     ; multi-line or empty: keep the last search term
            return
        commit_editbuf()
        ubyte llen = edoc.load(s_row, &tmpbuf)
        ubyte i = s_col
        ubyte o = 0
        while i < e_col and i < llen and o < 38 {
            find_term[o] = tmpbuf[i]
            o++
            i++
        }
        find_term[o] = 0
        sel_active = false
        draw_all_text()
    }

    sub act_find() {
        sel_to_find()
        if not prompt_str("Find:", &find_term, 38, false, true)
            return
        commit_editbuf()
        ubyte res = find_wrap(cur_row, cur_col)
        if res == 0 {
            notify("Not found")
            return
        }
        goto_found()
        if res == 2
            notify("Wrapped to top")
    }

    sub act_find_next() {
        if find_term[0] == 0 {
            sel_to_find()                   ; no term yet: adopt a single-line highlight as the term,
                                            ; so "select a word, F3" searches for it (no warning path)
            if find_term[0] == 0 {          ; nothing selected either -> warn, and BLOCK to eat the
                notify("No search term - use Find first")   ; key the user presses to react, so it
                void wait_key()             ; can't fall through and edit the document
                return
            }
        }
        commit_editbuf()
        ubyte res = find_wrap(cur_row, cur_col + 1)
        if res == 0 {
            notify("Not found")
            return
        }
        goto_found()
        if res == 2
            notify("Wrapped to top")
    }

    sub prompt_replace() -> ubyte {
        ; ask about the highlighted match; returns 'y', 'n', 'a' (all) or 27 (stop).
        bar_fill(STATUS_ROW, theme.CB_BAR)
        put_str_at(1, STATUS_ROW, "Replace?  Yes  No  All  Esc")
        ubyte hi = (theme.CB_BAR & $f0) | theme.ACCEL_FG    ; top-menu-style highlight for the trigger keys
        txt.setclr(11, STATUS_ROW, hi)          ; Y(es)
        txt.setclr(16, STATUS_ROW, hi)          ; N(o)
        txt.setclr(20, STATUS_ROW, hi)          ; A(ll)
        txt.setclr(25, STATUS_ROW, hi)          ; E \
        txt.setclr(26, STATUS_ROW, hi)          ; s  Esc
        txt.setclr(27, STATUS_ROW, hi)          ; c /
        draw_ww_label(false)                    ; read-only "Whole Word" reminder when it's on
        repeat {
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            when k {
                'y', ' ', 13 -> return 'y'
                'n' -> return 'n'
                'a' -> return 'a'
                27, 3 -> return 27
            }
        }
    }

    sub act_replace() {
        ; interactive find-and-replace: walk the whole document top-to-bottom, one match at a
        ; time. For each match, highlight it and ask Y/N/All/Esc (A = replace the rest without
        ; asking). The whole run is ONE undo group (a snapshot per touched line); if it changes
        ; more lines than the ring holds it drops history (can't undo fully).
        sel_to_find()
        if not prompt_str("Find:", &find_term, 38, false, true)
            return
        if not prompt_str("Replace with:", &repl_term, 38, true, true)    ; empty = delete
            return
        commit_editbuf()
        ubyte tlen = lsb(strings.length(find_term))
        ubyte rlen = lsb(strings.length(repl_term))
        g_repl_count = 0
        uword records = 0                   ; undo records pushed (= lines touched)
        uword last_snap = $ffff             ; last line we snapshotted (none yet)
        bool grp = false                    ; undo group started lazily on the first real change
        bool all = false
        uword r = 0                         ; scan cursor (search from the very top)
        ubyte c = 0
        while find_from(r, c) {             ; sets found_row / found_col
            bool do_repl = true
            if not all {
                ; highlight the match via the selection, scroll it into view, then ask
                cur_row = found_row
                cur_col = found_col + tlen
                anc_row = found_row
                anc_col = found_col
                sel_active = true
                void ensure_visible()
                draw_all_text()
                ubyte k = prompt_replace()
                if k == 27
                    break
                if k == 'n'
                    do_repl = false
                if k == 'a'
                    all = true
            }
            ubyte llen = edoc.load(found_row, &tmpbuf)      ; (re)load - rendering clobbered tmpbuf
            if (llen as uword) - tlen + rlen > edoc.MAX_LEN  ; replacement won't fit -> skip
                do_repl = false
            if do_repl {
                if not grp {                                ; start the undo group on 1st change only
                    undo_begin()                            ; (so cancelling with no edits keeps redo)
                    grp = true
                }
                if found_row != last_snap {                 ; snapshot the line's ORIGINAL once
                    urec_replace(found_row, &tmpbuf, llen)
                    last_snap = found_row
                    records++
                }
                ; build prefix [0,found_col) + repl + suffix [found_col+tlen, llen) into workbuf
                ubyte o = 0
                ubyte j = 0
                while j < found_col {
                    workbuf[o] = tmpbuf[j]
                    o++
                    j++
                }
                j = 0
                while j < rlen {
                    workbuf[o] = repl_term[j]
                    o++
                    j++
                }
                j = found_col + tlen
                while j < llen {
                    workbuf[o] = tmpbuf[j]
                    o++
                    j++
                }
                void edoc.commit(found_row, &workbuf, o)
                g_repl_count++
                r = found_row
                c = found_col + rlen                        ; continue after the inserted text
            } else {
                r = found_row
                c = found_col + tlen                        ; skip this match
            }
        }
        if records > UNDO_DEPTH             ; group bigger than the ring -> can't undo it fully
            undo_clear()
        sel_active = false
        if cur_row >= edoc.line_count
            cur_row = edoc.line_count - 1
        cur_len = edoc.load(cur_row, &editbuf)
        clamp_col()
        cur_dirty = false
        if g_repl_count != 0
            modified = true
        full_redraw()
        bar_fill(STATUS_ROW, theme.CB_BAR)
        put_str_at(1, STATUS_ROW, "Replaced ")
        void put_uw_at(10, STATUS_ROW, g_repl_count)
        sys.wait(80)
    }

    sub act_goto() {
        ; prompt for a line number and jump there
        fnbuf[0] = 0
        if not prompt_str("Go to line:", &fnbuf, 5, false, false)
            return
        uword n = 0
        ubyte i = 0
        while fnbuf[i] >= '0' and fnbuf[i] <= '9' {
            if n >= 6553                    ; guard: a further digit would overflow a uword
                break
            n = n * 10 + (fnbuf[i] - '0')
            i++
        }
        if n == 0
            n = 1
        if n > edoc.line_count
            n = edoc.line_count
        sel_active = false
        goto_row(n - 1)                     ; commits the current line, loads the target
        cur_col = 0
        redraw_after_move()
    }

    sub toggle_overwrite() {
        ovr_mode = not ovr_mode
        ; the cursor shape differs per mode (insert = underline sprite, overtype = reverse block),
        ; so repaint the cursor cell and move the sprite immediately
        if cur_row >= top_line and cur_row < top_line + TEXT_ROWS {
            if wrap_on
                draw_all_text()
            else
                draw_text_row(lsb(cur_row - top_line))
        }
        cursor_update()
        draw_status()
    }

    ; ---------- selection delete / clipboard (Edit menu + Ctrl shortcuts) ----------

    sub delete_selection() {
        ; remove the selected text; cursor ends at the selection start
        commit_editbuf()
        sel_norm()
        ; undo (one group): REPLACE the start line, then DELLINE each line below it that gets
        ; merged away (pushed high row first so undo re-inserts them in ascending order).
        undo_begin()
        ubyte snap0 = edoc.load(s_row, &tmpbuf)
        urec_replace(s_row, &tmpbuf, snap0)
        if s_row != e_row {
            uword rr = e_row
            while rr > s_row {
                ubyte dl = edoc.load(rr, &tmpbuf)
                urec_delline(rr, &tmpbuf, dl)
                rr--
            }
        }
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

    sub block_shift(bool indent) {
        ; Tab / Shift+Tab: indent or outdent every line the selection touches by one tab width, as ONE
        ; undo group (a single Ctrl+Z reverts the whole block). With no selection it acts on the current
        ; line. The affected range is re-selected as whole lines afterwards, so holding/repeating
        ; Tab / Shift+Tab keeps stepping the same block. Blank lines are skipped on indent (no trailing
        ; whitespace); outdent removes up to tab_width leading spaces from each line.
        commit_editbuf()
        bool had_sel = sel_active
        uword r0
        uword r1
        if had_sel {
            sel_norm()
            r0 = s_row
            r1 = e_row
            if r1 > r0 and e_col == 0        ; selection ends at col 0 of the line below the block -
                r1--                          ; that last line holds no selected text, so leave it alone
        } else {
            r0 = cur_row
            r1 = cur_row
        }
        ubyte w = theme.tab_width
        ubyte llen                                      ; prog8 has no block scope - hoist all scratch
        ubyte nlen
        ubyte rm
        ubyte i
        ubyte o
        undo_begin()
        uword r = r0
        while r <= r1 {
            llen = edoc.load(r, &tmpbuf)
            if indent {
                if llen != 0 {                          ; don't indent blank lines
                    urec_replace(r, &tmpbuf, llen)      ; snapshot pre-edit content for undo
                    nlen = 0
                    while nlen < w and nlen < edoc.MAX_LEN {
                        workbuf[nlen] = ' '
                        nlen++
                    }
                    i = 0
                    while i < llen and nlen < edoc.MAX_LEN {
                        workbuf[nlen] = tmpbuf[i]
                        nlen++
                        i++
                    }
                    void edoc.commit(r, &workbuf, nlen)
                }
            } else {
                rm = 0                                  ; count up to w leading spaces to strip
                while rm < w and rm < llen and tmpbuf[rm] == ' '
                    rm++
                if rm != 0 {
                    urec_replace(r, &tmpbuf, llen)
                    o = 0
                    i = rm
                    while i < llen {
                        tmpbuf[o] = tmpbuf[i]
                        o++
                        i++
                    }
                    void edoc.commit(r, &tmpbuf, o)
                }
            }
            r++
        }
        cur_row = r1
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        if had_sel {
            anc_row = r0                                 ; re-select the block as whole lines
            anc_col = 0
            cur_col = cur_len
            sel_active = true
        } else {
            cur_col = 0
            sel_active = false
        }
        modified = true
        cx16.kbdbuf_clear()                             ; drain key-repeat so a held Tab can't over-indent
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    ; ---------- REM comment ops (Dev menu + Ctrl+L / Ctrl+E / Ctrl+W) ----------
    ; Comment marker is "REM   " (uppercase-PETSCII R,E,M + 3 spaces - so it displays/​saves as
    ; uppercase REM, matching how BASLOAD source loads). Detection + removal are case-insensitive
    ; (folded) and lenient. Insert point (column 0 vs after the leading indent) is the EDCFG
    ; "Comment at" setting, theme.cmt_indent.
    ubyte[4] cmt_prefix = [$d2, $c5, $cd, $20]               ; "REM " in uppercase PETSCII

    sub cfold(ubyte b) -> ubyte {
        ; fold shifted-PETSCII letters ($C1-$DA) down onto $41-$5A so REM matches in any case
        if b >= $c1 and b <= $da
            return b - $80
        return b
    }

    sub rem_start(uword buf, ubyte blen) -> ubyte {
        ; index where a REM comment starts (after leading spaces), or 255 if the line isn't a comment.
        ; REM must be a whole token (end-of-line or a space next) so "REMARK" isn't mistaken for one.
        ubyte i = 0
        while i < blen and @(buf + i) == ' '
            i++
        if i + 3 > blen
            return 255
        ; compare against the FOLDED (uppercase $41-$5A) codes for R,E,M directly - a char literal like
        ; 'R' encodes to shifted PETSCII ($D2), which cfold would never produce, so match on $52/$45/$4D.
        if cfold(@(buf + i)) == $52 and cfold(@(buf + i + 1)) == $45 and cfold(@(buf + i + 2)) == $4d {
            if i + 3 == blen or @(buf + i + 3) == ' '
                return i
        }
        return 255
    }

    sub build_commented(uword buf, ubyte blen) -> ubyte {
        ; workbuf = buf with "REM " inserted at column 0, or after the leading spaces if cmt_indent
        ubyte ins = 0
        if theme.cmt_indent != 0
            while ins < blen and @(buf + ins) == ' '
                ins++
        ubyte o = 0
        ubyte i = 0
        while i < ins and o < edoc.MAX_LEN {            ; copy the leading indent (indent mode)
            workbuf[o] = @(buf + i)
            o++
            i++
        }
        ubyte j = 0
        while j < 4 and o < edoc.MAX_LEN {              ; insert the REM prefix
            workbuf[o] = cmt_prefix[j]
            o++
            j++
        }
        while i < blen and o < edoc.MAX_LEN {           ; copy the rest of the line
            workbuf[o] = @(buf + i)
            o++
            i++
        }
        return o
    }

    sub build_uncommented(uword buf, ubyte blen, ubyte rs) -> ubyte {
        ; workbuf = buf with the REM (3 chars at rs) + up to 3 following spaces removed
        ubyte cut = rs + 3
        ubyte sp = 0
        while sp < 3 and cut < blen and @(buf + cut) == ' ' {
            cut++
            sp++
        }
        ubyte o = 0
        ubyte i = 0
        while i < rs {                                  ; keep any indent before REM
            workbuf[o] = @(buf + i)
            o++
            i++
        }
        i = cut
        while i < blen {                                ; keep everything after the stripped REM
            workbuf[o] = @(buf + i)
            o++
            i++
        }
        return o
    }

    sub comment_apply(ubyte mode) {
        ; mode 0 = toggle the current line; 1 = comment the block; 2 = uncomment the block. One undo
        ; group. Selection blocks re-select as whole lines (like block_shift); no selection -> current line.
        commit_editbuf()
        bool had_sel = sel_active
        uword r0
        uword r1
        if mode == 0 {
            r0 = cur_row                                ; toggle acts on the current line only
            r1 = cur_row
        } else if had_sel {
            sel_norm()
            r0 = s_row
            r1 = e_row
            if r1 > r0 and e_col == 0
                r1--
        } else {
            r0 = cur_row
            r1 = cur_row
        }
        bool do_add = mode != 2                         ; comment adds REM; uncomment strips it
        if mode == 0 {
            ubyte cl = edoc.load(cur_row, &tmpbuf)
            do_add = rem_start(&tmpbuf, cl) == 255      ; toggle: add only if the line isn't a comment
        }
        ubyte llen
        ubyte newlen
        ubyte rs
        undo_begin()
        uword r = r0
        while r <= r1 {
            llen = edoc.load(r, &tmpbuf)
            if do_add {
                if rem_start(&tmpbuf, llen) == 255 {    ; don't double-comment an already-REM line
                    newlen = build_commented(&tmpbuf, llen)
                    urec_replace(r, &tmpbuf, llen)
                    void edoc.commit(r, &workbuf, newlen)
                }
            } else {
                rs = rem_start(&tmpbuf, llen)
                if rs != 255 {
                    newlen = build_uncommented(&tmpbuf, llen, rs)
                    urec_replace(r, &tmpbuf, llen)
                    void edoc.commit(r, &workbuf, newlen)
                }
            }
            r++
        }
        cur_row = r1
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        if had_sel and mode != 0 {
            anc_row = r0                                 ; re-select the block as whole lines
            anc_col = 0
            cur_col = cur_len
            sel_active = true
        } else {
            if cur_col > cur_len
                cur_col = cur_len
            sel_active = false
        }
        modified = true
        cx16.kbdbuf_clear()
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    sub copy_selection() {
        ; copy the selected text into the clipboard (with $0D between lines)
        commit_editbuf()
        sel_norm()
        cx16.push_rambank(CLIP_BANK)            ; clipbuf is banked; the edoc.load calls below nest
        uword o = 0                             ; and restore CLIP_BANK on return (tmpbuf is low RAM)
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
        cx16.pop_rambank()
        clip_len = o
        clip_has = true
        clip_line = false
    }

    sub copy_current_line() {
        ubyte i = 0
        cx16.push_rambank(CLIP_BANK)            ; clipbuf is banked; editbuf is low RAM
        while i < cur_len {
            @(clipbuf + i) = editbuf[i]
            i++
        }
        cx16.pop_rambank()
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
        undo_begin()
        if edoc.line_count <= 1 {
            urec_replace(0, &editbuf, cur_len)   ; undo: restore the cleared line's content
            cur_len = 0                          ; clear the only line, keep one empty line
            void edoc.commit(0, &editbuf, 0)
            cur_col = 0
        } else {
            urec_delline(cur_row, &editbuf, cur_len)   ; undo: re-insert the deleted line
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

    sub op_dup_line() {
        ; duplicate the current line, placing the copy below and moving the cursor onto it
        commit_editbuf()
        if not edoc.insert_line(cur_row + 1) {
            notify("Document full - save now")
            return
        }
        undo_begin()
        urec_addline(cur_row + 1)                    ; undo = delete the duplicated line
        void edoc.commit(cur_row + 1, &editbuf, cur_len)
        cur_row++
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        sel_active = false
        modified = true
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    sub op_move_line(bool down) {
        ; swap the current line with its neighbour above/below; the cursor follows the line
        if down {
            if cur_row + 1 >= edoc.line_count
                return
        } else if cur_row == 0 {
            return
        }
        commit_editbuf()
        uword other = cur_row - 1
        if down
            other = cur_row + 1
        ubyte olen = edoc.load(other, &tmpbuf)       ; neighbour's content
        undo_begin()
        urec_replace(cur_row, &editbuf, cur_len)     ; snapshot both lines -> one undo step
        urec_replace(other, &tmpbuf, olen)
        void edoc.commit(other, &editbuf, cur_len)   ; current line moves into the neighbour slot
        void edoc.commit(cur_row, &tmpbuf, olen)     ; neighbour fills the vacated slot
        cur_row = other
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        sel_active = false
        clamp_col()
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
            undo_begin()
            urec_addline(cur_row + 1)           ; undo: delete the pasted line
            ubyte bi = 0
            cx16.push_rambank(CLIP_BANK)        ; stage the banked clip line into low-RAM tmpbuf
            while bi < lsb(clip_len) {
                tmpbuf[bi] = @(clipbuf + bi)
                bi++
            }
            cx16.pop_rambank()
            void edoc.commit(cur_row + 1, &tmpbuf, lsb(clip_len))
            cur_row++
            cur_col = 0
            cur_len = edoc.load(cur_row, &editbuf)
            cur_dirty = false
        } else {
            ; selection clipboard: insert inline at the cursor, splitting on $0D. Undo = one
            ; group: REPLACE the start line + one ADDLINE per line the $0D splits insert (so a
            ; single-line inline paste is just the REPLACE - same as before, and a multi-line
            ; one is now fully undoable too).
            undo_begin()
            urec_replace(cur_row, &editbuf, cur_len)
            ubyte nsplits = 0
            bool ok = true
            uword pi = 0
            cx16.push_rambank(CLIP_BANK)        ; clip reads below; do_split's edoc calls nest and restore
            while pi < clip_len {
                ubyte ch = @(clipbuf + pi)
                pi++
                if ch == 13 {
                    if not do_split() {
                        ok = false
                        break
                    }
                    urec_addline(cur_row)       ; do_split inserted this line (now the cursor line)
                    nsplits++
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
            cx16.pop_rambank()
            cur_dirty = true
            if not ok or nsplits >= UNDO_DEPTH  ; OOM mid-paste, or more lines than the ring -> drop
                undo_clear()
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

    ; ---------- undo / redo engine ----------

    sub undo_clear() {
        u_sp = 0
        d_sp = 0
    }

    sub redo_clear() {
        d_sp = 0
    }

    sub u_drop_oldest() {               ; ring full: drop the oldest undo record (its snapshot leaks)
        ubyte i = 0
        while i + 1 < UNDO_DEPTH {
            u_op[i] = u_op[i+1]
            u_row[i] = u_row[i+1]
            u_grp[i] = u_grp[i+1]
            u_bnk[i] = u_bnk[i+1]
            u_off[i] = u_off[i+1]
            i++
        }
        u_sp = UNDO_DEPTH - 1
    }

    sub d_drop_oldest() {
        ubyte i = 0
        while i + 1 < UNDO_DEPTH {
            d_op[i] = d_op[i+1]
            d_row[i] = d_row[i+1]
            d_grp[i] = d_grp[i+1]
            d_bnk[i] = d_bnk[i+1]
            d_off[i] = d_off[i+1]
            i++
        }
        d_sp = UNDO_DEPTH - 1
    }

    sub push_rec(bool to_redo, ubyte op, uword row, ubyte bnk, uword off) {
        if to_redo {
            if d_sp >= UNDO_DEPTH
                d_drop_oldest()
            d_op[d_sp] = op
            d_row[d_sp] = row
            d_grp[d_sp] = g_group
            d_bnk[d_sp] = bnk
            d_off[d_sp] = off
            d_sp++
        } else {
            if u_sp >= UNDO_DEPTH
                u_drop_oldest()
            u_op[u_sp] = op
            u_row[u_sp] = row
            u_grp[u_sp] = g_group
            u_bnk[u_sp] = bnk
            u_off[u_sp] = off
            u_sp++
        }
    }

    sub undo_begin() {                  ; start a new user-action group; new edits invalidate redo
        g_group++
        redo_clear()
    }

    ; record helpers used by the mutation hooks (push onto the undo ring, group = g_group)
    sub urec_replace(uword row, uword src, ubyte slen) {
        if not edoc.store(src, slen) {          ; arena full -> can't track; drop history to stay safe
            undo_clear()
            return
        }
        push_rec(false, OP_REPLACE, row, edoc.r_bank, edoc.r_off)
    }
    sub urec_addline(uword row) {
        push_rec(false, OP_ADDLINE, row, 0, 0)
    }
    sub urec_delline(uword row, uword src, ubyte slen) {
        if not edoc.store(src, slen) {
            undo_clear()
            return
        }
        push_rec(false, OP_DELLINE, row, edoc.r_bank, edoc.r_off)
    }

    sub undo_touch_line() {
        ; called before mutating editbuf on the current line: records the pre-edit content once
        ; per editing session (the cur_dirty false->true transition collapses all its keystrokes).
        if not cur_dirty {
            undo_begin()
            urec_replace(cur_row, &editbuf, cur_len)
        }
    }

    sub apply_rec(ubyte op, uword row, ubyte bnk, uword off, bool to_redo) {
        ; restore this record's effect and push the inverse onto the opposite ring
        ubyte curlen                        ; function-scoped scratch (prog8 has no block scope)
        ubyte ib
        uword io
        ubyte slen
        when op {
            OP_REPLACE -> {
                if row < edoc.line_count {
                    curlen = edoc.load(row, &workbuf)           ; capture current for the inverse
                    void edoc.store(&workbuf, curlen)
                    ib = edoc.r_bank
                    io = edoc.r_off
                    slen = edoc.snap_load(bnk, off, &tmpbuf)
                    void edoc.commit(row, &tmpbuf, slen)
                    push_rec(to_redo, OP_REPLACE, row, ib, io)
                }
            }
            OP_ADDLINE -> {                                     ; undo an insertion => delete the line
                if row < edoc.line_count {
                    curlen = edoc.load(row, &workbuf)           ; capture content so it can be re-added
                    void edoc.store(&workbuf, curlen)
                    ib = edoc.r_bank
                    io = edoc.r_off
                    edoc.delete_line(row)
                    push_rec(to_redo, OP_DELLINE, row, ib, io)
                }
            }
            OP_DELLINE -> {                                     ; undo a deletion => re-insert the line
                if edoc.insert_line(row) {
                    slen = edoc.snap_load(bnk, off, &tmpbuf)
                    void edoc.commit(row, &tmpbuf, slen)
                    push_rec(to_redo, OP_ADDLINE, row, 0, 0)
                }
            }
        }
    }

    sub after_undo_redo(uword focus) {
        if edoc.line_count == 0
            void edoc.append(&editbuf, 0)       ; never leave a zero-line document
        if focus >= edoc.line_count
            focus = edoc.line_count - 1
        cur_row = focus
        cur_col = 0
        left_col = 0
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        sel_active = false
        modified = true
        void ensure_visible()
        draw_all_text()
        draw_status()
    }

    sub do_undo() {
        if u_sp == 0 {
            notify("Nothing to undo")
            return
        }
        commit_editbuf()                        ; flush the live line before touching storage
        g_group++                               ; inverses pushed to redo share this new group
        uword grp = u_grp[u_sp - 1]
        uword focus = u_row[u_sp - 1]
        while u_sp != 0 {
            if u_grp[u_sp - 1] != grp
                break
            u_sp--
            focus = u_row[u_sp]
            apply_rec(u_op[u_sp], u_row[u_sp], u_bnk[u_sp], u_off[u_sp], true)
        }
        after_undo_redo(focus)
    }

    sub do_redo() {
        if d_sp == 0 {
            notify("Nothing to redo")
            return
        }
        commit_editbuf()
        g_group++
        uword grp = d_grp[d_sp - 1]
        uword focus = d_row[d_sp - 1]
        while d_sp != 0 {
            if d_grp[d_sp - 1] != grp
                break
            d_sp--
            focus = d_row[d_sp]
            apply_rec(d_op[d_sp], d_row[d_sp], d_bnk[d_sp], d_off[d_sp], false)
        }
        after_undo_redo(focus)
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
        if wrap_on {
            ed_up_wrap()
            return
        }
        if cur_row > 0 {
            goto_row(cur_row - 1)
            clamp_col()
            redraw_after_move()
        }
    }

    sub ed_down() {
        if wrap_on {
            ed_down_wrap()
            return
        }
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
            undo_touch_line()
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
            ; undo: restore this line's old content + re-insert the next line (one group)
            undo_begin()
            urec_replace(cur_row, &editbuf, cur_len)
            urec_delline(cur_row + 1, &tmpbuf, nlen)
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
        ; advance to the next multiple of the user's tab width (EDCFG "Tab width", read from edit.cfg)
        ubyte spaces = theme.tab_width - (cur_col % theme.tab_width)
        repeat spaces
            ed_insert(' ')
    }

    ; ---------- editing ----------

    sub ed_insert(ubyte k) {
        undo_touch_line()
        if ovr_mode and cur_col < cur_len {
            editbuf[cur_col] = k                ; overwrite the char under the cursor
            cur_col++
            cur_dirty = true
            modified = true
            if ensure_visible()
                draw_all_text()
            else
                draw_doc_line()
            place_cursor()
            draw_status()
            return
        }
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
            undo_touch_line()
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
        ; undo: restore the previous line's old content + re-insert this line (one group)
        undo_begin()
        urec_replace(cur_row - 1, &tmpbuf, plen)
        urec_delline(cur_row, &editbuf, cur_len)
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
        ; split the current line at the cursor into two lines; auto-indent the new line to
        ; match the current line's leading whitespace
        ubyte indent = 0
        while indent < cur_col and editbuf[indent] == ' '
            indent++
        if not edoc.commit(cur_row, &editbuf, cur_col) {
            notify("Document full - save now")
            return
        }
        if not edoc.insert_line(cur_row + 1) {
            notify("Document full - save now")
            return
        }
        ; undo: restore this line to its full pre-split content + delete the new line (one group)
        undo_begin()
        urec_replace(cur_row, &editbuf, cur_len)
        urec_addline(cur_row + 1)
        ; build the new line: `indent` spaces, then the text right of the cursor
        ubyte nl = 0
        while nl < indent and nl < edoc.MAX_LEN {
            tmpbuf[nl] = ' '
            nl++
        }
        ubyte rp = cur_col
        while rp < cur_len and nl < edoc.MAX_LEN {
            tmpbuf[nl] = editbuf[rp]
            nl++
            rp++
        }
        void edoc.commit(cur_row + 1, &tmpbuf, nl)
        cur_row++
        cur_col = indent
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
        ; cursor-movement key collapses it. 147 = Shift+Home (CLR $93) and 132 = Shift+End
        ; (HELP $84): the X16 keymap delivers those combos as distinct codes, not Home/End+shift,
        ; so they are listed here explicitly - they only ever arrive with shift held.
        when k {
            17, 145, 29, 157, 19, 4, 2, 130, 147, 132 -> {
                if (g_mod & MOD_SHIFT) != 0 {
                    if not sel_active {
                        anc_row = cur_row
                        anc_col = cur_col
                        sel_active = true
                    }
                } else {
                    if sel_active {                     ; collapsing a selection: force a full repaint
                        sel_active = false              ; so the movement redraw erases the old highlight
                        sel_cleared = true
                    }
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
            17 -> {                          ; Down arrow (Ctrl = move the line down)
                if (g_mod & MOD_CTRL) != 0
                    op_move_line(true)
                else
                    ed_down()
            }
            145 -> {                         ; Up arrow (Ctrl = move the line up)
                if (g_mod & MOD_CTRL) != 0
                    op_move_line(false)
                else
                    ed_up()
            }
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
            147 -> ed_home()                ; Shift+Home (CLR $93): extend selection to line start
            132 -> ed_end()                 ; Shift+End (HELP $84): extend selection to line end
            25 -> {                         ; forward Delete key ($19). Shift+Del = Cut (CUA), if the
                if (g_mod & MOD_SHIFT) != 0  ; emulator delivers Shift+Del as this code + the shift bit
                    op_cut()
                else {
                    if sel_active
                        delete_selection()
                    else
                        ed_delete()
                }
            }
            2 -> ed_pgdn()
            130 -> ed_pgup()
            9 -> {                          ; Tab: indent the selected block, else insert spaces
                if sel_active
                    block_shift(true)
                else
                    ed_tab()
            }
            148 -> {                        ; $94: the Insert key -> INS/OVR toggle. On the X16 keymap
                if (g_mod & MOD_SHIFT) != 0  ; Shift+Del is ALSO $94 (the CBM INST/DEL combo); when the
                    op_cut()                 ; shift bit is set treat it as Shift+Del = Cut, else Insert.
                else
                    toggle_overwrite()
            }
            10 -> act_goto()                ; Ctrl+J  go to line
            ; ---- shortcut hotkeys (Ctrl+letter arrive as control codes 1..26) ----
            ; x16emu STEALS Ctrl+V (paste), Ctrl+F (fullscreen) and Ctrl+R (reset!)
            ; before they reach us (verified via Help>Key Probe). So those three
            ; actions get function-key aliases that pass through on both emulator
            ; and real hardware: F4=paste, F6=find, F8=replace. The Ctrl keys stay
            ; bound too, for muscle memory on real hardware where they work.
            3 -> op_copy()                  ; Ctrl+C  copy (selection or line)
            24 -> {                         ; $18 is BOTH Ctrl+X and Shift+Tab - split on the shift bit
                if (g_mod & MOD_SHIFT) != 0
                    block_shift(false)      ; Shift+Tab: outdent the block (or current line)
                else
                    op_cut()                ; Ctrl+X: cut (selection or line)
            }
            22, 138 -> op_paste()           ; Ctrl+V / F4  paste
            11 -> comment_apply(1)          ; Ctrl+K  comment the selected block (add REM) - Notepad++ key
            12 -> comment_apply(0)          ; Ctrl+L  toggle line comment (REM)
            5  -> op_delete_line()          ; Ctrl+E  delete line (moved off Ctrl+K, now Comment Block)
            23 -> comment_apply(2)          ; Ctrl+W  uncomment the selected block (strip REM)
            26 -> do_undo()                 ; Ctrl+Z  undo
            21 -> do_redo()                 ; Ctrl+U  redo
            6, 139 -> act_find()            ; Ctrl+F / F6  find
            7, 134 -> act_find_next()       ; Ctrl+G / F3  find next
            18, 140 -> act_replace()        ; Ctrl+R / F8  replace
            14 -> act_new()                 ; Ctrl+N  new
            15 -> act_open()                ; Ctrl+O  open
            137 -> void save_now()          ; F2  save
            135 -> act_run_basload()        ; F5  save + run through BASLOAD
            133 -> act_keymap()             ; F1  Help (keyboard map / edit.md)
            else -> {
                if (k >= 32 and k <= 126) or (k >= 160) {
                    if sel_active
                        delete_selection()
                    ed_insert(k)
                }
            }
        }
        ; drain the key-repeat backlog after a Shift+cursor selection step. Holding Shift+Arrow
        ; generates repeats faster than the selection-highlight redraw consumes them, so the KERNAL
        ; buffer fills and releasing the key kept extending the selection for a moment (overshoot).
        ; Flushing after each step caps movement to the redraw rate and stops the instant the key is
        ; released. Gated on a held Shift AND a cursor/selection key, so type-ahead of text - including
        ; Shift+letter capitals - is never flushed.
        if (g_mod & MOD_SHIFT) != 0 {
            when k {
                17, 145, 29, 157, 19, 4, 2, 130, 147, 132 -> cx16.kbdbuf_clear()
            }
        }
    }
}

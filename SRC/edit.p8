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
    const ubyte NMENU       = 6          ; File Edit Search Dev Window Help
    const ubyte WINDOW_MENU = 4          ; Window menu index (Next + document A/B/C list)
    const ubyte MOD_ALT    = $02        ; kbdbuf_get_modifiers bit
    ; get_editor_key returns 0 to mean "ALT released with no key -> open the menu bar" (0 is never a real
    ; key it returns). This replaced a MENU_KEY=200 sentinel that equalled PETSCII capital 'H' ($C8=200),
    ; so a real Shift+H (or a caps-folded 'h') used to open the menu instead of typing the letter.
    const uword BUILD_NUM  = 382         ; version's build segment: About shows "v0.9.<BUILD_NUM>".
                                        ; build.bat's build-sync step AUTO-INCREMENTS this (and README's
                                        ; "Version 0.9.N") by 1 on every compile - do not hand-edit.

    const ubyte MOD_SHIFT = $01         ; kbdbuf_get_modifiers shift bit
    const ubyte MOD_CTRL  = $04         ; kbdbuf_get_modifiers ctrl bit
    const ubyte MOD_CAPS  = $10         ; kbdbuf_get_modifiers bit 4 = Caps Lock
    ; Caps Lock breaks the Alt/Commodore menu keys: with Caps on, a letter is delivered as a graphics
    ; code 161-191 (which editor_key reads as a menu accelerator) and Caps shifts what the keyboard
    ; reports on top of that - so every keystroke opens a menu and ESC can't escape it. The KERNAL has
    ; NO API to clear the Caps toggle (kbd_leds drives only the LED), so we write shflag directly. It
    ; lives in RAM bank 0, adjacent to the $A80E fkey region EDIT already maps there; the address is
    ; undocumented so every write is GUARDED (see caps_kill). Same fix as sibling XFMGR2.
    const uword KBD_SHFLAG = $a80c      ; KERNAL shflag (Caps toggle) in RAM bank 0 - undocumented, guarded
    bool caps_was_on                    ; Caps was on at launch AND we cleared it -> restore it on exit
    bool upper_mode                     ; software Caps Lock: fold typed letters to uppercase at INSERT time
                                        ; (never via the KERNAL shflag, which breaks the Alt menus). Toggled
                                        ; by the Caps Lock key in get_editor_key; shown as CAPS on the footer.

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

    ; screen geometry. start() forces 80x30 (set_screen_mode $01; 40-col is unsupported), so these are
    ; INVARIANT - consts, not runtime vars, which folds ~60 use-sites to immediates and frees 3 BSS bytes.
    const ubyte SCR_W = 80
    const ubyte SCR_H = 30
    const ubyte STATUS_ROW = 29         ; = SCR_H - 1
    ubyte TEXT_ROWS                     ; = SCR_H - 2; stays a VAR (SES_PTRS holds &TEXT_ROWS)
    ubyte md_boxbot                     ; bottom screen row of the last-drawn menu dropdown, so
                                        ; closing/switching a menu can repaint just that band
    ubyte saved_mode                    ; screen mode to restore on exit
    ubyte saved_charset                 ; pre-launch charset (1=ISO 2=upper/gfx 3=lower); restored on exit
    ubyte saved_color                   ; pre-launch text colour; restored on exit

    ; document/cursor/view state
    str filename = "?" * 40
    str fnbuf    = "?" * 42             ; input scratch for prompts
    str savebuf  = "?" * 42             ; "@:" + filename for overwrite ("@:" + 40-char filename + NUL = 43)
    ; bakname (was a str*44 module buffer here) now aliases workbuf INSIDE act_make_backup - that sub
    ; never runs a Replace, so the 256B Replace scratch is dead there. Saves 44 B of low RAM.
    str untitled = "untitled"
    bool run_basload = false            ; F5 armed the BASLOAD hand-off; the start() tail chains to it
    bool run_config = false             ; Help>Config armed the hand-off to the EDCFG settings program
    str cfgprog = "edcfg.prg"           ; the settings program; theme.path_to() prefixes the
                                        ; install folder (read out of the root ED launcher)
    str runstate = "ed.run"             ; session-state file at the fsroot (see the layout note below)
    ; ---- session state (ed.run) ----
    ; A hand-off to BASLOAD / EDCFG (and later to any of our own utility programs) reloads EDIT from
    ; scratch, so everything in low RAM is lost. ed.run is what survives the trip. It used to carry
    ; just the active document's name + cursor line; it now describes the whole WORKSPACE - all three
    ; document slots, the clipboard and the search terms - so the return lands where the user left off
    ; rather than on one reopened file.
    ;
    ; Documents come back by REOPENING them from disk, which is why write_run_state force-saves any
    ; modified slot first. What deliberately does NOT survive is the undo/redo history: its snapshots
    ; are far pointers into the xarena, so restoring them would mean re-allocating every snapshot and
    ; rewriting both rings' bank/offset entries for three documents - a lot of fiddly code in a program
    ; with under 1KB of low RAM free, to save something a reload can legitimately drop. The rings ride
    ; along inside the context blocks below but are cleared on the way back in (see slot_restore).
    ;
    ; The per-document fields are NOT re-packed here. save_ctx already gathers all 42 of them into a
    ; CTX_SIZE context block in CLIP_BANK, so the file carries those blocks VERBATIM - which cannot
    ; disagree with the CTX table because it is that table's own output, and which costs ~1KB less low
    ; RAM than hand-packing the same fields (the first cut of this did, and overflowed memtop by 1054
    ; bytes). The trade: SES_VER MUST be bumped whenever CTX_ADDR/CTX_LEN change, or an old ed.run
    ; would scatter the wrong bytes into the wrong globals.
    ;
    ; The old format had no signature, so a stale or truncated file was parsed as though it were valid
    ; (hence its `fk + 99 <= n` length probe). This one leads with a magic + version and rejects
    ; anything else outright - a wrong file is a clean "start fresh", never a half-restored workspace.
    ;
    ; The SESSION-level fields (fkeys, search terms, clipboard flags, ...) all live in LOW RAM and
    ; stream straight to the file - the (field, length) list that defines their order lives with the
    ; rest of the session code in misc.ovl (fields() in misc.p8).
    ;
    ; Layout, written and read in exactly this order:
    ;    0   4   magic "eds1"
    ;    4   1   format version (SES_VER)
    ;    5  272  the session fields, in the order misc.p8's fields() streams them
    ;   ..  3*CTX_SIZE   the three document context blocks, exactly as save_ctx left them
    ;   ..   n           clipboard bytes (clip_len of them, 0..CLIP_MAX)
    ;
    ; The contexts are written at the full CTX_SIZE even though the CTX table only fills 466 of it -
    ; padding is free on disk and it means no length constant can drift out of step with the table.
    const ubyte SES_VER = 5             ; bump on ANY layout change - INCLUDING a change to CTX_ADDR/CTX_LEN
                                        ; (v2: UNDO_DEPTH 24 -> 20; v3: 20 -> 14; v4: 14 -> 12; v5: +per-doc iso_mode CTX field)
    const uword CLIP_MAX = 1024         ; clipbuf is $A000-$A3FF in CLIP_BANK
    ; magic + version as ONE record: it writes in a single f_write and verifies in a single compare
    ; loop, so the version can never be checked separately from (or forgotten alongside) the signature
    ubyte[5] seshdr = ['e', 'd', 's', '1', SES_VER]
    str tmpdoc   = "ed_a.tmp"           ; a modified UNTITLED doc spills here; [3] is patched per slot
    bool[NDOCS] ses_spill               ; that slot's document was untitled and went to a temp file
    bool  ses_failed                    ; ed.run existed but was not a session we understand
    ubyte ses_lost                      ; documents the session named that no longer exist on disk
    bool  ses_ok                        ; the session overlay handshake succeeded (see start())
    ; The session ORCHESTRATION (the old write_run_state / restore_run_state / slot_restore bodies)
    ; lives in misc.ovl - it runs once at startup and once at exit, making it the coldest ~900 bytes
    ; in the program, moved out when this feature left 20 bytes free. The overlay reaches main two
    ; ways: it calls back through ONE dispatcher (ses_svc below - overlay code can't name main's subs
    ; and must not map a bank itself), and it pokes main's globals through THIS table, by index.
    ; The table order and the ses_svc op numbers are the overlay ABI: keep them in lock-step with the
    ; P_*/OP_* constants in misc.p8 and bump SESOVL_VER on any change - the handshake then rejects a
    ; stale .ovl instead of letting it scribble through outdated pointers.
    ; @nosplit is LOAD-BEARING: prog8 stores uword arrays as separate lsb/msb halves by default, and
    ; &SES_PTRS on a split array yields the LSB half only - the overlay's peekw(ptrs + i*2) walk then
    ; reads pairs of ADJACENT LSBS as pointers and scribbles through garbage addresses (found the hard
    ; way: F5 BRKed into the ML monitor). @nosplit forces the interleaved lo/hi layout the overlay
    ; expects. Main's own indexed accesses work either way; it is only this raw cross-unit view that
    ; needs the linear layout.
    ; Two session buffers that are LIVE all session but TOUCHED only at the two ends (startup and
    ; exit) live in CLIP_BANK rather than low RAM - 181 bytes reclaimed. They sit above the three
    ; context blocks, which end at CTX_BASE + NDOCS*CTX_SIZE = $A400 + $600 = $AA00.
    ; They are still streamed to ed.run in the same order and the same lengths, so the FILE format
    ; is unchanged (SES_VER stays put) - but the overlay must move them with OP_XFER, never with
    ; fio(), because fio() hands the address to diskio as low RAM. That is why the SES_PTRS slots
    ; below hold these ADDRESSES rather than &fksnap / &startdir, and why SESOVL_VER is bumped: a
    ; stale misc.ovl would fio() them and stream from the wrong memory.
    ; SLACK WARNING: $AA00 is the FIRST byte after the context blocks, not a byte after them - slot 2
    ; is reserved through $A9FF exactly. ctx_field walks the CTX table with no bound check against
    ; CTX_SIZE, so the fit is arithmetic, not enforced: CTX_LEN sums to 82 + 16*UNDO_DEPTH, which is
    ; 274 at the current depth of 12 and crosses 512 at depth 27. Raising UNDO_DEPTH past 26 would
    ; have save_ctx(2) write straight through the fkey snapshot, which exit then commits into the
    ; KERNAL's fkeytb. Move these two up before touching UNDO_DEPTH.
    const uword FKSNAP_ADDR   = $AA00       ; 99 bytes: the KERNAL fkey-macro snapshot
    const uword STARTDIR_ADDR = $AA70       ; 82 bytes: the startup working directory
    const ubyte SESOVL_VER = 2
    ; Index 26 (&cur_col) is APPENDED for picker.ovl's .EDIT.SESSION engine (P_CUR_COL there). Appending
    ; at the end leaves misc.ovl's ABI (it only reads indices 0-25) untouched, so SESOVL_VER is NOT bumped.
    ; This table holds ADDRESSES only - it is never streamed to a file, so the ed.run format/SES_VER are
    ; unaffected too.
    uword[27] @nosplit SES_PTRS = [
        &g_active_slot, &modified, &filename, &fnbuf, &ses_spill,
        &tmpdoc, &seshdr, &tmpbuf, &clip_has, &clip_len,
        &cur_row, &top_line, &basload_err_line, &edoc.line_count, &sel_active,
        &sel_cleared, &cur_dirty, &ses_failed, &ses_lost, &TEXT_ROWS,
        FKSNAP_ADDR, &find_term, &repl_term, STARTDIR_ADDR, &ww_on, &clip_line, &cur_col ]
    uword basload_err_line = 0          ; line# scraped off the boot screen's BASLOAD error (0 = none)
    const ubyte BERR_MAX = 80           ; longest BASLOAD error line kept - one full 80-column row.
    const uword berr = $AB00            ; the scraped BASLOAD error line (screen codes) lives in CLIP_BANK
                                        ; at $AB00 (above STARTDIR $AA70), NOT low RAM - saves 80 B. Only
                                        ; berr_len stays low; the two access loops wrap push/pop CLIP_BANK.
    ubyte berr_len = 0                  ; length of berr (0 = no error captured)
    ubyte[5] retkey = [$5e, $2f, $45, $44, $0d]  ; F8 return macro: up-arrow "/ED" + CR -> reloads EDIT
    ; fksnap (the 99-byte snapshot of all 9 KERNAL fkey macros, restored verbatim on exit) lives at
    ; FKSNAP_ADDR in CLIP_BANK - see the note on that constant.
    ubyte[252] editbuf                  ; the line under the cursor (raw PETSCII). 252 = edoc.MAX_LEN(250)
    ubyte[252] tmpbuf                   ; + a 2-byte boundary margin; lines can never exceed 250 (ed_insert
    ubyte[252] hlcol                    ; guards, edoc.load force-breaks). tmpbuf=line joins, hlcol=syntax cols.
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
    ; Wrap-mode incremental-redraw state. Display-only, never persisted; rebuilt by every
    ; draw_all_text_wrapped, which every edit path runs (ensure_visible returns true under wrap).
    ; Together these answer "is the cursor on screen" and "which screen row is it on" with plain
    ; compares - the old code re-derived the window layout by loading every visible line from
    ; banked RAM on EVERY cursor move, which is the main reason wrap-mode scrolling crawled.
    ubyte g_cseg                        ; cursor's wrap-segment start, set by ensure_visible_wrap
    uword nxt_dl                        ; the first visual row BELOW the window: its doc line...
    ubyte nxt_seg                       ; ...and segment. (line_count, 0) when blanks are visible.
    ubyte cur_vseg                      ; wrap-segment the cursor was on at the last paint - the
                                        ; one-row-scroll fast path needs it to un-band the old row.
    ubyte cur_srow                      ; SCREEN row of the cursor's banded visual row at last paint;
                                        ; draw_wrapped_row records it so a no-scroll move un-bands
                                        ; the old row without searching for it (wrap fast path).
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
    bool g_attn                         ; the attention band (draw_attn) is up over the last text row
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
    str find_term = "?" * 38            ; current search term (prompt maxlen 38; sel_to_find caps at 38)
    str repl_term = "?" * 38            ; current replacement (prompt maxlen 38)
    ; Scratch for building a replaced line - aliased onto edoc.linebuf for 256 bytes of low RAM.
    ; edoc.linebuf is live ONLY inside edoc.load_file / edoc.save_file, and no workbuf holder spans
    ; either call: act_make_backup builds bakname here but copies it into savebuf BEFORE save_file
    ; runs; Replace, the block-comment builders and the undo capture are pure in-memory (edoc.commit
    ; and edoc.store never touch linebuf); halt_no_ovl builds its message at startup, before any load.
    ; RULE for anything new that parks data here: it must not stay live across an Open, a Save or a
    ; session restore. That is exactly what sank the FIRST attempt at this alias (v0.9.215) - the
    ; BASLOAD error line used to ride in workbuf, and it is scraped in start() BEFORE
    ; restore_run_state() (which load_file's the documents) and printed AFTER it, so load_file
    ; overwrote it while berr_len stayed non-zero and the status bar printed 80 bytes of the last
    ; loaded line. berr now owns its 80 bytes up top; net gain here is still 176.
    alias workbuf = edoc.linebuf
    uword found_row                     ; result of the last find
    ubyte found_col
    uword g_repl_count                  ; replacements committed in the last Replace run

    ; clipboard - holds either one whole line (clip_line=true, paste as a new line)
    ; or selected text (clip_line=false, paste inline; may contain $0D line breaks).
    ; OVERLAY: clipbuf lives in its own banked-RAM bank (CLIP_BANK), not scarce low RAM. It
    ; is modal (only copy/paste touch it) and fits one 8KB window. Every access maps the bank
    ; first (cx16.push_rambank .. pop_rambank); edoc.load/commit calls nested inside stay
    ; correct because push/pop is a CPU-stack LIFO that restores CLIP_BANK when they return.
    const ubyte CLIP_BANK = 9        ; reserved bank 9: the 1KB clipboard (+ the 3 doc CONTEXT blocks in its tail)
    const uword clipbuf   = xarena.WIN_START                ; $A000 within CLIP_BANK
    uword clip_len
    bool clip_has
    bool clip_line

    ; ---------- undo / redo (per-line snapshots kept in banked RAM) ----------
    const ubyte UNDO_DEPTH = 12         ; per-doc undo/redo history depth (trimmed 32 -> 24 -> 20 -> 14 -> 12
                                        ; to reclaim low RAM - each level costs 16 B across the two rings.
                                        ; 20 -> 14 funded the Caps Lock keyboard fix; 12 is the hard floor
                                        ; (user-set - do not trim below this). See caps_kill.
                                        ; Changing this changes the context layout: bump SES_VER with it.
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

    ; ---------- multiple documents (three: A up to 6000 lines, B/C up to 2500) ----------
    ; Only ONE document's state is "live" in the globals above at a time; the other two are stashed as
    ; ~594-byte CONTEXT blocks in the CLIP_BANK tail. F7 (switch_doc) cycles A->B->C->A: it flushes the
    ; live line, saves the active context, retargets the storage layer (edoc table base + line cap,
    ; xarena bounds/position) at the next slot, and loads its context. edoc/xarena ALWAYS point at the
    ; active slot; only switch_doc + startup init retarget them (New/Open/Save/undo run on the active
    ; slot and never touch another doc's banks). Each doc owns DISJOINT table + content banks, so the
    ; three undo histories (whose snapshots live in the arena) are isolated for free.
    const ubyte NDOCS = 3
    const ubyte CONTENT_FIRST_BANK = 14         ; content banks start above the 7 table + 6 reserved banks
    ubyte[NDOCS] SLOT_TBL_BASE  = [1, 4, 6]     ; first line-table bank per doc (A:1-3, B:4-5, C:6-7)
    uword[NDOCS] SLOT_MAX_LINES = [6000, 2500, 2500]
    ubyte[NDOCS] slot_arena_lo                  ; content-bank sub-range per doc (computed at startup)
    ubyte[NDOCS] slot_arena_hi
    bool[NDOCS] slot_modified                   ; each doc's modified flag as of its last save_ctx (for the
                                                ; status bar: the two INACTIVE docs are frozen, so this is live)
    ubyte g_active_slot = 0                      ; the live document: 0=A, 1=B, 2=C
    uword g_ctxp                                 ; running pointer into the context bank during a transfer
    const uword CTX_BASE = $A400                 ; context blocks sit above the 1KB clipboard ($A000-$A3FF)
    const uword CTX_SIZE = 512                   ; bytes reserved per doc context (actual 402 at depth 20)
    const ubyte CTX_FNAME_OFF = 18               ; byte offset of the 41-byte filename WITHIN a context block
                                                 ; (= sum of CTX_LEN[0..12]); the Window menu reads inactive
                                                 ; docs' names from here - keep in sync if the CTX order changes
    ; the per-document context is this ordered list of (address, byte-length) fields. save_ctx/load_ctx
    ; walk it in one loop (see ctx_xfer). Keep CTX_ADDR and CTX_LEN in lock-step; total length = 402
    ; at UNDO_DEPTH 20 (the ten ring entries scale with it; the rest is fixed at 82).
    const ubyte NCTXF = 43
    uword[NCTXF] CTX_ADDR = [
        &edoc.line_count, &edoc.oom, &xarena.cur_bank, &xarena.cur_ptr, &xarena.high_bank,
        &cur_row, &top_line, &prev_cur_row, &cur_col, &left_col, &top_seg, &modified, &ovr_mode,
        &filename,
        &ln_on, &gutter_w, &wrap_on, &hl_on, &hl_mode, &theme.ISO_MODE,
        &sel_active, &sel_cleared, &anc_row, &anc_col, &s_row, &e_row, &s_col, &e_col,
        &found_row, &found_col,
        &g_group, &u_sp, &d_sp,
        &u_op, &u_row, &u_grp, &u_bnk, &u_off,
        &d_op, &d_row, &d_grp, &d_bnk, &d_off ]
    ubyte[NCTXF] CTX_LEN = [
        2, 1, 1, 2, 1,
        2, 2, 2, 1, 1, 1, 1, 1,
        41,
        1, 1, 1, 1, 1, 1,
        1, 1, 2, 1, 2, 2, 1, 1,
        2, 1,
        2, 1, 1,
        UNDO_DEPTH, UNDO_DEPTH*2, UNDO_DEPTH*2, UNDO_DEPTH, UNDO_DEPTH*2,
        UNDO_DEPTH, UNDO_DEPTH*2, UNDO_DEPTH*2, UNDO_DEPTH, UNDO_DEPTH*2 ]

    ; CODE OVERLAY: the Open/View file picker (picker.ovl) in reserved bank 8. Its directory-record
    ; store lives in a SEPARATE dedicated bank (RECORDS_BANK) - an overlay running at $A000 can't map a
    ; second bank into $A000 to reach data, so the four rec_* helpers below run from LOW RAM (which
    ; stays mapped when the HIRAM bank flips) and do the banked access; the overlay calls them through
    ; jmp-(ptr) trampolines, staging bytes through recstage. Giving the records their own 8KB bank
    ; lifts the Open list to ~157 files. Same loadlib + extsub @bank pattern as misc.ovl / tview.ovl.
    ;   picker_setup(peek, read, write, move, stage)  - wire the bank helpers, once after load
    ;   pick(dest, theme_id, blkptr) -> 1 if a file was chosen (dest + @blkptr filled), 0 if cancelled.
    ;   del_sym(theme_id)             - Dev > Delete all SYM files: confirm + scan + delete + report,
    ;                                   all painted in-bank on the status row (returns the count deleted).
    const ubyte PICKER_BANK  = 8       ; reserved bank 8 for picker.ovl
    const ubyte RECORDS_BANK = 12      ; reserved bank 12: the picker's file-list records
    const ubyte REC_STAGE_LEN = 52                         ; bytes/record - MUST match picker.p8 FNREC
    extsub @bank 8 $A000 = picker_init()
    extsub @bank 8 $A003 = pick(uword dest @R0, ubyte theme_id @R1, uword blkptr @R2) -> ubyte @A
    extsub @bank 8 $A006 = picker_setup(uword peekfn @R0, uword readfn @R1, uword writefn @R2, uword movefn @R3, uword stage @R4)
    extsub @bank 8 $A009 = del_sym(ubyte theme_id @R0) -> ubyte @A   ; Dev > Delete all SYM files
    bool picker_ok                      ; picker.ovl loaded OK -> the Open/View picker is available
    bool session_on                     ; a .EDIT.SESSION exists in the cwd -> the feature is "on" (label +
                                        ; exit-update). Dev-mode only; set at startup, kept current by the
                                        ; toggle and after Open/View (the only cwd changes).
    str  pickerovl = "picker.ovl"
    ubyte[REC_STAGE_LEN] recstage       ; low-RAM staging buffer for one record (rec_read/rec_write)

    ; CODE OVERLAY: the About screen lives in misc.ovl, loaded into MISC_BANK (bank 10) at startup.
    ; It is cold (user-triggered) but carries literal text + its box-draw code, so it runs from
    ; banked RAM rather than EDIT's scarce low RAM. `extsub @bank 10` wraps each call in a JSRFAR
    ; that maps the bank around it. $A000 is the library init; $A003 = About (misc.p8's %jmptable).
    ;
    ; The overlay cannot see main's symbols, so it carries its OWN copy of theme.p8 and the box
    ; helpers: we pass the theme id, the build number and the emulator flag and it paints to match.
    const ubyte MISC_BANK = 10      ; reserved bank 10 for misc.ovl
    extsub @bank 10 $A000 = misc_init()
    extsub @bank 10 $A003 = ovl_about(ubyte theme_id @R0, uword build @R1, ubyte emu @R2)
    ; ovl_prompt ($A006): the modal status-row text input, moved out of low RAM into misc.ovl. Its key
    ; loop runs entirely in-bank (one JSRFAR per prompt); prompt_str() below is a thin main-side wrapper.
    ; flags: bit0 = allow_empty, bit1 = ww_hint, bits 4-7 = input-history category (see the PF_*
    ; consts at prompt_str). wwptr -> ww_on (toggled live on Commodore+W). Returns 1/0.
    extsub @bank 10 $A006 = ovl_prompt(uword promptmsg @R0, uword dest @R1, ubyte maxlen @R2, ubyte flags @R3, ubyte theme_id @R4, uword wwptr @R5) -> ubyte @A
    ; the session save/restore entries (see the SES_PTRS comment for the ABI)
    extsub @bank 10 $A009 = ovl_ses_setup(uword svcaddr @R0, uword ptrtbl @R1) -> ubyte @A
    extsub @bank 10 $A00C = ovl_ses_write()
    extsub @bank 10 $A00F = ovl_ses_restore() -> ubyte @A
    ; $A012: hands back the addresses of the three BASIC keyword blobs, which live in misc.ovl's
    ; string pool to keep ~450 B of keyword text out of low RAM. syntax.set_kw caches them + this bank.
    extsub @bank 10 $A012 = ovl_kw_addrs(uword outp @R0)
    ; program hand-off on exit (moved to misc.ovl to reclaim low RAM; both only run once at exit and
    ; touch KERNAL/VERA only, so the $A000 window is free for the overlay). prog/name stay in low RAM.
    extsub @bank 10 $A015 = ovl_chain_load(uword prog @R0)
    extsub @bank 10 $A018 = ovl_chain_basload(uword name @R0)
    ; msg_text ($A009 in menus.ovl, NOT misc.ovl - misc was full): copies a cold status-bar message
    ; (see MSG_* below) from the overlay's string pool into a low-RAM buffer. Those ~450 B of
    ; user-facing toast/prompt text never run in a hot loop, so they live in the overlay; msg(id)
    ; fetches one on demand. IDs are the ABI - keep in lock-step with menus.p8's msg_text `when`.
    extsub @bank 13 $A009 = msg_text(ubyte id @R0, uword dest @R1)
    const ubyte MSG_SES_ISSUE  = 0      ; "Session issue, starting fresh."
    const ubyte MSG_TOOBIG     = 1      ; "File too big - not loaded"
    const ubyte MSG_OPENERR    = 2      ; "Cannot open file"
    const ubyte MSG_SAVECAN    = 3      ; "Save cancelled"
    const ubyte MSG_ALLSAVED   = 4      ; "All documents already saved"
    const ubyte MSG_BAKFAIL    = 5      ; "Backup failed"
    const ubyte MSG_BAKSAVED   = 6      ; "Backup saved"
    const ubyte MSG_WRAPTOP    = 7      ; "Wrapped to top"
    const ubyte MSG_NOTERM     = 8      ; "No search term - use Find first"
    const ubyte MSG_CLIPEMPTY  = 9      ; "Clipboard empty"
    const ubyte MSG_NOUNDO     = 10     ; "Nothing to undo"
    const ubyte MSG_NOREDO     = 11     ; "Nothing to redo"
    const ubyte MSG_BACKINGUP  = 12     ; "Backing up..."
    const ubyte MSG_DOCFULL    = 13     ; "Document full - save now"
    const ubyte MSG_LINECOPIED = 14     ; "Line copied"
    const ubyte MSG_SAVECHG    = 15     ; "Save changes? Y/N  (Esc=Cancel)"
    const ubyte MSG_OVERWRITE  = 16     ; "Overwrite existing file? Y/N"
    const ubyte MSG_OPENFIRST  = 17     ; "Open or save a file first"
    const ubyte MSG_REPLACEBAR = 18     ; "Replace?  Yes  No  All  Esc"
    ubyte[36] msgbuf                    ; scratch msg(id) copies into; longest message is 34 chars + a
                                        ; margin (msg_text has no length guard, so keep this >= the
                                        ; longest string in menus.p8's msg_text + 1 for the NUL)
    bool misc_ok                        ; misc.ovl loaded OK -> About + the input prompts are available
    str  miscovl = "misc.ovl"

    ; CODE OVERLAY: the read-only text/hex file viewer (tview.ovl) in its own reserved bank 11.
    ; Used by Help > Keyboard (views the shipped edit.md) and File > View (any picked file). Same
    ; loadlib + extsub @bank pattern as misc.ovl; it carries its own theme.p8 copy, so we pass the
    ; theme id and it paints in EDIT's colours. $A003 = view_file(nameptr, theme_id).
    const ubyte TVIEW_BANK = 11     ; reserved bank 11 for tview.ovl
    extsub @bank 11 $A000 = tview_init()
    extsub @bank 11 $A003 = ovl_view(uword nameptr @R0, ubyte theme_id @R1)
    bool tview_ok                       ; tview.ovl loaded OK -> the viewer is available
    str  tviewovl = "tview.ovl"

    ; CODE OVERLAY: the dropdown-menu item labels + renderer (menus.ovl) in reserved bank 13. The old
    ; local draw_item (~1.1KB of inline label literals) moved here to reclaim low RAM; main keeps all
    ; the dropdown control/colour/layout/dispatch and just calls mnu_item() to paint each item's text.
    ; NOT optional: without it dropdowns paint blank (bar/accelerators/shortcut keys still work).
    ; flags bit0 = wrap_on, bit1 = hl_on, bit2 = ln_on (the three toggle-label states).
    const ubyte MENUS_BANK = 13     ; reserved bank 13 for menus.ovl
    extsub @bank 13 $A000 = menus_init()
    extsub @bank 13 $A003 = mnu_item(ubyte active @R0, ubyte i @R1, ubyte col @R2, ubyte row @R3, ubyte flags @R4)
    extsub @bank 13 $A006 = mnu_bar(uword ctxp @R0)      ; paints the whole menu bar (row 0)
    ; edsess_op ($A00C, menus.ovl's 4th jmptable entry): the per-folder .EDIT.SESSION engine. It lives
    ; here (not picker.ovl - that bank was full; menus.ovl had the room) and imports its own diskio for the
    ; file I/O, but drives main's ses_svc + SES_PTRS for the slot loads/saves. op = 0 exists? / 1 delete /
    ; 2 restore (load saved files+cursors onto the fresh slots) / 3 write. Pass &ses_svc + &SES_PTRS (0/0
    ; for ops 0 and 1). See act_session_toggle, refresh_session_on, and the start()/act_exit hooks.
    extsub @bank 13 $A00C = edsess_op(ubyte op @R0, uword svc @R1, uword ptrs @R2) -> ubyte @A
    ; mnu_mode ($A00F, menus.ovl's 5th entry): draws the footer INS/OVR + CAPS field and returns the column
    ; past it. Hosted in the overlay so its put_str_at calls + string literals don't sit in scarce low RAM.
    extsub @bank 13 $A00F = mnu_mode(ubyte col @R0, ubyte row @R1, ubyte ovr @R2, ubyte caps @R3, ubyte iso @R4) -> ubyte @A
    ; mnu_accel ($A012, menus.ovl's 6th entry): the dropdown accelerator tables (which 0 = folded letter
    ; -> item index; which 1 = item index -> accelerator column offset). Hosted beside the labels so the
    ; ~330 B of when-tables leave main's low RAM. showdev = theme.show_dev (the overlay has no theme).
    extsub @bank 13 $A012 = mnu_accel(ubyte which @R0, ubyte active @R1, ubyte arg @R2, ubyte showdev @R3) -> ubyte @A
    ; mnu_rem (picker.ovl $A00C, its 4th jmptable entry - menus.ovl was full): the REM-comment builders
    ; (op 0 = rem_start, 1 = build_commented with extra=cmt_indent, 2 = build_uncommented with extra=rs).
    ; buf/workp are &tmpbuf/&workbuf (low RAM, mapped for the overlay); iso = theme.ISO_MODE (fold + prefix).
    extsub @bank 8 $A00C = mnu_rem(ubyte op @R0, ubyte blen @R1, ubyte extra @R2, ubyte iso @R3, uword buf @R4, uword workp @R5) -> ubyte @A
    bool menus_ok                       ; menus.ovl loaded OK -> dropdown item labels are available
    ubyte[9] menuctx                    ; packed state handed to mnu_bar (see draw_menubar)
    str  menusovl = "menus.ovl"
    str  keysfile = "edit.md"           ; the help / Keyboard Map text file, viewed by Help > Keyboard
    str  basloadhlp = "basload.md"      ; the BASLOAD guide, viewed by Help > BASLOAD
    str  hintshlp   = "hints.md"        ; the Hints-Tips file, viewed by Help > Hints-Tips (Dev-only)
    ubyte pick_blocks                   ; size (clamped blocks) of the file last chosen by the picker
    ; startdir (the working dir at startup, restored on exit; diskio MAX_PATH_LEN=80 so 82 with the
    ; terminator) lives at STARTDIR_ADDR in CLIP_BANK - see the note on that constant.

    ubyte[NMENU] menu_col = [1, 7, 13, 21, 26, 34]  ; start col of each title: File@1, 2 spaces between titles
    ubyte[NMENU] menu_len = [4, 4, 6, 3, 6, 4]       ; File, Edit, Search, Dev, Window, Help

    ; ALT is the Commodore key, so ALT+letter arrives as a graphics code $A1..$BF (161..191);
    ; this maps each (indexed by code-161) back to its base letter. 0 = not a letter.
    ; (verbatim from sibling XFMGR2; e.g. ALT+F=187, ALT+E=177, ALT+S=174, ALT+H=180)
    ubyte[31] alt_letter = [
        'k','i','t', 0 ,'g', 0 ,'m', 0 , 0 ,'n','q','d','z','s','p',
        'a','e','r','w','h','j','l','y','u','o', 0 ,'f','c','x','v','b' ]

    ; menu_for_letter (top-menu-bar accelerator: F/E/S/D/W/H -> menu index) moved to menus.ovl's
    ; mnu_accel(which=2) to reclaim low RAM. Call it as mnu_accel(2, 0, letter, theme.show_dev as ubyte).

    ; item_accel + accel_off (the dropdown accelerator tables) moved to menus.ovl's mnu_accel ($A012)
    ; to reclaim ~330 B of low RAM - they belong beside the labels there. Call sites use mnu_accel
    ; directly: which 0 (folded letter -> item index) in run_dropdown; which 1 (item -> accel column)
    ; in draw_dropdown_item. theme.show_dev is passed since the overlay has no theme copy.

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        scan_basload_error(cx16.r0L, cx16.r0H)  ; read the still-intact boot screen (X=width,Y=height) for a
                                                ; BASLOAD error line BEFORE the mode switch below wipes it
        snapshot_machine_state()                ; capture charset + text colour while still in the booted mode
        caps_off()                              ; Caps Lock off for the session (it breaks the Alt menus); restored on exit
        ; 80-column only: force 80x30 regardless of the booted mode (40-col is NOT supported). The
        ; original mode is captured above (saved_mode) and put back on exit, so a machine booted in
        ; 40-col still returns to it. The UI lays itself out from SCR_W/SCR_H below.
        cx16.set_screen_mode($01)               ; 80x30 (SCR_W/SCR_H/STATUS_ROW are consts to match)
        TEXT_ROWS = SCR_H - 2                    ; the one geometry value kept as a var (SES_PTRS &TEXT_ROWS)
        txt.lowercase()                 ; boot charset = PETSCII lowercase. The ACTIVE doc's real mode
                                        ; (per-doc theme.ISO_MODE) is applied by apply_charset_mode once
                                        ; the slots are loaded, below (before the first full_redraw).
        sys.disable_caseswitch()        ; lock the charset - Shift+Commodore can't flip the whole
                                        ; display mid-edit (as in XFMGR2); wanted in ISO mode too

        g_emu = emudbg.is_emulator()    ; remember the runtime environment
        xarena.detect_banks()           ; clamp banked storage to the RAM actually installed
        docs_layout()                   ; carve the content banks (14..max) into three per-doc ranges
        point_storage(0)                ; point the storage layer at Doc A (slot 0) for the first document
        find_term[0] = 0                ; the "?"*N buffers start non-empty; clear them
        repl_term[0] = 0
        clip_has = false
        ; remember the working directory so we can restore it on exit (the file picker
        ; may chdir away). curdir() needs X16 DOS R42+; 0 = unsupported/error -> skip.
        cx16.push_rambank(CLIP_BANK)    ; startdir lives in the bank now (see FKSNAP_ADDR's note)
        @(STARTDIR_ADDR) = 0
        cx16.r1 = diskio.curdir()
        if cx16.r1 != 0
            void strings.copy(cx16.r1, STARTDIR_ADDR)
        cx16.pop_rambank()
        theme.apply(theme.cfg_read())   ; colour scheme from the install folder's edit.cfg (missing -> Classic).
                                        ; Read here, while the cwd is still the fsroot we launched in - theme's
                                        ; paths are relative to it and it does no chdir of its own.
        if not theme.show_dev {
            menu_col[4] = menu_col[3]                     ; Dev hidden -> Window slides into Dev's slot, and
            menu_col[5] = menu_col[4] + 6 + 2   ; Help follows Window (width 6 + 2-space gap). show_dev
        }                                                 ; is fixed for the session (only EDCFG changes it),
                                                          ; so this one-time overwrite is safe; Dev(3) is then
                                                          ; never drawn/opened.

        ; load the misc overlay (About) into its reserved bank, from the install folder (same place
        ; edit.cfg came from - we are still in the launch cwd). A missing misc.ovl is not fatal:
        ; misc_ok stays false and About says so instead of jumping into empty RAM.
        cx16.push_rambank(MISC_BANK)
        misc_ok = diskio.loadlib(theme.path_to(miscovl), $a000) != 0
        cx16.pop_rambank()
        if misc_ok
            misc_init()                 ; extsub @bank 10: clears the overlay's in-bank BSS, ONCE
        else
            void diskio.status()         ; drop the FILE NOT FOUND (else the activity LED blinks)
        ; wire up the session code + the keyword-blob addresses in the overlay. Guard first: the
        ; jmptable entries we are about to call must actually BE jumps (a stale pre-session misc.ovl
        ; is shorter - $A009+ would hold arbitrary code and calling it would crash). $A009/C/F are
        ; the session entries; $A012 is kw_addrs. ses_setup must also return the ABI version this
        ; binary was built against. Any failing -> that feature degrades (sessions off / keyword
        ; colouring off) but EDIT runs fine. One push/pop covers both checks.
        ses_ok = false
        if misc_ok {
            cx16.push_rambank(MISC_BANK)
            bool entries = @($a009) == $4c and @($a00c) == $4c and @($a00f) == $4c
            bool kw_entry = @($a012) == $4c
            cx16.pop_rambank()
            if entries
                ses_ok = ovl_ses_setup(&ses_svc, &SES_PTRS) == SESOVL_VER
            if kw_entry {
                ; syntax reads the blobs from MISC_BANK; hand it their addresses (via idle tmpbuf).
                ovl_kw_addrs(&tmpbuf)
                syntax.set_kw(peekw(&tmpbuf), peekw(&tmpbuf + 2), peekw(&tmpbuf + 4), MISC_BANK)
            }
        }

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
        ; All four overlays are REQUIRED. If any failed to load (file missing from the program
        ; folder), name it and stop here - BEFORE the fkey hijack and document setup, so returning is
        ; a clean exit. Running degraded is not offered: the menus, dialogs, prompts, viewer and the
        ; syntax keyword tables all live in overlays, so a missing one is a broken install. Ordered
        ; misc-first so a missing misc.ovl (which the input prompts + keyword colouring need) is named.
        if not misc_ok {
            halt_no_ovl(miscovl)
            return
        }
        if not menus_ok {
            halt_no_ovl(menusovl)
            return
        }
        if not picker_ok {
            halt_no_ovl(pickerovl)
            return
        }
        if not tview_ok {
            halt_no_ovl(tviewovl)
            return
        }
        ; A session restore rebuilds ALL THREE slots itself (documents, cursors, clipboard), so the
        ; fresh-launch path below - which blanks B and C - must not run on top of it.
        bool reloaded = restore_run_state()
        if not reloaded {               ; fresh launch (no session pending):
            snapshot_fkeys()            ;   capture the user's real fkeys before we ever hijack F8
            new_document()
            init_doc_slots()            ;   slot 0 is the launched doc; create empty docs B and C
        }                               ; (on reload, restore_run_state loaded the snapshot from ed.run)
        ; Per-folder .EDIT.SESSION (Dev mode only). A pending ed.run BASLOAD/EDCFG round-trip WINS (we only
        ; auto-load the folder session on a truly fresh launch), matching "if session from BASLOAD exists in
        ; root use that one". session_on tracks the file's existence for the Dev-menu label + the exit update.
        refresh_session_on()
        if session_on and not reloaded                  ; overlay the saved files+cursors onto the fresh slots
            edsess_rw(2)
        cursor_sprite_setup()                   ; the insert-mode underline cursor sprite (theme+mode set)
        font_setup()                            ; capture the { } \ | ~ glyphs from the ROM ISO font (once)
        apply_charset_mode()                    ; apply the active doc's PETSCII/ISO mode before the first paint
        full_redraw()
        ; One status-row message, most specific first: a BASLOAD error names a line to fix, a rejected
        ; session explains why the editor came up empty, missing files explain the blank slots. Silence
        ; would read as a bug in every one of those cases.
        if reloaded and berr_len != 0           ; the Run BASLOAD came back with an error; show the full
            show_basload_error()                ; error on the bar (cursor's already on the line it named)
        else if ses_failed or ses_lost != 0 {
            ; ed.run was unreadable, or the docs it named are gone - explain why the editor came up
            ; empty instead of with the saved workspace; silence would read as a bug. (ses_ok false -
            ; a misc.ovl session-ABI mismatch - can't really happen: misc.ovl ships with edit.prg and
            ; is a REQUIRED overlay, so a wrong one is a broken install that halts at startup. If it
            ; somehow did, the session just stays off, no message.)
            flash_notify(msg(MSG_SES_ISSUE))
        }
        g_running = true
        while g_running {
            ubyte k = get_editor_key()
            if k == 0
                menu_mode_loop(0)       ; get_editor_key returns 0 only on ALT-release -> open the menu
            else
                editor_key(k)
        }

        ; Restore the launch dir ONLY on a normal exit. The BASLOAD/Config hand-offs must keep the cwd
        ; at the DOCUMENT's directory: a file opened from a subfolder leaves the picker's cwd there with
        ; a BARE filename, and BASLOAD"name" / ed.run are resolved relative to the cwd - chdir'ing back
        ; to startdir here would make BASLOAD (and the F8 return-trip reload) look in the wrong folder.
        cx16.push_rambank(CLIP_BANK)        ; startdir is banked now - diskio reads the name straight
        if @(STARTDIR_ADDR) != 0 and not run_config and not run_basload   ; out of the mapped window
            diskio.chdir(STARTDIR_ADDR)
        cx16.pop_rambank()
        cursor_sprite_off()                     ; don't leave our cursor sprite on for the next program
        txt.clear_screen()
        cx16.set_screen_mode(saved_mode)        ; restore the original screen mode
        restore_machine_state()                 ; re-apply the user's charset + text colour (CINT reset them)
        caps_restore()                          ; put Caps Lock back as we found it - before ALL exit branches
        txt.clear_screen()                      ; clean screen in the restored charset/colours before sign-off
        if run_config {
            ovl_chain_load(theme.path_to(cfgprog))  ; hand off to EDCFG (misc.ovl); reloads EDIT on exit
        } else if run_basload {
            ovl_chain_basload(filename)         ; hand off to BASLOAD (misc.ovl); F8 stays armed to return
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

    sub caps_kill(ubyte mods) -> bool {
        ; Clear the Caps bit in the KERNAL shflag. `mods` MUST be the value kbdbuf_get_modifiers() just
        ; returned (with MOD_CAPS set). GUARD: only write if the byte at KBD_SHFLAG reads back exactly
        ; that value - a strong match (we are here only when Caps is set, so mods is a specific non-zero
        ; value, not a coincidental 0). If a future ROM moved shflag the two disagree and we leave it
        ; alone: the fix quietly no-ops instead of corrupting an unrelated KERNAL variable. Returns true
        ; if it actually cleared. push/pop bank 0 is balanced, so the caller's mapped bank is preserved.
        cx16.push_rambank(0)
        bool ok = @(KBD_SHFLAG) == mods
        if ok
            @(KBD_SHFLAG) = mods & (255 - MOD_CAPS)
        cx16.pop_rambank()
        return ok
    }

    sub caps_off() {
        ; Startup: if Caps Lock is on, clear it for the session and arm the exit restore. (Mid-session
        ; re-toggles are caught by the guard in get_editor_key, so Caps can never take hold while editing.)
        ubyte mods = cx16.kbdbuf_get_modifiers()
        if (mods & MOD_CAPS) != 0 {
            cx16.kbdbuf_clear()             ; keys typed pre-load were translated with Caps ON (graphics
                                            ; codes 161-191); drop that type-ahead so it can't open menus.
                                            ; Only fires when Caps was on - a normal launch keeps its type-ahead.
            if caps_kill(mods)
                caps_was_on = true
        }
    }

    sub caps_restore() {
        ; Exit: put Caps Lock back exactly as it was at launch. Only runs if caps_off() confirmed the
        ; address and actually cleared it, so it never writes on an unverified ROM.
        if not caps_was_on
            return
        cx16.push_rambank(0)
        @(KBD_SHFLAG) = @(KBD_SHFLAG) | MOD_CAPS
        cx16.pop_rambank()
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

    sub attn_frame() {
        ; 3-line attention box hugging the bottom of the screen: a top border on STATUS_ROW-2, the
        ; message/prompt row (STATUS_ROW-1) framed by │ side borders, and a bottom border on the
        ; footer row (STATUS_ROW). box_msg fills the middle and writes the text; g_attn marks it up so
        ; clear_attn (from draw_status) repaints the two covered text rows when the footer returns.
        ubyte top = STATUS_ROW - 2
        ubyte mid = STATUS_ROW - 1
        ubyte bot = STATUS_ROW
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setclr(c, top, theme.CB_BAR)
            txt.setchr(c, top, SC_H)
            txt.setclr(c, bot, theme.CB_BAR)
            txt.setchr(c, bot, SC_H)
        }
        txt.setchr(0, top, SC_TL)
        txt.setchr(SCR_W - 1, top, SC_TR)
        txt.setchr(0, bot, SC_BL)
        txt.setchr(SCR_W - 1, bot, SC_BR)
        txt.setclr(0, mid, theme.CB_BAR)
        txt.setchr(0, mid, SC_V)
        txt.setclr(SCR_W - 1, mid, theme.CB_BAR)
        txt.setchr(SCR_W - 1, mid, SC_V)
        g_attn = true
    }

    sub box_msg(str m, ubyte interior) {
        ; draw the attention box and put message/prompt `m` on its middle row, the interior filled in
        ; `interior` (theme.CB_BAR normally, a red/blink colour for a flash). Text is inset one cell
        ; from the │ side border. Replaces the old one-line bar_fill+put_str_at on the status row.
        attn_frame()
        ubyte mid = STATUS_ROW - 1
        ubyte c
        for c in 1 to SCR_W - 2 {
            txt.setclr(c, mid, interior)
            txt.setchr(c, mid, SPACE_SC)
        }
        put_str_at(2, mid, m)
    }

    sub clear_attn() {
        ; erase the attention box by repainting ONLY the two text rows it covered (the footer row is
        ; redrawn by draw_status itself) - never the whole screen, so Esc from a prompt doesn't
        ; flicker the document. Called from draw_status, so the box goes the instant the footer returns.
        if not g_attn
            return
        g_attn = false
        if not wrap_on {
            draw_text_row(TEXT_ROWS - 2)
            draw_text_row(TEXT_ROWS - 1)
            return
        }
        ; wrap: reflow the window with segment math to find (dl,seg) at each screen row, but RENDER
        ; only the last two rows (the ones the box sat on). The earlier rows are only walked, not drawn.
        ubyte tw = SCR_W - gutter_w
        uword dl = top_line
        ubyte seg = top_seg
        ubyte r = 0
        while r < TEXT_ROWS {
            if dl >= edoc.line_count {
                if r >= TEXT_ROWS - 2
                    draw_wrapped_row(r, dl, 0, 0, true, 0, 0)       ; blank row past end-of-document
                r++
            } else {
                ubyte llen = line_buf_len(dl)
                ubyte segend = wrap_next(g_wbuf, llen, seg, tw)
                if r >= TEXT_ROWS - 2
                    draw_wrapped_row(r, dl, seg, segend, seg == 0, g_wbuf, llen)
                if segend >= llen {
                    dl++
                    seg = 0
                } else {
                    seg = segend
                }
                r++
            }
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
        draw_gutter_dl(r, top_line + r, true, top_line + r == cur_row)
    }

    sub draw_gutter_dl(ubyte r, uword idx, bool shownum, bool hilite) {
        ; paint the gutter strip for screen row r showing doc line `idx`. shownum=false blanks the
        ; number (used for soft-wrap continuation rows, which share the line above's number).
        ; hilite mirrors the text band: whole line in unwrapped mode, cursor's visual row in wrap.
        if gutter_w == 0
            return
        ubyte sy = TEXT_TOP + r
        ubyte gcol = theme.CB_GUTTER
        if hilite
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
        ; UNWRAPPED rendering is the same operation as a wrap segment, with the "segment" set to
        ; the horizontal scroll window [left_col, left_col + textw). This used to be a second,
        ; ~85%-identical copy of draw_wrapped_row; it is now a wrapper. Kept as a named sub because
        ; eleven callers use it and `draw_text_row(r)` reads better than the 5-argument form.
        draw_wrapped_row(r, top_line + r, left_col, (left_col as uword) + (SCR_W - gutter_w), true, 0, 0)
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

    sub draw_wrapped_row(ubyte r, uword dl, uword cstart, uword cend, bool shownum,
                         uword pbuf, ubyte pblen) {
        ; THE row renderer: paint doc line `dl`'s column slice [cstart, cend) on screen row r -
        ; gutter, characters, body colour, selection, cursor. Both display modes come through here
        ; (see draw_text_row for the unwrapped wrapper), so a fix lands in both.
        ; pbuf = a line the CALLER has already staged, or 0 for "load it yourself".
        ubyte sy = TEXT_TOP + r
        ; resolve this row's source line once (the cursor row uses the live editbuf)
        ubyte blen = 0
        uword bufptr = 0
        if pbuf != 0 {
            bufptr = pbuf                   ; draw_all_text_wrapped has to load the line anyway to
            blen = pblen                    ; compute its wrap segments, so it hands it over rather
        } else if dl < edoc.line_count {    ; than have us load the same line a second time - that
            if dl == cur_row {              ; was one redundant BANKED read per visual row, and a
                bufptr = &editbuf           ; 3-segment line cost six loads to paint three rows
                blen = cur_len
            } else {
                blen = edoc.load(dl, &tmpbuf)
                bufptr = &tmpbuf
            }
        }
        ; syntax colouring: classify the whole line once into hlcol[] (one colour per doc
        ; column), then the cell loop reads it. Display-only; selection/cursor still override.
        if hl_on and blen != 0
            run_syntax(bufptr, blen)
        ubyte band = theme.CB_BAND & $f0        ; hoisted out of the cell loop: this and the
        bool bandrow = dl == cur_row            ; cur_row test were re-evaluated per cell before
        ; In wrap mode the band marks only the cursor's VISUAL row (the segment holding cur_col),
        ; not every row of a wrapped line - that is what lets a one-row scroll move the band by
        ; repainting just two rows (redraw_after_move) instead of the whole window.
        if bandrow and wrap_on
            bandrow = cur_col >= cstart and ((cur_col as uword) < cend or cend >= blen)
        if bandrow {
            cur_vseg = lsb(cstart)              ; this IS the cursor's visual row; record its segment
            cur_srow = r                        ; ...and its screen row, for the no-scroll fast path
        }
        draw_gutter_dl(r, dl, shownum, bandrow) ; line-number strip in cols [0, gutter_w)
        ubyte textw = SCR_W - gutter_w
        ; one column past the last character to draw. Wrap callers pass cend <= blen, so this is
        ; cend; the unwrapped wrapper passes the scroll-window end, which clamps to blen - the
        ; `srcidx < blen` test the separate unwrapped renderer used to do.
        uword vend = cend
        if (blen as uword) < vend
            vend = blen
        ; How many of this row's cells hold a character; the rest are padding. Deciding it ONCE is
        ; what keeps 16-bit arithmetic out of the hot loop: since vend <= blen <= 250, a row that
        ; draws anything has cstart < 250, so the source index and the hlcol index both fit a BYTE
        ; and the per-cell bounds test becomes a byte compare. (A uword srcidx here cost ~15% of
        ; wrap-mode scroll speed - it runs textw * TEXT_ROWS times per repaint.)
        ubyte nchar = 0
        if vend > cstart {
            uword avail = vend - cstart
            nchar = textw
            if avail < textw
                nchar = lsb(avail)
        }
        uword sp = bufptr + cstart              ; running source pointer - one 16-bit INC per cell
        ubyte si = lsb(cstart)                  ; hlcol index; valid whenever nchar != 0 (see above)
        ; Stream the row through VERA DATA0 with auto-increment: ONE address setup for the whole
        ; row, then two data writes per cell. txt.setchr/setclr each redo the full address dance
        ; (CTRL + 3 address registers) per call, and at 2 calls x 80 cells x 28 rows that latching
        ; WAS the repaint - wrap mode repaints everything on every cursor move and scrolled
        ; visibly slower than the key repeat rate. Text map stride is 256 bytes/row, cell = 2
        ; bytes (char, colour), same decode as vram_copy_row. Safe from mainline code: the
        ; KERNAL's vsync IRQ saves/restores the VERA address state it touches.
        ubyte mapb = cx16.VERA_L1_MAPBASE
        uword va = ((mapb & $7f) as uword) << 9
        va += (sy as uword) << 8
        va += (gutter_w as uword) << 1
        cx16.VERA_CTRL = 0                              ; ADDRSEL 0 -> ADDR0 / DATA0
        cx16.VERA_ADDR_L = lsb(va)
        cx16.VERA_ADDR_M = msb(va)
        cx16.VERA_ADDR_H = %00010000 | (mapb >> 7)      ; auto-increment 1 + bank bit
        ; single pass: each text cell gets its char + colour pushed through the data port
        ubyte c
        for c in 0 to textw - 1 {
            ubyte ch = SPACE_SC
            ubyte col = theme.CB_BODY
            if c < nchar {
                if theme.ISO_MODE
                    ch = iso_scr(@(sp))         ; ISO: ASCII byte -> shared-font screencode (chrome-safe)
                else
                    ch = txt.petscii2scr(@(sp))
                if hl_on
                    col = hlcol[si]
                sp++
                si++
            }
            if bandrow
                col = (col & $0f) | band        ; current-line band: theme bg, keep the fg
            cx16.VERA_DATA0 = ch
            cx16.VERA_DATA0 = col
        }
        ; selection highlight: cells whose doc column is in [c0, c1) on this row
        if sel_active {
            sel_norm()
            if dl >= s_row and dl <= e_row {
                uword c0 = 0
                if dl == s_row
                    c0 = s_col
                uword c1 = blen                 ; whole rest of line for non-end rows
                if dl == e_row
                    c1 = e_col
                ubyte cc = 0
                while cc < textw {
                    uword dcol = cstart + cc
                    if dcol >= c1 or dcol >= cend
                        break
                    if dcol >= c0
                        txt.setclr(gutter_w + cc, sy, theme.CB_MARK)
                    cc++
                }
            }
        }
        ; cursor cell. The reverse-block goes down whenever the underline SPRITE is NOT marking
        ; this cell: overtype, no sprite, or wrap mode (cursor_update turns the sprite off for the
        ; whole of wrap_on). In insert mode without wrap the cell is left alone so the sprite shows
        ; instead - that is what makes insert and overtype look different.
        if dl == cur_row and (cur_col as uword) >= cstart and (ovr_mode or not spr_ok or wrap_on) {
            bool oncur = (cur_col as uword) < cend
            if (cur_col as uword) == cend and cend >= blen
                oncur = true                    ; cursor at the very end of the last segment
            if oncur {
                ubyte ccol = lsb((cur_col as uword) - cstart)
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
                draw_wrapped_row(r, dl, 0, 0, true, 0, 0)   ; blank row past end-of-document
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
                draw_wrapped_row(r, dl, seg, segend, seg == 0, b, llen)  ; b/llen: already staged
                r++
                if segend >= llen {
                    dl++
                    seg = 0
                } else {
                    seg = segend
                }
            }
        }
        nxt_dl = dl                                         ; the first row that did NOT fit -
        nxt_seg = seg                                       ; ensure_visible_wrap tests against it
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

    sub ensure_visible_wrap() -> ubyte {
        ; keep the cursor's visual row on screen by moving (top_line, top_seg), and report HOW it
        ; moved so redraw_after_move can VRAM-scroll instead of full-repainting:
        ;   0 = didn't move (visible)   1 = advanced one row (down)   2 = retreated one row (up)
        ;   3 = far jump - full repaint required
        ; No load-walk: visibility is three compares against (nxt_dl, nxt_seg) - the first row below
        ; the window, which the last draw_all_text_wrapped recorded. (nxt) is not maintained here;
        ; the following repaint rebuilds it. g_cseg holds the cursor's segment for the band test.
        ubyte textw = SCR_W - gutter_w
        g_cseg = seg_start_of(&editbuf, cur_len, cur_col, textw)       ; cursor line = editbuf
        ubyte nseg = wrap_next(&editbuf, cur_len, g_cseg, textw)       ; end of the cursor's segment
        if cur_row < top_line or (cur_row == top_line and g_cseg < top_seg) {
            ; above the top. Exactly one visual row above (an upward scroll step) iff the row
            ; AFTER the cursor's is the current top - answerable from editbuf alone, no loads.
            if (nseg >= cur_len and cur_row + 1 == top_line and top_seg == 0)
               or (nseg < cur_len and cur_row == top_line and top_seg == nseg) {
                top_line = cur_row
                top_seg = g_cseg
                return 2
            }
            top_line = cur_row                  ; a far jump up -> pin cursor to the top row
            top_seg = g_cseg
            return 3
        }
        if cur_row < nxt_dl or (cur_row == nxt_dl and g_cseg < nxt_seg)
            return 0                            ; already visible
        if cur_row == nxt_dl and g_cseg == nxt_seg {
            ; one visual row below the bottom - a downward scroll step. Advance the top one visual
            ; row (advance_top, inlined here as its only caller), then keep nxt current: the fast
            ; path does NOT full-repaint, so nobody else rebuilds nxt, and a stale nxt would make the
            ; next down-step miss this test and fall back to a full repaint (the flicker). The
            ; cursor's row becomes the new bottom, so nxt is the row after the cursor's segment.
            ubyte tlen = line_buf_len(top_line)
            ubyte te = wrap_next(g_wbuf, tlen, top_seg, textw)
            if te >= tlen {
                top_line++
                top_seg = 0
            } else {
                top_seg = te
            }
            nxt_dl = cur_row
            nxt_seg = nseg
            if nseg >= cur_len {
                nxt_dl++
                nxt_seg = 0
            }
            return 1
        }
        top_line = cur_row                      ; a far jump down -> rebuild: cursor on the last
        top_seg = g_cseg                        ; row, walking the window backwards from it
        ubyte k = 0
        while k < TEXT_ROWS - 1 {
            retreat_top()
            k++
        }
        return 3
    }

    sub paint_wrapped_at(ubyte r, uword dl, ubyte seg) {
        ; fully repaint one visual row: doc line dl's segment at column seg, on screen row r. Loads
        ; dl (cursor line resolves to editbuf, no banked read). The scroll fast path uses it to
        ; repaint just the two rows whose current-line band changed.
        ubyte llen = line_buf_len(dl)
        ubyte e = wrap_next(g_wbuf, llen, seg, SCR_W - gutter_w)
        draw_wrapped_row(r, dl, seg, e, seg == 0, g_wbuf, llen)
    }

    sub vshift_up() {
        ; scroll the visible text window up one screen row in VRAM (both display modes use this)
        ubyte r
        for r in 0 to TEXT_ROWS - 2
            vram_copy_row(TEXT_TOP + r + 1, TEXT_TOP + r)
    }

    sub vshift_dn() {
        ; scroll it down one row - copied bottom-up so a row is read before it is overwritten
        ubyte r = TEXT_ROWS - 1
        while r != 0 {
            vram_copy_row(TEXT_TOP + r - 1, TEXT_TOP + r)
            r--
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
            ; wrap: adjust the visual top and report "scrolled" so every EDIT caller full-repaints.
            ; An edit can reflow the whole window, so a blanket repaint is the right answer for those.
            ; (redraw_after_move calls ensure_visible_wrap directly and uses its return code to
            ; VRAM-scroll a pure cursor move instead - that's the one caller that repaints less.)
            void ensure_visible_wrap()
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

    sub draw_sel_span() {
        ; Repaint just the screen rows the cursor swept while extending a selection.
        ; Extending only changes the row the cursor left (it now highlights to end of line)
        ; and the row it landed on; every other highlighted row is already correct on screen.
        ; This used to be a draw_all_text() -- one banked edoc.load and one run_syntax pass for every
        ; one of TEXT_ROWS rows (28 on the 80x30 screen EDIT sets) on every Shift+arrow, against the
        ; 2 rows an unshifted arrow costs. That ~14x is why marking text crawled.
        uword lo = cur_row
        uword hi = prev_cur_row
        if lo > hi {
            lo = prev_cur_row
            hi = cur_row
        }
        if lo < top_line
            lo = top_line
        uword last = top_line + TEXT_ROWS - 1
        if hi > last
            hi = last
        uword i = lo
        while i <= hi {
            draw_text_row(lsb(i - top_line))
            i++
        }
    }

    sub redraw_after_move() {
        ; Repaint after a cursor move as cheaply as the move allows:
        ;   * selection active        -> repaint only the rows the cursor swept
        ;   * no scroll                -> repaint only the old + new cursor rows
        ;   * scrolled by exactly 1    -> shift the text window in VRAM, repaint 1-2 rows
        ;   * scrolled further (PgUp/Dn)-> full repaint
        bool force_full = sel_cleared           ; a selection was just collapsed -> repaint every row once
        sel_cleared = false
        if wrap_on {
            ; A pure cursor move can't reflow the wrap segments (only edits do, and those go through
            ; ensure_visible/draw_all_text and full-repaint). So the band just moves between two visual
            ; rows: the one the cursor LEFT (band comes off) and the one it landed on (band on). Both a
            ; one-row scroll (VRAM window shift first) and an in-window move repaint exactly those two
            ; rows - no full redraw, no gutter redraw. The band marks only the cursor's visual row in
            ; wrap mode (draw_wrapped_row), which is what keeps it to two rows. An ACTIVE selection
            ; rides the same path: draw_wrapped_row paints each row's own selection span, and a single
            ; SHIFT+arrow only changes the highlight on the two edge rows (the one the cursor left, the
            ; one it landed on) - the rows already inside the selection don't change. Only a far jump
            ; (how 3) or a just-cleared selection (force_full) still full-repaints.
            ubyte how = ensure_visible_wrap()
            if force_full or how == 3 {
                draw_all_text()
                draw_status()
                return
            }
            ; A pure move only shifts the current-line band; repaint the row the cursor LEFT (band
            ; off) and the row it landed on (band on), never the whole window. The OLD visual
            ; position is exactly (prev_cur_row, cur_vseg) - line + segment recorded at the last paint.
            ubyte edge                          ; screen row of the cursor's NEW visual position
            ubyte oldrow                        ; screen row of its OLD position
            if how == 1 {                       ; scrolled down: window shifts up, new row at bottom
                vshift_up()
                edge = TEXT_ROWS - 1
                oldrow = TEXT_ROWS - 2
            } else if how == 2 {                ; scrolled up: window shifts down, new row at top
                vshift_dn()
                edge = 0
                oldrow = 1
            } else {
                ; how == 0: visible, no scroll. The OLD row is cur_srow (the renderer records it), so
                ; only the NEW cursor row is unknown - find it by walking the window from
                ; (top_line, top_seg) with segment math (no rendering). THIS is the in-window move
                ; that used to full-repaint the whole screen on every keypress (the slow scroll).
                oldrow = cur_srow
                ubyte tw = SCR_W - gutter_w
                uword wdl = top_line
                ubyte wseg = top_seg
                ubyte wr = 0
                edge = 255
                while wr < TEXT_ROWS and wdl < edoc.line_count {
                    if wdl == cur_row and wseg == g_cseg {
                        edge = wr
                        break
                    }
                    ubyte wl = line_buf_len(wdl)
                    ubyte we = wrap_next(g_wbuf, wl, wseg, tw)
                    if we >= wl {
                        wdl++
                        wseg = 0
                    } else {
                        wseg = we
                    }
                    wr++
                }
                if edge == 255 {                ; cursor not found in window (shouldn't happen) - safe
                    draw_all_text()
                    draw_status()
                    return
                }
            }
            if oldrow != edge
                paint_wrapped_at(oldrow, prev_cur_row, cur_vseg)    ; old cursor row, band removed
            paint_wrapped_at(edge, cur_row, g_cseg)                 ; new row, banded (sets cur_srow)
            prev_cur_row = cur_row
            draw_status()
            return
        }
        uword old_top = top_line
        ubyte old_left = left_col
        bool scrolled = ensure_visible()
        if force_full or left_col != old_left {
            ; a selection was just cleared, or a horizontal scroll changed every row
            draw_all_text()
            draw_status()
            return
        }
        if not scrolled {
            if sel_active {
                draw_sel_span()                 ; only the swept rows changed, not all 58
                prev_cur_row = cur_row
                draw_status()
                return
            }
            if prev_cur_row >= top_line and prev_cur_row < top_line + TEXT_ROWS
                draw_text_row(lsb(prev_cur_row - top_line))
            draw_text_row(lsb(cur_row - top_line))
            prev_cur_row = cur_row
            draw_status()
            return
        }
        if sel_active and cur_row != prev_cur_row + 1 and prev_cur_row != cur_row + 1 {
            ; scrolled AND jumped more than one row with a selection up: rows between the two
            ; positions changed highlight but the VRAM shift below only refreshes two of them
            draw_all_text()
            draw_status()
            return
        }
        if top_line == old_top + 1 {
            ; scrolled down one: text content moves up a row
            vshift_up()
            draw_text_row(TEXT_ROWS - 1)                ; new bottom row (holds the cursor)
            if prev_cur_row >= top_line and prev_cur_row < top_line + TEXT_ROWS
                draw_text_row(lsb(prev_cur_row - top_line))   ; clear the old cursor cell
        } else if old_top == top_line + 1 {
            ; scrolled up one: text content moves down a row
            vshift_dn()
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

    sub draw_menubar(ubyte active) {
        ; The menu bar's PAINTING (row 0: bar fill, titles, active highlight, accelerators, and the
        ; filename + A/B/C indicator that draw_filename_title used to do) lives in menus.ovl's mnu_bar
        ; now - it is cold, screen-only work, so exiling it reclaims ~0.5 KB of scarce low RAM. Pack
        ; the dynamic state into menuctx and hand it over; theme COLOURS ride along because the overlay
        ; has its own separate theme copy. menu_col/menu_len are static, so the overlay hardcodes the
        ; same columns while main keeps its copies for menu layout / hit-testing / dispatch.
        menuctx[0] = active
        ubyte f = 0
        if theme.show_dev
            f |= 1
        if modified
            f |= 2
        menuctx[1] = f
        menuctx[2] = theme.CB_BAR
        menuctx[3] = theme.CB_MENUSEL
        menuctx[4] = theme.ACCEL_FG
        menuctx[5] = g_active_slot
        ubyte sm = 0
        ubyte d
        for d in 0 to NDOCS - 1 {
            if slot_modified[d]
                sm |= (1 << d)
        }
        menuctx[6] = sm
        menuctx[7] = lsb(&filename)
        menuctx[8] = msb(&filename)
        mnu_bar(&menuctx)
    }

    sub draw_status() {
        clear_attn()                        ; footer is going back to normal -> erase the attention band
        bar_fill(STATUS_ROW, theme.CB_BAR)
        ubyte col = 1
        put_str_at(col, STATUS_ROW, "Line ")
        col += 5
        col = put_uw_at(col, STATUS_ROW, cur_row + 1)
        put_str_at(col, STATUS_ROW, "  Col ")
        col += 6
        col = put_uw_at(col, STATUS_ROW, cur_col + 1)
        ; INS/OVR + CAPS field. Drawn by menus.ovl (mnu_mode) to keep its strings/put_str_at out of low
        ; RAM. It returns the column just past the field (variable width - CAPS widens it when caps is on).
        col = mnu_mode(col, STATUS_ROW, ovr_mode as ubyte, upper_mode as ubyte, theme.ISO_MODE as ubyte)
        ; (the active-document ABC indicator used to sit here; it lives at the right end of the MENU
        ;  bar now, beside the filename. The col advances that reserved its width are gone with it, so
        ;  the "Total lines" guard below sees the extra 6 columns it freed.)
        ; right-side menu hint
        ubyte hint_col = SCR_W - 13
        put_str_at(hint_col, STATUS_ROW, "Esc/Alt=Menu")
        ; "Total lines <doc lines> of <slot capacity>", centered on the bar (drawn only if it clears the
        ; cursor info on the left and the menu hint on the right). A '*' sits 2 columns to its left when
        ; modified. NOT the current line (the gutter shows that) - this is the doc's size vs its cap.
        uword lcnt = edoc.line_count
        uword lmax = edoc.max_lines         ; active slot's cap: 6000 for Doc A, 2500 for B/C
        ubyte cdig = 1          ; (was an alias of the ABC loop's counter, which moved to the menu bar)
        uword t = lcnt
        while t >= 10 {
            cdig++
            t /= 10
        }
        ubyte tdig = 1
        t = lmax
        while t >= 10 {
            tdig++
            t /= 10
        }
        ubyte lwidth = 16 + cdig + tdig     ; "Total lines " (12) + count + " of " (4) + cap
        ubyte lstart = (SCR_W - lwidth) / 2 + 5      ; nudged 5 cols right of centre
        alias c2 = lwidth           ; reuse lwidth's byte (dead after the guard below) - saves scarce low RAM
        if lstart > col + 1 and lstart + lwidth < hint_col {
            if modified
                put_str_at(lstart - 2, STATUS_ROW, "*")     ; modified marker, 2 cols left of the block
            put_str_at(lstart, STATUS_ROW, "Total lines ")
            c2 = put_uw_at(lstart + 12, STATUS_ROW, lcnt)
            put_str_at(c2, STATUS_ROW, " of ")
            void put_uw_at(c2 + 4, STATUS_ROW, lmax)
        }
    }

    sub full_redraw() {
        g_attn = false                  ; clear_screen below erases the band; don't let draw_status redo it
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
        ; like wait_key, but ALT released with no key returns 0 (the main loop opens the menu on k==0).
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
            if (hold & MOD_CAPS) != 0 {     ; the Caps Lock key. caps_kill clears the KERNAL Caps bit (the
                if caps_kill(hold) {        ; menus need it gone). A SUCCESSFUL clear means the bit reads 0
                    upper_mode = not upper_mode ; next poll, so we flip our software caps EXACTLY ONCE per
                    draw_status()               ; press and show CAPS on the footer. If it can't clear (a ROM
                }                               ; where shflag moved) we don't flip - avoids a flicker loop.
                hold &= (255 - MOD_CAPS)
            }
            if (hold & MOD_ALT) != 0 {
                if theme.ISO_MODE {
                    iso_alt_menu()          ; ISO: read the C=+letter accelerator under a temporary
                    cursor_update()         ; PETSCII keyboard decode, open that menu, restore ISO decode
                    continue                ; then wait for the next real key
                }
                alt_was = true              ; PETSCII: ALT held - wait to see if a letter chord follows
            } else {
                if alt_was {                ; ALT released with no key -> return 0 = "open the menu". 0 is
                    alt_was = false         ; never a real key here, so no collision (unlike the old 200 = 'H').
                    return 0
                }
            }
        }
    }

    sub draw_ww_label(bool live) {
        ; whole-word indicator on the right of the search box's middle row (STATUS_ROW-1). Only the
        ; read-only live=false reminder is used from main now - the Find/Replace INPUT prompts run in
        ; misc.ovl and carry their own live toggle. The right margin clears the box's │ side border.
        ubyte row = STATUS_ROW - 1
        if live {
            ubyte c = SCR_W - 16            ; "Whole Word  Off" = 15 chars + a 1-col right margin
            if ww_on
                put_str_at(c, row, "Whole Word  On ")
            else
                put_str_at(c, row, "Whole Word  Off")
            txt.setclr(c, row, (theme.CB_BAR & $f0) | theme.ACCEL_FG)   ; highlight the W accelerator
        } else {
            if not ww_on
                return
            put_str_at(SCR_W - 11, row, "Whole Word")       ; 10 chars + a 1-col right margin
        }
    }

    ; prompt_str flags. These used to be two bool parameters; folding them into one byte made room
    ; for the history category at no cost (one ubyte param replacing two bools is a byte CHEAPER -
    ; prog8 has no call stack, so every parameter is permanently allocated low RAM).
    const ubyte PF_EMPTY = 1            ; accept an empty entry
    const ubyte PF_WW    = 2            ; show the whole-word label; Commodore+W toggles it live
    const ubyte PF_FIND  = $10          ; ---- history category, bits 4-7. No category = no history:
    const ubyte PF_REPL  = $20          ;      Go-to-line (a line number is faster to retype than to
                                        ;      arrow back to) and Save As (its name comes from the
                                        ;      document, and the file picker is the way back to an
                                        ;      old one) both pass 0.

    sub prompt_str(str promptmsg, uword dest, ubyte maxlen, ubyte flags) -> bool {
        ; modal text input on the status row. Enter -> true (false if empty and not PF_EMPTY);
        ; Esc/Stop -> false. Pre-fills with whatever is already in dest. See the PF_* consts above.
        ; The body lives in misc.ovl (ovl_prompt) to save low RAM - this wrapper hides the editor cursor
        ; and JSRFARs in. All state (dest, promptmsg, ww_on) is low RAM the overlay reads through
        ; pointers. misc.ovl is guaranteed present (start() halts if any overlay is missing).
        cursor_sprite_off()                     ; hide the editor cursor for the modal (was in wait_key)
        g_attn = true                           ; ovl_prompt draws the 3-line box; mark it so a later
                                                ; draw_status / full_redraw repaints the rows it covered
        if ovl_prompt(promptmsg, dest, maxlen, flags, theme.current, &ww_on) != 0
            return true
        ; Cancelled (Esc, or Enter on an empty line when allow_empty is off). Restore the footer here
        ; rather than in each caller: the prompt text was sitting on the status row, and callers
        ; reached by a HOTKEY (F6 Find, F8 Replace, Ctrl+J) have no menu_dispatch repaint behind them,
        ; so the dead prompt stayed on the bar until the next cursor move repainted it.
        draw_status()
        return false
    }

    sub flash_status(str m) {
        ; briefly show the prompt box before the caller settles it. RED flash disabled for the moment
        ; (user request) - draw the box in the normal bar colour instead of the red attention flash.
        ; box_msg(m, $21)                              ; RED flash (rem'd out for now)
        box_msg(m, theme.CB_BAR)
        sys.wait(18)                                    ; ~0.3s
    }

    sub halt_no_ovl(str ovlname) {
        ; A REQUIRED overlay is missing -> name it and stop, rather than run degraded. Called only
        ; from start(), before the fkey hijack / document setup, so returning from start() is a clean
        ; exit: just put the screen mode + charset back the way we found them. Message built in
        ; workbuf (idle at startup). The overlays are not optional - EDIT's menus, dialogs, prompts,
        ; viewer and syntax tables all live in them - so a missing one is fatal, not a soft downgrade.
        void strings.copy(ovlname, &workbuf)
        void strings.copy(" missing - reinstall. Press a key.", &workbuf + strings.length(ovlname))
        txt.clear_screen()
        put_str_at(1, 1, &workbuf)
        void wait_key()
        cx16.set_screen_mode(saved_mode)        ; restore the mode + charset we changed at entry
        restore_machine_state()
        caps_restore()                          ; and Caps Lock - this IS an exit path (returns from start),
                                                ; so it bypasses the caps_restore in start()'s normal tail
        txt.clear_screen()
    }

    sub confirm_save() -> ubyte {
        ; 0 = don't save, 1 = save, 2 = cancel. Flash the prompt so it isn't missed on the status
        ; row - users overlooked the silent bar and thought Open did nothing.
        flash_status(msg(MSG_SAVECHG))
        box_msg(msg(MSG_SAVECHG), theme.CB_BAR)              ; settle to the normal box, stays readable
        repeat {
            ubyte k = wait_key()
            if theme.ISO_MODE {
                if k >= $61 and k <= $7a
                    k -= $20
            } else {
                if k >= $c1 and k <= $da
                    k -= $80
            }
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
        flash_status(msg(MSG_OVERWRITE))
        box_msg(msg(MSG_OVERWRITE), theme.CB_BAR)
        repeat {
            ubyte k = wait_key()
            if theme.ISO_MODE {
                if k >= $61 and k <= $7a
                    k -= $20
            } else {
                if k >= $c1 and k <= $da
                    k -= $80
            }
            when k {
                'y' -> return true
                'n', 27, 3 -> return false
            }
        }
    }

    sub msg(ubyte id) -> uword {
        ; fetch cold status-bar text id from misc.ovl into msgbuf and return its address, so callers
        ; read `notify(msg(MSG_X))` in place of `notify("literal")`. misc.ovl is REQUIRED (start()
        ; halts if it is missing), so it is always mapped-in by the time any msg() runs.
        msg_text(id, &msgbuf)
        return &msgbuf
    }

    sub status_msg(str m) {
        ; paint a transient message in the attention box with NO delay - used for progress
        ; hints ("Saving..."/"Loading...") right before a slow operation that will repaint
        box_msg(m, theme.CB_BAR)
    }

    sub notify(str m) {
        status_msg(m)
        sys.wait(60)
    }

    sub notify_full() {
        ; the "Document full - save now" toast has five callers (edit.p8's edoc.commit /
        ; insert_line failure sites); one shared tail interns the 25-byte literal once instead of
        ; five times. Same shared-tail trick as halt_no_ovl's message building.
        notify(msg(MSG_DOCFULL))
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


    ; ---------- dropdown menus ----------

    sub menu_flags() -> ubyte {
        ; pack the states menus.ovl needs for its dynamic item labels:
        ; bit0 = word wrap, bit1 = syntax colour, bit2 = line numbers, bit3 = Dev menu shown,
        ; bit4 = a .EDIT.SESSION exists (Dev item shows Delete vs Create), bit5 = active doc is ISO.
        ; (when Dev is hidden, the Help menu also drops its BASLOAD + Hints-Tips items and compacts).
        ubyte f = 0
        if wrap_on
            f |= 1
        if hl_on
            f |= 2
        if ln_on
            f |= 4
        if theme.show_dev
            f |= 8
        if session_on
            f |= 16
        if theme.ISO_MODE
            f |= 32
        return f
    }

    sub help_logical(ubyte i) -> ubyte {
        ; map a DISPLAYED Help-menu row to its logical action index. When Dev is hidden the two Dev-only
        ; items - BASLOAD (logical 1) and Hints-Tips (logical 2) - are removed, so displayed rows 1..
        ; shift up past both of them.
        if not theme.show_dev and i >= 1
            return i + 2
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

    const ubyte WIN_NAME_MAX = 16       ; Window menu: max filename chars shown after "A - "
    ; winname (was a str*16 module buffer here): the doc name being drawn now aliases tmpbuf inside
    ; window_doc_name + draw_window_item. Both alias the SAME buffer, so the name one writes the other
    ; reads; the Window menu draws modally so tmpbuf (render scratch) isn't live then. Saves 16 B low RAM.

    sub window_doc_name(ubyte slot) {
        ; copy slot's filename (truncated to WIN_NAME_MAX, NUL-terminated) into winname. The ACTIVE slot's
        ; name is live in `filename`; the two INACTIVE slots keep theirs in their context block in CLIP_BANK
        ; (frozen while a doc is inactive), so read those straight from the bank.
        alias winname = tmpbuf              ; shared render scratch (see the note above the sub)
        ubyte j = 0
        if slot == g_active_slot {
            while filename[j] != 0 and j < WIN_NAME_MAX {
                winname[j] = filename[j]
                j++
            }
        } else {
            uword src = CTX_BASE + (slot as uword) * CTX_SIZE + CTX_FNAME_OFF
            cx16.push_rambank(CLIP_BANK)
            while j < WIN_NAME_MAX {
                ubyte ch = @(src + j)
                if ch == 0
                    break
                winname[j] = ch
                j++
            }
            cx16.pop_rambank()
        }
        winname[j] = 0
    }

    sub draw_window_item(ubyte i, ubyte col, ubyte row) {
        ; paint one Window-menu row. Item 0 = "Next"; items 1..3 = documents A/B/C (slot i-1): the slot's
        ; filename, or "Open" when it has no file loaded. Drawn here (not the banked menus.ovl) because the
        ; inactive docs' names live in CLIP_BANK, which the $A000 overlay cannot map.
        alias winname = tmpbuf              ; same buffer window_doc_name fills (see its note)
        if i == 0 {
            put_str_at(col, row, "Next         F7")
            return
        }
        ubyte slot = i - 1
        when slot {
            0 -> put_str_at(col, row, "A - ")
            1 -> put_str_at(col, row, "B - ")
            else -> put_str_at(col, row, "C - ")
        }
        window_doc_name(slot)
        if winname[0] == 0
            put_str_at(col + 4, row, "Open")
        else
            put_str_at(col + 4, row, winname)
    }

    sub draw_dropdown_item(ubyte active, ubyte x0, ubyte x1, ubyte i, ubyte sel) {
        ; paint ONE dropdown item row in its current selected/unselected state. Used both by the
        ; full draw and by the up/down navigation, which repaints only the two rows that change.
        ubyte row = dropdown_row(active, i)
        ubyte base = theme.CB_BAR
        set_color_run(x0 + 1, x1 - 1, row, theme.CB_BAR)
        if active == WINDOW_MENU
            draw_window_item(i, x0 + 2, row)                    ; dynamic A/B/C doc names - drawn by main
        else if menus_ok
            mnu_item(active, i, x0 + 2, row, menu_flags())      ; item label text lives in menus.ovl
        if i == sel {
            set_color_run(x0 + 1, x1 - 1, row, theme.CB_MENUSEL)   ; selected row: reverse so it pops
            base = theme.CB_MENUSEL
        }
        ; recolour just the accelerator letter (keep the row's bg) - drawn last so it
        ; survives the selection fill
        txt.setclr(x0 + 2 + mnu_accel(1, active, i, theme.show_dev as ubyte), row, (base & $f0) | theme.ACCEL_FG)
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
            0 -> return 7       ; File: document actions (New..Close All) | Exit
            1 -> return 8       ; Edit: line ops (Undo..Move Down) | display toggle (Word Wrap)
            3 -> return 6       ; Dev:  actions (Run BASLOAD, Make Backup, Delete SYM, comment ops, Session file) | toggles (Syntax, Line#)
            WINDOW_MENU -> return 0   ; Window: Next | documents A/B/C
        }
        return 255
    }

    sub run_dropdown(ubyte active) -> ubyte {
        ; returns the chosen item index, or 255=esc, 254=prev menu, 253=next menu
        ubyte n = 5                         ; Help default: Keyboard/BASLOAD/Hints-Tips/Config/About (Dev shown)
        ubyte boxw = 13                     ; Help ("Help... F1/BASLOAD.../Hints-Tips/Config.../About")
        when active {
            0 -> { n = 9  boxw = 17 }       ; File ("Open...    Ctrl+O")
            1 -> { n = 10  boxw = 22 }      ; Edit ("Paste        Ctrl+V/F4")
            2 -> { n = 4  boxw = 21 }       ; Search ("Replace...  Ctrl+R/F8")
            3 -> { n = 10  boxw = 22 }      ; Dev ("Uncomment Block Ctrl+W" / "Encoding     PETSCII")
            WINDOW_MENU -> { n = 4  boxw = 20 }   ; Window (Next + docs A/B/C: "A - <name>")
        }
        if active == 5 and not theme.show_dev
            n = 3                           ; Dev hidden -> Help drops BASLOAD + Hints-Tips, leaving Help/Config/About
        ubyte x0 = menu_col[active] - 1
        ubyte y0 = 1
        ubyte x1 = x0 + boxw + 3
        if x1 > SCR_W - 1 {                 ; safety: keep a wide dropdown box on screen
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
            if theme.ISO_MODE {
                if k >= $61 and k <= $7a
                    k -= $20
            } else {
                if k >= $c1 and k <= $da
                    k -= $80
            }
            ubyte acc = mnu_accel(0, active, k, theme.show_dev as ubyte)   ; letter accelerator activates the item
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
                    ; Save / Save As draw on the status row only, and erase_dropdown() has already
                    ; repainted the menu bar and the rows the dropdown covered - so claim g_redrawn
                    ; and skip the blanket full_redraw() below (a visible full-screen flash for a
                    ; save). Scoped to the menu path on purpose: save_now() has six other callers,
                    ; several of which DO need the repaint. Save All is not here - it calls
                    ; goto_slot(), which changes the text area, and does its own full_redraw().
                    3 -> {
                        void save_now()
                        g_redrawn = true
                        draw_status()
                    }
                    4 -> {
                        act_save_as()
                        g_redrawn = true
                        draw_status()
                    }
                    5 -> act_save_all()
                    6 -> act_new()          ; Close: the slots are fixed, so "closed" means "emptied" -
                                            ; that is exactly act_new. Listed separately because the
                                            ; menu should say what the user is trying to do.
                    7 -> act_close_all()
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
                    2 -> act_delete_sym()       ; delete every *.SYM in the cwd (code lives in picker.ovl)
                    3 -> comment_apply(0)       ; toggle REM comment on the current line
                    4 -> comment_apply(1)       ; comment the selected block (add REM)
                    5 -> comment_apply(2)       ; uncomment the selected block (strip REM)
                    6 -> act_session_toggle()   ; create/delete the per-folder .EDIT.SESSION (picker.ovl)
                    7 -> hl_on = not hl_on      ; toggle syntax colouring (menu_mode_loop repaints)
                    8 -> ln_on = not ln_on      ; toggle the line-number gutter (repaints on close)
                    else -> act_toggle_mode()   ; flip the active doc PETSCII<->ISO (also bound to Ctrl+F7)
                }
            }
            WINDOW_MENU -> {                ; Window
                when choice {
                    0 -> switch_doc()                       ; Next: cycle A->B->C->A
                    else -> act_window_goto(choice - 1)     ; A/B/C -> slot 0/1/2 (opens the picker if empty)
                }
            }
            else -> {                       ; Help (choice is a displayed row; map past hidden Dev-only items)
                when help_logical(choice) {
                    0 -> act_keymap()
                    1 -> act_basload_help()
                    2 -> act_hints_help()
                    3 -> act_config()
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

    ; ---------- multiple-document context swap ----------

    sub point_storage(ubyte slot) {
        ; retarget the storage layer at slot's banks (table base + line cap + content bounds). Does NOT
        ; touch the xarena bump POSITION - that is restored from the context (or reset by edoc.init).
        edoc.tbl_first_bank = SLOT_TBL_BASE[slot]
        edoc.max_lines      = SLOT_MAX_LINES[slot]
        xarena.set_bounds(slot_arena_lo[slot], slot_arena_hi[slot])
    }

    sub docs_layout() {
        ; carve the content banks (CONTENT_FIRST_BANK..max_bank) into three sub-ranges, sized roughly
        ; proportional to the per-doc caps (weights 12:5:5 ~ 6000:2500:2500). Once, at startup, after
        ; detect_banks() clamps max_bank to the RAM installed.
        uword total = (xarena.max_bank - CONTENT_FIRST_BANK + 1) as uword
        ubyte na = lsb(total * 12 / 22)
        ubyte nb = lsb(total * 5 / 22)
        slot_arena_lo[0] = CONTENT_FIRST_BANK
        slot_arena_hi[0] = CONTENT_FIRST_BANK + na - 1
        slot_arena_lo[1] = CONTENT_FIRST_BANK + na
        slot_arena_hi[1] = CONTENT_FIRST_BANK + na + nb - 1
        slot_arena_lo[2] = CONTENT_FIRST_BANK + na + nb
        slot_arena_hi[2] = xarena.max_bank
    }

    sub ctx_field(uword addr, ubyte n, bool saving) {
        ; copy n bytes between low-RAM `addr` and the context bank at g_ctxp (CLIP_BANK must be mapped)
        ubyte i = 0
        while i < n {
            if saving
                @(g_ctxp) = @(addr)
            else
                @(addr) = @(g_ctxp)
            g_ctxp++
            addr++
            i++
        }
    }

    sub ctx_xfer(ubyte slot, bool saving) {
        ; gather (saving=true) or scatter (false) every per-document field to/from slot's context block.
        ; A single (address,length) TABLE drives both directions (so save and load can never disagree)
        ; AND keeps the code small - 42 inline ctx_field calls cost ~500 bytes of scarce low RAM; the
        ; table is ~126 bytes of data plus one loop.
        g_ctxp = CTX_BASE + (slot as uword) * CTX_SIZE
        cx16.push_rambank(CLIP_BANK)
        ubyte fi
        for fi in 0 to NCTXF - 1
            ctx_field(CTX_ADDR[fi], CTX_LEN[fi], saving)
        cx16.pop_rambank()
    }

    sub save_ctx(ubyte slot) {
        ctx_xfer(slot, true)
        slot_modified[slot] = modified      ; cache for the status-bar A/B/C indicator
    }

    sub load_ctx(ubyte slot) {
        ctx_xfer(slot, false)           ; restores globals incl. the xarena bump position
        point_storage(slot)             ; retarget table base + line cap + arena bounds
    }

    sub blank_slot() {
        ; a fresh empty untitled document on the currently-pointed storage slot, all per-doc state at
        ; defaults (superset of new_document for the extra context fields new_document leaves alone).
        new_document()
        top_seg = 0
        prev_cur_row = 0
        ovr_mode = false
        sel_active = false
        sel_cleared = false
        anc_row = 0
        anc_col = 0
        found_row = 0
        found_col = 0
        g_group = 0
        ln_on = false
        gutter_w = 0
        wrap_on = false
        hl_on = false
        hl_mode = HL_BASIC
        theme.ISO_MODE = false          ; fresh slots start in PETSCII (New = PETSCII)
    }

    sub init_doc_slots() {
        ; slot 0 already holds the launched/new document. Build empty slots 1..NDOCS-1, save each, then
        ; restore slot 0 as active. Called once at startup, after slot 0's document exists.
        save_ctx(0)
        ubyte s
        for s in 1 to NDOCS - 1 {
            point_storage(s)
            blank_slot()
            save_ctx(s)
        }
        load_ctx(0)
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
    }

    sub act_toggle_mode() {
        ; Flip the ACTIVE doc's PETSCII/ISO mode. Reached from the Dev menu ("Encoding") and Ctrl+F7.
        ; RE-ENCODES the buffer so the displayed text stays visually stable across the switch (case is
        ; preserved, keywords keep colouring) instead of the same bytes being reinterpreted. ISO->PETSCII
        ; is lossy for { } \ | ~ (no PETSCII glyph - they survive as raw bytes but show as graphics).
        commit_editbuf()                        ; flush the live line into the arena (still old encoding)
        bool to_iso = not theme.ISO_MODE        ; the mode we are switching TO
        edoc.recode(to_iso)                     ; convert every committed line in place
        theme.ISO_MODE = to_iso
        cur_len = edoc.load(cur_row, &editbuf)  ; reload the live line in the NEW encoding
        cur_dirty = false
        undo_clear()                            ; snapshots are old-encoding far pointers - drop them
        apply_charset_mode()                    ; reconfigure font/keyboard for the new mode
        full_redraw()
    }

    sub apply_charset_mode() {
        ; Per-doc mode switch (per-doc theme.ISO_MODE, loaded on every doc switch). Key idea: the DISPLAY
        ; always uses the PETSCII upper/lower FONT (charset 3) - its screencode layout renders every piece
        ; of chrome + UI text, and iso_scr maps an ISO doc's ASCII bytes onto it (incl the { } \ | ~ glyphs
        ; patched in by font_setup). Only the KEYBOARD decode differs per mode. screen_set_charset MUST be
        ; called (it sets KERNAL `mode` + reloads the font glyphs; skipping it left the charset/keyboard
        ; state half-initialized -> wrong chars + lockup). ISO: set $0372 bit $40 + EXTAPI (iso_cursor_char
        ; $9f) so keys emit ASCII { } \ | ~; PETSCII: clear bit $40 (no EXTAPI, per ROM). cmt_prefix follows.
        cx16.screen_set_charset(5, 0)      ; THIN PETSCII upper/lower font in BOTH modes (reloads glyphs)
        font_xfer(false)                   ; re-stamp the { } \ | ~ glyphs the reload just wiped
        if theme.ISO_MODE {
            %asm {{
                lda  $0372
                ora  #$40
                sta  $0372
                clc
                ldx  #$9f
                lda  #$05
                jsr  $feab
            }}
            cmt_prefix[0] = $52            ; "REM " as ASCII
            cmt_prefix[1] = $45
            cmt_prefix[2] = $4d
        } else {
            %asm {{
                lda  $0372
                and  #$bf
                sta  $0372
            }}
            cmt_prefix[0] = $d2            ; "REM " in shifted PETSCII
            cmt_prefix[1] = $c5
            cmt_prefix[2] = $cd
        }
        sys.disable_caseswitch()           ; keep the display charset locked (Shift+C= can't flip it)
    }

    ; Screencode slots for the five ISO-only glyphs in the shared PETSCII-superset font. These are
    ; free graphics slots (NOT used by the box-draw chrome: SC_H $40, SC_V $5d, SC_VR $6b, SC_BL $6d,
    ; SC_TR $6e, SC_TL $70, SC_VL $73, SC_BR $7d, SC_UP $1e) and never produced by petscii2scr for any
    ; normal document byte, so font_setup can patch the { } \ | ~ glyphs there without disturbing chrome.
    const ubyte SC_LBRACE = $5b            ; {
    const ubyte SC_PIPE   = $5c            ; |
    const ubyte SC_BSLASH = $1c            ; backslash
    const ubyte SC_TILDE  = $5e            ; ~
    const ubyte SC_RBRACE = $5f            ; }  (NOT its natural $5d, which is the box vertical rail)

    sub iso_scr(ubyte b) -> ubyte {
        ; ISO document display: map a stored ASCII byte to a screencode in the shared PETSCII-superset
        ; font. Letters fold to the SAME slots a PETSCII doc uses (via a2p-then-petscii2scr), so ordinary
        ; text renders identically in both modes; the five ISO-only chars { } \ | ~ (no PETSCII code of
        ; their own) go to the custom glyph slots above. (`_` and backtick are not in the glyph set, so
        ; they fall through to their PETSCII look - left-arrow / box-edge - a known limit.)
        when b {
            $7b -> return SC_LBRACE        ; {
            $7c -> return SC_PIPE          ; |
            $7d -> return SC_RBRACE        ; }
            $7e -> return SC_TILDE         ; ~
            $5c -> return SC_BSLASH        ; backslash
        }
        ubyte p = b
        if b >= $41 and b <= $5a
            p = b + $80                    ; ASCII A-Z -> PETSCII $C1-$DA (uppercase glyphs)
        else if b >= $61 and b <= $7a
            p = b - $20                    ; ASCII a-z -> PETSCII $41-$5A (lowercase glyphs)
        return txt.petscii2scr(p)
    }

    ; --- ISO glyph patch. The shared display font is thin PETSCII (charset 5); these routines stamp the
    ; five ISO-only glyphs { } \ | ~ into the free screencode slots iso_scr maps them to, so ISO docs show
    ; them. The bitmaps are captured ONCE from the ROM thin ISO font (font_setup) and re-stamped after every
    ; screen_set_charset(5) reload (font_patch, from apply_charset_mode). The X16 charset lives at VRAM
    ; $1F000 (the default L1 tilebase, which EDIT never moves); glyph N is 8 bytes at $1F000 + N*8.
    const uword FONT_VADDR = $f000         ; low 16 bits of the charset VRAM base ($1F000)
    const ubyte FONT_A16   = $01           ; bit 16 of $1F000
    ubyte[40] iso_glyphs                    ; 5 captured 8-byte glyphs, order: { } \ | ~
    ubyte[5]  g_src = [$7b, $7d, $5c, $7c, $7e]                    ; ISO-font source slots
    ubyte[5]  g_dst = [SC_LBRACE, SC_RBRACE, SC_BSLASH, SC_PIPE, SC_TILDE]   ; display-font dest slots

    sub vera_glyph_addr(ubyte slot) {
        ; point VERA DATA0 (auto-increment +1) at charset glyph `slot`
        cx16.VERA_CTRL = 0
        cx16.VERA_ADDR_L = lsb(FONT_VADDR + (slot as uword) * 8)
        cx16.VERA_ADDR_M = msb(FONT_VADDR + (slot as uword) * 8)
        cx16.VERA_ADDR_H = %00010000 | FONT_A16
    }

    sub font_xfer(bool capture) {
        ; capture=true : read the 5 ISO glyphs from the (ISO) font VRAM into iso_glyphs.
        ; capture=false: stamp iso_glyphs into the display font's free slots (the { } \ | ~ patch).
        ubyte i
        for i in 0 to 4 {
            if capture
                vera_glyph_addr(g_src[i])
            else
                vera_glyph_addr(g_dst[i])
            uword p = &iso_glyphs + (i as uword) * 8
            ubyte j
            for j in 0 to 7 {
                if capture
                    @(p) = cx16.VERA_DATA0
                else
                    cx16.VERA_DATA0 = @(p)
                p++
            }
        }
    }

    sub font_setup() {
        ; Capture { } \ | ~ from the ROM THIN ISO font (charset 6, ASCII-ordered: glyph N = char code N),
        ; once at boot - thin so the patched glyphs match the thin display font. Restores the thin PETSCII
        ; display font before returning (apply_charset_mode reloads it anyway).
        cx16.screen_set_charset(6, 0)          ; thin ISO font into the charset VRAM
        font_xfer(true)
        cx16.screen_set_charset(5, 0)          ; restore the thin PETSCII display font
    }

    sub kbd_decode_petscii() {
        ; Flip ONLY the KERNAL keyboard decode back to PETSCII by clearing the ISO flag ($0372 bit $40).
        ; The ISO FONT is untouched (no screen_set_charset), so the screen still shows ISO glyphs; only
        ; how keys are decoded changes. Used briefly while C= is held so a C=+letter chord delivers the
        ; PETSCII graphics code 161-191 that alt_letter maps to a menu letter.
        %asm {{
            lda  $0372
            and  #$bf
            sta  $0372
        }}
    }

    sub kbd_decode_iso() {
        ; Restore ISO keyboard decode (ISO flag + EXTAPI) after kbd_decode_petscii, so typing { } \ | ~
        ; works again. Same sequence apply_charset_mode uses for ISO, minus the font load (already ISO).
        %asm {{
            lda  $0372
            ora  #$40
            sta  $0372
            clc
            ldx  #$9f
            lda  #$05
            jsr  $feab
        }}
    }

    sub iso_alt_menu() {
        ; ISO-mode menu open. In ISO the KERNAL keymap turns C= into a compose modifier, so a C=+letter
        ; chord never delivers a decodable menu letter. Trick: flip only the keyboard decode to PETSCII
        ; (the ISO font stays), so C=+letter now arrives as a graphics code 161-191 we CAN map - giving
        ; real Alt+E / Alt+W. We enter here having just seen C= held with nothing in the buffer yet, so
        ; the flip lands before the letter is decoded. Falls back to the menu bar (m=0) if C= is released
        ; with no letter, or if a non-accelerator arrives. Restores ISO decode before opening the menu so
        ; the dropdown accelerators (which use the ISO fold) and later text typing behave normally.
        kbd_decode_petscii()
        ubyte m = 0
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0 {
                if k >= 161 and k <= 191 {
                    ubyte mm = mnu_accel(2, 0, alt_letter[k - 161], theme.show_dev as ubyte)
                    if mm != 255
                        m = mm
                }
                break
            }
            if (cx16.kbdbuf_get_modifiers() & MOD_ALT) == 0
                break                       ; C= released with no letter -> open the bar (m stays 0)
        }
        kbd_decode_iso()
        menu_mode_loop(m)
    }

    sub switch_doc() {
        ; F7: cycle A->B->C->A. Flush the live line, save the active context, bring up the next doc.
        commit_editbuf()
        save_ctx(g_active_slot)
        g_active_slot++
        if g_active_slot >= NDOCS
            g_active_slot = 0
        load_ctx(g_active_slot)
        apply_charset_mode()            ; this doc may be a different mode than the one we left
        cur_len = edoc.load(cur_row, &editbuf)
        cur_dirty = false
        full_redraw()
    }

    sub goto_slot(ubyte target) {
        ; cycle forward until `target` is the active doc (switch_doc only advances). No-op if already there.
        while g_active_slot != target
            switch_doc()
    }

    sub act_window_goto(ubyte slot) {
        ; Window menu: make `slot` the active document. If that doc has no file loaded (untitled), drop
        ; straight into the Open picker so the "Open" row does what it says.
        goto_slot(slot)
        if filename[0] == 0
            act_open()
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

    sub pick_theme() -> ubyte {
        ; the theme id handed to the picker, with bit7 = Dev-menu-shown. The picker's Basl filter is a
        ; Dev feature, so it rides with the menu: hidden when the Dev menu is off. theme.current is 1..3,
        ; so the high bit is free to carry the flag.
        ubyte t = theme.current
        if theme.show_dev
            t |= $80
        return t
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
        cursor_sprite_off()             ; the overlay owns the screen: hide our cursor sprite
        if pick(&fnbuf, pick_theme(), &pick_blocks) == 0 {
            full_redraw()
            return
        }
        full_redraw()                   ; hide the Open popup before the load
        status_msg("Loading...")        ; box only - no red flash (user request); load repaints after
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
            ; the file opened but ran past this doc's line cap (edoc.max_lines: 6000 for A, 2500 for
            ; B/C; load_file truncated it and set oom). Refuse it rather than show a truncated half:
            ; load_file already filled the arena with the partial content, so reset to a fresh empty
            ; document and tell the user it was not loaded.
            new_document()
            notify(msg(MSG_TOOBIG))
        } else {
            notify(msg(MSG_OPENERR))
        }
        refresh_session_on()            ; the picker may have chdir'd into another folder
        full_redraw()                   ; repaint (needed when invoked via hotkey)
    }

    sub do_save(str name) -> bool {
        commit_editbuf()
        savebuf[0] = '@'
        savebuf[1] = ':'
        void strings.copy(name, &savebuf + 2)
        status_msg("Saving...")                 ; box only - no red blink; disk write repaints after
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
            if not prompt_str("Save as:", &fnbuf, 38, 0) or fnbuf[0] == 0 {
                flash_notify(msg(MSG_SAVECAN))
                return false
            }
            fold_str(&fnbuf)                    ; typed upper case -> the $41-$5A filenames use
            if not confirm_overwrite(fnbuf)     ; new name -> guard against clobbering a file
                return false
            void strings.copy(fnbuf, filename)
        }
        return do_save(filename)
    }

    sub act_save_as() {
        fnbuf[0] = 0
        if not prompt_str("Save as:", &fnbuf, 38, 0) or fnbuf[0] == 0 {
            notify(msg(MSG_SAVECAN))            ; Esc or Enter-on-blank-line -> cancel, with feedback
            return
        }
        fold_str(&fnbuf)                        ; typed upper case -> the $41-$5A filenames use
        if not confirm_overwrite(fnbuf)         ; guard against clobbering an existing file
            return
        void strings.copy(fnbuf, filename)
        void do_save(filename)
    }

    sub act_save_all() {
        ; Save the active document plus every OTHER document with unsaved edits. The view switches to each
        ; doc it saves (so an untitled doc's "Save as:" prompt shows the right document), then returns to
        ; the doc we started on. slot_modified[] flags the two inactive docs (they are frozen while away).
        ubyte start_slot = g_active_slot
        bool any = modified
        if modified
            void save_now()
        ubyte s
        for s in 0 to NDOCS - 1 {
            if s != start_slot and slot_modified[s] {
                any = true
                goto_slot(s)
                if modified                 ; re-check live after the switch (save_now clears it)
                    void save_now()
            }
        }
        goto_slot(start_slot)
        full_redraw()
        if not any
            flash_notify(msg(MSG_ALLSAVED))
    }

    sub act_close_all() {
        ; File>Close All: empty all three slots, prompting for each one that has unsaved edits.
        ; Same walk as act_exit (bring each doc up so the prompt matches what is on screen), but it
        ; empties rather than quits.
        ;
        ; Cancel STOPS - it does not skip to the next document. Slots already emptied stay emptied,
        ; so the loop closes each doc immediately after its own prompt rather than prompting for all
        ; three first: that way a Cancel on doc B has not yet touched doc C.
        ;
        ; The switch is unconditional, so the walk turns over NDOCS times and wraps right back to the
        ; document the user started on - cheaper than tracking the start slot and calling goto_slot,
        ; and switch_doc's own full_redraw leaves the screen correct on the way out.
        ubyte closed = 0
        while closed < NDOCS {
            if modified {
                ubyte r = confirm_save()
                ; Cancel (or a failed save) stops here, on the doc that was being asked about. No
                ; repaint on these paths: menu_dispatch calls full_redraw() when g_redrawn is unset,
                ; which is exactly how act_new's own cancel path gets the screen back.
                if r == 2
                    return
                if r == 1 {
                    if not save_now()
                        return
                }
            }
            new_document()                  ; empty THIS slot before moving on
            closed++
            switch_doc()                    ; next doc (the NDOCS'th switch wraps home)
        }
    }

    sub act_exit() {
        ; quitting closes ALL three documents - check each for unsaved edits. Bring each modified doc up
        ; (so the confirm/save flow and the on-screen doc match) and prompt; any Cancel aborts the quit
        ; and returns to the doc the user was on.
        ubyte start_slot = g_active_slot
        ubyte checked = 0
        while checked < NDOCS {
            if modified {
                ubyte r = confirm_save()
                if r == 2 {
                    goto_slot(start_slot)   ; Cancel -> abort quit, back to where we started
                    return
                }
                if r == 1 {
                    if not save_now() {
                        goto_slot(start_slot)
                        return
                    }
                }
            }
            checked++
            if checked < NDOCS
                switch_doc()                ; advance to the next doc and re-check
        }
        ; Per-folder session: silently update .EDIT.SESSION (no prompt) with the current files+cursors.
        ; The save-loop above advanced g_active_slot, so restore it to where the user was FIRST - that is
        ; the active slot the session records (and edsess_op's OP_BEGIN_W saves that slot's live editbuf).
        ; Only genuine quit reaches here; the BASLOAD/EDCFG hand-offs bypass act_exit and keep ed.run.
        if theme.show_dev and session_on {
            goto_slot(start_slot)
            edsess_rw(3)
        }
        g_running = false
        g_redrawn = true                ; we're quitting - skip the menu's post-action screen repaint
    }

    sub refresh_session_on() {
        ; session_on = does a .EDIT.SESSION exist in the current folder? Dev mode only (else it stays
        ; false, so the feature is fully off). Called at startup and after any cwd change (Open / View).
        if theme.show_dev
            session_on = edsess_op(0, 0, 0) != 0
    }

    sub edsess_rw(ubyte op) {
        ; the two ops that need main's dispatcher + pointer table: 2 = restore, 3 = write. Folded into
        ; one helper so the &ses_svc / &SES_PTRS argument pair is set up once, not at three call sites.
        void edsess_op(op, &ses_svc, &SES_PTRS)
    }

    sub act_session_toggle() {
        ; Dev > Create/Delete Session file. Toggles the per-folder .EDIT.SESSION: Create snapshots the
        ; current files+cursors (so exit keeps it updated), Delete removes it (feature off for this
        ; folder). No prompt. The read/write engine is in picker.ovl; main only flips session_on so the
        ; menu label (and the exit-update decision) follow. erase_dropdown already repainted the screen,
        ; so claim g_redrawn and just restore the footer - no full-screen flash for a one-file write.
        g_redrawn = true
        if session_on {
            void edsess_op(1, 0, 0)                     ; delete .EDIT.SESSION
            session_on = false
        } else {
            edsess_rw(3)                                ; write current workspace -> creates it
            session_on = true
        }
        draw_status()
    }

    sub act_make_backup() {
        ; write the current document to a sibling "<name>.bak" (extension replaced, or appended if
        ; the name has none). Backs up what is loaded in the editor - including unsaved edits - and
        ; deliberately leaves the document's own modified/saved state untouched: the .bak is a side
        ; copy, not a Save. An existing .bak triggers a Y/N overwrite prompt.
        alias bakname = workbuf                 ; reuse the dead 256B Replace scratch (no Replace here)
                                                ; instead of a dedicated 44B module buffer
        ; Everything this action draws lives on the status row, and erase_dropdown() has already
        ; repainted the menu bar plus the rows the dropdown covered. Claiming g_redrawn skips
        ; menu_dispatch's blanket full_redraw(), which was clearing and repainting all 28 text rows
        ; for a backup - a visible full-screen flash. Each exit restores the footer with draw_status().
        g_redrawn = true
        if filename[0] == 0 {
            flash_status(msg(MSG_OPENFIRST))    ; same string as line below - reuse the banked msg pool
            bar_fill(STATUS_ROW, theme.CB_BAR)
            put_str_at(1, STATUS_ROW, msg(MSG_OPENFIRST))
            void wait_key()
            draw_status()
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

        if not confirm_overwrite(bakname) {     ; existing .bak -> require Y before clobbering it
            draw_status()
            return
        }
        commit_editbuf()
        savebuf[0] = '@'                        ; "@:" = overwrite if it already exists
        savebuf[1] = ':'
        void strings.copy(bakname, &savebuf + 2)
        status_msg(msg(MSG_BACKINGUP))          ; box only - no red blink
        if not edoc.save_file(savebuf) {
            notify(msg(MSG_BAKFAIL))
            draw_status()
            return
        }
        notify(msg(MSG_BAKSAVED))               ; modified state left as-is on purpose
        draw_status()
    }

    sub act_delete_sym() {
        ; Dev > Delete all SYM files. The whole feature - the directory scan, the deletes and the result
        ; line - runs INSIDE picker.ovl on the status row (the cheapest low-RAM overlay pattern), so main
        ; only guards the jmptable entry and restores the footer. No confirm: it deletes on select.
        ; erase_dropdown
        ; already repainted the menu bar + text rows, and del_sym touches only the status row, so
        ; g_redrawn skips menu_dispatch's blanket full_redraw (no full-screen flash); draw_status puts
        ; the Line/Col footer back after del_sym has held its result on the bar.
        g_redrawn = true
        cx16.push_rambank(PICKER_BANK)
        bool have = @($a009) == $4c             ; del_sym present? (a stale picker.ovl degrades softly)
        cx16.pop_rambank()
        if have
            void del_sym(theme.current)
        draw_status()
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
        if not keep {
            filename[0] = 0                     ; discarding the edits: come back to an EMPTY Doc A
            modified = false                    ; (clearing both stops write_run_state re-saving it)
        }
        write_run_state()                       ; always: docs B and C are worth restoring even when
        run_config = true                       ; the user threw away Doc A's edits
        g_running = false                       ; leave the main loop; start()'s tail chains out
        g_redrawn = true
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
        ; fkeytb ($A80E, bank 0) and fksnap (CLIP_BANK) are BOTH in the $A000-$BFFF window, so only
        ; one of them is reachable at a time - the bank has to flip per byte, with the value parked
        ; in X across the switch. 99 bytes twice a session; the cost does not matter.
        cx16.r0 = FKSNAP_ADDR
        cx16.r1L = CLIP_BANK
        %asm {{
            php
            sei
            lda  $00                ; save the current RAM bank
            pha
            ldy  #0
_snl:       stz  $00                ; bank 0 (KVARS) to read fkeytb
            lda  $a80e,y
            tax
            lda  cx16.r1L           ; CLIP_BANK to write fksnap
            sta  $00
            txa
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
        cx16.r0 = FKSNAP_ADDR        ; same per-byte bank flip as snapshot_fkeys, in reverse
        cx16.r1L = CLIP_BANK
        %asm {{
            php
            sei
            lda  $00
            pha
            ldy  #0
_rsl:       lda  cx16.r1L           ; CLIP_BANK to read fksnap
            sta  $00
            lda  (cx16.r0),y
            tax
            stz  $00                ; bank 0 (KVARS) to write fkeytb
            txa
            sta  $a80e,y
            iny
            cpy  #99
            bne  _rsl
            pla
            sta  $00
            plp
        }}
    }

    sub ses_xfer(uword bankaddr, uword count, bool saving) -> bool {
        ; move count bytes of CLIP_BANK to/from the open ed.run. diskio reads and writes STRAIGHT out
        ; of the mapped bank - its KERNAL calls never touch the $A000-$BFFF window themselves, so the
        ; obvious staging buffer and its chunking loop are both unnecessary (they cost ~200 bytes of
        ; low RAM before this was noticed). false = the write failed or the file ran short.
        cx16.push_rambank(CLIP_BANK)
        bool ok
        if saving
            ok = diskio.f_write(bankaddr, count)
        else
            ok = diskio.f_read(bankaddr, count) == count
        cx16.pop_rambank()
        return ok
    }

    sub write_run_state() {
        ; Snapshot the whole workspace into ed.run. The body lives in misc.ovl (ses_write) - it is
        ; the coldest code in the program, moved out for low RAM. No overlay -> no session file, but
        ; EDIT still runs; the reload then just comes up fresh.
        if ses_ok
            ovl_ses_write()
    }

    sub restore_run_state() -> bool {
        ; Rebuild the workspace ed.run describes (body in misc.ovl: ses_restore + slot_restore).
        ; Returns true if a session was restored - start() then skips its fresh-launch setup.
        if not ses_ok
            return false
        return ovl_ses_restore() != 0
    }

    sub ses_svc() {
        ; Service dispatcher for the session code in misc.ovl: op in r0L, args in r1-r3, results in
        ; r0. The overlay cannot call main's subs by name (separate compilation units) and must NEVER
        ; map another bank over $A000 (it would swap itself out mid-instruction) - so every main-sub
        ; call and every CLIP_BANK access funnels through here, executing from low RAM where banking
        ; is safe (push/pop restores bank 10 before this returns to the overlay).
        ; Op numbers are the overlay ABI - keep in lock-step with misc.p8's OP_* constants and bump
        ; SESOVL_VER on any change.
        ubyte op = cx16.r0L
        when op {
            0 -> {                              ; begin a session write
                commit_editbuf()
                save_ctx(g_active_slot)
            }
            1 -> save_ctx(cx16.r1L)
            2 -> load_ctx(cx16.r1L)
            3 -> {                              ; activate slot r1L: context + its editbuf line
                load_ctx(cx16.r1L)
                cur_len = edoc.load(cur_row, &editbuf)
                cur_dirty = false
            }
            4 -> blank_slot()
            5 -> b2r(edoc.save_file(filename))
            6 -> {
                b2r(edoc.load_file(filename))
                if cx16.r0L == 0
                    void diskio.status()        ; drop the FILE NOT FOUND (stop the drive LED)
            }
            7 -> {                              ; per-slot post-reload init
                undo_clear()
                g_group = 0
                recompute_gutter()
            }
            8 -> b2r(ses_xfer(cx16.r1, cx16.r2, cx16.r3L != 0))
            9 -> {
                b2r(diskio.f_open(runstate))
                if cx16.r0L == 0
                    void diskio.status()
            }
            10 -> b2r(diskio.f_open_w(runstate))
            11 -> diskio.f_close_w()
            12 -> {                             ; finish reading: close + consume (one-shot file)
                diskio.f_close()
                diskio.delete(runstate)
                void diskio.status()
            }
            13 -> cx16.r0 = diskio.f_read(cx16.r1, cx16.r2)
            14 -> void diskio.f_write(cx16.r1, cx16.r2)
            15 -> {
                diskio.delete(fnbuf)
                void diskio.status()
            }
            16 -> apply_syntax_mode(filename)   ; .EDIT.SESSION restore: colour + gutter by extension, as
        }                                       ; Open does (ed.run's slot_restore skips this - it keeps
    }                                           ; the per-doc hl_on/ln_on the context already carries)

    sub b2r(bool b) {
        ; bool result -> the r0L result register (the overlay tests 0 / not-0)
        cx16.r0L = 0
        if b
            cx16.r0L = 1
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
        if n > BERR_MAX
            n = BERR_MAX
        c = 0
        cx16.push_rambank(CLIP_BANK)            ; berr is banked; getchr/setchr use VERA (no bank clash)
        while c < n {
            ubyte s = txt.getchr(c, row)
            if s >= 1 and s <= 26
                s += 64                         ; letter -> lowercase-charset uppercase slot
            @(berr + c) = s
            c++
        }
        cx16.pop_rambank()
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
        cx16.push_rambank(CLIP_BANK)            ; berr is banked (see its declaration)
        while c < n {
            txt.setchr(1 + c, STATUS_ROW, @(berr + c))
            c++
        }
        cx16.pop_rambank()
    }

    ; The About screen lives in misc.ovl (MISC_BANK) - see the extsub block near the top. What is
    ; left here is the hand-off: pass the overlay the theme (so it paints in the current colours),
    ; the build number and the emulator flag, which it has no way to read out of main. The overlay
    ; blocks on a key; we repaint the editor after.

    sub act_about() {
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

    sub act_hints_help() {
        ; the Hints-Tips file (hints.md), shown in the same viewer as the Keyboard Map
        view_help(hintshlp)
    }

    sub view_help(str fname) {
        ; open a shipped help text file (in the install folder) read-only in the viewer
        cursor_sprite_off()                     ; the overlay owns the screen: hide our cursor sprite
        ovl_view(theme.path_to(fname), theme.current)
        full_redraw()
    }

    sub act_view() {
        ; File > View: pick a file and show it read-only in the viewer, without loading it into the
        ; document (so it side-steps the document size limit for a quick look at a big file).
        fnbuf[0] = 0
        cursor_sprite_off()                     ; both overlays own the screen: hide our cursor sprite
        if pick(&fnbuf, pick_theme(), &pick_blocks) == 0 {
            full_redraw()
            return
        }
        ovl_view(&fnbuf, theme.current)
        refresh_session_on()            ; View can chdir too - keep session_on tracking the current folder
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
        ; case-fold a letter to the canonical $41-$5A range so either case matches.
        if theme.ISO_MODE and b >= $61 and b <= $7a
            return b - $20              ; ISO 'a'-'z' document/term bytes -> $41-$5A
        if b >= $c1 and b <= $da
            return b - $80              ; PETSCII 'A'-'Z' -> $41-$5A (filename fold rides this - item 10)
        return b
    }

    sub fold_str(uword p) {
        ; fold a whole string's PETSCII uppercase ($C1-$DA) down to $41-$5A, in place.
        ; Filenames only: now that the prompt accepts uppercase, a typed "TEST.BAS" would
        ; otherwise reach the disk as $D4$C5$D3$D4..., a different byte string from the
        ; $41-$5A the picker hands back and the installer writes - so it would not match
        ; an existing file and would create an oddly named new one. Search terms are NOT
        ; folded here: line_match already folds both sides, and leaving them alone keeps
        ; the entered text displaying as the upper case the user typed.
        ubyte i = 0
        while @(p + i) != 0 {
            @(p + i) = fold(@(p + i))
            i++
        }
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
        ; Multi-line selections are left alone - a search term is one line.
        ; Both callers BLANK find_term immediately before calling this, so "left alone" now means the
        ; prompt opens EMPTY rather than holding the previous term: with UP-arrow history the old
        ; term is one keystroke away, and starting empty saves backspacing it out every time. The
        ; blank is deliberately not done in here - find_next (F3) must keep find_term, and it reaches
        ; the search without going through this sub or the prompt at all.
        ; The selection is consumed (cleared) so the located match highlights cleanly instead of
        ; leaving a stale highlight spanning the old anchor to the new cursor.
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
        find_term[0] = 0                        ; new search starts EMPTY - see sel_to_find
        sel_to_find()
        if not prompt_str("Find:", &find_term, 38, PF_WW | PF_FIND)
            return
        commit_editbuf()
        ubyte res = find_wrap(cur_row, cur_col)
        if res == 0 {
            notify("Not found")
            return
        }
        goto_found()
        if res == 2
            notify(msg(MSG_WRAPTOP))
    }

    sub act_find_next() {
        if find_term[0] == 0 {
            sel_to_find()                   ; no term yet: adopt a single-line highlight as the term,
                                            ; so "select a word, F3" searches for it (no warning path)
            if find_term[0] == 0 {          ; nothing selected either -> warn, and BLOCK to eat the
                notify(msg(MSG_NOTERM))   ; key the user presses to react, so it
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
            notify(msg(MSG_WRAPTOP))
    }

    sub prompt_replace() -> ubyte {
        ; ask about the highlighted match; returns 'y', 'n', 'a' (all) or 27 (stop).
        box_msg(msg(MSG_REPLACEBAR), theme.CB_BAR)   ; text at col 2 in the box middle (STATUS_ROW-1)
        ubyte mid = STATUS_ROW - 1
        ubyte hi = (theme.CB_BAR & $f0) | theme.ACCEL_FG    ; top-menu-style highlight for the trigger keys
        txt.setclr(12, mid, hi)                 ; Y(es)    (cols are +1 vs the old col-1 bar - the box insets 1)
        txt.setclr(17, mid, hi)                 ; N(o)
        txt.setclr(21, mid, hi)                 ; A(ll)
        txt.setclr(26, mid, hi)                 ; E \
        txt.setclr(27, mid, hi)                 ; s  Esc
        txt.setclr(28, mid, hi)                 ; c /
        draw_ww_label(false)                    ; read-only "Whole Word" reminder when it's on
        repeat {
            ubyte k = wait_key()
            if theme.ISO_MODE {
                if k >= $61 and k <= $7a
                    k -= $20
            } else {
                if k >= $c1 and k <= $da
                    k -= $80
            }
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
        find_term[0] = 0                        ; new search starts EMPTY - see sel_to_find
        sel_to_find()
        if not prompt_str("Find:", &find_term, 38, PF_WW | PF_FIND)
            return
        if not prompt_str("Replace with:", &repl_term, 38, PF_EMPTY | PF_WW | PF_REPL)  ; empty = delete
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
                ; Reload editbuf for the row we just jumped to. draw_text_row renders the CUR_ROW
                ; from editbuf and every other row from the document, so moving cur_row without this
                ; paints the PREVIOUS cursor line's contents over the match - and paints it blank when
                ; that line was empty or shorter. goto_found() (the Find path) already does this; the
                ; inline jump here did not, which is why Find looked fine and Replace did not.
                cur_len = edoc.load(cur_row, &editbuf)
                cur_dirty = false
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
        if not prompt_str("Go to line:", &fnbuf, 5, 0)
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

    ; rem_start / build_commented / build_uncommented moved to menus.ovl's mnu_rem ($A015) to reclaim
    ; ~200 B of low RAM (the overlay writes main's workbuf directly - low RAM stays mapped). comment_apply
    ; calls mnu_rem with buf=&tmpbuf, workp=&workbuf, iso=theme.ISO_MODE.

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
            do_add = mnu_rem(0, cl, 0, theme.ISO_MODE as ubyte, &tmpbuf, 0) == 255   ; toggle: add only if not a comment
        }
        ubyte llen
        ubyte newlen
        ubyte rs
        undo_begin()
        uword r = r0
        while r <= r1 {
            llen = edoc.load(r, &tmpbuf)
            if do_add {
                ; Block Comment DOES stack a REM onto a line that is already a comment. Uncomment
                ; strips exactly one, so a block that contained real comments survives a
                ; comment/uncomment round trip with those original REMs still in place. (Toggle,
                ; mode 0, never reaches here on a REM line: do_add is false for it above.)
                ; SKIP a line the 4-byte "REM " prefix would push past MAX_LEN. build_commented
                ; clamps at MAX_LEN, so commenting such a line would silently drop characters off
                ; the end - and Uncomment could not put them back, since it only removes the prefix.
                ; Leaving the line untouched is recoverable; truncating it is not.
                if (llen as uword) + 4 <= edoc.MAX_LEN {
                    newlen = mnu_rem(1, llen, theme.cmt_indent, theme.ISO_MODE as ubyte, &tmpbuf, &workbuf)
                    urec_replace(r, &tmpbuf, llen)
                    void edoc.commit(r, &workbuf, newlen)
                }
            } else {
                rs = mnu_rem(0, llen, 0, theme.ISO_MODE as ubyte, &tmpbuf, 0)
                if rs != 255 {
                    newlen = mnu_rem(2, llen, rs, theme.ISO_MODE as ubyte, &tmpbuf, &workbuf)
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
                @(clipbuf + o) = edoc.p2a(tmpbuf[i])    ; clip is canonical ASCII (mode-neutral)
                o++
                i++
            }
        } else {
            ubyte slen = edoc.load(s_row, &tmpbuf)
            i = s_col
            while i < slen and o < 1023 {
                @(clipbuf + o) = edoc.p2a(tmpbuf[i])    ; clip is canonical ASCII (mode-neutral)
                o++
                i++
            }
            ; The terminator MUST carry the same o < 1023 guard as the content stores. Without it a
            ; selection longer than the clipboard still wrote one $0D per line with no ceiling, so o
            ; walked past the 1KB clipboard, through the three document context blocks at $A400, and
            ; (since those buffers moved here) into fksnap at $AA00 and startdir at $AA70 - which exit
            ; then commits into the KERNAL fkey table and hands to chdir as an unterminated string.
            if o < 1023 {
                @(clipbuf + o) = 13
                o++
            }
            uword r = s_row + 1
            while r < e_row and o < 1023 {
                ubyte ml = edoc.load(r, &tmpbuf)
                ubyte j = 0
                while j < ml and o < 1023 {
                    @(clipbuf + o) = edoc.p2a(tmpbuf[j])
                    o++
                    j++
                }
                if o < 1023 {
                    @(clipbuf + o) = 13
                    o++
                }
                r++
            }
            ubyte elen = edoc.load(e_row, &tmpbuf)
            ubyte k2 = 0
            while k2 < e_col and k2 < elen and o < 1023 {
                @(clipbuf + o) = edoc.p2a(tmpbuf[k2])
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
            @(clipbuf + i) = edoc.p2a(editbuf[i])   ; clip is canonical ASCII (mode-neutral)
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
            notify(msg(MSG_LINECOPIED))
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
            notify_full()
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
            notify(msg(MSG_CLIPEMPTY))
            return
        }
        if sel_active
            delete_selection()
        commit_editbuf()
        if clip_line {
            ; whole-line clipboard: insert it as a new line below the cursor
            if not edoc.insert_line(cur_row + 1) {
                notify_full()
                return
            }
            undo_begin()
            urec_addline(cur_row + 1)           ; undo: delete the pasted line
            ubyte bi = 0
            cx16.push_rambank(CLIP_BANK)        ; stage the banked clip line into low-RAM tmpbuf
            while bi < lsb(clip_len) {
                tmpbuf[bi] = edoc.a2p(@(clipbuf + bi))  ; canonical ASCII clip -> active doc encoding
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
                ubyte ch = edoc.a2p(@(clipbuf + pi))   ; canonical ASCII clip -> active doc encoding
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
                notify_full()
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
            notify(msg(MSG_NOUNDO))
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
            notify(msg(MSG_NOREDO))
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

    sub ed_doc_jump(bool bottom) {
        ; Ctrl+PgDn / Ctrl+PgUp: jump to the end / start of the whole document. The cursor lands on
        ; column 0 at the top and on the last line's end column at the bottom. redraw_after_move()
        ; sees a multi-row scroll and repaints in full, and handles wrap mode on its own path.
        uword nr = 0
        cur_col = 0
        if bottom
            nr = edoc.line_count - 1
        goto_row(nr)
        if bottom
            cur_col = cur_len
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
            notify_full()
            return
        }
        if not edoc.insert_line(cur_row + 1) {
            notify_full()
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
        ; Commodore(ALT)+letter opens a menu. In PETSCII the KERNAL delivers the chord as a graphics
        ; code 161..191 that alt_letter maps back to a base letter -> open that menu directly (intercept
        ; before the text-insert path below, which accepts k>=160; other ALT combos are swallowed).
        if not theme.ISO_MODE {
            if k >= 161 and k <= 191 {
                ubyte m = mnu_accel(2, 0, alt_letter[k - 161], theme.show_dev as ubyte)
                if m != 255
                    menu_mode_loop(m)
                return
            }
        } else if (g_mod & MOD_ALT) != 0 {
            ; ISO: the ISO keymap has no Commodore graphics table, so C= acts as AltGr/compose and the
            ; emitted byte can't be decoded to a menu letter. Claim any Commodore chord to open the menu
            ; bar (we type no accented/compose chars - the glyph set is { } \ | ~, all base keys); the
            ; user then picks the menu with the arrow keys or a dropdown accelerator letter.
            menu_mode_loop(0)
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
            27 -> menu_mode_loop(0)         ; Esc opens the menu bar (ALT-release does it via a 0 return)
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
            2 -> {                          ; PgDn (Ctrl = jump to end of file)
                if (g_mod & MOD_CTRL) != 0
                    ed_doc_jump(true)
                else
                    ed_pgdn()
            }
            130 -> {                        ; PgUp (Ctrl = jump to start of file)
                if (g_mod & MOD_CTRL) != 0
                    ed_doc_jump(false)
                else
                    ed_pgup()
            }
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
            136 -> {                        ; F7 cycle docs; Ctrl+F7 toggles THIS doc's PETSCII/ISO mode
                if (g_mod & MOD_CTRL) != 0
                    act_toggle_mode()
                else
                    switch_doc()
            }
            133 -> act_keymap()             ; F1  Help (keyboard map / edit.md)
            else -> {
                if (k >= 32 and k <= 126) or (k >= 160) {
                    if theme.ISO_MODE {
                        if upper_mode and k >= $61 and k <= $7a
                            k -= $20    ; software Caps Lock (ISO): fold a-z ($61-$7A) up to A-Z ($41-$5A)
                    } else {
                        if upper_mode and k >= $41 and k <= $5a
                            k += $80    ; software Caps Lock: fold lowercase a-z ($41-$5A) to capital ($C1-$DA)
                    }
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

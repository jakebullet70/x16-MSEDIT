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
; And hosts the SESSION save/restore (ed.run): the coldest code in EDIT - it runs once at startup and
; once at exit - which made it the natural ~900B to move out when the session feature dropped main's
; free low RAM to 20 bytes. Unlike ovl_prompt this code must CALL BACK into main (save_ctx, edoc
; loads, diskio on main's channel state) and poke a score of main globals, so the boundary is:
;   ses_setup(svc, ptrs)  - main hands over ONE dispatcher address (ses_svc, running in low RAM,
;                           op in r0L / args r1-r3 / result r0) and ONE pointer table (SES_PTRS,
;                           every main-RAM location this code touches, by P_* index).
;   ses_write/ses_restore - the moved write_run_state / restore_run_state bodies, translated to
;                           dispatcher ops + pointer accesses.
; The overlay NEVER maps a bank itself (it would swap itself out) - anything banked (the context
; blocks in CLIP_BANK, the clipboard) is moved by main's ses_xfer, reached via OP_XFER.
; SES_PTRS order and the op numbers are the ABI: keep P_*/OP_* in lock-step with edit.p8 and bump
; SESOVL_VER (returned by ses_setup, checked by main) on ANY change to either.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = help_about, $A006 = ovl_prompt,
; $A009 = ses_setup, $A00C = ses_write, $A00F = ses_restore.
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
    %jmptable ( main.help_about, main.ovl_prompt, main.ses_setup, main.ses_write, main.ses_restore, main.kw_addrs, main.chain_load, main.chain_basload )

    const ubyte SPACE_SC = sc:' '
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'
    const ubyte SC_UP = $1e             ; screen code for the PETSCII up-arrow ($5e) - the Hist hint

    ubyte SCR_W, SCR_H                  ; UNINITIALIZED -> BSS tail, safe for the jmptable

    ; ---- input-history rings (UP/DOWN recall inside ovl_prompt) ----
    ; The whole feature lives in this bank and costs main ZERO low RAM. That is only possible because
    ; ovl_prompt's key loop runs in-bank: recall is in-place on the status row, so nothing has to
    ; repaint the text area and no callback into main is needed. (XFMGR2 pays 51 B for the same
    ; feature because its recall is a POPUP over the panes, which main has to redraw.)
    ; One ring per category so filenames and search terms don't interleave; category comes in on
    ; the caller's flags byte, bits 4-7 (0 = history off for that prompt).
    const ubyte HIST_CATS = 2           ; 1 = Find, 2 = Replace
    const ubyte HIST_N    = 8           ; entries kept per category, slot 0 = most recent
    const ubyte HIST_W    = 41          ; bytes per slot: 40 chars + NUL (main's prompts cap at 38)
    ; CATS*N*W = 656 B, past prog8's 256-byte array cap, so it's a memory() slab behind a pointer.
    ; hist_buf must stay UNINITIALIZED (-> BSS, keeps the jmptable put) and is filled in start().
    uword hist_buf                      ; slab address
    ubyte[HIST_CATS] hist_count         ; entries held, per category (index = cat-1)

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here (which zeroes hist_count).
        hist_buf = memory("edithist", HIST_CATS * HIST_N * HIST_W as uword, 0)
    }

    sub hist_ptr(ubyte cat, ubyte k) -> uword {
        ; address of slot k in category cat (1-based). Widen before the multiply - the product
        ; runs to 943 and would wrap in a ubyte.
        uword off = cat - 1
        off *= HIST_N
        off += k
        off *= HIST_W
        return hist_buf + off
    }

    sub hist_store(ubyte cat, uword sptr) {
        ; insert the string at sptr as category cat's newest entry (slot 0). An exact match already
        ; in the ring is PROMOTED, not duplicated: it is removed first (compacting the tail up one
        ; slot) so re-running the same search doesn't fill the ring with one term.
        if cat == 0 or @(sptr) == 0
            return
        ubyte ci = cat - 1
        ubyte i
        if hist_count[ci] != 0 {
            for i in 0 to hist_count[ci] - 1 {
                if strings.compare(hist_ptr(cat, i), sptr) == 0 {
                    while i + 1 < hist_count[ci] {
                        void strings.copy(hist_ptr(cat, i + 1), hist_ptr(cat, i))
                        i++
                    }
                    hist_count[ci]--
                    break
                }
            }
        }
        ubyte top = hist_count[ci]
        if top >= HIST_N
            top = HIST_N - 1                ; ring full -> the oldest entry falls off the end
        while top != 0 {
            void strings.copy(hist_ptr(cat, top - 1), hist_ptr(cat, top))
            top--
        }
        uword d = hist_ptr(cat, 0)
        ubyte n = 0
        while n < HIST_W - 1 and @(sptr + n) != 0 {
            @(d + n) = @(sptr + n)
            n++
        }
        @(d + n) = 0
        if hist_count[ci] < HIST_N
            hist_count[ci]++
    }

    sub hist_recall(uword dest, ubyte maxlen, ubyte base, ubyte statusrow, ubyte oldn,
                    ubyte cat, ubyte slot) -> ubyte {
        ; load ring slot into dest and return the new length. slot 255 = clear the field.
        ; The caller's loop repaints dest[0..n-1] every pass but never erases past it, so a shorter
        ; entry would leave the tail of the longer one on the bar - blank the old width here first.
        ubyte j = 0
        while j <= oldn {                       ; <= : the extra cell is the cursor block
            txt.setchr(base + j, statusrow, SPACE_SC)
            j++
        }
        ubyte n = 0
        if slot != 255 {
            uword s = hist_ptr(cat, slot)
            while n < maxlen and @(s + n) != 0 {
                @(dest + n) = @(s + n)
                n++
            }
        }
        @(dest + n) = 0
        return n
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

    sub kw_addrs(uword outp @R0) {
        ; Write the addresses of the three BASIC keyword blobs (which live in THIS overlay's string
        ; pool, so they are only valid while MISC_BANK is mapped) into the caller's 3-uword array at
        ; outp in low RAM. syntax.p8 caches them and maps MISC_BANK around its keyword matching -
        ; that is how ~450 B of keyword text was moved out of the editor's scarce low RAM.
        ; These blobs used to live in syntax.p8. Statements split CBM/X16 only to stay under the
        ; 255-byte str limit; both classify as keywords. Function forms keep any trailing '$'.
        ; PETSCII, space-delimited, matched case-insensitively by syntax.in_blob.
        uword p
        p = "END FOR NEXT DATA INPUT DIM READ LET GOTO RUN IF RESTORE GOSUB RETURN STOP ON WAIT LOAD SAVE VERIFY DEF POKE PRINT CONT LIST CLR CMD SYS OPEN CLOSE GET NEW TO THEN NOT STEP AND OR GO ELSE"
        @(outp) = lsb(p)
        @(outp + 1) = msb(p)
        p = "VPOKE SCREEN PSET LINE FRAME RECT CIRCLE CHAR MOUSE COLOR LOCATE CLS DOS OLD MON VLOAD BLOAD BSAVE BVERIFY BOOT RESET KEY BANK MENU FONT"
        @(outp + 2) = lsb(p)
        @(outp + 3) = msb(p)
        p = "SGN INT ABS USR FRE POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN VAL ASC TAB SPC FN STR$ CHR$ LEFT$ RIGHT$ MID$ VPEEK HEX$ BIN$"
        @(outp + 4) = lsb(p)
        @(outp + 5) = msb(p)
    }

    sub prompt_box(ubyte interior) {
        ; the 3-line attention box for the input prompt, matching edit.p8's box_msg: a top border on
        ; SCR_H-3, the input row (SCR_H-2) framed by │ side borders, and a bottom border on the footer
        ; row (SCR_H-1). interior = the middle row's fill (red flash, then theme.CB_BAR).
        ubyte top = SCR_H - 3
        ubyte mid = SCR_H - 2
        ubyte bot = SCR_H - 1
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
        for c in 1 to SCR_W - 2 {
            txt.setclr(c, mid, interior)
            txt.setchr(c, mid, SPACE_SC)
        }
        txt.setclr(0, mid, theme.CB_BAR)
        txt.setchr(0, mid, SC_V)
        txt.setclr(SCR_W - 1, mid, theme.CB_BAR)
        txt.setchr(SCR_W - 1, mid, SC_V)
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
        ubyte statusrow = SCR_H - 2             ; the box's MIDDLE row (box hugs the bottom 3 rows)
        bool allow_empty = (flags & 1) != 0
        bool ww_hint     = (flags & 2) != 0
        ubyte cat        = flags >> 4           ; history category, 0 = no history on this prompt
        ubyte hidx       = 255                  ; slot currently recalled; 255 = showing live text
        ; RED flash rem'd out for now (user request) - draw the box straight in the normal colour.
        ; prompt_box($21)                        ; one red flash so the prompt draws the eye
        ; put_str_at(2, statusrow, promptmsg)
        ; sys.wait(18)                           ; ~0.3s
        prompt_box(theme.CB_BAR)                 ; the normal box
        put_str_at(2, statusrow, promptmsg)
        if ww_hint
            draw_ww_label(statusrow, wwptr)
        if cat != 0
            draw_hist_hint(statusrow, ww_hint)
        ubyte base = lsb(strings.length(promptmsg)) + 3
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
                    hist_store(cat, dest)       ; no-ops on cat 0 and on an empty entry
                    if allow_empty
                        return 1
                    if n != 0
                        return 1
                    return 0
                }
                145 -> {                        ; up-arrow -> an OLDER entry
                    if cat != 0 and hist_count[cat - 1] != 0 {
                        if hidx == 255
                            hidx = 0
                        else if hidx + 1 < hist_count[cat - 1]
                            hidx++
                        n = hist_recall(dest, maxlen, base, statusrow, n, cat, hidx)
                    }
                }
                17 -> {                         ; down-arrow -> a NEWER entry; past the newest, blank
                    if cat != 0 and hidx != 255 {
                        if hidx == 0
                            hidx = 255          ; hist_recall clears the field on 255 - the quick way
                        else                    ; to drop the pre-filled term and start over
                            hidx--
                        n = hist_recall(dest, maxlen, base, statusrow, n, cat, hidx)
                    }
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
                    ; $C1-$DA is where the UPPERCASE letters live: the editor runs the lowercase
                    ; PETSCII charset (txt.lowercase in main), so $41-$5A draw as a..z and a shifted
                    ; letter arrives as $C1-$DA. The old 32..126 test dropped every one of them, so
                    ; the prompt would only take lower case. Deliberately NOT the document typing
                    ; path's blanket "k >= 160" - that range also carries Commodore+letter and
                    ; function keys, which would land in the buffer as garbage.
                    if theme.ISO_MODE {
                        if n < maxlen and ((k >= 32 and k <= 126) or (k >= $a0)) {
                            @(dest + n) = k
                            n++
                        }
                    } else {
                        if n < maxlen and ((k >= 32 and k <= 126) or (k >= $c1 and k <= $da)) {
                            @(dest + n) = k
                            n++
                        }
                    }
                }
            }
        }
    }

    ; ------------------------------------------------------------------ session save/restore (ed.run)
    ; The moved bodies of edit.p8's write_run_state / restore_run_state / slot_restore. Every call
    ; into main goes through the ses_svc dispatcher (svc), every main global through the SES_PTRS
    ; table (ptrs) - see the header comment for the ABI. The pointer-soup reads worse than the
    ; originals, but this is the coldest code in the program and bank space is free; the originals'
    ; comments (WHY the order matters, what each guard is for) are kept next to their translations.

    const ubyte SESOVL_VER = 2          ; handshake: main refuses the session feature on mismatch
                                        ; (2: fksnap/startdir moved into CLIP_BANK - their SES_PTRS
                                        ;  slots are now bank ADDRESSES and must move via OP_XFER,
                                        ;  so a v1 overlay would fio() them out of the wrong memory)

    ; architecture constants duplicated from edit.p8 - fixed for the life of the bank map
    const ubyte NDOCS    = 3
    const uword CTX_BASE = $A400        ; doc context blocks in CLIP_BANK, above the 1KB clipboard
    const uword CTX_SIZE = 512
    const uword CLIPBUF  = $A000        ; the clipboard itself, at the base of CLIP_BANK
    const uword CLIP_MAX = 1024

    ; dispatcher ops (edit.p8 ses_svc must match). Ops that were always called back-to-back are
    ; MERGED into one (BEGIN_W, ACTIVATE, UNDO_INIT, FINISH_R, the status drops folded into their
    ; only callers) - every arm removed from main's `when` chain is low RAM reclaimed.
    const ubyte OP_BEGIN_W    = 0       ; commit_editbuf() + save_ctx(g_active_slot)
    const ubyte OP_SAVE_CTX   = 1       ; save_ctx(r1L)
    const ubyte OP_LOAD_CTX   = 2       ; load_ctx(r1L)
    const ubyte OP_ACTIVATE   = 3       ; load_ctx(r1L) + reload editbuf from its cur_row
    const ubyte OP_BLANK      = 4       ; blank_slot()
    const ubyte OP_SAVE_FILE  = 5       ; edoc.save_file(filename) -> r0L
    const ubyte OP_LOAD_FILE  = 6       ; edoc.load_file(filename) -> r0L; drops the DOS status on fail
    const ubyte OP_UNDO_INIT  = 7       ; undo_clear() + g_group = 0 + recompute_gutter()
    const ubyte OP_XFER       = 8       ; ses_xfer(r1 bankaddr, r2 count, r3L saving) -> r0L
    const ubyte OP_OPEN_R     = 9       ; diskio.f_open(ed.run) -> r0L; drops the DOS status on fail
    const ubyte OP_OPEN_W     = 10      ; diskio.f_open_w(ed.run) -> r0L
    const ubyte OP_CLOSE_W    = 11
    const ubyte OP_FINISH_R   = 12      ; f_close + delete ed.run (one-shot) + drop the DOS status
    const ubyte OP_READ       = 13      ; diskio.f_read(r1, r2) -> r0
    const ubyte OP_WRITE      = 14      ; diskio.f_write(r1, r2)
    const ubyte OP_DEL_FNBUF  = 15      ; delete the file named in fnbuf + drop the DOS status

    ; SES_PTRS indices (edit.p8 SES_PTRS must match)
    const ubyte P_ACT       = 0         ; g_active_slot (ubyte)
    const ubyte P_MOD       = 1         ; modified (bool)
    const ubyte P_FILENAME  = 2         ; filename (str)
    const ubyte P_FNBUF     = 3         ; fnbuf (str)
    const ubyte P_SPILL     = 4         ; ses_spill (NDOCS bools)
    const ubyte P_TMPDOC    = 5         ; tmpdoc "ed_a.tmp" (str, [3] patched per slot)
    const ubyte P_SESHDR    = 6         ; seshdr (5 bytes: magic + SES_VER)
    const ubyte P_TMPBUF    = 7         ; tmpbuf (256B scratch)
    const ubyte P_CLIP_HAS  = 8         ; clip_has (bool)
    const ubyte P_CLIP_LEN  = 9         ; clip_len (uword)
    const ubyte P_CUR_ROW   = 10        ; cur_row (uword)
    const ubyte P_TOP_LINE  = 11        ; top_line (uword)
    const ubyte P_BERRLINE  = 12        ; basload_err_line (uword)
    const ubyte P_LINECOUNT = 13        ; edoc.line_count (uword)
    const ubyte P_SELA      = 14        ; sel_active (bool)
    const ubyte P_SELC      = 15        ; sel_cleared (bool)
    const ubyte P_DIRTY     = 16        ; cur_dirty (bool)
    const ubyte P_FAILED    = 17        ; ses_failed (bool)
    const ubyte P_LOST      = 18        ; ses_lost (ubyte)
    const ubyte P_TEXTROWS  = 19        ; TEXT_ROWS (ubyte)
    ; the session-FIELDS group - streamed to/from ed.run by fields() below, which owns the
    ; (index, length) list; main no longer carries any field table of its own
    const ubyte P_FKSNAP    = 20        ; fksnap (99 bytes)
    const ubyte P_FIND      = 21        ; find_term (41)
    const ubyte P_REPL      = 22        ; repl_term (41)
    const ubyte P_STARTDIR  = 23        ; startdir (82)
    const ubyte P_WW        = 24        ; ww_on (bool)
    const ubyte P_CLIP_LINE = 25        ; clip_line (bool)

    uword svc                           ; main's ses_svc dispatcher (low RAM) - set by ses_setup
    uword ptrs                          ; main's SES_PTRS table (low RAM)    - set by ses_setup
                                        ; (both UNINITIALIZED -> BSS tail, safe for the jmptable)

    sub ses_setup(uword svcaddr @R0, uword ptrtbl @R1) -> ubyte {
        svc  = svcaddr
        ptrs = ptrtbl
        return SESOVL_VER               ; main checks this - a stale overlay refuses politely
    }

    sub pt(ubyte i) -> uword {
        return peekw(ptrs + (i as uword) * 2)
    }

    ; op helpers. Each one sets ALL its registers itself and then calls the dispatcher - argument
    ; registers are never left set across a nested prog8 call, so nothing can clobber them first.
    sub op0(ubyte op) {
        cx16.r0L = op
        void call(svc)
    }
    sub op1(ubyte op, ubyte a) {
        cx16.r1L = a
        cx16.r0L = op
        void call(svc)
    }
    sub opr(ubyte op) -> ubyte {
        cx16.r0L = op
        void call(svc)
        return cx16.r0L
    }
    sub op2r(ubyte op, uword a, uword b) -> uword {
        cx16.r1 = a
        cx16.r2 = b
        cx16.r0L = op
        void call(svc)
        return cx16.r0
    }
    sub op3r(ubyte op, uword a, uword b, ubyte c) -> ubyte {
        cx16.r1 = a
        cx16.r2 = b
        cx16.r3L = c
        cx16.r0L = op
        void call(svc)
        return cx16.r0L
    }

    sub fio(ubyte wr, ubyte pi, ubyte n) {
        if wr != 0
            void op2r(OP_WRITE, pt(pi), n)
        else
            void op2r(OP_READ, pt(pi), n)
    }

    sub bio(ubyte wr, ubyte pi, uword n) {
        ; same as fio, but for a field that lives in CLIP_BANK instead of main's low RAM. fio hands
        ; the address straight to diskio, which would read it as low RAM; OP_XFER routes it through
        ; main's ses_xfer, which maps the bank first. The SES_PTRS slot holds the bank address.
        void op3r(OP_XFER, pt(pi), n, wr)
    }

    sub fields(ubyte wr) {
        ; the session-level fields, streamed to/from ed.run one field at a time. THIS list defines
        ; the file layout between the header and the context blocks - order and lengths are part of
        ; the ed.run format, so any change here means bumping SES_VER in edit.p8. (These all live in
        ; main's low RAM; the lengths mirror the buffer declarations there.) Written as explicit
        ; calls, not a table: module-level initialized arrays would land in front of the code and
        ; shove the %jmptable off its fixed offsets.
        bio(wr, P_FKSNAP, 99)           ; banked (CLIP_BANK), not low RAM - see bio()
        fio(wr, P_FIND, 41)
        fio(wr, P_REPL, 41)
        bio(wr, P_STARTDIR, 82)         ; banked
        fio(wr, P_SPILL, NDOCS)
        fio(wr, P_WW, 1)
        fio(wr, P_CLIP_HAS, 1)
        fio(wr, P_CLIP_LINE, 1)
        fio(wr, P_CLIP_LEN, 2)
        fio(wr, P_ACT, 1)
    }

    sub ses_write() {
        ; Snapshot the whole workspace into ed.run (was edit.p8 write_run_state - see the layout
        ; comment there). Documents are saved in a FIRST pass, before ed.run is opened: diskio has a
        ; single write channel, so the saves and the session writes cannot be interleaved.
        op0(OP_BEGIN_W)                         ; commit the live line + save the active context
        ubyte act = @(pt(P_ACT))
        ubyte s
        for s in 0 to NDOCS - 1 {
            op1(OP_LOAD_CTX, s)
            @(pt(P_SPILL) + s) = 0
            if @(pt(P_MOD)) != 0 {              ; restore reopens documents BY NAME - anything not
                if @(pt(P_FILENAME)) == 0 {     ; on disk would simply not come back
                    @(pt(P_TMPDOC) + 3) = 'a' + s
                    void strings.copy(pt(P_TMPDOC), pt(P_FILENAME))
                    @(pt(P_SPILL) + s) = 1      ; untitled: restore undoes this temp name
                }
                void opr(OP_SAVE_FILE)          ; a failed write shows up at restore as missing
                @(pt(P_MOD)) = 0
            }
            op1(OP_SAVE_CTX, s)                 ; the spill may have named the doc / cleared modified
        }
        op1(OP_ACTIVATE, act)                   ; the load_ctx walk left editbuf on another document

        if opr(OP_OPEN_W) == 0
            return
        void op2r(OP_WRITE, pt(P_SESHDR), 5)
        fields(1)
        for s in 0 to NDOCS - 1
            void op3r(OP_XFER, CTX_BASE + (s as uword) * CTX_SIZE, CTX_SIZE, 1)
        if @(pt(P_CLIP_HAS)) != 0 and peekw(pt(P_CLIP_LEN)) != 0
            void op3r(OP_XFER, CLIPBUF, peekw(pt(P_CLIP_LEN)), 1)
        op0(OP_CLOSE_W)
    }

    sub slot_restore(ubyte s) {
        ; Bring slot s back up (was edit.p8 slot_restore). Its context block is already in CLIP_BANK
        ; (read straight off disk), so OP_LOAD_CTX scatters filename, cursor and view flags into
        ; main's globals for free; all that is left is to reopen the document and fix up the fields
        ; the RELOAD owns rather than the context.
        ;
        ; Order matters: OP_LOAD_FILE runs AFTER OP_LOAD_CTX precisely so that the fresh load wins on
        ; line_count and the xarena bump position - replaying a saved arena position onto a freshly
        ; loaded document would hand every line record a bogus far pointer.
        op1(OP_LOAD_CTX, s)
        ubyte got = 0
        if @(pt(P_FILENAME)) != 0
            got = opr(OP_LOAD_FILE)             ; drops the DOS status itself on a miss
        if got == 0 {
            if @(pt(P_FILENAME)) != 0
                @(pt(P_LOST))++                 ; moved or deleted since the hand-off - an empty slot
            op0(OP_BLANK)                       ; beats taking the whole session down with it
            op1(OP_SAVE_CTX, s)
            return
        }
        op0(OP_UNDO_INIT)                       ; undo cleared (the reload reset the arena - every
                                                ; saved snapshot pointer in the restored rings is
                                                ; meaningless) + the gutter refit to the line count
        if s == @(pt(P_ACT)) and peekw(pt(P_BERRLINE)) != 0     ; a BASLOAD error beats the saved
            pokew(pt(P_CUR_ROW), peekw(pt(P_BERRLINE)) - 1)     ; cursor (its line#s are 1-based)
        if peekw(pt(P_CUR_ROW)) >= peekw(pt(P_LINECOUNT))       ; the file may have shrunk
            pokew(pt(P_CUR_ROW), peekw(pt(P_LINECOUNT)) - 1)
        if peekw(pt(P_TOP_LINE)) > peekw(pt(P_CUR_ROW))         ; the error jump (or a shorter file)
            pokew(pt(P_TOP_LINE), 0)                            ; can strand the saved scroll pos -
        uword trows = @(pt(P_TEXTROWS)) as uword                ; pull the cursor back on screen
        if peekw(pt(P_CUR_ROW)) - peekw(pt(P_TOP_LINE)) >= trows
            pokew(pt(P_TOP_LINE), peekw(pt(P_CUR_ROW)) - trows + 1)
        @(pt(P_MOD)) = 0
        if @(pt(P_SPILL) + s) != 0 {            ; it was untitled when we spilled it - keep it so
            void strings.copy(pt(P_FILENAME), pt(P_FNBUF))
            @(pt(P_FILENAME)) = 0
            @(pt(P_MOD)) = 1
            op0(OP_DEL_FNBUF)                   ; the temp file has done its job
        }
        @(pt(P_SELA)) = 0                       ; a selection across a reload is more confusing than
        @(pt(P_SELC)) = 0                       ; useful - the anchor refers to a pre-edit document
        @(pt(P_DIRTY)) = 0
        op1(OP_SAVE_CTX, s)
    }

    sub ses_restore() -> ubyte {
        ; Rebuild the workspace ed.run describes (was edit.p8 restore_run_state). Returns 1 if a
        ; session was restored - main's start() then skips its fresh-launch setup. The file is
        ; consumed either way: a stale ed.run left by a crash must not resurrect itself.
        if opr(OP_OPEN_R) == 0          ; no ed.run on a normal launch (the dispatcher drops the
            return 0                    ; FILE NOT FOUND status itself)
        bool ok = op2r(OP_READ, pt(P_TMPBUF), 5) == 5
        if ok {
            ubyte m                     ; signature AND version in one compare - an ed.run from an
            for m in 0 to 4 {           ; older EDIT is rejected, never scattered into the globals
                if @(pt(P_TMPBUF) + m) != @(pt(P_SESHDR) + m)
                    ok = false
            }
        }
        if not ok {
            op0(OP_FINISH_R)            ; close + consume the unusable file
            @(pt(P_FAILED)) = 1         ; say so rather than silently opening a blank editor
            return 0
        }
        fields(0)
        ubyte s                         ; the contexts land straight in the bank they live in
        for s in 0 to NDOCS - 1 {
            if op3r(OP_XFER, CTX_BASE + (s as uword) * CTX_SIZE, CTX_SIZE, 0) == 0
                ok = false
        }
        if @(pt(P_ACT)) >= NDOCS
            @(pt(P_ACT)) = 0
        if peekw(pt(P_CLIP_LEN)) > CLIP_MAX
            pokew(pt(P_CLIP_LEN), CLIP_MAX)
        if ok and @(pt(P_CLIP_HAS)) != 0 and peekw(pt(P_CLIP_LEN)) != 0 {
            if op3r(OP_XFER, CLIPBUF, peekw(pt(P_CLIP_LEN)), 0) == 0 {
                @(pt(P_CLIP_HAS)) = 0   ; truncated: a partial clipboard is worse than none
                pokew(pt(P_CLIP_LEN), 0)
            }
        }
        op0(OP_FINISH_R)                ; close + delete: ed.run is one-shot
        if not ok {
            @(pt(P_FAILED)) = 1         ; contexts short-read: the slots below would be junk
            return 0
        }

        for s in 0 to NDOCS - 1         ; now the documents - OP_LOAD_FILE needs the read channel
            slot_restore(s)             ; OP_FINISH_R just freed
        op1(OP_ACTIVATE, @(pt(P_ACT)))
        return 1
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

    sub draw_hist_hint(ubyte statusrow, bool ww_hint) {
        ; "^Hist" on the right of the prompt bar, telling the user UP recalls. Drawn whenever the
        ; prompt HAS a category, empty ring or not - otherwise it only ever appears after the user
        ; has already found the feature without it. The arrow carries the accent colour so it reads
        ; as an affordance rather than as part of the prompt text.
        ubyte c = SCR_W - 6                     ; 5 wide + a 1-column right margin
        if ww_hint
            c -= 16                             ; clear of "Whole Word  Off", which sits at SCR_W-16
        txt.setchr(c, statusrow, SC_UP)
        txt.setclr(c, statusrow, (theme.CB_BAR & $f0) | theme.ACCEL_FG)
        put_str_at(c + 1, statusrow, "Hist")
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

    ; ---- program hand-off (exit path) ----
    ; Both print a command line on the BASIC screen, then feed CR + RUN + CR through the 10-byte
    ; keyboard queue so BASIC re-reads the line. Moved here from edit.p8 to reclaim main low RAM:
    ; they run ONCE on exit and touch only KERNAL/VERA (no $A000-window banking of their own), so an
    ; overlay is a safe home. prog/name point into main's low RAM, which stays mapped under bank 10.
    sub print_ptr(uword p) {
        while @(p) != 0 {
            txt.chrout(@(p))
            p++
        }
    }

    sub chain_load(uword prog @R0) {
        ; LOAD + RUN an arbitrary .prg (used for the EDCFG hand-off).
        txt.chrout($93)                         ; clear screen, cursor home
        txt.nl()
        txt.print("load")
        txt.chrout($22)                         ; "
        print_ptr(prog)
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

    sub chain_basload(uword name @R0) {
        ; print `BASLOAD"name"` and run it (F5 hand-off). The screen dance is unchanged from edit.p8:
        ; the col-10 reminder clears BASIC's "READY." and the injected RETURN re-reads only row 1.
        txt.chrout($93)                         ; clear screen, cursor home
        txt.plot(7, 0)
        txt.print("*press f8 to return to edit*")
        txt.plot(0, 0)                          ; home for the inject dance (cursor rides over the reminder)
        txt.nl()                                ; -> row 1
        txt.print("basload")                    ; command on row 1 - inject re-reads this
        txt.chrout($22)                         ; "
        print_ptr(name)
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
}

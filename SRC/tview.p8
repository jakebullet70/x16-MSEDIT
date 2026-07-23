; tview - read-only paged text / hex file viewer for EDIT, run from a HIRAM bank overlay.
;
; Ported from XFMGR2's tview.p8 (its standalone viewer), adapted for EDIT: stock diskio, EDIT's
; theme colours, a runtime-read screen width (works in 80- AND 40-column modes), and the ZSM
; music-header breakout dropped (EDIT views text/BASIC source, not music). Built as a %output
; library overlay loaded into its own reserved HIRAM bank and called via `extsub @bank`.
;
; Controls:  PgDn/PgUp page   T/Home top   B bottom   H hex<->text   F find   N/Space next   Q/Esc quit
; Text mode caches up to 48 page-tops for backward paging; hex mode uses a 32-bit offset (any size).
; Hex mode needs >= 72 columns, so it is disabled in 40-column mode.
;
; Call contract: the caller keeps the screen in its text mode and passes view_file(nameptr, theme_id);
; the overlay applies the theme (its own theme.p8 copy) so it paints in EDIT's current colours, copies
; the filename in, runs its own key loop, and returns. The caller repaints afterwards.

%import textio
%import diskio
%import strings
%import theme
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; Jump table: the compiler prepends `jmp start` at $A000 (library init), so $A000 = start,
    ; $A003 = view_file. KEEP module-level vars UNINITIALIZED (no "= ...") - prog8 emits a block's
    ; initialized data BEFORE its code, which would shove the jump table off $A003.
    %jmptable ( main.view_file )

    const ubyte VTOP    = 1            ; first text row (row 0 = header bar)
    const ubyte VROWS   = 28           ; content rows 1..28 (screen is 30 rows in both modes)
    const ubyte SCR_BOT = 29           ; footer row
    const uword HEXPAGE = VROWS * 16   ; bytes shown per hex page

    ubyte[256] viewbuf                 ; read buffer (up to 250 bytes/call)
    ubyte[81] namebuf                  ; the file to view (80 chars + NUL); filled per call
    ubyte g_key                        ; last key read

    ubyte SCR_W                        ; screen width, read once per view (80 or 40)
    ubyte VWIDTH                       ; text wrap column = SCR_W - 1 (keep off the last col)
    ; derived setclr colours (split from EDIT's theme bytes on entry; uninitialized -> BSS tail)
    ubyte c_bar_fg, c_bar_bg           ; status/header bar: fg on bg
    ubyte c_bar_key                    ; hotkey-letter fg (on the bar bg)
    ubyte c_con_fg, c_con_bg           ; content area: fg on bg
    ubyte c_find                       ; found-text highlight (combined setclr byte)

    ; --- viewer state ---
    long[48] view_pages                ; text-mode page-top offsets (backward-paging cache; <= 64/prog8)
    bool view_eof                      ; the last rendered page reached end-of-file
    bool view_hex                      ; showing hex dump (vs text)
    long view_off                      ; hex-mode current page top offset
    ubyte view_page                    ; text-mode current page index
    ubyte view_known                   ; text-mode highest page index with a known offset
    ubyte[34] view_find                ; in-file search term (<= 32 chars + NUL)
    long view_next                     ; offset to resume "find next" from
    long view_match                    ; offset of the last search hit
    ubyte saved_page                   ; text page stashed across a hex excursion (H toggle)
    long hex_entry_off                 ; view_off on entering hex; unchanged -> restore saved_page

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. No UI/system init - the
        ; caller owns the screen. Call ONCE after load.
    }

    sub view_file(uword nameptr @R0, ubyte theme_id @R1) {
        ; real entry ($A003). Consume @R0/@R1 FIRST - diskio/strings calls clobber cx16.r0-r3.
        ubyte tid = theme_id
        void strings.copy(nameptr, namebuf)
        theme.apply(tid)                    ; paint in EDIT's current scheme (our own theme.p8 copy)
        c_bar_bg  = theme.CB_BAR >> 4
        c_bar_fg  = theme.CB_BAR & $0f
        c_bar_key = theme.ACCEL_FG
        c_con_bg  = theme.CB_BODY >> 4
        c_con_fg  = theme.CB_BODY & $0f
        c_find    = theme.CB_MARK
        SCR_W  = txt.width()
        VWIDTH = SCR_W - 1
        view_run()
    }

    ; ---------- helpers ----------

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
    }

    sub bar_fill(ubyte row) {
        ; full-width bar via setchr/setclr (no cursor move, so the last column is safe to fill)
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, (c_bar_bg << 4) | c_bar_fg)
        }
        txt.color2(c_bar_fg, c_bar_bg)
    }

    sub bar_key(str s) {
        ; print a highlighted hotkey (accent on the bar), then revert to normal bar text
        txt.color2(c_bar_key, c_bar_bg)
        txt.print(s)
        txt.color2(c_bar_fg, c_bar_bg)
    }

    sub print_trunc(str s, ubyte maxlen) {
        ubyte i = 0
        while i < maxlen and s[i] != 0 {
            txt.chrout(s[i])
            i++
        }
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub scr_of(ubyte b) -> ubyte {
        ; ASCII ($20..$7E) -> screen code for setchr (writes VRAM directly, no control-code scroll).
        ; PETSCII-lowercase charset: a-z fold to $01..$1A, A-Z stay $41..$5A, $20..$3F map 1:1.
        if b >= $61 and b <= $7A
            return b - $60
        if b >= $41 and b <= $5A
            return b
        if b < $40
            return b
        return b - $40
    }

    ; ---------- text page render ----------

    sub view_render(long start_off, bool draw) -> long {
        ; render (or, draw=false, only MEASURE) one page of text from byte offset start_off; return
        ; the offset where the next page begins and set view_eof at end-of-file.
        view_eof = false
        ubyte br
        if draw {
            txt.color2(c_con_fg, c_con_bg)
            for br in VTOP to VTOP + VROWS - 1
                blank_span(0, SCR_W - 2, br)
        }
        if not diskio.f_open(namebuf) {
            if draw {
                txt.plot(0, VTOP)
                txt.print("cannot open file.")
            }
            view_eof = true
            return start_off
        }
        long toskip = start_off
        ubyte lastskip = 0
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            lastskip = viewbuf[lsb(got) - 1]
            toskip -= got
        }
        long consumed = start_off
        ubyte row = 0
        ubyte col = 0
        bool prev_cr = lastskip == 13      ; swallow a CR/LF split across the page boundary
        bool full = false
        ubyte plen = lsb(strings.length(view_find))
        long mend = view_match + plen
        bool line_head = false             ; the line being drawn starts with '#' (markdown heading)
        ubyte head_col = theme.C_KEYWORD   ; its colour: h1_col for '#', h2_col for '##'+
        ; markdown heading colours, precomputed once. Normally '#'=C_KEYWORD, '##'+=C_FUNCTION; the
        ; CLASSIC theme (id 1) SWAPS the two here, per user preference, without touching the palette
        ; (so BASIC keyword/function syntax colouring is unaffected).
        ubyte h1_col = theme.C_KEYWORD
        ubyte h2_col = theme.C_FUNCTION
        if theme.current == 1 {
            h1_col = theme.C_FUNCTION
            h2_col = theme.C_KEYWORD
        }
        repeat {
            uword n = diskio.f_read(&viewbuf, 250)
            if n == 0 {
                view_eof = true
                break
            }
            ubyte cnt = lsb(n)
            ubyte j
            for j in 0 to cnt-1 {
                ubyte ch = viewbuf[j]
                consumed++
                if ch == 10 and prev_cr {
                    prev_cr = false
                    continue
                }
                prev_cr = false
                if ch == 13 or ch == 10 {
                    if ch == 13
                        prev_cr = true
                    row++
                    col = 0
                    if row >= VROWS {
                        full = true
                        break
                    }
                } else {
                    if ch < 32 or ch > 126
                        ch = '.'
                    if draw {
                        txt.setchr(col, VTOP + row, scr_of(ch))
                        if col == 0 {
                            line_head = ch == '#'                ; markdown heading: first char '#'
                            head_col = h1_col
                            if line_head and j < cnt-1 and viewbuf[j+1] == '#'
                                head_col = h2_col                ; '##' (or deeper): different colour
                        }
                        if line_head
                            txt.setclr(col, VTOP + row, head_col)
                        if plen != 0 and consumed-1 >= view_match and consumed-1 < mend
                            txt.setclr(col, VTOP + row, c_find)  ; find-highlight wins over heading
                    }
                    col++
                    if col >= VWIDTH {
                        row++
                        col = 0
                        if row >= VROWS {
                            full = true
                            break
                        }
                    }
                }
            }
            if full
                break
        }
        diskio.f_close()
        return consumed
    }

    ; ---------- hex dump (needs >= 72 columns) ----------

    sub hex_digit(ubyte v) -> ubyte {
        if v < 10
            return '0' + v
        return 'a' + (v - 10)           ; source 'a' = $41 -> shows as A..F in the lowercase charset
    }

    sub put_hex8(ubyte b) {
        txt.chrout(hex_digit(b >> 4))
        txt.chrout(hex_digit(b & 15))
    }

    sub put_hex24(long v) {
        put_hex8((v >> 16) as ubyte)
        put_hex8((v >> 8) as ubyte)
        put_hex8(v as ubyte)
    }

    sub view_render_hex(long start_off) -> long {
        view_eof = false
        ubyte br
        txt.color2(c_con_fg, c_con_bg)
        for br in VTOP to VTOP + VROWS - 1
            blank_span(0, SCR_W - 2, br)
        if not diskio.f_open(namebuf) {
            txt.plot(0, VTOP)
            txt.print("cannot open file.")
            view_eof = true
            return start_off
        }
        long toskip = start_off
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        long off = start_off
        ubyte row = 0
        repeat {
            ubyte cnt = lsb(diskio.f_read(&viewbuf, 16))
            if cnt == 0 {
                view_eof = true
                break
            }
            txt.plot(0, VTOP + row)
            put_hex24(off)
            txt.print(": ")
            ubyte i
            for i in 0 to 15 {
                if i < cnt {
                    put_hex8(viewbuf[i])
                    txt.spc()
                } else {
                    txt.print("   ")
                }
            }
            txt.spc()
            for i in 0 to cnt-1 {
                ubyte ch = viewbuf[i]
                if ch < 32 or ch > 126
                    ch = '.'
                txt.setchr(57 + i, VTOP + row, scr_of(ch))   ; ascii col = 6+2+48+1 = 57
            }
            off += cnt
            row++
            if cnt < 16 {
                view_eof = true
                break
            }
            if row >= VROWS
                break
        }
        diskio.f_close()
        return off
    }

    ; ---------- search ----------

    sub view_fold(ubyte b) -> ubyte {
        ; ASCII case fold A-Z -> a-z
        if b >= $41 and b <= $5a
            return b + $20
        return b
    }

    sub view_find_at(long from) -> bool {
        ; scan from byte offset `from` for view_find (case-insensitive); set view_match on a hit
        ubyte plen = lsb(strings.length(view_find))
        if plen == 0
            return false
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Working...")
        if not diskio.f_open(namebuf)
            return false
        long toskip = from
        while toskip != 0 {
            uword want = 250
            if toskip < 250
                want = toskip as uword
            uword got = diskio.f_read(&viewbuf, want)
            if got == 0
                break
            toskip -= got
        }
        long pos = from
        ubyte mi = 0
        bool found = false
        repeat {
            ubyte cnt = lsb(diskio.f_read(&viewbuf, 250))
            if cnt == 0
                break
            ubyte j
            for j in 0 to cnt-1 {
                ubyte b = view_fold(viewbuf[j])
                if b == view_fold(view_find[mi]) {
                    mi++
                    if mi == plen {
                        view_match = pos - plen + 1
                        found = true
                        break
                    }
                } else {
                    mi = 0
                    if b == view_fold(view_find[0])
                        mi = 1
                }
                pos++
            }
            if found
                break
        }
        diskio.f_close()
        return found
    }

    sub view_read_find() -> bool {
        ; read a search term on the footer row; false if cancelled or empty
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Find: ")
        ubyte n = 0
        view_find[0] = 0
        txt.plot(7, SCR_BOT)
        repeat {
            g_key = wait_key()
            if g_key == 13 {
                view_find[n] = 0
                return n != 0
            }
            if g_key == 27 or g_key == 3 {
                view_find[0] = 0
                return false
            }
            if g_key == 20 {                    ; backspace
                if n != 0 {
                    n--
                    view_find[n] = 0
                    txt.plot(7 + n, SCR_BOT)
                    txt.spc()
                    txt.plot(7 + n, SCR_BOT)
                }
            } else {
                if theme.ISO_MODE {
                    if g_key >= $61 and g_key <= $7a
                        g_key -= $20
                } else {
                    if g_key >= $c1 and g_key <= $da
                        g_key -= $80
                }
                if n < 32 and g_key >= 32 and g_key < 127 {
                    view_find[n] = g_key
                    txt.chrout(g_key)
                    n++
                }
            }
        }
    }

    sub view_notify(str m) {
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(m)
        sys.wait(75)
    }

    sub view_jump() {
        view_next = view_match + 1
        if view_hex {
            view_off = view_match - (view_match & 15)
        } else {
            view_seek_page(view_match)
        }
    }

    sub view_seek_page(long target) {
        ; rebuild the text page chain from the top up to the page holding `target`, so PgUp still
        ; scrolls back above a search hit
        view_pages[0] = 0
        view_page = 0
        view_known = 0
        repeat {
            long nxt = view_render(view_pages[view_page], false)
            if view_eof
                break
            if target < nxt
                break
            if view_page + 1 >= 48
                break
            view_pages[view_page+1] = nxt
            view_known = view_page + 1
            view_page++
        }
    }

    sub file_len() -> long {
        if not diskio.f_open(namebuf)
            return 0
        long total = 0
        repeat {
            uword n = diskio.f_read(&viewbuf, 250)
            if n == 0
                break
            total += n
        }
        diskio.f_close()
        return total
    }

    sub view_bottom() {
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.print(" Working...")
        if view_hex {
            long sz = file_len()
            view_off = 0
            while sz - view_off > HEXPAGE
                view_off += HEXPAGE
        } else {
            view_pages[0] = 0
            view_page = 0
            view_known = 0
            long nxt
            repeat {
                nxt = view_render(view_pages[view_page], false)
                if view_eof {
                    if nxt == view_pages[view_page] and view_page != 0
                        view_page--
                    break
                }
                if view_page + 1 >= 48
                    break
                view_pages[view_page+1] = nxt
                view_known = view_page + 1
                view_page++
            }
        }
    }

    ; ---------- footer ----------

    sub draw_footer(long nxt) {
        ; per-page status bar. Full key legend on a wide screen; a compact one at 40 columns.
        bar_fill(SCR_BOT)
        txt.plot(0, SCR_BOT)
        txt.spc()
        if SCR_W >= 80 {
            bar_key("PgDn/PgUp")
            txt.print("  ")
            bar_key("T")
            txt.print("op  ")
            bar_key("B")
            txt.print("ottom  ")
            bar_key("H")
            if view_hex
                txt.print(" text  ")
            else
                txt.print("ex  ")
            bar_key("F")
            txt.print("ind  ")
            bar_key("N")
            txt.print("ext  ")
            bar_key("Q")
            txt.print("uit")
            if view_find[0] != 0 {
                txt.print("   (")
                bar_key("Space")
                txt.print(":Next)")
            }
        } else {
            ; 40-col: keep it under the width, no right-justified position indicator
            bar_key("PgDn/Up")
            txt.print(" ")
            bar_key("T")
            txt.print("op ")
            bar_key("B")
            txt.print("ot ")
            bar_key("F")
            txt.print("ind ")
            bar_key("Q")
            txt.print("uit")
            return
        }
        ; right-justified position indicator (wide screen only): page/offset [+ END]
        ubyte w
        if view_hex
            w = 7                        ; "$" + 6 hex digits
        else {
            ubyte pg = view_page + 1
            w = 4
            if pg >= 10
                w = 5
            if pg >= 100
                w = 6
        }
        if view_eof
            w += 6                       ; " (END)"
        txt.plot(SCR_W - 1 - w, SCR_BOT)
        if view_hex {
            txt.chrout('$')
            put_hex24(view_off)
        } else {
            txt.print("Pg:")
            txt.print_uw(view_page + 1)
        }
        if view_eof
            txt.print(" (END)")
    }

    ; ---------- main view loop ----------

    sub view_run() {
        txt.color2(c_con_fg, c_con_bg)
        txt.clear_screen()
        bar_fill(0)                        ; header bar (row 0)
        txt.plot(0, 0)
        txt.print(" VIEW: ")
        print_trunc(namebuf, SCR_W - 8)
        view_hex = false
        view_off = 0
        view_page = 0
        view_known = 0
        view_next = 0
        view_find[0] = 0
        view_pages[0] = 0
        repeat {
            long nxt
            if view_hex
                nxt = view_render_hex(view_off)
            else
                nxt = view_render(view_pages[view_page], true)
            draw_footer(nxt)

            g_key = wait_key()
            if theme.ISO_MODE {
                if g_key >= $61 and g_key <= $7a
                    g_key -= $20
            } else {
                if g_key >= $c1 and g_key <= $da
                    g_key -= $80
            }
            when g_key {
                27, 3, 'q' -> return
                2 -> {                          ; PgDn: next page
                    if not view_eof {
                        if view_hex {
                            view_off += HEXPAGE
                        } else if view_page >= view_known {
                            if view_page + 1 < 48 {
                                view_pages[view_page+1] = nxt
                                view_known = view_page + 1
                                view_page++
                            }
                        } else {
                            view_page++
                        }
                    }
                }
                130 -> {                        ; PgUp: previous page
                    if view_hex {
                        if view_off >= HEXPAGE
                            view_off -= HEXPAGE
                        else
                            view_off = 0
                    } else if view_page != 0 {
                        view_page--
                    }
                }
                't', 19 -> {                    ; T / Home: top
                    if view_hex
                        view_off = 0
                    else
                        view_page = 0
                }
                'b' -> view_bottom()            ; B: last page
                'h' -> {                        ; toggle hex / text (hex needs >= 72 cols)
                    if view_hex {
                        view_hex = false
                        if view_off == hex_entry_off
                            view_page = saved_page
                        else
                            view_seek_page(view_off)
                    } else if SCR_W >= 72 {
                        saved_page = view_page
                        view_off = view_pages[view_page]
                        view_off = view_off - (view_off & 15)
                        hex_entry_off = view_off
                        view_hex = true
                    } else {
                        view_notify(" hex needs 80 columns")
                    }
                }
                'f' -> {                        ; find: prompt, search from the top
                    if view_read_find() {
                        if view_find_at(0)
                            view_jump()
                        else
                            view_notify(" not found")
                    }
                }
                'n', ' ' -> {                   ; N / Space: find next
                    if view_find_at(view_next)
                        view_jump()
                    else
                        view_notify(" not found")
                }
            }
        }
    }
}

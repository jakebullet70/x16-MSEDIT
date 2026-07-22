; syntax - BASIC source syntax colouring for the EDIT text editor.
;
; classify() scans ONE line of PETSCII text and writes a per-column colour byte into
; a caller buffer (one setclr colour per document column). BASIC highlighting is
; STATELESS per line - strings, REM comments and DATA all end at end-of-line, so no
; state carries between lines. That keeps this a pure leaf: it reads the line via a
; pointer, writes colours via a pointer, and needs nothing but its own keyword table.
;
; Text is PETSCII (as stored in editbuf / returned by edoc.load). Keyword matching is
; case-insensitive via fold(): both the input letters and the (PETSCII-encoded) table
; literals are folded to a canonical range, so PRINT / print / Print all match, and the
; match is robust to either PETSCII letter convention.
;
; Colours all keep the black background nibble ($0x) - a dark IDE look - so the editor's
; selection (CB_MARK) and cursor (CB_CUR) passes, which run AFTER this in draw_text_row,
; still override cleanly.

%import theme

syntax {
    %option ignore_unused

    ; REM is matched specially (it comments the rest of the line), so it's kept out of the tables.
    str rem_kw = "REM"

    ; X16 BASIC keyword sets: Commodore BASIC V2 + the Commander X16 additions. Statements are
    ; coloured as keywords; value-returning functions are coloured yellow (like sub names in an IDE
    ; theme). The blobs themselves (~450 B of space-delimited PETSCII) were moved OUT of low RAM into
    ; the misc overlay to reclaim editor RAM; these are pointers into MISC_BANK, set by set_kw() at
    ; startup, and are only valid while that bank is mapped - lookup() maps it around the matching.
    ; kw_enabled is false until the overlay hands them over; if misc.ovl is missing, keyword/function
    ; colouring is simply skipped (strings, numbers, REM and ## comments still colour).
    uword kw_stmt_p, kw_stmtx_p, kw_func_p
    ubyte kw_bank
    bool kw_enabled = false

    sub set_kw(uword a @R0, uword b @R1, uword c @R2, ubyte bank @R3) {
        kw_stmt_p = a
        kw_stmtx_p = b
        kw_func_p = c
        kw_bank = bank
        kw_enabled = true
    }

    sub fold(ubyte b) -> ubyte {
        ; letters -> a single canonical range ($41-$5A) so either case matches; else self.
        if b >= $41 and b <= $5a
            return b                     ; PETSCII 'a'-'z' / ISO 'A'-'Z' (already canonical)
        if b >= $c1 and b <= $da
            return b - $80               ; PETSCII 'A'-'Z' (also the PETSCII keyword-table literals) -> $41-$5A
        if theme.ISO_MODE and b >= $61 and b <= $7a
            return b - $20               ; ISO 'a'-'z' document bytes -> $41-$5A
        return b
    }

    sub is_letter(ubyte b) -> bool {
        if theme.ISO_MODE
            return (b >= $41 and b <= $5a) or (b >= $61 and b <= $7a)
        return (b >= $41 and b <= $5a) or (b >= $c1 and b <= $da)
    }

    sub is_digit(ubyte b) -> bool {
        return b >= $30 and b <= $39
    }

    sub eq(uword a, uword b, ubyte n) -> bool {
        ; compare n bytes case-insensitively (letters folded; '$' etc. literal)
        ubyte i
        for i in 0 to n - 1 {
            if fold(@(a + i)) != fold(@(b + i))
                return false
        }
        return true
    }

    sub in_blob(uword blob, uword tp, ubyte tlen) -> bool {
        ; true if token tp[0..tlen) matches a whole space-delimited word in blob (folded).
        ; (s hoisted - prog8 vars are function-scoped, no block scope.)
        ubyte i = 0
        ubyte s
        while @(blob + i) != 0 {
            s = i                                   ; word start
            while @(blob + i) != 0 and @(blob + i) != $20
                i++
            if (i - s) == tlen and eq(blob + s, tp, tlen)
                return true
            while @(blob + i) == $20                ; skip the separator(s)
                i++
        }
        return false
    }

    sub lookup(uword tp, ubyte tlen) -> ubyte {
        ; classify an identifier token: 2 = REM (comment), 1 = statement keyword,
        ; 3 = built-in function, 0 = plain.
        if tlen == 3 and eq(tp, rem_kw, 3)         ; rem_kw + tp are low RAM - test before mapping
            return 2
        if not kw_enabled
            return 0                                ; overlay absent -> no keyword colouring
        ; The blobs live in MISC_BANK; map it around the reads. in_blob reads @(blob+i) from the
        ; bank and eq() reads the token tp from low RAM, which stays mapped under the $A000 window.
        cx16.push_rambank(kw_bank)
        ubyte r = 0
        if in_blob(kw_stmt_p, tp, tlen)
            r = 1
        else if in_blob(kw_stmtx_p, tp, tlen)
            r = 1
        else if in_blob(kw_func_p, tp, tlen)
            r = 3
        cx16.pop_rambank()
        return r
    }

    sub classify_md(uword src, ubyte slen, uword dest) {
        ; Markdown colouring: minimal, two colours. A line whose FIRST character is '#' (so '#',
        ; '##', '###' ... all count) is a heading and the whole line gets C_KEYWORD; every other
        ; line is plain body text (C_DEFAULT). Line-oriented and stateless, like the BASIC path.
        ;
        ; '#' (H1) and '##'-or-deeper (H2) get DIFFERENT colours. The "/#" ESCAPE needs no special
        ; case: an escaped heading starts with '/', not '#', so the first-char test leaves it body-
        ; coloured. The '/' is kept verbatim - this is an editor, so what is on disk is what is shown;
        ; dropping a real byte belongs to a rendered view, not here.
        ubyte col = theme.C_DEFAULT
        if slen != 0 and @(src) == '#' {
            col = theme.C_KEYWORD                       ; '#'  heading
            if slen > 1 and @(src + 1) == '#'
                col = theme.C_FUNCTION                  ; '##' (or deeper) subheading
        }
        ubyte i
        for i in 0 to slen - 1
            @(dest + i) = col
    }

    sub classify(uword src, ubyte slen, uword dest) {
        ; fill dest[0..slen) with a per-column colour byte for the PETSCII line at src.
        ubyte i = 0
        ubyte d                             ; scratch lookahead byte (function-scoped in prog8)
        while i < slen {
            ubyte c = @(src + i)
            if c == $22 {                       ; " -> string literal to closing quote or EOL
                @(dest + i) = theme.C_STRING
                i++
                bool closed = false
                while i < slen and not closed {
                    @(dest + i) = theme.C_STRING
                    if @(src + i) == $22
                        closed = true
                    i++
                }
            } else if c == $23 and i + 1 < slen and @(src + i + 1) == $23 {
                while i < slen {                ; ## -> BASLOAD comment: colour the rest of the line
                    @(dest + i) = theme.C_COMMENT
                    i++
                }
            } else {
                if is_letter(c) {               ; identifier / keyword / BASLOAD label
                    ubyte ts = i
                    i++
                    while i < slen {
                        d = @(src + i)
                        ; '.' is a legal char INSIDE a BASLOAD label (DIR.READ.BIN.NUM16), so it
                        ; keeps the whole dotted name as one token. No keyword contains a '.', so a
                        ; label can never match the tables -> it stays default-coloured, and an
                        ; embedded keyword-like fragment (the READ in DIR.READ) is no longer
                        ; mis-coloured as the READ statement.
                        if is_letter(d) or is_digit(d) or d == $2e
                            i++
                        else
                            break
                    }
                    if i < slen and @(src + i) == $24   ; trailing '$' (string-func / var)
                        i++
                    ubyte kind = lookup(src + ts, i - ts)
                    if kind == 2 {              ; REM -> colour the rest of the line
                        while ts < slen {
                            @(dest + ts) = theme.C_COMMENT
                            ts++
                        }
                        i = slen
                    } else {
                        ubyte col = theme.C_DEFAULT
                        if kind == 1
                            col = theme.C_KEYWORD
                        if kind == 3
                            col = theme.C_FUNCTION
                        while ts < i {
                            @(dest + ts) = col
                            ts++
                        }
                    }
                } else {
                    if is_digit(c) {            ; numeric constant / line number
                        while i < slen {
                            d = @(src + i)
                            if is_digit(d) or d == $2e {
                                @(dest + i) = theme.C_NUMBER
                                i++
                            } else
                                break
                        }
                    } else {                    ; operator / punctuation / space
                        @(dest + i) = theme.C_DEFAULT
                        i++
                    }
                }
            }
        }
    }
}

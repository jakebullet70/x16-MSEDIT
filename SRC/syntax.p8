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
    ; coloured as keywords; value-returning functions are coloured yellow (like sub names in an
    ; IDE theme). Stored as space-delimited PETSCII blobs, matched case-insensitively (fold/eq).
    ; This replaced the old uword[] arrays, which cost 188 bytes of lsb/msb pointer tables on top
    ; of the same string bytes. Function forms keep any trailing '$'. Statements are split CBM/X16
    ; only to keep each str well under the 256-byte limit; both classify as keywords.
    str kw_stmt  = "END FOR NEXT DATA INPUT DIM READ LET GOTO RUN IF RESTORE GOSUB RETURN STOP ON WAIT LOAD SAVE VERIFY DEF POKE PRINT CONT LIST CLR CMD SYS OPEN CLOSE GET NEW TO THEN NOT STEP AND OR GO ELSE"
    str kw_stmtx = "VPOKE SCREEN PSET LINE FRAME RECT CIRCLE CHAR MOUSE COLOR LOCATE CLS DOS OLD MON VLOAD BLOAD BSAVE BVERIFY BOOT RESET KEY BANK MENU FONT"
    str kw_func  = "SGN INT ABS USR FRE POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN VAL ASC TAB SPC FN STR$ CHR$ LEFT$ RIGHT$ MID$ VPEEK HEX$ BIN$"

    sub fold(ubyte b) -> ubyte {
        ; letters -> a single canonical range so either PETSCII case matches; else self.
        if b >= $41 and b <= $5a
            return b                     ; PETSCII 'a'-'z'
        if b >= $c1 and b <= $da
            return b - $80               ; PETSCII 'A'-'Z' -> same range
        return b
    }

    sub is_letter(ubyte b) -> bool {
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
        if tlen == 3 and eq(tp, rem_kw, 3)
            return 2
        if in_blob(kw_stmt, tp, tlen)
            return 1
        if in_blob(kw_stmtx, tp, tlen)
            return 1
        if in_blob(kw_func, tp, tlen)
            return 3
        return 0
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
                if is_letter(c) {               ; identifier / keyword
                    ubyte ts = i
                    i++
                    while i < slen {
                        d = @(src + i)
                        if is_letter(d) or is_digit(d)
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

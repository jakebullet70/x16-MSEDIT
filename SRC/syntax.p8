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
; Colours keep the blue background nibble ($6x) so the editor's selection (CB_MARK) and
; cursor (CB_CUR) passes, which run AFTER this in draw_text_row, still override cleanly.

syntax {
    %option ignore_unused

    ; setclr colour bytes: high nibble = bg, low nibble = fg. Background is dark grey (b)
    ; to match the editor's CB_BODY (XFMGR default palette); only the fg varies per token.
    const ubyte C_DEFAULT = $b1         ; white     - normal text / variables / operators
    const ubyte C_KEYWORD = $b7         ; yellow    - BASIC keywords (XFMGR accent)
    const ubyte C_STRING  = $b3         ; cyan      - "quoted strings"
    const ubyte C_NUMBER  = $ba         ; lt red    - numeric constants / line numbers
    const ubyte C_COMMENT = $bd         ; lt green  - REM ... to end of line

    ; REM is matched specially (it comments the rest of the line), so it's kept out of kw.
    str rem_kw = "REM"

    ; X16 BASIC keyword set: Commodore BASIC V2 + the Commander X16 additions. Stored as
    ; PETSCII string literals; matched case-insensitively. String-function forms keep their
    ; trailing '$' because the tokenizer includes a trailing '$' in an identifier token.
    uword[] kw = [
        ; --- CBM BASIC V2 statements ---
        "END", "FOR", "NEXT", "DATA", "INPUT", "DIM", "READ", "LET", "GOTO", "RUN",
        "IF", "RESTORE", "GOSUB", "RETURN", "STOP", "ON", "WAIT", "LOAD", "SAVE",
        "VERIFY", "DEF", "POKE", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN",
        "CLOSE", "GET", "NEW", "TAB", "TO", "FN", "SPC", "THEN", "NOT", "STEP", "AND",
        "OR", "GO", "ELSE",
        ; --- CBM BASIC V2 functions ---
        "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND", "LOG", "EXP", "COS",
        "SIN", "TAN", "ATN", "PEEK", "LEN", "VAL", "ASC",
        "STR$", "CHR$", "LEFT$", "RIGHT$", "MID$",
        ; --- Commander X16 additions ---
        "VPEEK", "VPOKE", "SCREEN", "PSET", "LINE", "FRAME", "RECT", "CIRCLE", "CHAR",
        "MOUSE", "COLOR", "LOCATE", "CLS", "DOS", "OLD", "MON", "VLOAD", "BLOAD",
        "BSAVE", "BVERIFY", "BOOT", "RESET", "KEY", "BANK", "HEX$", "MENU", "FONT",
        "BIN$"
    ]

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

    sub slen_of(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
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

    sub lookup(uword tp, ubyte tlen) -> ubyte {
        ; classify an identifier token: 2 = REM (comment), 1 = keyword, 0 = plain
        if tlen == 3 and eq(tp, rem_kw, 3)
            return 2
        ubyte n = len(kw)
        ubyte k
        for k in 0 to n - 1 {
            uword s = kw[k]
            if slen_of(s) == tlen and eq(tp, s, tlen)
                return 1
        }
        return 0
    }

    sub classify(uword src, ubyte slen, uword dest) {
        ; fill dest[0..slen) with a per-column colour byte for the PETSCII line at src.
        ubyte i = 0
        ubyte d                             ; scratch lookahead byte (function-scoped in prog8)
        while i < slen {
            ubyte c = @(src + i)
            if c == $22 {                       ; " -> string literal to closing quote or EOL
                @(dest + i) = C_STRING
                i++
                bool closed = false
                while i < slen and not closed {
                    @(dest + i) = C_STRING
                    if @(src + i) == $22
                        closed = true
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
                            @(dest + ts) = C_COMMENT
                            ts++
                        }
                        i = slen
                    } else {
                        ubyte col = C_DEFAULT
                        if kind == 1
                            col = C_KEYWORD
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
                                @(dest + i) = C_NUMBER
                                i++
                            } else
                                break
                        }
                    } else {                    ; operator / punctuation / space
                        @(dest + i) = C_DEFAULT
                        i++
                    }
                }
            }
        }
    }
}

; basdet - BASIC .PRG detokenizer: turns a tokenized Commander X16 BASIC program
; back into readable text. Pure worker - it opens, parses and writes files and never
; touches the screen. The UI lives in detok.p8; the only thing this reports back is a
; numeric error code plus the running lines_done counter (and an optional per-line hook).
;
; FILE FORMAT
; A tokenized program is a 2-byte load address (normally $0801) followed by a linked
; list of lines:
;
;     [next-line ptr lo,hi] [line# lo,hi] [tokens / PETSCII ...] $00
;
; and the list ends with a next-line pointer of $0000. The pointers are absolute
; load-time addresses, so they are stale for any program saved from a different load
; address - we WALK the list by the $00 line terminators and use the pointer only to
; spot the end of the program. That makes the parse independent of where it was saved.
;
; TOKENS
; Every table here was extracted from the X16 ROM (bank 4, labels .reslst / .reslst2 /
; .reslst3) rather than copied from a C64 list, and the escape arithmetic below mirrors
; the ROM's own LIST routine byte for byte, so output matches LIST exactly:
;
;   $80-$CB  Commodore BASIC V2 keywords, in ROM order          -> kw0 / kw1
;   $FF      pi (no ASCII form - emitted as the raw $FF byte)
;   $CE xx   the ONLY escape prefix X16 BASIC uses. The second byte indexes ONE
;            continuous list spanning .reslst2 then .reslst3 (81 entries, kx0..kx3):
;              xx = $80..$CF -> index xx - $80    (statements)
;              xx = $D0..$FF -> index xx - $8E    (the function group; the ROM's
;                                                  CMP #$D0 / SBC #$8D path)
;            The two ranges overlap on entries 66..79 - that is the ROM's behaviour,
;            not a bug here: the tokenizer emits $D0+ for functions, and LIST decodes
;            either form. Verified against real programs (SCREEN = $CE $86, RECT =
;            $CE $8A, PSET = $CE $87, COLOR = $CE $8D, LOCATE = $CE $92).
;   $CC-$CD, $CF-$FD  single-byte values above the V2 range are NOT keywords on the
;            X16 (all extensions are escaped) - passed through as literal text.
;
; Tokens are only expanded OUTSIDE quoted strings, and everything after a REM ($8F) is
; literal to end of line - both are exactly where the tokenizer stopped tokenizing, so
; a string or comment containing a high byte survives the round trip.
;
; OUTPUT ENCODING
; CRLF line ends, matching what edoc.save_file writes, so the .bas opens cleanly in EDIT
; and feeds BASLOAD. Program bytes are copied VERBATIM and need no conversion: BASIC is
; stored in unshifted PETSCII, where $41-$5A are the capitals and already coincide with
; ASCII 'A'-'Z'. Only the keyword text is folded (see kw_char) - and only because prog8
; encodes this file's string literals as shifted PETSCII. Copying program bytes straight
; through is what keeps graphics characters inside PRINT strings intact.

%import diskio
%import conv

basdet {
    %option ignore_unused

    const ubyte ERR_OK    = 0
    const ubyte ERR_NOSRC = 1           ; source .prg would not open
    const ubyte ERR_NOTBAS = 2          ; too short / no load address - not a BASIC program
    const ubyte ERR_NODST = 3           ; could not create the output file
    const ubyte ERR_WRITE = 4           ; a write failed part way through
    const ubyte ERR_TRUNC = 5           ; file ended inside a line

    uword lines_done                    ; lines emitted so far - the UI may poll/print this
    uword load_addr                     ; the load address we read from the header
    uword tick_cb = 0                   ; optional "one line done" hook; 0 = none. The UI puts
                                        ; its progress printer here - this module stays UI-free.

    ubyte[256] iobuf                    ; read window over the source file
    uword iolen                         ; bytes currently in iobuf
    uword iopos                         ; read cursor within iobuf
    bool  ioeof

    ubyte[256] linebuf                  ; output line being built
    ubyte llen
    bool  wr_err
    ubyte[2] crlf

    ; ---- keyword tables ----
    ; Space-delimited blobs rather than uword[] pointer arrays (the same trick syntax.p8
    ; uses): indexing walks the blob, which costs nothing here and saves ~320 bytes of
    ; lsb/msb tables. Each blob stays well under the 255-byte str limit. NO entry contains
    ; a space, so the delimiter is unambiguous.

    ; $80-$CB, in ROM order. kw0 = tokens $80-$A5, kw1 = $A6-$CB.
    str kw0 = "END FOR NEXT DATA INPUT# INPUT DIM READ LET GOTO RUN IF RESTORE GOSUB RETURN REM STOP ON WAIT LOAD SAVE VERIFY DEF POKE PRINT# PRINT CONT LIST CLR CMD SYS OPEN CLOSE GET NEW TAB( TO FN"
    str kw1 = "SPC( THEN NOT STEP + - * / ^ AND OR > = < SGN INT ABS USR FRE POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN STR$ VAL ASC CHR$ LEFT$ RIGHT$ MID$ GO"

    ; the $CE-escaped list: .reslst2 (44 entries) followed by .reslst3 (37), indexed 0..80.
    str kx0 = "MON DOS OLD GEOS VPOKE VLOAD SCREEN PSET LINE FRAME RECT CHAR MOUSE COLOR TEST RESET CLS CODEX LOCATE BOOT KEYMAP BLOAD BVLOAD BVERIFY BANK"
    str kx1 = "FMINIT FMNOTE FMDRUM FMINST FMVIB FMFREQ FMVOL FMPAN FMPLAY FMCHORD FMPOKE PSGINIT PSGNOTE PSGVOL PSGWAV PSGFREQ PSGPAN PSGPLAY PSGCHORD"
    str kx2 = "REBOOT POWEROFF I2CPOKE SLEEP BSAVE MENU REN LINPUT# LINPUT BINPUT# HELP BANNER EXEC TILE EDIT SPRITE SPRMEM MOVSPR BASLOAD OVAL RING HBLOAD"
    str kx3 = "VPEEK MX MY MB JOY HEX$ BIN$ I2CPEEK POINTER STRPTR RPT$ MWHEEL TDATA TATTR MOD"

    ; blob boundaries as running totals, so kw_ptr() reads like the table above
    const ubyte KW0_N = 38              ; kw0 holds indices 0..37   (tokens $80-$A5)
    const ubyte KW_N  = 76              ; kw0+kw1 = all of $80-$CB
    const ubyte KX0_N = 25              ; kx0 holds 0..24
    const ubyte KX1_N = 44              ; +19  -> end of .reslst2
    const ubyte KX2_N = 66              ; +22  -> .reslst3 statements
    const ubyte KX_N  = 81              ; +15  -> .reslst3 functions

    ; ---- byte source ----

    sub getb() -> ubyte {
        ; next byte of the source file, refilling iobuf as needed. Sets ioeof at EOF and
        ; returns 0 from then on, so callers can test ioeof after a read instead of
        ; threading a status through every level.
        if iopos >= iolen {
            iolen = diskio.f_read(&iobuf, 256)
            iopos = 0
            if iolen == 0 {
                ioeof = true
                return 0
            }
        }
        ubyte b = iobuf[lsb(iopos)]
        iopos++
        return b
    }

    ; ---- output ----

    sub flush() {
        if llen != 0 {
            if not diskio.f_write(&linebuf, llen)
                wr_err = true
            llen = 0
        }
    }

    sub emit(ubyte c) {
        ; append one byte, flushing when the buffer fills. A detokenized line can be far
        ; longer than BASIC's 88-character input limit (LIST happily produces them), so
        ; the buffer is a window, not a cap - nothing is ever truncated.
        linebuf[llen] = c
        llen++
        if llen >= 240
            flush()
    }

    sub kw_char(ubyte b) -> ubyte {
        ; Fold ONE byte of KEYWORD text to ASCII. prog8 encodes the upper-case letters in
        ; the blobs below as shifted PETSCII ($C1-$DA), so those come back to 'A'-'Z';
        ; $41-$5A is already ASCII upper case and everything else (#, $, (, operators)
        ; is identical in both encodings.
        ;
        ; This deliberately does NOT run over program text. In the unshifted PETSCII the
        ; tokenizer stores, $C1-$DA are GRAPHICS glyphs, not capitals - folding them would
        ; turn the box-drawing in a PRINT string into random letters (the sample programs
        ; in run/BASIC-MISC contain 326 such bytes). Program bytes are copied verbatim so
        ; strings and REM text survive byte for byte; $41-$5A already reads as ASCII
        ; capitals, which is the whole reason the output needs no conversion at all.
        if b >= $c1 and b <= $da
            return b - $80
        return b
    }

    sub emit_str(uword p) {
        while @(p) != 0 {
            emit(@(p))
            p++
        }
    }

    ; ---- keyword lookup ----

    sub kw_skip(uword p, ubyte n) -> uword {
        ; advance past n space-delimited entries; 0 if the blob runs out first
        while n != 0 {
            while @(p) != ' ' {
                if @(p) == 0
                    return 0
                p++
            }
            p++
            n--
        }
        return p
    }

    sub kw_ptr(bool ext, ubyte idx) -> uword {
        if ext {
            if idx < KX0_N
                return kw_skip(kx0, idx)
            if idx < KX1_N
                return kw_skip(kx1, idx - KX0_N)
            if idx < KX2_N
                return kw_skip(kx2, idx - KX1_N)
            if idx < KX_N
                return kw_skip(kx3, idx - KX2_N)
            return 0
        }
        if idx < KW0_N
            return kw_skip(kw0, idx)
        if idx < KW_N
            return kw_skip(kw1, idx - KW0_N)
        return 0
    }

    sub emit_kw(bool ext, ubyte idx) {
        uword p = kw_ptr(ext, idx)
        if p == 0 {
            emit('?')                   ; token outside every table - keep going, don't abort
            return
        }
        while @(p) != 0 and @(p) != ' ' {
            emit(kw_char(@(p)))
            p++
        }
    }

    ; ---- the parse ----

    sub do_line() -> bool {
        ; body of one BASIC line, up to and including its $00 terminator.
        ; false = the file ended mid-line.
        bool inquote = false
        bool inrem = false
        repeat {
            ubyte b = getb()
            if ioeof
                return false
            if b == 0
                return true
            if inrem or inquote {
                if b == $22             ; the closing quote re-enables tokens (REM never ends)
                    inquote = false
                emit(b)
                continue
            }
            if b == $22 {
                inquote = true
                emit(b)
                continue
            }
            if b < $80 {
                emit(b)
                continue
            }
            if b == $ff {
                emit($ff)               ; pi - no ASCII equivalent, pass the byte through
                continue
            }
            if b == $ce {               ; escaped X16 keyword: one more byte to index
                ubyte b2 = getb()
                if ioeof
                    return false
                if b2 < $80 {
                    emit('?')           ; V7/V10 legacy escape the X16 ROM does not implement
                    continue
                }
                if b2 >= $d0
                    emit_kw(true, b2 - $8e)
                else
                    emit_kw(true, b2 - $80)
                continue
            }
            if b <= $cb {
                emit_kw(false, b - $80)
                if b == $8f             ; REM: the tokenizer stopped here, so must we
                    inrem = true
                continue
            }
            emit(b)                     ; $CC-$CD / $CF-$FE: not keywords on the X16
        }
    }

    sub detok(uword srcname, uword dstname) -> ubyte {
        lines_done = 0
        load_addr = 0
        wr_err = false
        ioeof = false
        iolen = 0
        iopos = 0
        llen = 0
        crlf[0] = 13
        crlf[1] = 10

        if not diskio.f_open(srcname) {
            void diskio.status()        ; drop the DOS error so the activity LED stops blinking
            return ERR_NOSRC
        }

        ubyte lo = getb()               ; 2-byte load address header
        ubyte hi = getb()
        if ioeof {
            diskio.f_close()
            return ERR_NOTBAS
        }
        load_addr = mkword(hi, lo)

        ; the output file is created only once the source looks sane, so a bad pick never
        ; leaves a stray empty .bas behind. Delete-then-create with a BARE name in the cwd:
        ; ",w" does not truncate, and an absolute-path scratch silently no-ops on the host FS.
        diskio.delete(dstname)
        void diskio.status()
        if not diskio.f_open_w(dstname) {
            diskio.f_close()
            return ERR_NODST
        }

        ubyte err = ERR_OK
        repeat {
            ubyte l1 = getb()           ; next-line pointer - only ever tested against 0
            ubyte h1 = getb()
            if ioeof
                break                   ; a program that just stops is common enough; accept it
            if l1 == 0 and h1 == 0
                break                   ; proper end of program
            ubyte l2 = getb()           ; line number
            ubyte h2 = getb()
            if ioeof {
                err = ERR_TRUNC
                break
            }
            emit_str(conv.str_uw(mkword(h2, l2)))
            emit(' ')
            if not do_line() {
                err = ERR_TRUNC
                break
            }
            flush()
            if not diskio.f_write(&crlf, 2)
                wr_err = true
            lines_done++
            if tick_cb != 0
                void call(tick_cb)
            if wr_err {
                err = ERR_WRITE
                break
            }
        }

        flush()
        diskio.f_close_w()
        diskio.f_close()
        if err == ERR_OK and wr_err
            err = ERR_WRITE
        return err
    }

    sub err_text(ubyte code) -> uword {
        when code {
            ERR_NOSRC -> return "cannot open that file"
            ERR_NOTBAS -> return "not a BASIC program (no load address)"
            ERR_NODST -> return "cannot create the output file"
            ERR_WRITE -> return "write failed - disk full?"
            ERR_TRUNC -> return "file ends inside a line (truncated .prg)"
        }
        return "ok"
    }
}

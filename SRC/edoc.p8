; edoc - document / storage layer for the EDIT text editor.
;
; The document is a list of text lines. Each line is stored in BANKED RAM
; (the X16 8KB window at $A000, banks 1..255) via the xarena bump allocator,
; length-prefixed:  [len:ubyte][chars...].  Main RAM holds a far-pointer table
; - 3 bytes per line: [bank][off_lo][off_hi] - in a memory() slab (prog8 arrays
; are capped at 256 entries, so a slab indexed by pointer arithmetic is used to
; allow far more lines) plus the line count.
;
; The UI keeps the line under the cursor in its own RAM buffer (editbuf) and
; calls commit() to (re)store it only when the cursor leaves the line or on
; save, so we don't re-allocate on every keystroke. xarena never frees a single
; record, so an edited-and-left line leaks its old slot; the editor reclaims it
; with free compaction on save (write to disk, reset(), reload).

%import xarena
%import diskio
%import theme                           ; theme.ISO_MODE gates the a2p/p2a case-fold (identity in ISO)

edoc {
    %option ignore_unused

    uword max_lines = 6000              ; per-doc line cap. A VARIABLE now (was const 10000): the three
                                        ; documents have different caps (6000 / 2500 / 2500) and the editor
                                        ; sets this per slot on every switch (see edit.p8 SLOT_MAX_LINES).
    const ubyte MAX_LEN   = 250         ; max chars per line (1-byte length prefix)

    ; The line-pointer table lives in BANKED RAM (not scarce low RAM): 3 bytes per
    ; line - [bank][off_lo][off_hi]. 2048 entries per 8KB bank (a power of 2, so
    ; idx -> bank/offset is a cheap shift/mask and an entry never straddles a bank).
    ; With three documents, each table sits in its OWN bank region: tbl_first_bank is
    ; a VARIABLE the editor points at the active doc's first table bank on switch
    ; (Doc A banks 1-3 = up to 6144 slots, Doc B 4-5, Doc C 6-7). Line CONTENT lives in
    ; the banks above all three table regions + the reserved overlay banks (see edit.p8).
    const uword TBL_PER_BANK   = 2048   ; must stay a power of 2
    ubyte tbl_first_bank       = 1      ; first table bank of the ACTIVE doc (set per slot on switch)
    const uword TBL_WIN        = $a000
    uword line_count
    bool  oom                           ; set if an allocation failed (document full)

    uword iobuf = memory("iobuf", 256, 0)   ; disk read chunk buffer (main RAM). 256 = the load_file
                                            ; read size below; was 512 (over-allocated - only 256 used).
    ubyte[252] linebuf                       ; scratch: assembling / reading one line (<= MAX_LEN 250; load
                                             ; force-breaks longer, so 252 = 250 + a 2-byte boundary margin)

    ; result of the last store(): far pointer to the new record
    ubyte r_bank
    uword r_off

    ubyte[2] crlf                       ; line terminator written on save

    ; ASCII <-> PETSCII: keyboard and screen are PETSCII, but text files on disk
    ; are plain ASCII (so they round-trip with the host and other tools). The only
    ; real difference for printable text is the letter case ranges.
    sub a2p(ubyte b) -> ubyte {
        if theme.ISO_MODE
            return b                    ; ISO: internal bytes ARE the disk bytes - no fold
        if b >= $41 and b <= $5a
            return b + $80              ; ASCII A-Z -> PETSCII upper ($C1-$DA)
        if b >= $61 and b <= $7a
            return b - $20              ; ASCII a-z -> PETSCII lower ($41-$5A)
        return b
    }
    sub p2a(ubyte b) -> ubyte {
        if theme.ISO_MODE
            return b                    ; ISO: no fold (also fixes $C1-$DA capital round-trip corruption)
        if b >= $41 and b <= $5a
            return b + $20              ; PETSCII lower -> ASCII a-z
        if b >= $c1 and b <= $da
            return b - $80              ; PETSCII upper -> ASCII A-Z
        return b
    }

    sub init() {
        xarena.reset()
        line_count = 0
        oom = false
    }

    ; ---- far-pointer table accessors (3 bytes per line in the slab) ----

    ; far-table addressing: idx>>11 = idx/2048 = which table bank; idx&$07ff = the
    ; slot within it (both derived from TBL_PER_BANK=2048). Switch to that bank, then
    ; the 3-byte record sits in the $A000 window.
    sub set_entry(uword idx, ubyte bank, uword off) {
        cx16.push_rambank(tbl_first_bank + lsb(idx >> 11))
        uword p = TBL_WIN + (idx & $07ff) * 3
        @(p) = bank
        pokew(p + 1, off)
        cx16.pop_rambank()
    }
    sub ent_bank(uword idx) -> ubyte {
        cx16.push_rambank(tbl_first_bank + lsb(idx >> 11))
        ubyte b = @(TBL_WIN + (idx & $07ff) * 3)
        cx16.pop_rambank()
        return b
    }
    sub ent_off(uword idx) -> uword {
        cx16.push_rambank(tbl_first_bank + lsb(idx >> 11))
        uword o = peekw(TBL_WIN + (idx & $07ff) * 3 + 1)
        cx16.pop_rambank()
        return o
    }

    ; ---- low-level banked record I/O (one bank switch per record; a record
    ;      never straddles a bank boundary, guaranteed by xarena.alloc) ----

    sub store(uword src, ubyte slen) -> bool {
        ; allocate slen+1 bytes and write [slen][chars] into the arena
        if not xarena.alloc(slen + 1) {
            oom = true
            return false
        }
        r_bank = xarena.result_bank
        r_off  = xarena.result_off
        cx16.push_rambank(r_bank)
        uword dst = r_off
        @(dst) = slen
        dst++
        ubyte i = 0
        while i < slen {
            @(dst) = @(src)
            dst++
            src++
            i++
        }
        cx16.pop_rambank()
        return true
    }

    sub get_len(uword idx) -> ubyte {
        return xarena.far_peek(ent_bank(idx), ent_off(idx))
    }

    sub load(uword idx, uword dest) -> ubyte {
        ; copy line idx's chars into dest (main RAM); returns the length
        ubyte bank = ent_bank(idx)
        uword src = ent_off(idx)
        cx16.push_rambank(bank)
        ubyte slen = @(src)
        src++
        ubyte i = 0
        while i < slen {
            @(dest) = @(src)
            dest++
            src++
            i++
        }
        cx16.pop_rambank()
        return slen
    }

    ; ---- undo/redo snapshot access (by explicit far pointer, not the line table) ----
    ; A snapshot is stored with store() (which sets r_bank/r_off); snap_load reads a
    ; [len][chars] record back from an arbitrary far pointer into a main-RAM buffer.
    sub snap_load(ubyte bank, uword off, uword dest) -> ubyte {
        cx16.push_rambank(bank)
        ubyte slen = @(off)
        off++
        ubyte i = 0
        while i < slen {
            @(dest) = @(off)
            dest++
            off++
            i++
        }
        cx16.pop_rambank()
        return slen
    }

    ; ---- line-table operations ----

    sub commit(uword idx, uword src, ubyte slen) -> bool {
        ; (re)store line idx's content from src/slen
        if not store(src, slen)
            return false
        set_entry(idx, r_bank, r_off)
        return true
    }

    sub append(uword src, ubyte slen) -> bool {
        ; add a new line at the end
        if line_count >= max_lines {
            oom = true
            return false
        }
        if not commit(line_count, src, slen)
            return false
        line_count++
        return true
    }

    sub insert_line(uword idx) -> bool {
        ; open a gap at idx by shifting entries idx..count-1 up one slot, high-to-low so
        ; each source entry is read before it is overwritten. slot idx is left unset.
        if line_count >= max_lines {
            oom = true
            return false
        }
        uword i = line_count
        while i > idx {
            set_entry(i, ent_bank(i - 1), ent_off(i - 1))
            i--
        }
        line_count++
        return true
    }

    sub delete_line(uword idx) {
        ; remove entry idx by shifting entries idx+1..count-1 down one slot, low-to-high.
        if line_count == 0
            return
        uword i = idx
        while i + 1 < line_count {
            set_entry(i, ent_bank(i + 1), ent_off(i + 1))
            i++
        }
        line_count--
    }

    ; ---- file load / save ----

    sub flush_line(ubyte slen) {
        ; helper for load_file: append linebuf[0..slen-1] as a new line
        void append(&linebuf, slen)
    }

    sub load_file(str name) -> bool {
        ; replace the document with the contents of `name` (split on CR/LF/CRLF)
        init()
        if not diskio.f_open(name)
            return false
        ubyte ll = 0
        bool prev_cr = false
        repeat {
            uword n = diskio.f_read(iobuf, 256)
            if n == 0
                break
            uword j = 0
            while j < n {
                ubyte ch = @(iobuf + j)
                j++
                if prev_cr and ch == 10 {
                    prev_cr = false             ; swallow LF of a CR/LF pair
                    continue
                }
                prev_cr = false
                if ch == 13 or ch == 10 {
                    if ch == 13
                        prev_cr = true
                    flush_line(ll)              ; terminate the current line
                    ll = 0
                } else {
                    if ch < 32                  ; sanitize stray control bytes (incl tab)
                        ch = 32
                    if ll >= MAX_LEN {          ; force-break over-long lines
                        flush_line(ll)
                        ll = 0
                    }
                    linebuf[ll] = a2p(ch)       ; store as PETSCII
                    ll++
                }
            }
        }
        diskio.f_close()
        if ll > 0                               ; trailing line without a newline
            flush_line(ll)
        if line_count == 0
            void append(&linebuf, 0)            ; never leave an empty document
        return not oom
    }

    sub save_file(str name) -> bool {
        ; write every line as ASCII + a CR/LF terminator
        if not diskio.f_open_w(name)
            return false
        crlf[0] = 13
        crlf[1] = 10
        uword i = 0
        while i < line_count {
            ubyte slen = load(i, &linebuf)      ; PETSCII content
            ubyte j = 0
            while j < slen {                    ; convert to ASCII in place
                linebuf[j] = p2a(linebuf[j])
                j++
            }
            if slen > 0 {
                if not diskio.f_write(&linebuf, slen) {
                    diskio.f_close_w()
                    return false
                }
            }
            if not diskio.f_write(&crlf, 2) {
                diskio.f_close_w()
                return false
            }
            i++
        }
        diskio.f_close_w()
        return true
    }
}

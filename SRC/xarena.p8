; xarena - banked "bump" allocator for the X16 HIRAM window ($A000-$BFFF).
;
; Why a bump allocator and not malloc/free:
;   XTree's data lifetime is append-only during a scan, then bulk-freed on rescan.
;   We never free a single record, so a bump pointer is all we need: O(1) alloc,
;   zero per-record header, zero fragmentation, "free" = reset the pointer.
;
; Storage spans many 8KB banks (1..MAX_BANK). A 16-bit pointer can only see the
; one 8KB window that is currently mapped, so an arena location is a FAR pointer:
;   (bank: ubyte, offset: uword).   No record straddles a bank boundary - if it
;   would not fit in the remaining space, we waste the tail and roll to the next
;   bank (tail waste < ~3% for small records).

%import strings

xarena {
    %option ignore_unused

    ; first bank used for CONTENT. Bank 0 is the Kernal's; edoc reserves a few low
    ; banks for its line-pointer table and bumps this up so content starts above them.
    ubyte first_bank = 1
    ; highest usable bank. Defaults to 255 (a full 2MB machine) but detect_banks()
    ; clamps it to the RAM actually installed: a 512KB machine has 64 banks (0..63),
    ; so the top usable bank is 63. Without this the arena would write to
    ; non-existent banks on smaller machines and silently lose data.
    ubyte max_bank = 255
    const uword WIN_START  = $a000
    const uword WIN_END    = $bf00      ; reserve $bf00-$bfff as scratch / guard

    ; --- allocator state ---
    ubyte cur_bank
    uword cur_ptr
    ubyte high_bank                     ; highest bank touched (for stats / eviction)

    ; --- result of the last alloc(): a far pointer to the reserved space ---
    ubyte result_bank
    uword result_off

    sub detect_banks() {
        ; Clamp the arena to the RAM actually installed. cx16.numbanks() returns the
        ; total bank count (256 for 2MB, 64 for 512KB, ...); banks are 0..count-1 and
        ; bank 0 is system RAM, so the top usable bank is count-1. Call once at startup.
        max_bank = lsb(cx16.numbanks() - 1)
    }

    sub reset() {
        ; Bulk-free everything. No traversal needed.
        cur_bank  = first_bank
        cur_ptr   = WIN_START
        high_bank = first_bank
    }

    sub alloc(uword nbytes) -> bool {
        ; Reserve nbytes; on success result_bank/result_off point at the space.
        ; nbytes must be <= (WIN_END - WIN_START); callers only store small records.
        if cur_ptr + nbytes > WIN_END {
            ; won't fit in the current bank -> roll to the next one
            if cur_bank >= max_bank
                return false
            cur_bank++
            cur_ptr = WIN_START
            if cur_bank > high_bank
                high_bank = cur_bank
        }
        result_bank = cur_bank
        result_off  = cur_ptr
        cur_ptr += nbytes
        return true
    }

    sub add_str(str s) -> bool {
        ; Allocate len+1 bytes and copy the NUL-terminated string into the arena.
        ; On success the far pointer is in result_bank/result_off.
        if not alloc(strings.length(s) + 1)
            return false
        cx16.push_rambank(result_bank)
        uword dst = result_off
        ubyte ix = 0
        ubyte c
        repeat {
            c = s[ix]
            @(dst) = c
            dst++
            ix++
            if c == 0
                break
        }
        cx16.pop_rambank()
        return true
    }

    ; ---- far accessors (caller passes the far pointer) ----

    sub far_peek(ubyte bank, uword off) -> ubyte {
        cx16.push_rambank(bank)
        ubyte v = @(off)
        cx16.pop_rambank()
        return v
    }

    sub far_poke(ubyte bank, uword off, ubyte value) {
        cx16.push_rambank(bank)
        @(off) = value
        cx16.pop_rambank()
    }

    sub read_str(ubyte bank, uword off, str dest) {
        ; Copy a NUL-terminated string from the arena into a main-RAM buffer.
        cx16.push_rambank(bank)
        uword src = off
        ubyte ix = 0
        ubyte c
        repeat {
            c = @(src)
            dest[ix] = c
            src++
            ix++
            if c == 0
                break
        }
        cx16.pop_rambank()
    }
}

; fktest.p8 -- save/restore ALL KERNAL function-key macros to a file.
;
; The X16 KERNAL keeps the programmable F-key / SHIFT+RUN macros in a table
; `fkeytb` = 99 bytes at $A80E in RAM bank 0 (KVARS). Layout: 9 slots x 11 bytes
; (max 10 chars + a NUL terminator), in order F1,F2,...,F8,SHIFT+RUN.
;   slot 0..7 = F1..F8 ; slot 8 (fkeytb+88) = SHIFT+RUN.
; `pfkey` (EXTAPI 7) only WRITES one slot; to snapshot them all we read the
; table directly (bank 0), and to restore we write it back directly.
;
; Source:  x16-rom r49  kernal/cbm/editor.s  (fkeytb / pfkey / set_fkey_defaults)
;          address from  x16emu kernal.sym   (.fkeytb = $A80E, RAM bank 0)
;
; This is a spike proving the "snapshot on start, restore on exit" approach that
; lets EDIT put the F-keys back exactly as it found them (see edit-basload-run).

%import textio
%import diskio

main {
    const ubyte FKBYTES = 99            ; 9 slots x 11 bytes
    const ubyte SLOTLEN = 11            ; bytes per slot (10 chars + NUL)

    ubyte[FKBYTES] snap                 ; snapshot written to / read from the file
    ubyte[FKBYTES] live                 ; scratch: a fresh copy of the live table
    str fkfile  = "fkeys.bin"
    str clobber = "CLOBBERED!"          ; 10 chars: a distinctive test macro

    sub start() {
        txt.print("\nfkey save / restore test\n\n")

        txt.print("current F-key macros:\n")
        show_all()

        ; 1) snapshot the whole table and write it to disk
        read_fkeytb(&snap)
        if not save_file() {
            txt.print("\nSAVE FAILED\n")
            return
        }
        txt.print("\nsaved ")
        txt.print_ub(FKBYTES)
        txt.print(" bytes -> ")
        txt.print(fkfile)
        txt.nl()

        ; 2) clobber a few keys via pfkey, to prove the restore really works
        set_key(1, &clobber, 10)        ; F1
        set_key(7, &clobber, 10)        ; F7
        set_key(8, &clobber, 10)        ; F8
        set_key(9, &clobber, 10)        ; SHIFT+RUN
        txt.print("\nafter clobbering F1/F7/F8/RUN:\n")
        show_all()

        ; 3) restore the whole table from the file
        if not load_file() {
            txt.print("\nLOAD FAILED\n")
            return
        }
        write_fkeytb(&snap)
        txt.print("\nrestored from ")
        txt.print(fkfile)
        txt.print(":\n")
        show_all()

        txt.print("\ndone - saved, clobbered, restored all 9 macros.\n")
        txt.print("press a key to exit.\n")
        while cbm.GETIN2() == 0 {
            ; wait so the results stay on screen (returning to BASIC warm-starts it)
        }
    }

    sub show_all() {
        read_fkeytb(&live)              ; refresh from the real KERNAL table
        ubyte slot
        for slot in 0 to 8 {
            print_label(slot)
            txt.print(": ")
            print_slot(slot)
            txt.nl()
        }
    }

    sub print_label(ubyte slot) {
        if slot == 8 {
            txt.print("RUN")
            return
        }
        txt.chrout('F')
        txt.print_ub(slot + 1)          ; F1..F8
    }

    sub print_slot(ubyte slot) {
        ; print the NUL-terminated macro in `live`, showing controls as <hh>
        ubyte base = slot * SLOTLEN
        ubyte i
        for i in 0 to SLOTLEN - 1 {
            ubyte b = live[base + i]
            if b == 0
                break
            if b >= 32 and b <= 126
                txt.chrout(b)
            else {
                txt.chrout('<')
                txt.print_ubhex(b, false)
                txt.chrout('>')
            }
        }
    }

    ; ---- direct access to the KERNAL fkey table (RAM bank 0 / KVARS) ----

    sub read_fkeytb(uword dest) {
        cx16.r0 = dest
        %asm {{
            php
            sei
            lda  $00                    ; save the current RAM bank
            pha
            stz  $00                    ; select RAM bank 0 (KVARS)
            ldy  #0
_rl:        lda  $a80e,y                ; fkeytb -> dest
            sta  (cx16.r0),y
            iny
            cpy  #99
            bne  _rl
            pla
            sta  $00                    ; restore the RAM bank
            plp
        }}
    }

    sub write_fkeytb(uword src) {
        cx16.r0 = src
        %asm {{
            php
            sei
            lda  $00
            pha
            stz  $00                    ; RAM bank 0 (KVARS)
            ldy  #0
_wl:        lda  (cx16.r0),y            ; src -> fkeytb
            sta  $a80e,y
            iny
            cpy  #99
            bne  _wl
            pla
            sta  $00
            plp
        }}
    }

    ; ---- single-key program via the documented KERNAL API (EXTAPI 7 = pfkey) ----

    sub set_key(ubyte keynum, uword strptr, ubyte mlen) {
        ; keynum 1..8 = F1..F8, 9 = SHIFT+RUN
        cx16.r0 = strptr
        cx16.r1L = keynum
        cx16.r2L = mlen
        %asm {{
            ldx  cx16.r1L
            ldy  cx16.r2L
            lda  #7                     ; EXTAPI_pfkey
            jsr  cx16.extapi
        }}
    }

    ; ---- file I/O ----

    sub save_file() -> bool {
        if not diskio.f_open_w(fkfile)
            return false
        void diskio.f_write(&snap, FKBYTES)
        diskio.f_close_w()
        return true
    }

    sub load_file() -> bool {
        if not diskio.f_open(fkfile)
            return false
        uword n = diskio.f_read(&snap, FKBYTES)
        diskio.f_close()
        return n == FKBYTES
    }
}

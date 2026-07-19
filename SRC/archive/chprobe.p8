; CHPROBE - why does basdet.p8 fail to write on the host file system?
;
; Round 1 disproved the obvious theory: having a read channel and a write channel open at
; the same time works fine. What basdet actually does is ALTERNATE between them - read a
; chunk of the source, write a line, read again - and prog8's f_read / f_write each do
; their own CHKIN / CHKOUT. That interleaving is what this probe models.
;
; It also matters that diskio.f_read CLOSES the read channel by itself when it hits EOF,
; so a later read attempt is operating on a channel that is already gone.
;
; Build:  build.bat archive\chprobe.p8      Run with PAINT16C.PRG in the cwd.

%import textio
%import diskio
%import strings
%zeropage basicsafe

main {
    ubyte[200] buf
    ubyte[80] line

    sub tell(str what) {
        txt.print(what)
        txt.print(" status=")
        txt.print(diskio.status())
        txt.nl()
    }

    sub start() {
        txt.print("chprobe 2 - interleaved read and write\n\n")

        if not diskio.f_open("paint16c.prg") {
            tell("f_open FAILED")
            return
        }
        diskio.delete("probe3.txt")
        void diskio.status()
        if not diskio.f_open_w("probe3.txt") {
            tell("f_open_w FAILED")
            return
        }

        ; alternate exactly the way basdet does: pull a chunk of source, emit a line,
        ; repeat. Report the first cycle that goes wrong rather than only the total.
        ubyte i
        uword total_read = 0
        uword writes_ok = 0
        ubyte failed_at = 0
        for i in 0 to 19 {
            uword got = diskio.f_read(&buf, 100)
            total_read += got

            line[0] = 'l'
            line[1] = 'n'
            line[2] = '0' + i / 10
            line[3] = '0' + i % 10
            line[4] = 13
            line[5] = 10
            if diskio.f_write(&line, 6) {
                writes_ok++
            } else {
                if failed_at == 0 {
                    failed_at = i + 1
                    txt.print("first write failure on cycle ")
                    txt.print_ub(i)
                    txt.print("  after reading ")
                    txt.print_uw(total_read)
                    txt.print(" bytes\n")
                    tell("  at failure:")
                }
            }
        }

        diskio.f_close_w()
        diskio.f_close()

        txt.print("\ncycles      : 20\n")
        txt.print("writes ok   : ")
        txt.print_uw(writes_ok)
        txt.nl()
        txt.print("bytes read  : ")
        txt.print_uw(total_read)
        txt.nl()
        tell("after close :")

        txt.print("\nprobe3.txt on disk: ")
        if diskio.f_open("probe3.txt") {
            uword back = diskio.f_read(&buf, 200)
            diskio.f_close()
            txt.print_uw(back)
            txt.print(" bytes (expect 120)\n")
        } else {
            txt.print("WOULD NOT OPEN\n")
        }
        void diskio.status()
        txt.print("\nPROBE-END\n")
    }
}

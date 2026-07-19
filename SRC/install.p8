; install - self-installer for EDIT, run once from the unpacked release folder.
;
; A normal $0801 PRG. The user copies the release files (edit.prg, edcfg.prg, the .ovl overlays) plus this installer
; into ONE folder on their SD card, boots the X16, CDs into that folder and runs it. It:
;   * reports the folder it is running from,
;   * works out where EDIT should go (see below),
;   * creates that folder on the drive root,
;   * copies the program files into it (255-byte stream copy),
;   * writes the tiny root launcher /ED  ("10 LOAD \"/MSEDIT/EDIT.PRG\""),
; so EDIT can then be started from anywhere with the caret-run command:  ^/ed
;
; /ED is not just a convenience: EDIT reads the path back OUT of it to learn where it was installed
; (theme.find_progdir), and that is how edit.cfg and edcfg.prg are located at runtime. That makes
; /ED the AUTHORITY on where a previous install lives - and since find_progdir accepts any folder,
; not just /msedit, an existing /ED pointing somewhere else is a real install we must not orphan.
; So on startup we parse /ED and, when it names a folder other than the default, offer to update
; that one in place. Installing to /msedit instead would leave the old copy on disk with /ED
; pointing at whichever was written last. Decline and you are asked to name a folder, ENTER taking
; /msedit. Any depth is allowed - enter_dest creates the whole chain, so /dos/basload-editor works
; from a bare drive.
;
; The launcher is therefore GENERATED to match the destination (write_ed) rather than being a fixed
; byte literal - launcher and install folder cannot drift apart.
;
; An existing edit.cfg in the destination is PRESERVED on reinstall, so an update doesn't reset the
; user's settings. Run from the destination folder itself and the copy step is skipped (source ==
; dest would truncate the files); only the launcher is written.
;
; All filename literals are lowercase: uppercase A-Z would encode to $C1-DA, which the filesystem
; won't match. Conveniently that means a lowercase prog8 literal is already the $41-$5A ASCII the
; BASIC text of /ED needs, so write_ed copies the path in without any case folding.

%import textio
%import diskio
%import strings
%zeropage basicsafe

main {
    str DEF_DIR  = "/msedit"                    ; default install folder, absolute from the drive root
    str ED_NAME  = "/ed"                        ; the root launcher, read on startup and written at the end
    ; edit.prg is mandatory; the rest are copied when present. misc.ovl = About screen, tview.ovl =
    ; the text/hex viewer (File>View and Help>Keyboard/BASLOAD), picker.ovl = the Open/View file
    ; picker, menus.ovl = dropdown labels, edit.md / basload.md / hints.md = the help text files the
    ; viewer shows. prg2basload.prg is the stand-alone PRG-to-BASLOAD-source converter - a separate
    ; program, not called by EDIT, installed alongside it so it is on hand. All are loaded/opened at
    ; runtime; without them EDIT still runs and the affected menu items just report the file missing.
    ; edit.cfg is the user's settings, PRESERVED.
    str[11] FILES = ["edit.prg", "edcfg.prg", "prg2basload.prg", "misc.ovl", "tview.ovl", "picker.ovl", "menus.ovl", "edit.md", "basload.md", "hints.md", "edit.cfg"]
    str CFG = "edit.cfg"                        ; preserved on reinstall (holds the user's settings)

    ubyte[80] cur                ; folder we were launched from (copied out of curdir's transient buffer)
    ubyte[96] srcabs             ; absolute source path built per file: cur + "/" + name
    ubyte[255] cpbuf             ; stream-copy chunk buffer
    ubyte[256] edbuf             ; raw bytes of an existing /ed (sized like EDIT's own, see read_ed_dir)
    ubyte[40] edir               ; folder parsed out of that /ed - "" when there is no previous install
    ubyte[40] instdir            ; where we are actually installing: DEF_DIR, or edir if the user adopts it
    ubyte[40] typed              ; folder the user types when declining the one /ed names
    ubyte[64] edpath             ; instdir + "/edit.prg" - the string that goes inside the new launcher
    ubyte[64] edout              ; the generated launcher PRG

    ; Longest install folder EDIT can read back: theme.find_progdir caps progdir at 31 chars and
    ; that includes the trailing '/', so the folder itself gets 30.
    const ubyte MAX_DIR = 30

    const ubyte ACT_CANCEL  = 0
    const ubyte ACT_INSTALL = 1
    const ubyte ACT_TEST    = 2

    ; ...and for the "which folder?" question, which is a different choice with a different default
    const ubyte WHERE_CANCEL = 0
    const ubyte WHERE_ADOPT  = 1     ; the folder named by the existing /ed
    const ubyte WHERE_DEF    = 2     ; the default /msedit

    sub start() {
        ; Stay in the boot (uppercase) charset and write every message in lowercase SOURCE, which
        ; renders as clean ALL-CAPS - no charset to save/restore. prog8's init leaves the screen
        ; yellow-on-black, so paint it white-on-blue.
        txt.color2(1, 6)
        txt.clear_screen()
        txt.print("\n\nedit installer\n\n")

        ; curdir() points into a transient shared buffer - copy it out before any other disk call.
        void strings.copy(diskio.curdir(), cur)
        ubyte cl = strings.length(cur)
        if cl > 1 and cur[cl-1] == '/'          ; normalise: drop a trailing slash (keep bare root "/")
            cur[cl-1] = 0

        txt.print("running from: ")
        txt.print(cur)
        txt.nl()

        ; Where does EDIT already live? The root launcher is the authority - it is the same file
        ; EDIT parses to find itself, so whatever folder it names IS the previous install.
        bool have_ed = read_ed_dir()
        txt.print("/ed:          ")
        if have_ed {
            txt.print("found -> ")
            txt.print(edir)
            txt.nl()
        } else {
            txt.print("not found\n")
        }

        void strings.copy(DEF_DIR, instdir)
        if have_ed and strings.compare_nocase(edir, instdir) != 0 {
            ; A previous install somewhere other than the default. Updating it in place is almost
            ; always what's wanted: installing to /msedit instead leaves the old copy on disk and
            ; leaves /ed pointing at only one of the two.
            txt.print("\na previous install lives there.\n")
            txt.print("install into it?\n\n")
            txt.print("  y = ")
            txt.print(edir)
            txt.print("\n  n = somewhere else")
            txt.print("   (esc cancels)\n\n  ")
            ubyte where = ask_where()
            txt.nl()
            if where == WHERE_CANCEL {
                txt.print("\ncancelled.\n")
                return
            }
            if where == WHERE_ADOPT {
                void strings.copy(edir, instdir)
            } else {
                ; Declining doesn't have to mean the default. Ask for a folder, with /msedit on
                ; ENTER so the common answer stays a single keystroke.
                repeat {
                    txt.print("\n  folder [")
                    txt.print(DEF_DIR)
                    txt.print("]: ")
                    if not read_line(&typed, len(typed) - 1) {
                        txt.print("\n\ncancelled.\n")
                        return
                    }
                    set_instdir(&typed)
                    if strings.length(instdir) <= MAX_DIR
                        break
                    ; Refuse rather than truncate: EDIT would parse only the first MAX_DIR chars
                    ; back out of the launcher and then look for edit.cfg in a folder that isn't
                    ; the one we installed to.
                    txt.print("  too long - 30 characters max.\n")
                }
            }
        }

        ; Exact-path test, not a basename one: /downloads/msedit is NOT the install folder, and
        ; treating it as one would skip the copy and quietly install nothing.
        bool already = strings.compare_nocase(cur, instdir) == 0
        bool test_mode = false
        ubyte act

        if already {
            ; launched from INSIDE the destination: source == dest would truncate the files, so skip
            ; the copy and only (re)write the launcher.
            txt.print("\nfiles are already in ")
            txt.print(instdir)
            txt.print(".\n")
            txt.print("write the /ed launcher?  ")
            act = ask_action(true)
            txt.print("\n\n")
            if act == ACT_CANCEL {
                txt.print("cancelled.\n")
                return
            }
            test_mode = act == ACT_TEST
        } else {
            ; must be run from the folder that actually holds the release files
            if not diskio.f_open("edit.prg") {
                txt.print("\nedit.prg not found here.\n")
                txt.print("run this from the folder holding the\n")
                txt.print("unpacked edit release files.\n")
                return
            }
            diskio.f_close()

            ; does the destination already exist? A CD onto a MISSING dir is a silent no-op, so gate
            ; on the status code to tell "landed there" from "still where we were".
            diskio.chdir(instdir)
            bool have_prev = diskio.status_code() == 0
            diskio.chdir(cur)                   ; back to the launch folder

            txt.print("installing to ")
            txt.print(instdir)
            if have_prev
                txt.print("\n              (reinstall - settings kept)\n")
            else
                txt.print("\n              (fresh install)\n")

            txt.nl()
            if have_prev
                txt.print("reinstall?  ")
            else
                txt.print("install?  ")
            act = ask_action(true)
            txt.print("\n\n")
            if act == ACT_CANCEL {
                txt.print("cancelled.\n")
                return
            }
            test_mode = act == ACT_TEST
        }

        if test_mode
            txt.print("** test mode - nothing written **\n\n")

        if not already {
            ; a dry run writes nothing at all, so don't create the folder either
            if not test_mode and not enter_dest() {
                txt.print("cannot open or create\n  ")
                txt.print(instdir)
                txt.print("\nnothing was installed.\n")
                return
            }

            ubyte i
            for i in 0 to len(FILES) - 1 {
                build_src(FILES[i])
                txt.print("  ")
                txt.print(FILES[i])
                pad_to(FILES[i], 17)        ; 17, not 14: "prg2basload.prg" is 15 chars and would
                                            ; otherwise run straight into the status word
                if test_mode {
                    txt.print("test (skipped)\n")
                } else if strings.compare_nocase(FILES[i], CFG) == 0 and dest_exists(CFG) {
                    txt.print("kept (your settings)\n")     ; never clobber a saved config on reinstall
                } else if copy_one(srcabs, FILES[i]) {
                    txt.print("ok\n")
                } else {
                    txt.print("skip (not found)\n")
                }
            }
            txt.nl()
        }

        ; write the root launcher /ed - EDIT reads its install path back out of this file
        diskio.chdir("/")
        txt.print("  ed")
        pad_to("ed", 14)
        if test_mode {
            txt.print("test (skipped)\n")
        } else if write_ed() {
            txt.print("ok\n")
        } else {
            txt.print("failed\n")
        }

        txt.print("\ndone. launch from anywhere with:\n\n   ^/ed\n")
    }

    ;====================================================================

    ; Parse the install folder out of an existing root /ed into `edir`, exactly the way EDIT itself
    ; does it (theme.find_progdir): find the quoted path in  10 LOAD "<path>"  and cut at the last
    ; '/'. False when there is no launcher, or it names no folder, or the path is relative - a
    ; relative one is useless to us as a destination and EDIT can't resolve it either.
    ;
    ; edbuf is sized like EDIT's for the same reason: load_raw has already written the whole file by
    ; the time we see the length, so the buffer has to be comfortably bigger than any real launcher.
    sub read_ed_dir() -> bool {
        edir[0] = 0
        uword endaddr = diskio.load_raw(ED_NAME, &edbuf)
        if endaddr == 0 {
            void diskio.status()                ; drop the FILE NOT FOUND (else the activity LED blinks)
            return false
        }
        ubyte n = lsb(endaddr - &edbuf)
        ubyte i = 0
        while i < n and edbuf[i] != $22         ; opening quote
            i++
        if i >= n
            return false
        i++
        ubyte j = 0
        ubyte cut = 0                           ; chars up to and including the LAST '/'
        while i < n and edbuf[i] != $22 and j < len(edir) - 2 {
            edir[j] = edbuf[i]
            j++
            if edbuf[i] == '/'
                cut = j
            i++
        }
        if cut == 0
            return false                        ; a bare filename names no folder
        if cut > 1
            cut--                               ; "/msedit/" -> "/msedit", but keep a bare root "/"
        edir[cut] = 0
        return edir[0] == '/'
    }

    ; Make `instdir` the current directory, creating any part of it that is missing, so a nested
    ; destination like /dos/basload-editor works from nothing.
    ;
    ; Walked one component at a time from the root rather than handed over whole: CMDR-DOS MD takes
    ; a BARE name, so "MD:/dos/basload-editor" does not create the chain. CD into each component
    ; first and only MD when that fails, which leaves existing folders (and their contents) alone.
    sub enter_dest() -> bool {
        diskio.chdir("/")
        if diskio.status_code() != 0
            return false

        ubyte at = 1                            ; instdir always starts '/' - step over it
        while instdir[at] != 0 {
            ; carve out the next component, temporarily terminating it in place
            ubyte end = at
            while instdir[end] != 0 and instdir[end] != '/'
                end++
            ubyte sep = instdir[end]            ; '/' or the real 0 terminator
            instdir[end] = 0

            if end != at {                      ; tolerate a doubled slash - "" is not a folder
                diskio.chdir(&instdir + at)
                if diskio.status_code() != 0 {
                    diskio.mkdir(&instdir + at)
                    diskio.chdir(&instdir + at)
                    if diskio.status_code() != 0 {
                        instdir[end] = sep      ; put the path back before reporting it
                        return false
                    }
                }
            }

            instdir[end] = sep
            at = end
            if sep != 0                         ; skip the separator, unless that was the end
                at++
        }
        return true
    }

    ; srcabs = cur + "/" + name  (cur is normalised; bare root "/" yields "/name")
    sub build_src(str name) {
        void strings.copy(cur, srcabs)
        ubyte l = strings.length(srcabs)
        if l == 0 or srcabs[l-1] != '/'
            void strings.append(srcabs, "/")
        void strings.append(srcabs, name)
    }

    ; print spaces after `name` so the status column lines up at `col`
    sub pad_to(str name, ubyte col) {
        ubyte n = strings.length(name)
        while n < col {
            txt.spc()
            n++
        }
    }

    ; stream-copy the file at absolute path `src` into bare `dst` in the current dir. False only if
    ; the source doesn't open (a missing optional file); the destination is left untouched then.
    sub copy_one(str src, str dst) -> bool {
        if not diskio.f_open(src)
            return false
        diskio.delete(dst)                      ; clear any existing dest (open won't truncate)
        if not diskio.f_open_w(dst) {
            diskio.f_close()
            return false
        }
        repeat {
            uword nread = diskio.f_read(&cpbuf, 255)
            if nread == 0
                break
            if not diskio.f_write(&cpbuf, nread)
                break
        }
        diskio.f_close()
        diskio.f_close_w()
        return true
    }

    ; true if `name` already exists in the current dir (used to preserve the user's edit.cfg)
    sub dest_exists(str name) -> bool {
        if diskio.f_open(name) {
            diskio.f_close()
            return true
        }
        return false
    }

    ; Assemble and write the /ed launcher into the current dir: a $0801 PRG holding
    ;   10 LOAD "<instdir>/EDIT.PRG"
    ; sized to the path we actually installed to. The path is ABSOLUTE, so ^/ED works from any
    ; folder - and EDIT parses this very string back out to locate edit.cfg and the overlays
    ; (theme.find_progdir), which is why it is generated here instead of being a fixed literal.
    sub write_ed() -> bool {
        void strings.copy(instdir, edpath)
        ubyte l = strings.length(edpath)
        if l == 0 or edpath[l-1] != '/'         ; a bare root "/" already ends in one
            void strings.append(edpath, "/")
        void strings.append(edpath, "edit.prg")
        ubyte n = strings.length(edpath)
        if n > len(edout) - 12
            return false

        ; layout after the load address: link(2) linenum(2) LOAD(1) quote(1) path(n) quote(1) eol(1),
        ; so the next-line link targets the $00,$00 end marker at $0801 + 8 + n.
        uword link = $0809 + n
        edout[0] = $01
        edout[1] = $08
        edout[2] = lsb(link)
        edout[3] = msb(link)
        edout[4] = $0a                          ; line number 10
        edout[5] = $00
        edout[6] = $93                          ; LOAD token
        edout[7] = $22
        ubyte i
        for i in 0 to n - 1
            edout[8 + i] = edpath[i]
        edout[8 + n] = $22
        edout[9 + n] = $00                      ; end of line
        edout[10 + n] = $00                     ; end of program
        edout[11 + n] = $00

        diskio.delete("ed")
        if not diskio.f_open_w("ed")
            return false
        void diskio.f_write(&edout, n + 12)
        diskio.f_close_w()
        return true
    }

    ; Normalise a typed folder into the absolute, trailing-slash-free form the rest of the installer
    ; assumes. Empty input keeps the default. A missing leading '/' is added rather than rejected:
    ; everything here is rooted at the drive root anyway, and a relative path would defeat the whole
    ; point of the launcher - EDIT resolves it from wherever ^/ED happened to be run.
    sub set_instdir(uword p) {
        ubyte n = strings.length(p)
        if n == 0 {
            void strings.copy(DEF_DIR, instdir)
            return
        }
        instdir[0] = 0
        if @(p) != '/'
            void strings.append(instdir, "/")
        void strings.append(instdir, p)
        n = strings.length(instdir)
        while n > 1 and instdir[n-1] == '/' {   ; drop trailing slashes, but keep a bare root "/"
            instdir[n-1] = 0
            n--
        }
    }

    ; Read one line into `buf`, echoing as it is typed. False = ESC. DEL rubs out.
    sub read_line(uword buf, ubyte maxlen) -> bool {
        ubyte n = 0
        repeat {
            ubyte k = getkey()
            ; Fold shifted letters ($C1-$DA) down to $41-$5A. We are in the boot charset, so an
            ; unshifted key already gives $41-$5A - but SHIFT is an easy slip, and the filesystem
            ; matches only the unshifted form, so it would surface much later as "cannot open".
            if k >= $c1 and k <= $da
                k -= $80
            if k == 13 {
                @(buf + n) = 0
                txt.nl()
                return true
            }
            if k == 27
                return false
            if k == 20 {
                if n != 0 {
                    n--
                    txt.chrout(20)
                }
            } else if k >= 32 and k < 128 and n < maxlen {
                @(buf + n) = k
                n++
                txt.chrout(k)
            }
        }
    }

    ; ask whether to use the folder /ed names. No default on ENTER - the two answers write to
    ; different places, so make the user actually pick one.
    sub ask_where() -> ubyte {
        txt.print("y/n ")
        repeat {
            ubyte k = getkey()
            when k {
                'y', 'Y' -> return WHERE_ADOPT
                'n', 'N' -> return WHERE_DEF
                27 -> return WHERE_CANCEL
                else -> { }
            }
        }
    }

    ; print the "[y]/n  (t=dry run)" tail and read one decision key. ENTER takes `default_install`.
    sub ask_action(bool default_install) -> ubyte {
        if default_install
            txt.print("[y]/n  (t=dry run) ")
        else
            txt.print("y/[n]  (t=dry run) ")
        repeat {
            ubyte k = getkey()
            when k {
                'y', 'Y' -> return ACT_INSTALL
                't', 'T' -> return ACT_TEST
                'n', 'N', 27 -> return ACT_CANCEL
                13 -> {
                    if default_install
                        return ACT_INSTALL
                    return ACT_CANCEL
                }
                else -> { }
            }
        }
    }

    sub getkey() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }
}

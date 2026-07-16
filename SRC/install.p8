; install - self-installer for EDIT, run once from the unpacked release folder.
;
; A normal $0801 PRG. The user copies the release files (edit.prg, edcfg.prg, the .ovl overlays) plus this installer
; into ONE folder on their SD card, boots the X16, CDs into that folder and runs it. It:
;   * reports the folder it is running from,
;   * creates /MSEDIT on the drive root,
;   * copies the program files into it (255-byte stream copy),
;   * writes the tiny root launcher /ED  ("10 LOAD \"MSEDIT/EDIT.PRG\""),
; so EDIT can then be started from anywhere with the caret-run command:  ^/ed
;
; /ED is not just a convenience: EDIT reads the path back OUT of it to learn where it was installed
; (theme.find_progdir), and that is how edit.cfg and edcfg.prg are located at runtime. So the
; launcher and the install folder must agree - change TARGET_DIR and ED_BYTES together.
;
; An existing MSEDIT/edit.cfg is PRESERVED on reinstall, so an update doesn't reset the user's
; settings. Run from a folder that IS already /msedit and the copy step is skipped (source == dest
; would truncate the files); only the launcher is written.
;
; All filename literals are lowercase: uppercase A-Z would encode to $C1-DA, which the filesystem
; won't match.

%import textio
%import diskio
%import strings
%zeropage basicsafe

main {
    str TARGET_DIR = "msedit"                   ; install folder at the drive root
    ; edit.prg is mandatory; the rest are copied when present. misc.ovl = About screen, tview.ovl =
    ; the text/hex viewer (File>View and Help>Keyboard/BASLOAD), picker.ovl = the Open/View file
    ; picker, edit.md / basload.md = the help text files the viewer shows. All are loaded/opened at
    ; runtime; without them EDIT still runs and the affected menu items just report the file missing.
    ; edit.cfg is the user's settings, PRESERVED.
    str[8] FILES = ["edit.prg", "edcfg.prg", "misc.ovl", "tview.ovl", "picker.ovl", "edit.md", "basload.md", "edit.cfg"]
    str CFG = "edit.cfg"                        ; preserved on reinstall (holds the user's settings)

    ; the root launcher, byte-for-byte: a $0801 PRG holding  10 LOAD "/MSEDIT/EDIT.PRG"
    ; (matches the file run.bat/dbg.bat generate for the dev tree). The path is ABSOLUTE - a
    ; leading '/' from the drive root - so the reload works no matter what folder ^/ED is run from.
    ; The line grew one byte vs. the old relative form, so the next-line link is $0819 not $0818
    ; (it targets the $00,$00 end marker, which shifted up by the inserted '/').
    ubyte[28] ED_BYTES = [
        $01,$08, $19,$08, $0a,$00, $93,
        $22, $2f, $4d,$53,$45,$44,$49,$54, $2f, $45,$44,$49,$54,$2e,$50,$52,$47, $22,
        $00, $00,$00 ]

    ubyte[80] cur                ; folder we were launched from (copied out of curdir's transient buffer)
    ubyte[96] srcabs             ; absolute source path built per file: cur + "/" + name
    ubyte[255] cpbuf             ; stream-copy chunk buffer

    const ubyte ACT_CANCEL  = 0
    const ubyte ACT_INSTALL = 1
    const ubyte ACT_TEST    = 2

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

        bool already = basename_is_target(cur)  ; are we already sitting in /msedit ?
        bool test_mode = false
        ubyte act

        if already {
            ; launched from INSIDE /msedit: source == dest would truncate the files, so skip the copy
            ; and only (re)write the launcher.
            txt.print("\nfiles are already in /msedit.\n")
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

            ; is there a prior install? A CD onto a MISSING dir is a silent no-op, so gate on the
            ; status code to tell "landed in /msedit" from "still where we were".
            diskio.chdir("/msedit")
            bool have_prev = diskio.status_code() == 0
            diskio.chdir(cur)                   ; back to the launch folder

            txt.print("/msedit:      ")
            if have_prev
                txt.print("found  (reinstall - settings kept)\n")
            else
                txt.print("not found  (fresh install)\n")

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
            ; create /msedit (harmless if it exists) and make it the copy destination
            diskio.chdir("/")
            diskio.mkdir(TARGET_DIR)
            diskio.chdir("/msedit")

            ubyte i
            for i in 0 to len(FILES) - 1 {
                build_src(FILES[i])
                txt.print("  ")
                txt.print(FILES[i])
                pad_to(FILES[i], 14)
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

    ; case-insensitive test: is the last path component of `p` == "msedit"?
    sub basename_is_target(str p) -> bool {
        ubyte idx
        bool found
        idx, found = strings.rfind(p, '/')
        uword bp = p
        if found
            bp = p + idx + 1
        return strings.compare_nocase(bp, TARGET_DIR) == 0
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

    ; write the 27-byte /ed launcher into the current dir
    sub write_ed() -> bool {
        diskio.delete("ed")
        if not diskio.f_open_w("ed")
            return false
        void diskio.f_write(&ED_BYTES, len(ED_BYTES))
        diskio.f_close_w()
        return true
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

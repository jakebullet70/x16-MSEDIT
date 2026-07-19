# ************************************************************************************************
#
#	Name:		buildbasl.py
#	Purpose:	Tokenise a BASLOAD source (SRC\<NAME>.BASL) into run\<NAME>.PRG by running
#			BASLOAD headless inside the emulator.
#
# ************************************************************************************************
#
#	BASLOAD is an X16 ROM utility -- there is no host-side tokeniser for it. So we tokenise the
#	only way there is: boot the emulator with run\ as its drive, "type"  BASLOAD "<NAME>.BASL"
#	at the BASIC prompt, and let the source's own  #SAVEAS "@:<NAME>.PRG"  write the tokenised
#	program to that drive. Adapted from the same trick in the GPC compiler tree
#	(x16-blitz-compiler\source\gpc\build_basl.py).
#
#	DIRECTION OF TRAVEL -- opposite to GPC's. There the master lives on the emulator drive and is
#	mirrored back into the source tree; here run\ is gitignored in its entirety (see .gitignore),
#	so the master is the TRACKED copy in SRC\ and this script stages it OUT to run\ before every
#	build. Edit SRC\<NAME>.BASL; run\<NAME>.BASL is a build artefact and is overwritten. That also
#	means the interactive loop works: the staged copy is right there on the drive, so you can
#	re-tokenise by hand inside the emulator with  BASLOAD "PRG2BASLOAD.BASL"  without rebuilding.
#
#	BUILD NUMBER: if the source carries  VERSION$ = "a.b.n"  the last component is bumped in the
#	MASTER before every build, so the banner always names the exact build you are on -- the same
#	convention edit.p8's BUILD_NUM follows (syncbuild.ps1). Sources without a VERSION$ are fine
#	and are simply not bumped.
#
#	Headless: SDL_VIDEODRIVER=dummy so the emulator never steals the desktop's keyboard focus
#	(a visible run would swallow whatever the user is typing), and it is killed BY PID -- never
#	by image name, because other X16 projects on this box run x16emu at the same time.
#
#	Usage:  python buildbasl.py PRG2BASLOAD          (SRC\PRG2BASLOAD.BASL -> run\PRG2BASLOAD.PRG)
#		python buildbasl.py PRG2BASLOAD --run    (...then launch it in the emulator)
#
# ************************************************************************************************

import os, re, sys, time, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "SRC")
RUN  = os.path.join(HERE, "run")

DRIVER = "BASLBLD.BAS"      # scratch: the one line we "type" at the BASIC prompt
LOG    = "BASLBLD.LOG"      # scratch: the emulator echo log


def die(msg):
    print("  buildbasl: FAIL -- " + msg)
    sys.exit(1)


def find_emulator():
    """x16emu.exe + its rom.bin. LOCAL.BAT is the one place this repo records the local
    emulator path (it is per-machine and untracked-ish), so parse it rather than hard-coding
    a second copy that could drift out of step with run.bat / dbg.bat."""
    local = os.path.join(HERE, "LOCAL.BAT")
    exe = None
    if os.path.exists(local):
        with open(local, "r", errors="replace") as f:
            m = re.search(r'(?im)^\s*SET\s+x16\s*=\s*(.+?)\s*$', f.read())
            if m:
                exe = m.group(1).strip().strip('"')
    if not exe:
        die("no  SET x16=...  line in LOCAL.BAT -- cannot find the emulator")
    if not os.path.exists(exe):
        die("emulator not found: %s (from LOCAL.BAT)" % exe)
    rom = os.path.join(os.path.dirname(exe), "rom.bin")
    if not os.path.exists(rom):
        die("no rom.bin beside the emulator (%s)" % rom)
    return exe, rom


def bump_version(path):
    """Increment the last dotted component of  VERSION$ = "a.b.n"  in place, preserving the rest
    of the line and the file's exact line endings. Returns the new version, or None if the source
    carries no VERSION$ at all (which is not an error -- not every tool wants a build counter)."""
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    m = re.search(r'(VERSION\$\s*=\s*")([0-9]+(?:\.[0-9]+)*)(")', text)
    if not m:
        return None
    parts = m.group(2).split(".")
    if not parts[-1].isdigit():
        die('VERSION$ = "%s": last component is not numeric -- cannot bump' % m.group(2))
    parts[-1] = str(int(parts[-1]) + 1)
    newver = ".".join(parts)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text[:m.start(2)] + newver + text[m.end(2):])
    return newver


def tokenise(exe, rom, basl_name, prg_name, also_clean=()):
    """Boot the emulator headless with run\\ as the drive and run  BASLOAD "<basl_name>"  so the
    source's own #SAVEAS writes run\\<prg_name>. Returns the tokenised bytes; dies on failure.
    also_clean lists extra outputs (a #SYMFILE, say) to remove up front so a stale one from an
    earlier build cannot be mistaken for this build's success."""
    with open(os.path.join(RUN, DRIVER), "w", newline="\n") as f:
        f.write('BASLOAD "%s"\n' % basl_name)

    # Start from a clean slate: #SAVEAS overwrites, but we poll for the file's APPEARANCE as the
    # success signal, so a leftover PRG would report success for a build that never ran.
    for f in (prg_name,) + tuple(also_clean):
        p = os.path.join(RUN, f)
        if os.path.exists(p):
            os.remove(p)

    env = dict(os.environ)
    env["SDL_VIDEODRIVER"] = "dummy"
    args = [exe, "-rom", rom, "-fsroot", ".", "-warp", "-pastewarp", "-echo", "-bas", DRIVER]
    logpath = os.path.join(RUN, LOG)
    target  = os.path.join(RUN, prg_name)

    lf = open(logpath, "wb")
    proc = subprocess.Popen(args, cwd=RUN, stdout=lf, stderr=subprocess.STDOUT, env=env)
    ok = False
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            time.sleep(0.4)
            if os.path.exists(target) and os.path.getsize(target) > 0:
                s1 = os.path.getsize(target)
                time.sleep(0.4)
                if os.path.getsize(target) == s1:        # size stable -> the save finished
                    ok = True
                    break
    finally:
        proc.kill()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        lf.close()

    log = open(logpath, "rb").read()
    for f in (DRIVER, LOG):
        p = os.path.join(RUN, f)
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass

    # BASLOAD reports its own errors to the screen and writes nothing, so the echo log is the
    # only diagnostic there is -- print its tail rather than just "timed out".
    if not ok:
        die("BASLOAD wrote no %s within 30s -- echo log tail:\n%s"
            % (prg_name, log[-600:].decode("latin-1", "replace")))

    data = open(target, "rb").read()
    if len(data) < 3 or data[0] != 0x01 or data[1] != 0x08:
        die("%s does not load at $0801 (first bytes %s)" % (prg_name, data[:2].hex()))
    return data


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    do_run   = "--run" in sys.argv[1:]
    stage_only = "--stage" in sys.argv[1:]
    if len(argv) != 1:
        die("usage: buildbasl.py <NAME> [--run] [--stage]\n"
            "         (SRC\\<NAME>.BASL -> run\\<NAME>.PRG;  --stage copies only, no emulator)")

    name   = argv[0].upper()
    if name.endswith(".BASL"):
        name = name[:-5]
    master = os.path.join(SRC, name + ".BASL")
    if not os.path.exists(master):
        die("no %s" % master)
    if not os.path.isdir(RUN):
        die("no run\\ directory (%s)" % RUN)

    # --stage: refresh the emulator drive's copy and stop. This exists because the in-emulator
    # loop reads run\<NAME>.BASL, NOT SRC\ -- so editing SRC\ and then running BASLOAD by hand
    # inside the emulator silently tokenises the PREVIOUS source. That failure is nasty because
    # run\<NAME>.PRG ends up NEWER than the SRC\ edit, so the timestamps look fine while the
    # content is stale, and the bug you just fixed is still there. No version bump: staging is
    # not a build.
    if stage_only:
        staged = os.path.join(RUN, name + ".BASL")
        with open(master, "rb") as a, open(staged, "wb") as b:
            b.write(a.read())
        print("  buildbasl: staged SRC\\%s.BASL -> run\\%s.BASL  (no build)" % (name, name))
        print("             now  BASLOAD \"%s.BASL\"  in the emulator picks up your edit" % name)
        sys.exit(0)

    exe, rom = find_emulator()

    newver = bump_version(master)
    if newver:
        print("  buildbasl: bumped VERSION$ -> %s" % newver)

    # Stage the master onto the emulator drive. This is what BASLOAD actually reads, and leaving
    # it there is deliberate -- it is what makes the in-emulator  BASLOAD "NAME.BASL"  loop work.
    staged = os.path.join(RUN, name + ".BASL")
    with open(master, "rb") as a, open(staged, "wb") as b:
        b.write(a.read())

    prg  = name + ".PRG"
    data = tokenise(exe, rom, name + ".BASL", prg, also_clean=(name + ".SYM",))
    print("  buildbasl: OK -- run\\%s (%d bytes, loads $0801) tokenised from SRC\\%s.BASL"
          % (prg, len(data), name))
    print("             run\\%s.BASL staged for in-emulator  BASLOAD \"%s.BASL\"" % (name, name))

    if do_run:
        subprocess.Popen([exe, "-rom", rom, "-fsroot", RUN,
                          "-prg", os.path.join(RUN, prg), "-run", "-rtc", "-joy1"], cwd=RUN)
        print("             launched run\\%s in the emulator" % prg)

    sys.exit(0)


if __name__ == "__main__":
    main()

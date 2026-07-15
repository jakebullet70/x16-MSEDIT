; theme - colour scheme (theme) support for EDIT.
;
; Every colour EDIT paints with lives here as a VARIABLE (not a const), so a theme switch is
; just a table copy + repaint - no draw-code knows about themes. The colour bytes are setclr
; bytes: high nibble = background, low nibble = foreground, both indices into the X16's stock
; 16-colour palette (0 black, 1 white, 6 blue, 7 yellow, 11 dark grey, 12 medium grey,
; 14 light blue, 15 light grey). The palette itself is NEVER repainted (unlike XFMGR2's themes,
; which remap the VERA palette RGB) - EDIT reuses the same colour INDICES for opposite roles
; (index 0 is both the body background and the cursor's foreground), so a light theme is only
; expressible by changing the index pairs, not their RGB.
;
; The theme id is persisted in edit.cfg ("theme=N\r") next to edit.prg in the program folder.
;
; NO %encoding directive: diskio filenames must stay PETSCII (the host fs matches those bytes).

%import diskio
%import strings

theme {
    %option ignore_unused

    const ubyte FIRST = 1
    const ubyte LAST  = 3
    const ubyte NCOL  = 21              ; colour bytes per theme (must match the var order below)

    str[3] NAMES = ["Classic  (dark grey / light blue)",
                    "X16      (blue / light blue)",
                    "Light    (light grey / blue)"]

    ; ---- the live colours: every draw in edit.p8 / syntax.p8 reads these ----
    ubyte COL_FG        = 1             ; txt.color2 fg (clear_screen / chrout)
    ubyte COL_BG        = 0             ; txt.color2 bg (content field)
    ubyte CB_BODY       = $0f           ; edit area
    ubyte CB_BAR        = $e1           ; menu + status bars, dropdown interior
    ubyte CB_BOX        = $b1           ; popup interior
    ubyte CB_BORDER     = $be           ; popup frame lines + title bars
    ubyte CB_SEL        = $e1           ; selected picker item
    ubyte CB_MENUSEL    = $1e           ; active menu-bar title / selected dropdown row
    ubyte CB_CUR        = $10           ; text cursor cell
    ubyte CB_MARK       = $e1           ; selected text
    ubyte CB_SHADOW     = $cc           ; popup drop shadow (solid fill)
    ubyte CB_GUTTER     = $b1           ; line-number gutter
    ubyte CB_GUTTER_CUR = $b7           ; gutter, cursor's line
    ubyte CB_BAND       = $b0           ; current-line band: only the BG nibble is used (the fg stays
                                        ; whatever the body/syntax colour was), so it must not collide
                                        ; with the chrome or the field background
    ubyte ACCEL_FG      = 0             ; accelerator-letter fg (keeps its row's bg)
    ubyte C_DEFAULT     = $0f           ; syntax: normal text / variables / operators
    ubyte C_KEYWORD     = $0e           ; syntax: BASIC statement keywords
    ubyte C_FUNCTION    = $07           ; syntax: BASIC built-in functions
    ubyte C_STRING      = $08           ; syntax: "quoted strings"
    ubyte C_NUMBER      = $0d           ; syntax: numeric constants / line numbers
    ubyte C_COMMENT     = $05           ; syntax: REM ... to end of line

    ubyte current = 1                   ; the applied theme id (1..LAST)

    ; ---- the presets, NCOL bytes each, in the exact var order above ----
    ;                   FG  BG  BODY BAR  BOX  BORD SEL  MSEL CUR  MARK SHAD GUT  GUTC BAND ACC  DEF  KEY  FUN  STR  NUM  REM
    ubyte[63] TABLE = [
        ; 1 Classic - the original EDIT look: dark-grey/black field, light-blue chrome (XFMGR palette)
         1,  0, $0f, $e1, $b1, $be, $e1, $1e, $10, $e1, $cc, $b1, $b7, $b0,  0, $0f, $0e, $07, $08, $0d, $05,
        ; 2 X16 - the machine's own colours: blue field with light-blue text, like the BASIC screen.
        ; The bars are black on LIGHT GREY, which puts them outside every family already in use here:
        ; blue is the field, black is the current-line band, and the greys were too close to both the
        ; band and the popups to read as separate chrome. A light bar also flips the contrast the
        ; right way round - dark text on a light strip, framing a dark work area. Accelerators go red
        ; on it, and the selected row inverts to light-grey-on-black.
        ;
        ; The band cannot be the thing that moves: only its BG nibble is used (the fg stays whatever
        ; the syntax colour was), and every syntax fg here is a light tone, so the band must stay dark.
        ;
        ; Syntax colours are picked for a BLUE field, not reused from the dark themes: on blue, the
        ; darker half of the palette (medium grey, orange, blue) has almost no contrast - grey comments
        ; and orange strings both sank into the background. Everything here is a LIGHT tone, and each
        ; token type gets a different hue so they stay apart when the current-line band goes black
        ; underneath them: text white, keywords yellow, functions cyan, strings light red, numbers
        ; light green, comments light grey (the one deliberately muted tone - comments should recede,
        ; but still be readable, which medium grey on blue was not).
        14,  6, $6e, $f0, $61, $6e, $e1, $0f, $16, $e1, $00, $6c, $67, $00,  2, $61, $67, $63, $6a, $6d, $6f,
        ; 3 Light - light-grey field with black text, blue chrome, white popups.
        ; The selected menu row is white-on-DARK GREY, not the obvious white-on-blue invert: the
        ; accelerator letter keeps its row's background and only recolours the fg, so it has to stay
        ; legible on BOTH the bar and the selected row. Yellow works on the blue bar and on dark grey;
        ; on a white selected row it vanished completely.
         0, 15, $f0, $61, $10, $16, $61, $b1, $0f, $61, $cc, $c0, $c6, $10,  7, $f0, $f6, $f4, $f2, $f5, $fb
    ]

    sub apply(ubyte id) {
        if id < FIRST or id > LAST
            id = FIRST
        current = id
        ; the vars are declared consecutively, but prog8 gives no layout guarantee, so copy by name
        uword p = &TABLE + (id - 1) * NCOL
        COL_FG        = @(p)
        COL_BG        = @(p+1)
        CB_BODY       = @(p+2)
        CB_BAR        = @(p+3)
        CB_BOX        = @(p+4)
        CB_BORDER     = @(p+5)
        CB_SEL        = @(p+6)
        CB_MENUSEL    = @(p+7)
        CB_CUR        = @(p+8)
        CB_MARK       = @(p+9)
        CB_SHADOW     = @(p+10)
        CB_GUTTER     = @(p+11)
        CB_GUTTER_CUR = @(p+12)
        CB_BAND       = @(p+13)
        ACCEL_FG      = @(p+14)
        C_DEFAULT     = @(p+15)
        C_KEYWORD     = @(p+16)
        C_FUNCTION    = @(p+17)
        C_STRING      = @(p+18)
        C_NUMBER      = @(p+19)
        C_COMMENT     = @(p+20)
    }

    ; ---- where the programs are installed ----
    ; NOT hard-coded: the root launcher `ED` (a tokenized `10 LOAD"/MSEDIT/EDIT.PRG"`) already names
    ; the folder EDIT was installed into, so we read the path out of ITS quotes and keep everything up
    ; to the last '/'. That makes the install location the installer's business alone - move the
    ; programs, point ED at them, and edit.cfg / edcfg.prg follow automatically. An ED we can't read
    ; or parse falls back to DEF_DIR.
    ;
    ; The bytes inside ED are the same PETSCII our string literals compile to, so the path can be
    ; copied straight out with no re-encoding.

    str  ED_NAME  = "ed"                ; the launcher, at the fsroot
    str  DEF_DIR  = "/msedit/"          ; fallback when ED is missing/unparsable (absolute, like ED's path)
    str  CFG_FILE = "edit.cfg"
    str  progdir  = "?" * 32            ; install folder incl. trailing slash (empty = programs at root)
    str  progpath = "?" * 44            ; progdir + a filename, built by path_to()
    ubyte[32] edbuf                     ; ED launcher load buffer (the launcher is 27 bytes)
    ubyte[16] cfg_line                  ; cfg load buffer (the theme=N line is 8 bytes)
    bool dir_known = false

    ; There is deliberately NO save/restore of the working directory around the disk calls below.
    ; Both programs read the cfg while their cwd is still the fsroot they were launched from, and
    ; the paths built by path_to() are relative to it. The chdir dance that used to guard these cost
    ; an 84-byte path buffer in EDIT, which has under 1KB of low RAM to spare. If a caller ever needs
    ; to read the cfg after chdir'ing away, it must hop back itself before calling.

    sub find_progdir() {
        ; parse the install folder out of the root ED launcher; called once, before the first cfg use.
        dir_known = true
        void strings.copy(DEF_DIR, progdir)
        uword endaddr = diskio.load_raw(ED_NAME, &edbuf)
        if endaddr == 0 {
            void diskio.status()            ; drop the FILE NOT FOUND (else the activity LED blinks)
            return
        }
        ubyte n = lsb(endaddr - &edbuf)
        if n > 32
            n = 32
        ; the quoted path inside the tokenized BASIC line: LOAD "<path>"
        ubyte i = 0
        while i < n and edbuf[i] != $22                  ; opening quote
            i++
        if i >= n
            return                                       ; no quote -> keep the default
        i++
        ubyte j = 0
        ubyte cut = 0                                    ; chars up to and including the LAST '/'
        while i < n and edbuf[i] != $22 and j < 31 {
            progdir[j] = edbuf[i]
            j++
            if edbuf[i] == '/'
                cut = j
            i++
        }
        progdir[cut] = 0                                 ; drop the filename, keep the folder (or "" at root)
    }

    sub path_to(str fname) -> str {
        ; progdir + fname, e.g. "/msedit/" + "edit.cfg"
        if not dir_known
            find_progdir()
        void strings.copy(progdir, progpath)
        void strings.append(progpath, fname)
        return progpath
    }

    sub cfg_read() -> ubyte {
        ; the saved theme id; missing file / junk -> 1 (Classic). Uses the headerless KERNAL LOAD
        ; (load_raw), never f_open: XFMGR2 found that an f_open on an ABSENT file leaves read-channel
        ; traffic that corrupts the next UI draw. load_raw returns 0 when the file isn't there.
        ubyte id = FIRST
        uword endaddr = diskio.load_raw(path_to(CFG_FILE), &cfg_line)
        if endaddr == 0 {
            ; No cfg yet (the normal first-run case). The failed LOAD leaves a FILE NOT FOUND on the
            ; DOS error channel, which the X16 shows as a blinking activity LED until something reads
            ; it - so read and discard it here, or EDIT boots with the drive light flashing.
            void diskio.status()
            return id
        }
        @(endaddr) = 0
        ubyte p = 0
        while cfg_line[p] != 0 and cfg_line[p] != '='
            p++
        if cfg_line[p] == '=' {
            ubyte d = cfg_line[p+1]
            if d >= '1' and d <= '9'
                id = d - '0'
        }
        if id < FIRST or id > LAST
            id = FIRST
        return id
    }

    ; NOTE: writing the cfg lives in EDCFG (edcfg.p8), not here. EDIT only ever READS it, and keeping
    ; f_open_w/f_write out of edit.prg keeps that diskio code out of its low RAM.
}

# SRC\archive

Retired sources. Nothing here is part of a normal build — `build.bat edit.p8` never reaches
into this folder, and neither does any overlay build.

## detok.p8 + basdet.p8 + rundetok.bat

The prog8 stand-alone BASIC detokenizer, superseded by the BASLOAD port in `SRC\PRG2BASLOAD.BASL`
(build it with `buildbasl.bat PRG2BASLOAD`). The port is behaviour-for-behaviour: same token tables
extracted from ROM bank 4, same `$CE`-escape arithmetic, same error codes, same CRLF output.

Kept rather than deleted because it is the reference implementation the port was validated
against, and it is still the faster of the two by a wide margin — the BASLOAD version is
interpreted BASIC walking one byte at a time.

Still buildable:

    SRC\archive\rundetok.bat

The name collision that used to exist here is gone: the archived prog8 build still writes
`run\DETOK.PRG`, while the live tool now writes `run\PRG2BASLOAD.PRG`. Building one no longer
overwrites the other.

One difference worth remembering if you read both: prog8 encodes upper-case string literals as
shifted PETSCII (`$C1-$DA`), so `basdet.p8` needs `kw_char` to fold keyword text back to ASCII
while passing program bytes through verbatim. BASLOAD stores them as `$41-$5A` already, so the
BASLOAD version has no folding step at all.

## AUTO.BL — shelved, never written

There is no source file for this one. The idea was a program that calls the BASLOAD API directly
to turn a `.BASL` into a tokenized program *without running it*. It was dropped once the premise
turned out to be wrong.

BASLOAD does not run anything. The ROM command tokenizes and returns to `READY.`, and `#SAVEAS`
only autosaves the tokenized program. The `RUN` is **ours**: `chain_to_basload` in `edit.p8`
prints `BASLOAD"name"` on screen and then stuffs `CR` + `r` `u` `n` + `CR` into the keyboard
queue. So "convert but do not run" is three `kbdbuf_put` calls removed, not an API call — worth
a menu item (Run vs. Compile) if we ever want both.

That leaves the API buying only one thing: the result read programmatically instead of scrolled
past on screen. Worth revisiting if we ever want EDIT to jump the cursor to a failing line.

The contract, from `basload.md`, if it is ever picked up:

    call  $C000 in ROM bank 15
    in    R0L ($02) filename length, R0H ($03) device, filename at $00:BF00
    out   R1L ($04) return code (0 = OK, 20 codes total)
          R1H..R2H ($05-07) source line of the error
          R3 ($08-09) pointer to the source filename (always bank 1)
          plain-text message at $00:BF00

Two things found while scouting it, both non-obvious:

- **The ROM banks are self-identifying.** The last 16 bytes of each bank carry a name + version:
  bank 15 is `"basload"` v1.2, bank 13 is `"X16EDIT"` v3.8. That is how bank 15 was confirmed.
- **Only bank 0 has real interrupt vectors.** Every other bank holds filler (`$AAAA`, `$BBBB`,
  `$FFFF`) where NMI/RESET/IRQ belong — bank 15's "vectors" are part of that name header. So an
  IRQ is never serviced with a non-zero bank selected, and any call into bank 15 has to go
  through the KERNAL's `JSRFAR`. Note that a search of the ROM turned up **no** site doing a
  visible bank-15 dispatch (`LDA #$0F/STA $01`, `JSR $C000`, or `JSRFAR`), so how BASIC's own
  `BASLOAD` statement gets there was never established — expect to settle it empirically.

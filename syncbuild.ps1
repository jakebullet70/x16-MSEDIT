# Sync the EDIT build number across every place it appears, always leveling UP to the LARGEST value
# found. Bump the number in ANY one file and the next build propagates it to the rest - no manual
# multi-file edits, no drift. build.bat calls this BEFORE the compile, so THIS build's binary shows
# the resulting number. (Modeled on the sibling XFMGR2 project's syncbuild.ps1.)
#
#   -Src     SRC\edit.p8   const uword BUILD_NUM = N   (compiled -> "v0.9.N" on the About screen)
#   -Readme  README.md     "Version 0.9.N" marker
#
# Each file keeps its own wording; only the numeric field is rewritten. Edits are byte-preserving
# (Latin-1 is a 1:1 byte<->char map) so the PETSCII string bytes in the .p8 source and the UTF-8 in
# README.md survive untouched - only the ASCII digits change.

param([string]$Src, [string]$Readme)

$enc  = [System.Text.Encoding]::GetEncoding('iso-8859-1')
$opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

# each target: a display name, its path, and the regex whose group 2 is the number (group 1 = the
# text BEFORE it, which we preserve verbatim on rewrite)
$targets = @(
    @{ name = 'edit.p8';   path = $Src;    pat = '(BUILD_NUM\s*=\s*)(\d+)' }
    @{ name = 'README.md'; path = $Readme; pat = '(Version\s+0\.9\.)(\d+)' }
)

# --- pass 1: read the build number out of every file, find the largest ---
$max = -1
foreach ($t in $targets) {
    $t.text = $null
    $t.num  = $null
    if ($t.path -and (Test-Path $t.path)) {
        $t.text = $enc.GetString([System.IO.File]::ReadAllBytes($t.path))
        $m = [regex]::Match($t.text, $t.pat, $opts)
        if ($m.Success) {
            $t.num = [int]$m.Groups[2].Value
            if ($t.num -gt $max) { $max = $t.num }
        }
    }
}

if ($max -lt 0) {
    Write-Host '  build-sync: no build number found in any file - skipped.' -ForegroundColor Yellow
    return
}

# --- pass 2: level every file UP to the max (rewriting only the ones that are behind) ---
$changed = 0
foreach ($t in $targets) {
    if ($null -eq $t.num) {
        Write-Host ("  build-sync: {0,-11} no marker - left as-is" -f $t.name) -ForegroundColor Yellow
    }
    elseif ($t.num -eq $max) {
        Write-Host ("  build-sync: {0,-11} build {1}" -f $t.name, $t.num) -ForegroundColor DarkGray
    }
    else {
        $new = [regex]::Replace($t.text, $t.pat, ('${1}' + $max), $opts)   # ${1} = the prefix, then the max
        [System.IO.File]::WriteAllBytes($t.path, $enc.GetBytes($new))
        Write-Host ("  build-sync: {0,-11} build {1} -> {2}" -f $t.name, $t.num, $max) -ForegroundColor Green
        $changed++
    }
}
if ($changed -gt 0) {
    Write-Host ("  build-sync: leveled {0} file(s) up to build {1}." -f $changed, $max) -ForegroundColor Cyan
} else {
    Write-Host ("  build-sync: all in sync at build {0}." -f $max) -ForegroundColor Cyan
}

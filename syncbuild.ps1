# Auto-increment the EDIT build number on EVERY compile: find the largest value across the files,
# add 1, and write it back to ALL of them (so they stay in sync AND advance by one each build).
# build.bat calls this BEFORE the compile, so THIS build's binary shows the freshly bumped number.
# (Modeled on the sibling XFMGR2 project's syncbuild.ps1, but that one only levels; this one bumps.)
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

# --- pass 2: bump to max+1 and write it to every file (all of them advance, staying in sync) ---
$next = $max + 1
foreach ($t in $targets) {
    if ($null -eq $t.num) {
        Write-Host ("  build-sync: {0,-11} no marker - left as-is" -f $t.name) -ForegroundColor Yellow
    }
    else {
        $new = [regex]::Replace($t.text, $t.pat, ('${1}' + $next), $opts)   # ${1} = the prefix, then max+1
        [System.IO.File]::WriteAllBytes($t.path, $enc.GetBytes($new))
        Write-Host ("  build-sync: {0,-11} build {1} -> {2}" -f $t.name, $t.num, $next) -ForegroundColor Green
    }
}
Write-Host ("  build-sync: bumped to build {0}." -f $next) -ForegroundColor Cyan

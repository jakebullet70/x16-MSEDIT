# Parse a prog8/64tass build log and print a main-RAM memory-stats block.
# Called by build.bat after a successful compile.
#   -Log  path to the captured compiler output
#   -Prg  path to the produced .prg (for the on-disk size)
param([string]$Log, [string]$Prg)

$code = 0; $codeEnd = 0
$vars = 0; $slabs = 0; $hi = 0

foreach ($l in Get-Content $Log) {
    if ($l -match '^Data:\s+(\d+)\s+\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+)') {
        $code    = [int]$matches[1]
        $codeEnd = [Convert]::ToInt32($matches[3], 16)
        if ($codeEnd -gt $hi) { $hi = $codeEnd }
    }
    elseif ($l -match '^Gap:\s+(\d+)\s+\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+)\s+\$[0-9A-Fa-f]+\s+(\S+)') {
        $sz  = [int]$matches[1]
        $end = [Convert]::ToInt32($matches[3], 16)
        if ($matches[4] -like 'BSS_SLAB*') { $slabs += $sz } else { $vars += $sz }
        if ($end -gt $hi) { $hi = $end }
    }
}

if ($hi -eq 0) { return }   # no segment map found (nothing to report)

$used  = $hi - 0x801
$free  = 0x9F00 - $hi
$prgsz = if (Test-Path $Prg) { (Get-Item $Prg).Length } else { 0 }
function KB($b) { '{0,5:N1} KB' -f ($b / 1024) }

Write-Host ''
Write-Host '  ---- memory stats (main RAM; banked HIRAM not counted) ----' -ForegroundColor Cyan
Write-Host ('   code + data (image) : {0,6} B   $0801-${1}' -f $code, $codeEnd.ToString('X4')) -ForegroundColor Cyan
Write-Host ('   vars (BSS)          : {0,6} B' -f $vars) -ForegroundColor Cyan
Write-Host ('   slabs (memory())    : {0,6} B' -f $slabs) -ForegroundColor Cyan
Write-Host    '   ----------------------------------------------------------' -ForegroundColor Cyan
Write-Host ('   main RAM used       : {0,6} B  ({1})   $0801-${2}' -f $used, (KB $used), $hi.ToString('X4')) -ForegroundColor Green
Write-Host ('   free to $9F00       : {0,6} B  ({1})' -f $free, (KB $free)) -ForegroundColor Green
Write-Host ('   .prg on disk        : {0,6} B' -f $prgsz) -ForegroundColor Cyan
Write-Host ''

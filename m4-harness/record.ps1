$rec = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data"
$env:SPRING_WRITEDIR = $rec
$env:SPRING_DATADIR = "$rec;$data"
& "$data\engine\recoil_2026.07.04\spring-headless.exe" --write-dir $rec "$rec\script.txt" *> "$rec\stdout.log"
"exit $LASTEXITCODE" | Out-File -Append "$rec\stdout.log"

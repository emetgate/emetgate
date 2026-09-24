param(
    [Parameter(Mandatory = $true)][string]$Ref,
    [int]$Jobs = 4,
    [int]$Runs = 3
)

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$stages = New-Object System.Collections.Generic.List[object]
$started = Get-Date

function Show-Stages {
    Write-Host ""
    Write-Host "accept $Ref"
    foreach ($s in $stages) {
        Write-Host ("  {0,-34} {1,7:N1} s  exit {2}" -f $s.Name, $s.Seconds, $s.Exit)
    }
    Write-Host ("  {0,-34} {1,7:N1} s" -f "total", ((Get-Date) - $started).TotalSeconds)
}

function Invoke-Stage([string]$Name, [scriptblock]$Body) {
    $t = Get-Date
    & $Body
    $code = $LASTEXITCODE
    $stages.Add([pscustomobject]@{ Name = $Name; Seconds = ((Get-Date) - $t).TotalSeconds; Exit = $code })
    if ($code -ne 0) {
        Show-Stages
        Write-Host "accept: $Name failed"
        exit $code
    }
}

& git rev-parse --verify --quiet "$Ref^{commit}" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "accept: $Ref is not a commit"
    exit 2
}

for ($i = 1; $i -le $Runs; $i++) {
    Invoke-Stage "zig build test ($i of $Runs)" { zig build test "-j$Jobs" "-Dtest-jobs=$Jobs" }
}
Invoke-Stage "zig build mutate-tool" { zig build mutate-tool "-j$Jobs" }
$report = Join-Path $root ".zig-cache/mutate/report.json"
if (Test-Path $report) { Remove-Item $report }
Invoke-Stage "mutants changed since $Ref" {
    & (Join-Path $root "zig-out/bin/emetgate-mutate.exe") "--jobs=$Jobs" --skip-survivors --changed-since $Ref
}
Invoke-Stage "verification page up to date" {
    python (Join-Path $root "tools/verification_page.py") --check
}
if (Test-Path $report) {
    $outcomes = Get-Content $report -Raw | ConvertFrom-Json
    $schema = @($outcomes | Where-Object { $_.origin -eq 'schema' }).Count
    Write-Host ("accept: {0} mutation(s) selected, {1} from the schema binary, {2} on their own" -f $outcomes.Count, $schema, ($outcomes.Count - $schema))
}
Show-Stages

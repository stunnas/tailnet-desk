# Installs the PowerShell modules CI needs, at pinned versions, after checking each package's SHA-256.
# Works in PowerShell 7 and Windows PowerShell 5.1. A package is a zip file from the PowerShell Gallery; it's unpacked
# into the current user's module folder. Bump a version and its hash together, by hand, to a release at least two
# weeks old.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$modules = @(
    # Pester 5.7.1 was released 2025-01-08; PSScriptAnalyzer 1.25.0 on 2026-03-20.
    @{ Name = 'Pester'; Version = '5.7.1'; Sha256 = '4a27904c6814a5fbe4758f8e49861f6a1994aee77b71165a5c43c0371ba6c580' }
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0'; Sha256 = '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60' }
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$ProgressPreference = 'SilentlyContinue'

# The first module folder under the user's home: Documents\WindowsPowerShell\Modules or ~/.local/share/powershell/Modules.
$sep = [IO.Path]::PathSeparator
$userModules = @($env:PSModulePath.Split($sep) | Where-Object { $_ -and $_.StartsWith($HOME) }) | Select-Object -First 1
if (-not $userModules) { throw 'No module folder under the home folder in PSModulePath.' }

$work = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    foreach ($m in $modules) {
        $zip = Join-Path $work "$($m.Name).$($m.Version).zip"
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.powershellgallery.com/api/v2/package/$($m.Name)/$($m.Version)" -OutFile $zip
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $m.Sha256) { throw "$($m.Name) $($m.Version): SHA-256 $hash doesn't match the pinned $($m.Sha256)." }
        $dest = Join-Path (Join-Path $userModules $m.Name) $m.Version
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $dest
        # Package metadata the gallery adds; not part of the module.
        foreach ($extra in @('_rels', 'package', '[Content_Types].xml', "$($m.Name).nuspec")) {
            $p = Join-Path $dest $extra
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Write-Host "$($m.Name) $($m.Version): SHA-256 matches, installed."
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

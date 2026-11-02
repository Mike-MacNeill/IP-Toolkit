param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$RuntimeIdentifier = "win-x64"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Join-Path $Root "IPToolkit.Windows\IPToolkit.Windows.csproj"
$Output = Join-Path $Root "dist\$RuntimeIdentifier"
$IconGenerator = Join-Path $Root "generate-icon.ps1"
$InstallerCompiler = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $InstallerCompiler) {
    foreach ($Candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path $Candidate) {
            $InstallerCompiler = $Candidate
            break
        }
    }
}
if (-not $InstallerCompiler) {
    throw "Inno Setup 6 is required to create the installer. Install it from https://jrsoftware.org/isinfo.php and rerun this script."
}

& $IconGenerator
dotnet publish $Project -c Release -r $RuntimeIdentifier --self-contained true `
    -p:PublishSingleFile=true -o $Output
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Push-Location $Root
try {
    & $InstallerCompiler "installer.iss" "/DRuntimeIdentifier=$RuntimeIdentifier"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

Write-Output "Published Windows app: $Output"
Write-Output "Created installer: $(Join-Path $Root "dist\installer\IPToolkit-Setup-$RuntimeIdentifier.exe")"
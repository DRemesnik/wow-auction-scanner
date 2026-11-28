param(
  [switch]$CreateDesktopShortcut,
  [string]$DefaultEndpoint = ""
)

$ErrorActionPreference = "Stop"
$desktopDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcFile    = Join-Path $desktopDir "src\GoblinBrokerDesktop.cs"
$icoFile    = Join-Path $desktopDir "goblin_broker.ico"
$outExe     = Join-Path $desktopDir "GoblinBrokerDesktop.exe"
$csc        = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path $csc)) {
  throw "C# compiler not found at $csc"
}

if (-not [string]::IsNullOrWhiteSpace($DefaultEndpoint)) {
  $srcText = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
  $updated = [regex]::Replace(
    $srcText,
    'public const string DefaultEndpointUrl = "[^"]*";',
    ('public const string DefaultEndpointUrl = "' + $DefaultEndpoint + '";')
  )
  [System.IO.File]::WriteAllText($srcFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("Baked DefaultEndpointUrl: {0}" -f $DefaultEndpoint)
}

$argsList = @(
  "/nologo",
  "/target:winexe",
  "/optimize+",
  "/platform:anycpu",
  "/utf8output",
  "/win32icon:$icoFile",
  "/out:$outExe",
  "/r:System.dll",
  "/r:System.Core.dll",
  "/r:System.Drawing.dll",
  "/r:System.Windows.Forms.dll",
  "/r:System.Web.Extensions.dll",
  $srcFile
)

& $csc @argsList
if ($LASTEXITCODE -ne 0) {
  throw "Build failed with exit code $LASTEXITCODE"
}

$fi = Get-Item $outExe
Write-Host ("Built {0} ({1:N1} KB)" -f $fi.FullName, ($fi.Length / 1024.0))

if ($CreateDesktopShortcut) {
  $desktopPath = [Environment]::GetFolderPath("Desktop")
  $lnkPath = Join-Path $desktopPath "Goblin Broker Desktop.lnk"
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnkPath)
  $sc.TargetPath = $outExe
  $sc.WorkingDirectory = $desktopDir
  $sc.IconLocation = "$outExe,0"
  $sc.Description = "Goblin Broker: Desktop (WoW: Forever AH Telemetry Companion)"
  $sc.Save()
  Write-Host ("Created Desktop shortcut: {0}" -f $lnkPath)
}

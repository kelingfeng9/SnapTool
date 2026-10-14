param([switch]$Test, [string]$OutputPath = 'artifacts\SnapTool.exe')
$ErrorActionPreference = 'Stop'
try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (!(Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (!(Test-Path -LiteralPath $compiler)) { throw '.NET Framework compiler is missing.' }
    if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'app.ico'))) { & (Join-Path $PSScriptRoot 'gen-icon.ps1') }
    $output = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $PSScriptRoot $OutputPath }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
    $rsp = Join-Path ([IO.Path]::GetDirectoryName($output)) 'references.rsp'
    $refs = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SnapTool.rsp') | ForEach-Object {
        $line = $_.Replace('C:\Windows', $env:WINDIR)
        if ($line.StartsWith('/reference:')) {
            $path = $line.Substring(11)
            if ([IO.Path]::IsPathRooted($path) -and !(Test-Path -LiteralPath $path)) { throw "Missing build reference: $path" }
            '/reference:"' + $path + '"'
        } else { $line }
    }
    [IO.File]::WriteAllLines($rsp, [string[]]$refs, [Text.UTF8Encoding]::new($false))
    $sources = @('AssemblyInfo.cs','Program.cs','ConfigurationStore.cs','CaptureForm.cs','AnnotationGeometry.cs','SelectionShape.cs','ImageClipboard.cs','PinForm.cs','OcrHelper.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
    $options = @('/nologo','/codepage:65001','/platform:anycpu','/optimize+','/warn:4','/warnaserror+',"@$rsp","/out:$output")
    if ($Test) { $options += '/target:exe','/main:SnapTool.RegressionTests'; $sources += Join-Path $PSScriptRoot 'tests\RegressionTests.cs'; $sources += Join-Path $PSScriptRoot 'tests\ShapeTests.cs'; $sources += Join-Path $PSScriptRoot 'tests\SettingsTests.cs'; $sources += Join-Path $PSScriptRoot 'tests\AnnotationTests.cs' }
    else { $options += '/target:winexe',('/win32icon:' + (Join-Path $PSScriptRoot 'app.ico')) }
    & $compiler @options @sources
    if ($LASTEXITCODE -ne 0) { throw "Compiler failed with exit code $LASTEXITCODE" }
    Write-Output "Build OK: $output"
    if ($Test) {
        & $output
        if ($LASTEXITCODE -ne 0) { throw "Tests failed with exit code $LASTEXITCODE" }
    }
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }

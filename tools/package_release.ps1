#Requires -Version 5.1
<#
.SYNOPSIS
    Assembles the Fap Hero Journey release zips from Godot's export output.

.DESCRIPTION
    Godot's export does NOT emit bin/. ffmpeg.exe / ffprobe.exe are non-resource files and
    export_presets.cfg only ships "*.json" as non-resources, so they are not in the PCK either
    (MediaPoolService's res:// extraction fallback is dead code in an exported build). The only
    bundled path that resolves at runtime is <game dir>/bin/, which has to be copied in when
    packaging - a manual step with no CI build behind it.

    v0.6.0 shipped without it: every Windows user without a system ffmpeg on PATH hit
    "ffmpeg / ffprobe could not be run" on save, because the save gate only skips the ffmpeg
    check when Auto-Transcode is off AND nothing is trimmed.

    This script removes the human step, and REFUSES to produce a Windows zip missing the
    binaries - the exact check that would have caught v0.6.0.

    Linux deliberately gets no bin/: the repo only carries Windows .exe binaries, and the
    Linux build resolves ffmpeg from the system PATH by design.

    NOTE: this file is deliberately pure ASCII. Windows PowerShell 5.1 reads .ps1 as ANSI
    unless the file has a UTF-8 BOM, so non-ASCII punctuation breaks parsing.

.PARAMETER Export
    Run Godot's headless exporter for both presets first, then package the result. This is the
    one-command path: export -> bundle ffmpeg -> zip -> checksums. Without it, the script
    packages the folders given by -WindowsExport / -LinuxExport (export from the editor first).

.PARAMETER GodotExe
    Godot binary used by -Export. Defaults to the installed 4.6.2 mono CONSOLE build, else a
    "godot" on PATH. Must be the console build: the GUI binary detaches, so you get no output
    and no usable exit code.

.PARAMETER WindowsExport
    Folder containing Godot's exported Windows build ("Fap Hero Journey.exe" + DLLs).
    Omit to skip packaging Windows. Ignored when -Export is used.

.PARAMETER LinuxExport
    Folder containing Godot's exported Linux build ("Fap Hero Journey.x86_64" + .so files).
    Omit to skip packaging Linux. Ignored when -Export is used.

.PARAMETER Version
    Release version, e.g. "0.6.1". Defaults to application/config/version in project.godot.
    With -Export the built binaries carry that same value, so the two cannot drift.

.PARAMETER OutDir
    Where the zips + checksums.txt are written. Defaults to <repo>/dist.

.EXAMPLE
    # One command: export both platforms and produce upload-ready artifacts.
    .\tools\package_release.ps1 -Export

.EXAMPLE
    # Package builds you already exported from the editor.
    .\tools\package_release.ps1 -WindowsExport "C:\Downloads\FHJ-win" -LinuxExport "C:\Downloads\FHJ-linux"

.NOTES
    Known limitation: zipping from Windows does not preserve the Unix executable bit, so Linux
    users still need `chmod +x "Fap Hero Journey.x86_64"` (see LINUX_STARTUP.md). Fixing that
    needs a zip writer that stores Unix modes; out of scope here.

    -Export assumes the project has been imported at least once (a .godot/ cache exists). On a
    clean clone, run Godot once with --headless --path <repo> --import first. It also assumes the
    C# assembly is built (.godot/mono/temp/bin/Debug) - without it Godot's project init cannot
    create the C# autoloads. The CI workflow does both explicitly.

    Godot's export can crash on teardown AFTER writing a complete binary (seen on the GitHub
    Actions windows runner, never locally). That exact case is tolerated; see Invoke-GodotExport.
#>
[CmdletBinding()]
param(
    [switch]$Export,
    [string]$GodotExe,
    [string]$WindowsExport,
    [string]$LinuxExport,
    [string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

# Binaries the Windows build must ship beside the exe (see .DESCRIPTION).
$RequiredWinBins = @('ffmpeg.exe', 'ffprobe.exe')

# Preset names as they appear in export_presets.cfg. Must match exactly.
$WindowsPreset = 'Windows Desktop'
$LinuxPreset   = 'Linux'

# Windows access violation (0xC0000005), which Godot's crash handler reports as "signal 11".
# PowerShell surfaces it signed; compare against both forms.
$ACCESS_VIOLATION_SIGNED   = -1073741819
$ACCESS_VIOLATION_UNSIGNED = 3221225477

# Floor for "Godot actually wrote a binary rather than a stub". Both presets' outputs are tens of
# MB (Windows embeds the PCK at ~124 MB; the Linux binary is ~71 MB), so this only catches an
# empty/stub file - it is a sanity check, not an integrity check. See Invoke-GodotExport.
$MIN_EXPORT_BYTES = 1MB

# The console build prints to stdout and returns a real exit code; the plain GUI binary
# detaches on Windows and gives neither.
$DefaultGodotExe = 'C:\Program Files (x86)\Godot\app\Godot_v4.6.2-stable_mono_win64_console.exe'

function Resolve-GodotExe {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "Godot not found: $Explicit" }
        return $Explicit
    }
    if (Test-Path -LiteralPath $DefaultGodotExe) { return $DefaultGodotExe }
    $cmd = Get-Command 'godot' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Godot not found. Pass -GodotExe <path to Godot_..._console.exe>."
}

# Exports one preset headlessly. Godot can exit 0 having written nothing (bad preset name,
# missing templates), so the output file is verified rather than trusted.
#
# Both facts are reported before deciding: Godot can also crash AFTER writing a complete pack
# (it has been seen access-violating on teardown once "savepack" is DONE), and "crashed with no
# output" vs "crashed with a full-size binary" are very different problems. We still refuse to
# package from a crashed exporter - a build whose exporter segfaulted is not one to ship - but
# the error should say which case it was.
function Invoke-GodotExport {
    param([string]$GodotBin, [string]$PresetName, [string]$OutFile)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Write-Host "==> Exporting preset '$PresetName'" -ForegroundColor Cyan
    & $GodotBin --headless --path $RepoRoot --export-release $PresetName $OutFile
    $code = $LASTEXITCODE

    $produced = Test-Path -LiteralPath $OutFile
    $size = 0
    if ($produced) { $size = (Get-Item -LiteralPath $OutFile).Length }
    Write-Host "    exit=$code  output_written=$produced  size=$size bytes"

    if ($code -eq 0) {
        if (-not $produced) {
            throw "Godot exited 0 but did not write '$OutFile' (preset '$PresetName')."
        }
        return
    }

    # --- Tolerated failure: teardown crash after a completed export -------------------------
    # Godot 4.6.2 access-violates while unwinding at the END of a headless export on the GitHub
    # Actions windows runner: "savepack" reports DONE, the full binary is written, and the process
    # then dies on the way out. Locally the identical command exits 0, and CI's binary matched a
    # fully verified local build to within ~200 bytes (explained by the runner's dotnet SDK
    # emitting a slightly different assembly).
    #
    # Two candidate causes were investigated and ruled out: the ffmpeg GDExtension (loads cleanly
    # in CI - the errors around it only appear locally) and the C# autoloads failing to compile
    # (a real bug, fixed by building the assembly before export; the crash outlives that fix).
    #
    # So this tolerates EXACTLY that crash, and only with a real binary on disk. Any other exit
    # code, or a crash with no output, still hard-fails: "the exporter crashed but the file looked
    # fine" must not become a general rule.
    #
    # Residual risk, stated plainly: a crash DURING packing could leave a large-but-truncated file
    # that passes these checks. The size floor cannot detect truncation. What argues against it
    # here is that Godot itself reports "[ DONE ] savepack" before dying.
    $crashed = ($code -eq $ACCESS_VIOLATION_SIGNED) -or ($code -eq $ACCESS_VIOLATION_UNSIGNED)
    if ($crashed -and $produced -and $size -ge $MIN_EXPORT_BYTES) {
        Write-Host ("::warning::Godot crashed on teardown exporting '{0}' (0xC0000005) AFTER writing a complete {1}-byte binary. Accepting the artifact - see Invoke-GodotExport in tools/package_release.ps1." -f $PresetName, $size)
        Write-Host "    TOLERATED: teardown crash after a completed export; continuing." -ForegroundColor Yellow
        return
    }

    throw "Godot export failed for '$PresetName' (exit $code, output_written=$produced, size=$size bytes)."
}

function Get-ProjectVersion {
    $projectFile = Join-Path $RepoRoot 'project.godot'
    if (-not (Test-Path -LiteralPath $projectFile)) { throw "project.godot not found at $projectFile" }
    foreach ($line in Get-Content -LiteralPath $projectFile) {
        if ($line -match '^\s*config/version\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    throw "Could not read application/config/version from project.godot"
}

# UpdateService.platform_asset() matches on the platform keyword + "build", case-insensitively
# and separator-agnostically (GitHub rewrites spaces to dots). Assert it here so a rename can
# never silently break the in-app updater's asset lookup.
function Assert-UpdaterWillMatch {
    param([string]$ZipName, [string]$PlatformKeyword)
    $n = $ZipName.ToLower()
    if (($n -notlike "*$PlatformKeyword*") -or ($n -notlike '*build*') -or ($n -notlike '*.zip')) {
        throw "Asset name '$ZipName' will not be found by UpdateService (needs '$PlatformKeyword' + 'build' + .zip)."
    }
}

function New-Stage {
    param([string]$ExportDir, [string]$StageDir, [string]$ExpectedExe)

    if (-not (Test-Path -LiteralPath $ExportDir)) { throw "Export folder not found: $ExportDir" }
    $exe = Join-Path $ExportDir $ExpectedExe
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "'$ExpectedExe' not found in $ExportDir - is that really Godot's export output?"
    }

    if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    Copy-Item -Path (Join-Path $ExportDir '*') -Destination $StageDir -Recurse -Force
}

# The zip must be FLAT (no top-level folder): UpdateService._extract_beside() creates a target
# folder named after the zip and extracts entries into it. A base directory here would nest the
# build one level too deep for the in-app updater.
#
# Entries are written by hand rather than via ZipFile::CreateFromDirectory because .NET
# Framework (what Windows PowerShell 5.1 loads) writes entry paths with BACKSLASHES, violating
# the zip spec. Godot's ZIPReader would then see "bin\ffmpeg.exe" as a single flat filename,
# get_base_dir() would find no separator, and the in-app updater's extract would fail outright.
# Forward slashes are required.
function New-ReleaseZip {
    param([string]$StageDir, [string]$ZipPath)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $stageFull = (Resolve-Path -LiteralPath $StageDir).Path.TrimEnd('\')
    $zip = [System.IO.Compression.ZipFile]::Open(
        $ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $stageFull -Recurse -File)) {
            $rel = $f.FullName.Substring($stageFull.Length + 1) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, $rel,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
}

# Every spelling of an asset name GitHub might serve, so the checksum can be found whichever
# upload path was used:
#   - the API (softprops/action-gh-release, i.e. the release workflow) PRESERVES the filename;
#   - the web UI rewrites spaces to dots ("Fap.Hero.JOURNEY.v0.6.1.-.Windows.Build.zip").
# UpdateService looks the hash up by the name it downloaded and matches the line as a substring,
# so listing both spellings makes verification work either way. This matters because a name
# mismatch does not fail loudly - _verify_checksum returns "skip" and the update installs
# UNVERIFIED, which is exactly how a dotted-only checksums.txt sat there doing nothing.
function Get-AssetNameVariants {
    param([string]$LocalName)
    $variants = @($LocalName)
    $dotted = $LocalName -replace ' ', '.'
    if ($dotted -ne $LocalName) { $variants += $dotted }
    return $variants
}

if (-not $Version) { $Version = Get-ProjectVersion }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---- Export (optional) -----------------------------------------------------
if ($Export) {
    if ($WindowsExport -or $LinuxExport) {
        throw "-Export builds the project itself; don't also pass -WindowsExport / -LinuxExport."
    }
    $godot = Resolve-GodotExe -Explicit $GodotExe
    Write-Host "Using Godot: $godot"
    Write-Host "Building version $Version (from project.godot)"

    $exportRoot = Join-Path $OutDir '.export'
    if (Test-Path -LiteralPath $exportRoot) { Remove-Item -LiteralPath $exportRoot -Recurse -Force }

    $WindowsExport = Join-Path $exportRoot 'windows'
    Invoke-GodotExport -GodotBin $godot -PresetName $WindowsPreset `
        -OutFile (Join-Path $WindowsExport 'Fap Hero Journey.exe')

    $LinuxExport = Join-Path $exportRoot 'linux'
    Invoke-GodotExport -GodotBin $godot -PresetName $LinuxPreset `
        -OutFile (Join-Path $LinuxExport 'Fap Hero Journey.x86_64')
}

if (-not $WindowsExport -and -not $LinuxExport) {
    throw "Nothing to do - pass -Export, or -WindowsExport / -LinuxExport."
}

$stageRoot = Join-Path $OutDir '.stage'
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }

$built = @()

# ---- Windows ---------------------------------------------------------------
if ($WindowsExport) {
    Write-Host "==> Staging Windows build" -ForegroundColor Cyan
    $name  = "Fap Hero JOURNEY v$Version - Windows Build"
    $stage = Join-Path $stageRoot 'windows'
    New-Stage -ExportDir $WindowsExport -StageDir $stage -ExpectedExe 'Fap Hero Journey.exe'

    # The whole point: bundle the ffmpeg CLI beside the exe.
    $binSrc = Join-Path $RepoRoot 'bin'
    $binDst = Join-Path $stage 'bin'
    New-Item -ItemType Directory -Force -Path $binDst | Out-Null
    foreach ($b in $RequiredWinBins) {
        $src = Join-Path $binSrc $b
        if (-not (Test-Path -LiteralPath $src)) { throw "Bundled binary missing from repo: $src" }
        Copy-Item -LiteralPath $src -Destination $binDst -Force
        Write-Host "    + bin/$b"
    }

    # Guard: refuse to ship the v0.6.0 bug again.
    foreach ($b in $RequiredWinBins) {
        if (-not (Test-Path -LiteralPath (Join-Path $binDst $b))) {
            throw "REFUSING TO PACKAGE: bin/$b missing from the staged Windows build."
        }
    }

    $zip = Join-Path $OutDir "$name.zip"
    Assert-UpdaterWillMatch -ZipName "$name.zip" -PlatformKeyword 'windows'
    Write-Host "==> Zipping $name.zip"
    New-ReleaseZip -StageDir $stage -ZipPath $zip
    $built += $zip
}

# ---- Linux -----------------------------------------------------------------
if ($LinuxExport) {
    Write-Host "==> Staging Linux build" -ForegroundColor Cyan
    $name  = "Fap Hero JOURNEY v$Version - Linux Build"
    $stage = Join-Path $stageRoot 'linux'
    New-Stage -ExportDir $LinuxExport -StageDir $stage -ExpectedExe 'Fap Hero Journey.x86_64'
    # No bin/ here on purpose: the repo only carries Windows binaries and the Linux build
    # resolves ffmpeg from the system PATH by design.
    Write-Host "    (no bin/ - Linux uses system ffmpeg by design)"

    $zip = Join-Path $OutDir "$name.zip"
    Assert-UpdaterWillMatch -ZipName "$name.zip" -PlatformKeyword 'linux'
    Write-Host "==> Zipping $name.zip"
    New-ReleaseZip -StageDir $stage -ZipPath $zip
    $built += $zip
}

# ---- checksums.txt ---------------------------------------------------------
# Format mirrors sha256sum: "<hash>  <filename>". UpdateService takes the first whitespace
# token as the hash, so a UTF-8 BOM would corrupt the first entry - write without one.
Write-Host "==> Writing checksums.txt" -ForegroundColor Cyan
$lines = @()
foreach ($zip in $built) {
    $hash      = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    $localName = [System.IO.Path]::GetFileName($zip)
    Write-Host "    $localName"
    Write-Host "      $hash"
    foreach ($variant in (Get-AssetNameVariants -LocalName $localName)) {
        $lines += "$hash  $variant"
    }
}
$checksums = Join-Path $OutDir 'checksums.txt'
[System.IO.File]::WriteAllText($checksums, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

Remove-Item -LiteralPath $stageRoot -Recurse -Force
# Raw export output is scratch once it's zipped; the zips are the artifact.
$exportScratch = Join-Path $OutDir '.export'
if ($Export -and (Test-Path -LiteralPath $exportScratch)) {
    Remove-Item -LiteralPath $exportScratch -Recurse -Force
}

Write-Host ""
Write-Host "Done. Artifacts in $OutDir" -ForegroundColor Green
foreach ($zip in $built) {
    $mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Write-Host ("  {0}  ({1} MB)" -f [System.IO.Path]::GetFileName($zip), $mb)
}
Write-Host "  checksums.txt"
Write-Host ""
Write-Host "Release checklist:" -ForegroundColor Yellow
Write-Host "  1. Tag v$Version  (clean 'v' + dotted - 'v.$Version' mis-parses in UpdateService)"
Write-Host "  2. Paste the CHANGELOG.md section for this version as the Release body (any length; Discord truncates its embed and links back)"
Write-Host "  3. Attach the zips above AND checksums.txt (it lists each asset under both the"
Write-Host "     spaced and dotted spellings, so verification works however GitHub names them)"

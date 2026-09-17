[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Build,
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    # Path to a script or executable that Authenticode-signs one file passed as its only
    # argument (for example a wrapper around `dotnet sign code artifact-signing`). Optional:
    # falls back to $env:PROGRAMA_WINDOWS_SIGN_SCRIPT, and the build ships unsigned when
    # neither is set. See docs/windows-signing.md.
    [string]$SignScript = $env:PROGRAMA_WINDOWS_SIGN_SCRIPT
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'build-windows.ps1 must run on Windows with the MSVC toolchain and .NET 10 SDK.'
}
if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    throw "Version must be a canonical semantic version, got '$Version'."
}
if ($Build -cnotmatch '^[1-9][0-9]*$') { throw "Build must be a positive canonical decimal integer, got '$Build'." }
if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw "Commit must be a 40-character lowercase hexadecimal SHA, got '$Commit'." }

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $ResolvedOutput) {
    if ((Get-ChildItem -LiteralPath $ResolvedOutput -Force | Measure-Object).Count -ne 0) { throw "OutputDirectory must be fresh and empty: $ResolvedOutput" }
} else { New-Item -ItemType Directory -Path $ResolvedOutput | Out-Null }

$BuildRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("programa-windows-build-" + [Guid]::NewGuid().ToString('N'))
$NativeRoot = Join-Path $BuildRoot 'native'
$CoreTarget = Join-Path $BuildRoot 'core-target'
$TerminalTarget = Join-Path $BuildRoot 'terminal-target'
$PublishRoot = Join-Path $BuildRoot 'publish'
New-Item -ItemType Directory -Path $NativeRoot | Out-Null
$PreviousRustFlags = $env:RUSTFLAGS
$env:RUSTFLAGS = if ([string]::IsNullOrWhiteSpace($PreviousRustFlags)) { '-C target-feature=+crt-static' } else { "$PreviousRustFlags -C target-feature=+crt-static" }

function Invoke-Checked([string]$Description, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

# Signs $ExecutablePath in place when $SignScript is set, and otherwise prints an unsigned-build
# notice and returns $false. Must run on the single published exe before any byte-identical copy
# of it is made: Authenticode signing embeds a certificate and timestamp fetched fresh per
# signing call, so signing two already-duplicated files separately would make them diverge.
function Invoke-ProgramaWindowsSigning([string]$ExecutablePath, [string]$SignScript) {
    if ([string]::IsNullOrWhiteSpace($SignScript)) {
        Write-Output "Unsigned build: no signing script configured (pass -SignScript or set PROGRAMA_WINDOWS_SIGN_SCRIPT). Shipping $([System.IO.Path]::GetFileName($ExecutablePath)) unsigned."
        return $false
    }

    Invoke-Checked 'Windows executable signing' { & $SignScript $ExecutablePath }

    $Signature = Get-AuthenticodeSignature -LiteralPath $ExecutablePath
    if ($Signature.Status -ne 'Valid') {
        throw "Signing was requested via -SignScript but Get-AuthenticodeSignature reports '$($Signature.Status)' for $ExecutablePath, not Valid: $($Signature.StatusMessage)"
    }
    Write-Output "Signed $([System.IO.Path]::GetFileName($ExecutablePath)): Authenticode signature Valid (signer: $($Signature.SignerCertificate.Subject))."
    return $true
}

try {
    $CoreManifest = Join-Path $RepositoryRoot 'core\Cargo.toml'
    Invoke-Checked 'core formatting' { cargo fmt --manifest-path $CoreManifest --all -- --check }
    Invoke-Checked 'core tests' { cargo test --manifest-path $CoreManifest --workspace --locked --target x86_64-pc-windows-msvc --target-dir $CoreTarget }
    Invoke-Checked 'core release build' { cargo build --manifest-path $CoreManifest --package programa-ffi --release --locked --target x86_64-pc-windows-msvc --target-dir $CoreTarget }

    $TerminalManifest = Join-Path $RepositoryRoot 'core\crates\programa-terminal\Cargo.toml'
    Invoke-Checked 'terminal formatting' { cargo fmt --manifest-path $TerminalManifest -- --check }
    Invoke-Checked 'terminal tests' { cargo test --manifest-path $TerminalManifest --locked --target x86_64-pc-windows-msvc --target-dir $TerminalTarget }
    $TerminalVendorManifest = Join-Path $RepositoryRoot 'core\vendor\alacritty_terminal\Cargo.toml'
    Invoke-Checked 'terminal read regression' { cargo test --manifest-path $TerminalVendorManifest --locked --lib parses_buffered_bytes_before_returning_a_terminal_read_error --target x86_64-pc-windows-msvc --target-dir $TerminalTarget }
    Invoke-Checked 'terminal release build' { cargo build --manifest-path $TerminalManifest --release --locked --target x86_64-pc-windows-msvc --target-dir $TerminalTarget }

    Copy-Item -LiteralPath (Join-Path $CoreTarget 'x86_64-pc-windows-msvc\release\programa_core.dll') -Destination $NativeRoot
    Copy-Item -LiteralPath (Join-Path $TerminalTarget 'x86_64-pc-windows-msvc\release\programa_terminal.dll') -Destination $NativeRoot

    $TestProject = Join-Path $RepositoryRoot 'windows\Programa.Tests\Programa.Tests.csproj'
    Invoke-Checked 'managed tests' { dotnet test $TestProject --configuration Release --runtime win-x64 --property:PublishSingleFile=false --property:ProgramaNativeDirectory=$NativeRoot }

    $AppProject = Join-Path $RepositoryRoot 'windows\Programa\Programa.csproj'
    Invoke-Checked 'WinUI publish' {
        dotnet publish $AppProject --configuration Release --runtime win-x64 --self-contained true --output $PublishRoot `
            --property:ProgramaNativeDirectory=$NativeRoot --property:ProgramaVersion=$Version `
            --property:ProgramaBuild=$Build --property:ProgramaCommit=$Commit
    }

    $BuiltExecutable = Join-Path $PublishRoot 'programa.exe'
    if (-not (Test-Path -LiteralPath $BuiltExecutable -PathType Leaf)) { throw "dotnet publish did not produce $BuiltExecutable" }
    $ActualVersion = (& $BuiltExecutable --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The published executable could not report its version.' }
    $ExpectedVersion = "programa $Version (build $Build, commit $Commit)"
    if ($ActualVersion -cne $ExpectedVersion) { throw "Version mismatch. Expected '$ExpectedVersion', got '$ActualVersion'." }
    $NativeProbe = (& $BuiltExecutable --verify-native-libraries | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $NativeProbe -cne 'ok') { throw "The single-file executable could not extract and load both native libraries. Output: '$NativeProbe'." }

    $Stream = [System.IO.File]::OpenRead($BuiltExecutable)
    $Reader = [System.IO.BinaryReader]::new($Stream)
    try {
        if ($Reader.ReadUInt16() -ne 0x5A4D) { throw 'The built artifact has no DOS MZ header.' }
        $Stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $PeOffset = $Reader.ReadInt32()
        if ($PeOffset -lt 0x40 -or $PeOffset -gt ($Stream.Length - 6)) { throw 'The built artifact has an invalid PE header offset.' }
        $Stream.Seek($PeOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        if ($Reader.ReadUInt32() -ne 0x00004550) { throw 'The built artifact has no PE signature.' }
        if ($Reader.ReadUInt16() -ne 0x8664) { throw 'The built artifact is not an x86-64 Windows executable.' }
    } finally { $Reader.Dispose(); $Stream.Dispose() }

    # Must run before the two byte-identical copies below are written; see
    # Invoke-ProgramaWindowsSigning for why.
    $SigningPerformed = Invoke-ProgramaWindowsSigning -ExecutablePath $BuiltExecutable -SignScript $SignScript

    $RollingExecutable = Join-Path $ResolvedOutput 'programa-windows.exe'
    $ArchivedExecutable = Join-Path $ResolvedOutput "programa-windows-$Build.exe"
    Copy-Item -LiteralPath $BuiltExecutable -Destination $RollingExecutable
    Copy-Item -LiteralPath $BuiltExecutable -Destination $ArchivedExecutable
    $RollingHash = (Get-FileHash -LiteralPath $RollingExecutable -Algorithm SHA256).Hash
    $ArchivedHash = (Get-FileHash -LiteralPath $ArchivedExecutable -Algorithm SHA256).Hash
    if ($RollingHash -cne $ArchivedHash) { throw 'The rolling and build-numbered executables are not byte-identical.' }
    if ((Get-ChildItem -LiteralPath $ResolvedOutput -File | Measure-Object).Count -ne 2) { throw 'The output directory must contain exactly two files.' }

    if ($SigningPerformed) {
        foreach ($SignedExecutable in @($RollingExecutable, $ArchivedExecutable)) {
            $CopySignature = Get-AuthenticodeSignature -LiteralPath $SignedExecutable
            if ($CopySignature.Status -ne 'Valid') { throw "Post-copy signature check failed for ${SignedExecutable}: $($CopySignature.Status)." }
        }
        Write-Output 'Authenticode signature verified on both release artifacts.'
    } else {
        Write-Output 'Unsigned build: skipping Authenticode verification.'
    }

    Write-Output "Windows executable: $RollingExecutable"
    Write-Output "Archived executable: $ArchivedExecutable"
    Write-Output "SHA-256: $RollingHash"
} finally {
    $env:RUSTFLAGS = $PreviousRustFlags
    if (Test-Path -LiteralPath $BuildRoot) { Remove-Item -LiteralPath $BuildRoot -Recurse -Force }
}

<#
.SYNOPSIS
Builds one release of Lamella's interpreter firmware: an image for every board in tools/boards.json, built from
the Lamella source at a tag, with its checks, third-party notices, SHA256SUMS, manifest.json and release notes.

.DESCRIPTION
Run it from a checkout of lamella-interpreter-firmware. It writes <OutRoot>/<Version>/, where OutRoot is out/ in
that checkout unless -OutRoot names another folder:
  release/           the compiled output files
  release-notes.md   the release's description, from tools/release-notes.md
  build-record.json  what was built, from which commit, with which toolchain and with which command
  source/, target/   the Lamella source and cargo's build directory, kept so that building again is quick

The source is cloned at the tag from -SourceRepository (by default boards.json's sourceRepository, or a local clone path).
Its commit must match the tag named in boards.json's sourceRepository, since the release states which published source it
was built from.

This script requires PowerShell 7, Git, and Rust through rustup (with the toolchain boards.json names and each board's target).

.EXAMPLE
pwsh tools/build-images.ps1 -Version 0.3.0 -Prerelease

.EXAMPLE
pwsh tools/build-images.ps1 -Version 0.3.0 -SourceRepository D:\src\lamella -OutRoot D:\b
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Tag,
    [string]$SourceRepository,
    [string]$OutRoot,
    [string[]]$Board,
    [int]$Jobs,
    [switch]$Prerelease,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run this with PowerShell 7 (pwsh).' }
# The builds this starts inherit the priority, so the computer stays usable while they run.
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
. (Join-Path $PSScriptRoot 'firmware-image.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Config = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'boards.json') | ConvertFrom-Json -AsHashtable
if ($Config['schema'] -ne 1) { throw "tools/boards.json is schema $($Config['schema']); this script reads schema 1" }
if (-not $Tag) { $Tag = "v$Version" }
if (-not $OutRoot) { $OutRoot = Join-Path $RepoRoot 'out' }
$PublicSource = $Config['sourceRepository']
$CloneFrom = if ($SourceRepository) { $SourceRepository } else { $PublicSource }
$Rust = $Config['rust']
$Wifi = $Config['wifi']

$OutDir = [IO.Path]::GetFullPath((Join-Path $OutRoot $Version))
$SourceDir = Join-Path $OutDir 'source'
$TargetDir = Join-Path $OutDir 'target'
$WorkDir = Join-Path $OutDir 'work'
$ReleaseDir = Join-Path $OutDir 'release'

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function ConvertFrom-Hex32([string]$Text) { [Convert]::ToUInt32(($Text -replace '^0x', ''), 16) }
function Write-Lf([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}
# The first of $Needles found in the file, compared byte for byte (case-insensitively), or $null.
function Find-Bytes([string]$Path, [string[]]$Needles) {
    $haystack = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($Path))
    foreach ($needle in $Needles) {
        if (-not $needle) { continue }
        $bytes = [Text.Encoding]::Latin1.GetString([Text.Encoding]::UTF8.GetBytes($needle))
        if ($haystack.IndexOf($bytes, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $needle }
    }
    $null
}

# --- the boards ---------------------------------------------------------------------------------------
$required = 'board', 'name', 'language', 'crate', 'bin', 'target', 'features', 'wifi', 'format', 'flashBase', 'uf2Family'
$Selected = @(if ($Board) {
        foreach ($id in $Board) {
            $found = @($Config['boards'] | Where-Object { $_['board'] -eq $id })
            if (-not $found.Count) { throw "tools/boards.json has no board $id" }
            $found[0]
        }
    } else { $Config['boards'] })
foreach ($entry in $Selected) {
    foreach ($key in $required) { if ($null -eq $entry[$key]) { throw "board $($entry['board']) in tools/boards.json has no $key" } }
    if ($entry['format'] -ne 'uf2') { throw "board $($entry['board']): this script writes uf2 images, not $($entry['format'])" }
    if (-not $Config['languageNames'][$entry['language']]) { throw "board $($entry['board']): languageNames has no $($entry['language'])" }
}

# --- the source ---------------------------------------------------------------------------------------
if ((Test-Path -LiteralPath $ReleaseDir) -and @(Get-ChildItem -LiteralPath $ReleaseDir -Force).Count) {
    if (-not $Rebuild) { throw "$ReleaseDir holds a build already; pass -Rebuild to build this release again" }
}
Remove-Item -LiteralPath $ReleaseDir, $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $OutDir, $TargetDir, $WorkDir, $ReleaseDir | Out-Null

Write-Host "==> $Tag in $PublicSource"
$refs = @(& git ls-remote --tags $PublicSource)
if ($LASTEXITCODE -ne 0) { throw "git ls-remote $PublicSource failed" }
# An annotated tag's own line names the tag object; its peeled line (^{}) names the commit.
$escaped = [regex]::Escape($Tag)
$tagLine = @(@($refs | Where-Object { $_ -match "\srefs/tags/$escaped\^\{\}$" }) + @($refs | Where-Object { $_ -match "\srefs/tags/$escaped$" })) |
    Select-Object -First 1
if (-not $tagLine) { throw "$PublicSource has no tag $Tag; publish the source and its tag first" }
$Commit = ($tagLine -split '\s+')[0]
Write-Host "    $Tag is $Commit"

$marker = Join-Path $OutDir 'source-commit.txt'
$reuse = (Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $SourceDir) -and (Get-Content -Raw -LiteralPath $marker).Trim() -eq $Commit
if ($reuse) {
    Write-Host "    the source at $Commit is already in $SourceDir"
} else {
    Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $SourceDir) { Remove-Item -LiteralPath $SourceDir -Recurse -Force }
    Write-Host "    cloning $CloneFrom at $Tag into $SourceDir"
    # core.autocrlf=false keeps every file as committed: a checkout that rewrote line endings would change what
    # the images embed, and the same release would differ from one computer to the next.
    $cloneArgs = @('clone', '--quiet', '-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '--branch', $Tag)
    if ($CloneFrom -match '^(https?|ssh|git)://') { $cloneArgs += @('--depth', '1') }
    $cloneArgs += @($CloneFrom, $SourceDir)
    Invoke-Checked 'git clone' { & git @cloneArgs }
}
$head = "$(& git -C $SourceDir rev-parse HEAD)".Trim()
if ($head -ne $Commit) { throw "$CloneFrom's $Tag is $head, but $PublicSource's $Tag is $Commit; build from the published source" }
$changed = @(& git -C $SourceDir status --porcelain)
if ($changed.Count) { throw "$SourceDir differs from ${Tag}: $($changed -join '; ')" }
if (-not $reuse) { Write-Lf $marker "$Commit`n" }

# --- the toolchain ------------------------------------------------------------------------------------
$targets = @($Selected | ForEach-Object { $_['target'] } | Select-Object -Unique)
$install = "rustup toolchain install $Rust --profile minimal --target $($targets -join ',')"
& rustup --version *> $null
if ($LASTEXITCODE -ne 0) { throw 'rustup is not installed; it is how this script reaches the Rust toolchain (https://rustup.rs)' }
$rustc = "$(& rustc "+$Rust" --version 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $rustc) { throw "Rust $Rust is not installed; run: $install" }
$installed = @(& rustup target list --installed --toolchain $Rust)
$missingTargets = @($targets | Where-Object { $_ -notin $installed })
if ($missingTargets.Count) { throw "Rust $Rust has no $($missingTargets -join ', ') target; run: rustup target add --toolchain $Rust $($missingTargets -join ' ')" }
foreach ($name in 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_BUILD_RUSTFLAGS') {
    if ([Environment]::GetEnvironmentVariable($name)) { throw "$name is set, and it would replace the path remapping this build passes; unset it" }
}
Write-Host "    $rustc"

# --- the images ---------------------------------------------------------------------------------------
$homeDir = [Environment]::GetFolderPath('UserProfile')
$cargoHome = [IO.Path]::GetFullPath($(if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $homeDir '.cargo' })).TrimEnd('\', '/')
$sourceRoot = [IO.Path]::GetFullPath($SourceDir).TrimEnd('\', '/')
$targetRoot = [IO.Path]::GetFullPath($TargetDir).TrimEnd('\', '/')
$machinePaths = @($sourceRoot, $targetRoot, $OutDir, $RepoRoot, $cargoHome, $homeDir) |
    ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') } |
    ForEach-Object { $_; $_.Replace('\', '/'); $_.Replace('\', '\\') } | Select-Object -Unique
$remaps = @("$sourceRoot=", "$cargoHome=/cargo", "$targetRoot=/target")
if (@($remaps | Where-Object { $_.Contains("'") }).Count) { throw "a path holds a ' , which a TOML literal string cannot: $($remaps -join ', ')" }
$rustflags = ($remaps | ForEach-Object { "'--remap-path-prefix=$_'" }) -join ', '

function Get-CargoProfile($Entry) {
    if ($Entry['profile']) { return $Entry['profile'] }
    $section = ''
    $wanted = "$($Entry['language'])_interpreter"
    $boardFile = Join-Path $SourceDir "bsp/boards/$($Entry['board'])/board.toml"
    if (-not (Test-Path -LiteralPath $boardFile)) { throw "the source has no bsp/boards/$($Entry['board'])/board.toml" }
    foreach ($boardLine in Get-Content -LiteralPath $boardFile) {
        if ($boardLine -match '^\s*\[\[?([^\]]+)\]\]?') { $section = $Matches[1]; continue }
        if ($section -eq $wanted -and $boardLine -match '^\s*optimization\s*=\s*"([^"]*)"') {
            $mapped = $Config['profiles'][$Matches[1]]
            if (-not $mapped) { throw "$($Entry['board'])'s board.toml asks for the build '$($Matches[1])', which boards.json's profiles does not map" }
            return $mapped
        }
    }
    throw "$($Entry['board'])'s board.toml has no [$wanted] optimization, and boards.json gives no profile for it"
}

$secretValues = @($Wifi['secretVariables'] | ForEach-Object { [Environment]::GetEnvironmentVariable($_) } | Where-Object { $_ })
$savedNetwork = @{}
foreach ($name in $Wifi['buildVariables']) { $savedNetwork[$name] = [Environment]::GetEnvironmentVariable($name) }
$images = [Collections.Generic.List[object]]::new()
try {
    # Removed with a real null: setting $null from PowerShell would set an empty variable, which a build reads as
    # a network with an empty name.
    foreach ($name in $Wifi['buildVariables']) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
    foreach ($entry in $Selected) {
        $id = $entry['board']
        $cargoProfile = Get-CargoProfile $entry
        $command = "cargo +$Rust build --locked -p $($entry['crate']) --bin $($entry['bin']) --profile $cargoProfile --target $($entry['target']) --features $($entry['features'])"
        Write-Host "==> $id`: $command"
        $cargoArgs = @("+$Rust", 'build', '--quiet', '--locked', '-p', $entry['crate'], '--bin', $entry['bin'], '--profile', $cargoProfile,
            '--target', $entry['target'], '--features', $entry['features'], '--config', "target.$($entry['target']).rustflags=[$rustflags]")
        if ($Jobs) { $cargoArgs += @('-j', $Jobs) }
        $savedTarget = $env:CARGO_TARGET_DIR
        $env:CARGO_TARGET_DIR = $TargetDir
        Push-Location -LiteralPath $SourceDir
        try { Invoke-Checked "$id's build" { & cargo @cargoArgs } } finally { Pop-Location; $env:CARGO_TARGET_DIR = $savedTarget }

        $elfPath = Join-Path $WorkDir "$id.elf"
        Copy-Item -LiteralPath (Join-Path $TargetDir "$($entry['target'])/$cargoProfile/$($entry['bin'])") -Destination $elfPath -Force
        $flashBase = ConvertFrom-Hex32 $entry['flashBase']
        $family = ConvertFrom-Hex32 $entry['uf2Family']
        $flat = Get-FlatImage $elfPath
        if ($flat.Base -ne $flashBase) { throw ("{0}'s image begins at 0x{1:x8}, not at the start of flash, 0x{2:x8}" -f $id, $flat.Base, $flashBase) }
        $flatPath = Join-Path $WorkDir "$id.bin"
        [IO.File]::WriteAllBytes($flatPath, $flat.Bytes)
        $fileName = "lamella-$($entry['language'])-$id-$Version.uf2"
        $uf2Path = Join-Path $ReleaseDir $fileName
        [IO.File]::WriteAllBytes($uf2Path, (ConvertTo-Uf2 $flat.Bytes $flashBase $family))

        foreach ($path in $elfPath, $flatPath, $uf2Path) {
            $found = Find-Bytes $path $machinePaths
            if ($found) { throw "$path holds the path $found of this computer" }
            if (Find-Bytes $path $secretValues) { throw "$path holds a Wi-Fi network name or password set in this shell" }
        }
        foreach ($path in $elfPath, $flatPath) {
            if (Find-Bytes $path @($Wifi['buildTimeNetworkMessage'])) { throw "$path joins a network named at build time" }
            $saysNoNetwork = [bool](Find-Bytes $path @($Wifi['noNetworkMessage']))
            if ($entry['wifi'] -and -not $saysNoNetwork) { throw "$path is marked Wi-Fi in boards.json but has no Wi-Fi of a build that names no network" }
            if (-not $entry['wifi'] -and $saysNoNetwork) { throw "$path has Wi-Fi, but boards.json does not mark $id as Wi-Fi" }
        }
        $blocks = Test-Uf2 $uf2Path $flashBase $family
        $images.Add([pscustomobject]@{
                Board = $id; Name = $entry['name']; Language = $entry['language']; Crate = $entry['crate']; Target = $entry['target']
                Features = $entry['features']; Wifi = [bool]$entry['wifi']; File = $fileName; Bytes = (Get-Item -LiteralPath $uf2Path).Length
                ImageBytes = $flat.Bytes.Length; Blocks = $blocks; FlashBase = $entry['flashBase']; Uf2Family = $entry['uf2Family']
                Sha256 = (Get-Sha256 $uf2Path); ElfSha256 = (Get-Sha256 $elfPath); Command = $command
            })
        Write-Host ("    {0}: {1:N0} bytes of flash, {2:N0}-byte UF2 ({3} blocks){4}" -f $fileName, $flat.Bytes.Length, (Get-Item -LiteralPath $uf2Path).Length, $blocks, $(if ($entry['wifi']) { ', Wi-Fi' } else { '' }))
    }
} finally {
    foreach ($name in $savedNetwork.Keys) {
        if ($null -eq $savedNetwork[$name]) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
        else { [Environment]::SetEnvironmentVariable($name, $savedNetwork[$name]) }
    }
}

# --- the third-party notices ----------------------------------------------------------------------------
Write-Host '==> the third-party notices'
$noticeName = '^(licen[cs]e|copying|copyright|notice|unlicense)'
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
function Get-NoticeText([string]$Path) {
    try { $body = $strictUtf8.GetString([IO.File]::ReadAllBytes($Path)) } catch { throw "$Path is not UTF-8 text" }
    $body.TrimStart([char]0xFEFF).Replace("`r`n", "`n").TrimEnd("`n", ' ')
}
# The license a crate is used under here when the one it states offers a copyleft (GPL, LGPL or AGPL) choice: the
# other choices. A crate whose every choice is copyleft is refused; shipping one is a decision, not a build step.
function Get-UsedUnder([string]$Crate, [string]$License) {
    $tokens = @(($License -replace '/', ' OR ' -replace '\(', ' ( ' -replace '\)', ' ) ') -split '\s+' | Where-Object { $_ })
    $choices = @(); $current = @(); $depth = 0
    foreach ($token in $tokens) {
        if ($token -eq '(') { $depth++ } elseif ($token -eq ')') { $depth-- }
        if ($depth -eq 0 -and $token -ceq 'OR') { $choices += , $current; $current = @(); continue }
        $current += $token
    }
    $choices += , $current
    $free = @($choices | Where-Object { -not ($_ | Where-Object { $_ -match '^(A|L)?GPL' }) })
    if ($free.Count -eq $choices.Count) { return $null }
    if (-not $free.Count) { throw "$Crate is licensed $License alone, a copyleft license; an image that links it is not built without a decision to ship it" }
    (@($free | ForEach-Object { ($_ -join ' ').Replace('( ', '(').Replace(' )', ')') }) -join ' OR ')
}

$packages = @{}
$linkedBy = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
Push-Location -LiteralPath $SourceDir
try {
    foreach ($crateGroup in ($images | Group-Object -Property Crate)) {
        $crateManifest = Join-Path $SourceDir "crates/$($crateGroup.Name)/Cargo.toml"
        $union = (@($crateGroup.Group | ForEach-Object { $_.Features -split ',' }) | Select-Object -Unique) -join ','
        foreach ($targetName in @($crateGroup.Group | ForEach-Object { $_.Target } | Select-Object -Unique)) {
            $metadata = & cargo "+$Rust" metadata --format-version 1 --locked --filter-platform $targetName --manifest-path $crateManifest --features $union
            if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed for $($crateGroup.Name)" }
            foreach ($listed in (($metadata -join "`n") | ConvertFrom-Json -AsHashtable)['packages']) {
                $packages["$($listed['name']) $($listed['version'])"] = $listed
            }
        }
        # What each image links: cargo tree resolves that build's features for its target, over the normal
        # dependencies only (a build script's and a test's are not in the image).
        foreach ($image in $crateGroup.Group) {
            $tree = & cargo "+$Rust" tree --locked -p $image.Crate --target $image.Target --features $image.Features -e normal --prefix none --format '{p}'
            if ($LASTEXITCODE -ne 0) { throw "cargo tree failed for $($image.Board)" }
            foreach ($treeLine in $tree) {
                if ($treeLine -notmatch '^(\S+) v(\S+)') { continue }
                $key = "$($Matches[1]) $($Matches[2])"
                if (-not $packages.ContainsKey($key)) { throw "cargo tree names $key, which cargo metadata does not list" }
                if (-not $linkedBy.ContainsKey($key)) { $linkedBy[$key] = [Collections.Generic.List[string]]::new() }
                if (-not $linkedBy[$key].Contains($image.File)) { $linkedBy[$key].Add($image.File) }
            }
        }
    }
    $sysroot = "$(& rustc "+$Rust" --print sysroot)".Trim()
} finally { Pop-Location }
$stdNotice = Join-Path $sysroot 'share/doc/rust/COPYRIGHT-library.html'
if (-not (Test-Path -LiteralPath $stdNotice)) { throw "Rust $Rust at $sysroot has no share/doc/rust/COPYRIGHT-library.html, the standard library's notice" }
Copy-Item -LiteralPath $stdNotice -Destination (Join-Path $ReleaseDir 'RUST-STANDARD-LIBRARY-NOTICES.html')

# The Wi-Fi chip's firmware a Wi-Fi image carries: its version and source from the pins the source states, and its
# license from the file the build downloaded beside it, matched by the license's pinned hash.
$wifiImages = @($images | Where-Object { $_.Wifi })
$radio = $null
if ($wifiImages.Count) {
    $pins = Get-Content -Raw -LiteralPath (Join-Path $SourceDir $Wifi['radioFirmwarePins'])
    $radioVersion = [regex]::Match($pins, 'pub const VERSION: &str = "([^"]+)"').Groups[1].Value
    $upstream = [regex]::Match($pins, 'pub const UPSTREAM: &str = "([^"]+)"').Groups[1].Value
    $licensePin = [regex]::Match($pins, '(?s)pub const LICENSE: Pin = Pin \{.*?name: "([^"]+)".*?sha256: "([0-9a-f]{64})"')
    $licenseCommit = [regex]::Match($pins, 'license_file: "([0-9a-f]{40})/')
    if (-not $radioVersion -or -not $upstream -or -not $licensePin.Success -or -not $licenseCommit.Success) {
        throw "$($Wifi['radioFirmwarePins']) states no version, upstream, license pin or license commit in the form this script reads"
    }
    $licenseFile = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter $licensePin.Groups[1].Value |
            Where-Object { (Get-Sha256 $_.FullName) -eq $licensePin.Groups[2].Value } | Select-Object -First 1)
    if (-not $licenseFile.Count) { throw "the build left no $($licensePin.Groups[1].Value) with the pinned SHA-256 $($licensePin.Groups[2].Value) in $TargetDir" }
    $radio = [pscustomobject]@{
        Version = $radioVersion; Source = ($upstream -replace '^https://raw\.githubusercontent\.com/', 'https://github.com/')
        Commit = $licenseCommit.Groups[1].Value; LicenseName = $licensePin.Groups[1].Value; LicensePath = $licenseFile[0].FullName
    }
}

$languageNames = @($images | ForEach-Object { $Config['languageNames'][$_.Language] } | Select-Object -Unique)
$languages = $languageNames -join ' and '
$notice = [Text.StringBuilder]::new()
$say = { param([string]$Words = '') [void]$notice.Append($Words).Append("`n") }
$given = @{}
$give = {
    param([string]$Label, [string]$Path)
    $body = Get-NoticeText $Path
    if ($given.ContainsKey($body)) { & $say "${Label}: the same text as $($given[$body]), above."; & $say; return }
    $given[$body] = $Label
    & $say $Label; & $say ('-' * 80); & $say $body; & $say
}
$ours = @($linkedBy.Keys | Where-Object { $null -eq $packages[$_]['source'] })
$crates = @($linkedBy.Keys | Where-Object { $null -ne $packages[$_]['source'] })
& $say "Third-party notices: Lamella interpreter firmware $Version"
& $say
& $say "These images are Lamella's $languages interpreter firmware, built from $PublicSource at tag $Tag."
& $say 'Each is Lamella''s own code, under your choice of the MIT license (LICENSE-MIT) or the Apache License,'
& $say 'Version 2.0 (LICENSE-APACHE), built together with the third-party software below.'
& $say
foreach ($image in $images) { & $say "  $($image.File): $($image.Name), built with the features $($image.Features) for $($image.Target)" }
& $say
& $say "1. The Rust core and alloc libraries, which every image links. Their notice is the Rust project's own,"
& $say "   RUST-STANDARD-LIBRARY-NOTICES.html beside this file, as $rustc ships it."
$item = 2
if ($radio) {
    & $say "$item. The CYW43439 Wi-Fi chip's firmware $($radio.Version), which the $(($wifiImages | ForEach-Object { $_.Name }) -join ' and ') images"
    & $say '   carry, under the license given under "Wi-Fi chip firmware".'
    $item++
}
& $say "$item. Components in Lamella's own crates that came from others, under ""From Lamella's source"", each with"
& $say '   its license text.'
$item++
& $say "$item. The $($crates.Count) crates the images link, under ""Crates"". For each: its version, the license it states,"
& $say '   the license it is used under here when it offers a copyleft choice, where its source is published, which'
& $say '   images link it, and every license and notice file it ships, in full. A text the same as one given above'
& $say '   it is not given again; its entry names the one it repeats.'
& $say
if ($radio) {
    & $say ('=' * 80); & $say 'Wi-Fi chip firmware'; & $say ('=' * 80); & $say
    & $say "CYW43439 firmware $($radio.Version), from $($radio.Source) (its license at commit $($radio.Commit))"
    & $say "  In: $(($wifiImages | ForEach-Object { $_.File }) -join ', ')"
    & $say
    & $give $radio.LicenseName $radio.LicensePath
}
& $say ('=' * 80); & $say 'From Lamella''s source'; & $say ('=' * 80); & $say
$before = $notice.Length
foreach ($key in $ours) {
    $crateDir = Split-Path -Parent $packages[$key]['manifest_path']
    if ([IO.Path]::GetFullPath($crateDir).TrimEnd('\', '/') -ieq $sourceRoot) { throw "an image links $key, whose folder is the source's root" }
    $files = [string[]]@(Get-ChildItem -LiteralPath $crateDir -File -Recurse -Force | Where-Object {
            $_.Name -match $noticeName -and ('/' + [IO.Path]::GetRelativePath($crateDir, $_.FullName).Replace('\', '/')) -notmatch '/(target|tests|examples|benches)/'
        } | ForEach-Object { $_.FullName })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    foreach ($file in $files) { & $give ([IO.Path]::GetRelativePath($SourceDir, $file).Replace('\', '/')) $file }
}
if ($notice.Length -eq $before) { & $say 'None: no crate of Lamella''s that these images link holds code that came from others.'; & $say }
& $say ('=' * 80); & $say 'Crates'; & $say ('=' * 80); & $say
foreach ($key in $crates) {
    $pkg = $packages[$key]
    $crateDir = Split-Path -Parent $pkg['manifest_path']
    $files = [string[]]@(Get-ChildItem -LiteralPath $crateDir -File -Force | Where-Object { $_.Name -match $noticeName } | ForEach-Object { $_.Name })
    if (-not $files.Count) { throw "$key ships no license or notice file at its root ($crateDir)" }
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $license = [string]$pkg['license']
    if (-not $license) { throw "$key states no license" }
    & $say $key
    & $say "  License: $license"
    $usedUnder = Get-UsedUnder $key $license
    if ($usedUnder) { & $say "  Used here under: $usedUnder" }
    $origin = [string]$pkg['source']
    if ($origin -in 'registry+https://github.com/rust-lang/crates.io-index', 'sparse+https://index.crates.io/') { & $say "  Source: https://crates.io/crates/$($pkg['name'])/$($pkg['version'])" }
    else { & $say "  Source: $origin" }
    if ($pkg['repository']) { & $say "  Repository: $($pkg['repository'])" }
    $in = @($linkedBy[$key])
    & $say "  In: $(if ($in.Count -eq $images.Count) { 'every image' } else { $in -join ', ' })"
    & $say
    foreach ($file in $files) { & $give "$key, $file" (Join-Path $crateDir $file) }
}
$noticesPath = Join-Path $ReleaseDir 'THIRD-PARTY-NOTICES.txt'
Write-Lf $noticesPath $notice.ToString()
$found = Find-Bytes $noticesPath $machinePaths
if ($found) { throw "THIRD-PARTY-NOTICES.txt holds the path $found of this computer" }

# --- the manifest, the sums, the notes and the record ---------------------------------------------------
$manifest = [ordered]@{
    schema     = 1
    repository = "https://github.com/$($Config['firmwareRepository'])"
    version    = $Version
    tag        = $Tag
    prerelease = [bool]$Prerelease
    source     = [ordered]@{ repository = $PublicSource; tag = $Tag; commit = $Commit }
    toolchain  = $rustc
    images     = @($images | ForEach-Object {
            [ordered]@{
                board = $_.Board; name = $_.Name; language = $_.Language; file = $_.File; format = 'uf2'; bytes = $_.Bytes
                sha256 = $_.Sha256; flashBase = $_.FlashBase; uf2Family = $_.Uf2Family; build = $_.Command
                remappedPaths = 'the source tree to nothing, cargo''s home to /cargo and the build directory to /target, by --remap-path-prefix'
            }
        })
}
Write-Lf (Join-Path $ReleaseDir 'manifest.json') (($manifest | ConvertTo-Json -Depth 5) + "`n")

$names = [string[]]@(Get-ChildItem -LiteralPath $ReleaseDir -File | Where-Object { $_.Name -ne 'SHA256SUMS' } | ForEach-Object { $_.Name })
[Array]::Sort($names, [StringComparer]::Ordinal)
Write-Lf (Join-Path $ReleaseDir 'SHA256SUMS') ((($names | ForEach-Object { "$(Get-Sha256 (Join-Path $ReleaseDir $_))  $_" }) -join "`n") + "`n")

$rows = ($images | ForEach-Object { "| $($_.Name) | ``$($_.File)`` |" }) -join "`n"
$radioText = if ($radio) {
    "`nThe $(($wifiImages | ForEach-Object { $_.Name }) -join ' and ') images carry the CYW43439 Wi-Fi chip's firmware $($radio.Version)" +
    "; that firmware's license is in ``THIRD-PARTY-NOTICES.txt``."
} else { '' }
$notes = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'release-notes.md')).Replace('{{languages}}', $languages).
    Replace('{{version}}', $Version).Replace('{{tag}}', $Tag).Replace('{{source}}', $PublicSource).Replace('{{boards}}', $rows).
    Replace('{{radio}}', $radioText)
if ($notes -match '\{\{[a-z]+\}\}') { throw "tools/release-notes.md has a placeholder this script does not fill: $($Matches[0])" }
Write-Lf (Join-Path $OutDir 'release-notes.md') ($notes.TrimEnd() + "`n")

$record = [ordered]@{
    builtAt = (Get-Date).ToUniversalTime().ToString('o'); version = $Version; tag = $Tag; commit = $Commit; toolchain = $rustc
    builtWith = "$(& git -C $RepoRoot rev-parse HEAD 2>$null)".Trim()
    images = @($images | ForEach-Object { [ordered]@{ board = $_.Board; file = $_.File; sha256 = $_.Sha256; elfSha256 = $_.ElfSha256; imageBytes = $_.ImageBytes; command = $_.Command } })
}
Write-Lf (Join-Path $OutDir 'build-record.json') (($record | ConvertTo-Json -Depth 5) + "`n")

Write-Host "==> release $Version is in $ReleaseDir"
Get-ChildItem -LiteralPath $ReleaseDir -File | Sort-Object Name | ForEach-Object { Write-Host ("    {0,-52} {1,10:N0} B" -f $_.Name, $_.Length) }
Write-Host "    release notes: $(Join-Path $OutDir 'release-notes.md')"
Write-Host "    next: pwsh tools/publish-release.ps1 -Version $Version$(if ($OutRoot -ne (Join-Path $RepoRoot 'out')) { " -OutRoot $OutRoot" }) -DryRun"

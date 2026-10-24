# Turns a linked firmware ELF into the files a board is installed from. Dot-sourced by build-images.ps1.

# The bytes a flasher writes, as `objcopy -O binary` computes them: every PT_LOAD segment that carries file
# bytes, at its physical address (where the part's flash holds it), from the lowest address to the highest, with
# the gaps zero-filled and the segments copied in program-header order. Returns the image's base and bytes.
function Get-FlatImage([string]$Path) {
    $elf = [IO.File]::ReadAllBytes($Path)
    $isElf32 = $elf.Length -ge 52 -and $elf[0] -eq 0x7F -and $elf[1] -eq 0x45 -and $elf[2] -eq 0x4C -and $elf[3] -eq 0x46 -and
        $elf[4] -eq 1 -and $elf[5] -eq 1 -and [BitConverter]::ToUInt16($elf, 16) -eq 2
    if (-not $isElf32) { throw "$Path is not a linked little-endian ELF32 executable" }
    $headerOffset = [BitConverter]::ToUInt32($elf, 28)
    $headerSize = [BitConverter]::ToUInt16($elf, 42)
    $headerCount = [BitConverter]::ToUInt16($elf, 44)
    if ($headerSize -lt 32) { throw "$Path has program headers of $headerSize bytes, fewer than 32" }
    $segments = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $headerCount; $i++) {
        $at = [long]$headerOffset + [long]$i * $headerSize
        if ($at + 32 -gt $elf.Length) { throw "$Path is truncated in its program headers" }
        if ([BitConverter]::ToUInt32($elf, $at) -ne 1) { continue }
        $offset = [long][BitConverter]::ToUInt32($elf, $at + 4)
        $address = [long][BitConverter]::ToUInt32($elf, $at + 12)
        $length = [long][BitConverter]::ToUInt32($elf, $at + 16)
        if ($length -eq 0) { continue }
        if ($offset + $length -gt $elf.Length) { throw "$Path is truncated in a segment" }
        $segments.Add([pscustomobject]@{ Address = $address; Offset = $offset; Length = $length })
    }
    if (-not $segments.Count) { throw "$Path declares no loadable bytes" }
    $base = [long]::MaxValue
    $end = [long]0
    foreach ($segment in $segments) {
        $base = [Math]::Min($base, $segment.Address)
        $end = [Math]::Max($end, $segment.Address + $segment.Length)
    }
    $image = [byte[]]::new([int]($end - $base))
    foreach ($segment in $segments) {
        [Array]::Copy($elf, $segment.Offset, $image, $segment.Address - $base, $segment.Length)
    }
    [pscustomobject]@{ Base = [uint32]$base; Bytes = $image }
}

# A UF2 file (https://github.com/microsoft/uf2): 512-byte blocks, each carrying one 256-byte page of the image, the
# last page zero-filled, with its flash address, its index, the number of blocks and the chip's family id. A boot
# ROM refuses a block that does not carry a whole page, so every block does.
function ConvertTo-Uf2([byte[]]$Image, [uint32]$Base, [uint32]$Family) {
    if (-not $Image.Length) { throw 'an empty image makes no UF2' }
    $blocks = [int][Math]::Ceiling($Image.Length / 256)
    $uf2 = [byte[]]::new($blocks * 512)
    $tail = [BitConverter]::GetBytes([uint32]0x0AB16F30)
    for ($i = 0; $i -lt $blocks; $i++) {
        $at = $i * 512
        $words = [uint32[]]@(0x0A324655, 0x9E5D5157u, 0x00002000, ([uint32]($Base + 256 * $i)), 256, $i, $blocks, $Family)
        for ($w = 0; $w -lt 8; $w++) { [Array]::Copy([BitConverter]::GetBytes($words[$w]), 0, $uf2, $at + 4 * $w, 4) }
        [Array]::Copy($Image, 256 * $i, $uf2, $at + 32, [Math]::Min(256, $Image.Length - 256 * $i))
        [Array]::Copy($tail, 0, $uf2, $at + 508, 4)
    }
    , $uf2
}

# Throws unless the file is UF2 blocks of whole 256-byte pages for $Family, numbered in order, at consecutive
# pages from $Base. Returns the number of blocks.
function Test-Uf2([string]$Path, [uint32]$Base, [uint32]$Family) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes.Length % 512) { throw "$Path is $($bytes.Length) bytes, not whole 512-byte UF2 blocks" }
    $blocks = $bytes.Length / 512
    for ($i = 0; $i -lt $blocks; $i++) {
        $at = $i * 512
        $fields = 0..7 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $at + 4 * $_) }
        if ($fields[0] -ne 0x0A324655 -or $fields[1] -ne 0x9E5D5157u -or [BitConverter]::ToUInt32($bytes, $at + 508) -ne 0x0AB16F30) {
            throw "$Path block $i has no UF2 magic"
        }
        if (-not ($fields[2] -band 0x2000) -or $fields[7] -ne $Family) { throw "$Path block $i is not for family 0x$('{0:x8}' -f $Family)" }
        if ($fields[3] -ne [uint32]($Base + 256 * $i) -or $fields[4] -ne 256 -or $fields[5] -ne $i -or $fields[6] -ne $blocks) {
            throw "$Path block $i is not page $i of $blocks from 0x$('{0:x8}' -f $Base)"
        }
    }
    $blocks
}

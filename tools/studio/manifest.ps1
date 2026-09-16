<#
  Kallskar: list every Luau source on disk with the Studio path Rojo would give it, its class, byte count and an
  FNV-1a 32-bit hash. tools/studio/hash_sources.luau prints the same fields from inside Studio, so the two outputs
  can be diffed to prove the MCP-pushed scripts match disk exactly (the "no drift" rule from the plan).

  Rojo naming rules applied (default.project.json):
    src/shared  -> ReplicatedStorage.Kallskar          (Folder)
    src/server  -> ServerScriptService.Kallskar        (Folder)
    src/client  -> StarterPlayer.StarterPlayerScripts.Kallskar (Folder)
    tests       -> ServerStorage.KallskarTests          (Folder)
    X.luau -> ModuleScript X;  X.server.luau -> Script X;  X.client.luau -> LocalScript X
    dir/init.luau (or init.server/.client) -> dir itself becomes that script; its other files become children

  Usage:  pwsh -File tools/studio/manifest.ps1            (prints a sorted table)
#>
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$maps = [ordered]@{
    'src/shared' = 'ReplicatedStorage.Kallskar'
    'src/server' = 'ServerScriptService.Kallskar'
    'src/client' = 'StarterPlayer.StarterPlayerScripts.Kallskar'
    'tests'      = 'ServerStorage.KallskarTests'
}

function Get-Fnv1a([byte[]]$bytes) {
    # NOTE: a bare 0xFFFFFFFF literal is Int32 -1 in PowerShell, so the mask must be an explicit UInt64.
    $mask = [uint64]4294967295
    $prime = [uint64]16777619
    [uint64]$h = 2166136261
    foreach ($b in $bytes) {
        $h = $h -bxor [uint64]$b
        $h = ($h * $prime) -band $mask   # h < 2^32 and prime < 2^25, so the product fits in UInt64
    }
    return ('{0:x8}' -f $h)
}

$rows = foreach ($kv in $maps.GetEnumerator()) {
    $base = Join-Path $Root $kv.Key
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -Path $base -Recurse -File -Filter *.luau | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        $parts = $rel -split '/'
        $file = $parts[-1]
        $dirs = if ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] } else { @() }

        $class = 'ModuleScript'
        $name = $file -replace '\.luau$', ''
        if ($name -like '*.server') { $class = 'Script'; $name = $name -replace '\.server$', '' }
        elseif ($name -like '*.client') { $class = 'LocalScript'; $name = $name -replace '\.client$', '' }

        if ($name -eq 'init') {
            $segments = $dirs          # the directory itself is the script
        } else {
            $segments = @($dirs) + $name
        }
        $studio = (@($kv.Value) + $segments) -join '.'
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        [pscustomobject]@{ Path = $studio; Class = $class; Bytes = $bytes.Length; Hash = (Get-Fnv1a $bytes) }
    }
}
$rows | Sort-Object Path | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.Path, $_.Class, $_.Bytes, $_.Hash }

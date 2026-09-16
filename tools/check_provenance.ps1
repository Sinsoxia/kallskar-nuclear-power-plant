<#
  Kallskar: disk-side provenance check (the half the in-Studio ConfigSpec can't do).
  - every derived("...", "tools/derive/<file>") names a file that exists
  - every decision(..., "D-###") names a heading "## D-###" in docs/DECISIONS.md
  Exits 1 on any problem. Run before committing Config changes:
      pwsh -File tools/check_provenance.ps1
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$configDir = Join-Path $Root 'src/shared/Config'
$decisions = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'docs/DECISIONS.md')
$known = [regex]::Matches($decisions, '(?m)^## (D-\d{3})\b') | ForEach-Object { $_.Groups[1].Value }

$problems = @()
$derivedRefs = 0; $decisionRefs = 0
# Provenance.luau defines the constructors; its header comment contains usage examples, not data.
Get-ChildItem $configDir -Filter *.luau | Where-Object { $_.Name -ne 'Provenance.luau' } | ForEach-Object {
    $text = Get-Content -Raw -Encoding UTF8 $_.FullName
    foreach ($m in [regex]::Matches($text, 'tools/derive/[A-Za-z0-9_./-]+')) {
        $derivedRefs++
        $rel = $m.Value.TrimEnd('.', ')')
        if (-not (Test-Path (Join-Path $Root $rel))) { $problems += "$($_.Name): derived script '$rel' does not exist" }
    }
    foreach ($m in [regex]::Matches($text, 'decision\([^)]*?"(D-\d{3})')) {
        $decisionRefs++
        $id = $m.Groups[1].Value
        if ($known -notcontains $id) { $problems += "$($_.Name): decision '$id' has no '## $id' entry in docs/DECISIONS.md" }
    }
}
"derived refs: $derivedRefs, decision refs: $decisionRefs, decision records: $($known.Count)"
if ($problems.Count) { $problems | ForEach-Object { "PROBLEM $_" }; exit 1 }
"provenance references OK"

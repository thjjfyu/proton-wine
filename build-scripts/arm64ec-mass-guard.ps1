param(
    [string]$Root = ".",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$includeRoots = @("dlls", "include", "programs", "libs", "loader", "server", "tools")
$extensions = @("*.c", "*.h", "*.inl", "*.idl")

function Convert-Content {
    param([string]$Text)

    $changed = $false
    $newText = $Text

    # 1) #ifdef __x86_64__ -> explicit guard for arm64ec
    $pattern1 = '(?m)^([ \t]*)#ifdef[ \t]+__x86_64__([ \t]*(?:/\*.*\*/)?[ \t]*)$'
    $replace1 = '$1#if defined(__x86_64__) && !defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern1, $replace1)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 2) #if defined(__x86_64__) ... (without arm64ec) -> add guard
    $pattern2 = '(?m)^([ \t]*)#if[ \t]+defined\(__x86_64__\)(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace2 = '$1#if defined(__x86_64__) && !defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern2, $replace2)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 3) #elif defined(__x86_64__) ... (without arm64ec) -> add guard
    $pattern3 = '(?m)^([ \t]*)#elif[ \t]+defined\(__x86_64__\)(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace3 = '$1#elif defined(__x86_64__) && !defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern3, $replace3)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 4) Handle short GNU style: defined __x86_64__
    $pattern4 = '(?m)^([ \t]*)#if[ \t]+defined[ \t]+__x86_64__(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace4 = '$1#if defined(__x86_64__) && !defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern4, $replace4)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    $pattern5 = '(?m)^([ \t]*)#elif[ \t]+defined[ \t]+__x86_64__(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace5 = '$1#elif defined(__x86_64__) && !defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern5, $replace5)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 5) #elif defined(__aarch64__) ... (without arm64ec) -> include arm64ec
    $pattern6 = '(?m)^([ \t]*)#elif[ \t]+defined\(__aarch64__\)(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace6 = '$1#elif defined(__aarch64__) || defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern6, $replace6)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    $pattern7 = '(?m)^([ \t]*)#elif[ \t]+defined[ \t]+__aarch64__(?![^\r\n]*arm64ec)([^\r\n]*)$'
    $replace7 = '$1#elif defined(__aarch64__) || defined(__arm64ec__)$2'
    $tmp = [regex]::Replace($newText, $pattern7, $replace7)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 6) (defined(__i386__) || defined(__x86_64__)) -> add !arm64ec if missing
    $pattern8 = '\([ \t]*defined\(__i386__\)[ \t]*\|\|[ \t]*defined\(__x86_64__\)[ \t]*\)(?![^\r\n]*__arm64ec__)'
    $replace8 = '(defined(__i386__) || defined(__x86_64__)) && !defined(__arm64ec__)'
    $tmp = [regex]::Replace($newText, $pattern8, $replace8)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    # 7) (defined(__x86_64__) || defined(__i386__)) -> add !arm64ec if missing
    $pattern9 = '\([ \t]*defined\(__x86_64__\)[ \t]*\|\|[ \t]*defined\(__i386__\)[ \t]*\)(?![^\r\n]*__arm64ec__)'
    $replace9 = '(defined(__x86_64__) || defined(__i386__)) && !defined(__arm64ec__)'
    $tmp = [regex]::Replace($newText, $pattern9, $replace9)
    if ($tmp -ne $newText) { $newText = $tmp; $changed = $true }

    return @{ Changed = $changed; Text = $newText }
}

$allFiles = @()
foreach ($dir in $includeRoots) {
    $fullDir = Join-Path $Root $dir
    if (-not (Test-Path $fullDir)) { continue }
    foreach ($ext in $extensions) {
        $allFiles += Get-ChildItem -Path $fullDir -Recurse -File -Filter $ext
    }
}

$totalChanged = 0
$changedFiles = @()

foreach ($f in $allFiles) {
    $old = Get-Content -LiteralPath $f.FullName -Raw
    $res = Convert-Content -Text $old
    if (-not $res.Changed) { continue }

    $totalChanged++
    $changedFiles += $f.FullName
    if ($Apply) {
        Set-Content -LiteralPath $f.FullName -Value $res.Text -NoNewline
    }
}

if ($Apply) {
    Write-Output ("Applied changes to {0} file(s)." -f $totalChanged)
} else {
    Write-Output ("Dry-run: would change {0} file(s)." -f $totalChanged)
}

if ($changedFiles.Count -gt 0) {
    $changedFiles | Sort-Object | ForEach-Object { Write-Output $_ }
}

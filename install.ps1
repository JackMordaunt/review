# review installer for Windows. It downloads the four binaries for this
# machine — review and the sidecars it reads Go and Odin through — checks
# every sha256 before installing any, and puts them side by side in
# ~/.local/bin.
#
#   irm https://mordaunt.dev/code/review/install.ps1 | iex
#
# Run through iex it must never `exit`, which would close the caller's
# shell; errors are thrown instead. REVIEW_VERSION pins a release tag;
# REVIEW_BINDIR picks the directory; REVIEW_RELEASE_BASE overrides the
# download URL.

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue' # Windows PowerShell downloads crawl with it on.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $base = $env:REVIEW_RELEASE_BASE
  if (-not $base) {
    $base = if ($env:REVIEW_VERSION) {
      "https://github.com/jackmordaunt/review/releases/download/$env:REVIEW_VERSION"
    } else {
      'https://github.com/jackmordaunt/review/releases/latest/download'
    }
  }
  $bindir = if ($env:REVIEW_BINDIR) { $env:REVIEW_BINDIR } else { Join-Path $HOME '.local\bin' }
  $binaries = 'review', 'review-go', 'review-vet', 'odin-review-extract'

  # A local directory or file:// base is copied from, as curl does for the
  # shell installer; PowerShell 7's web cmdlets refuse the file scheme.
  function Get-Release($name, $to) {
    if ($base -match '^https?://') { Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $to }
    else { Copy-Item -Path (Join-Path ([uri]$base).LocalPath $name) -Destination $to }
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) "review-install-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    Write-Host "fetching review for windows-amd64 from $base"
    Get-Release 'sha256sums.txt' (Join-Path $work 'sha256sums.txt')
    $sums = Get-Content -Raw -Path (Join-Path $work 'sha256sums.txt')
    foreach ($b in $binaries) {
      $asset = "$b-windows-amd64.exe"
      Get-Release $asset (Join-Path $work $asset)
      # Accept an optional * before the name, which sha256sum prints in binary mode.
      $want = $sums -split "`n" | ForEach-Object {
        $f = $_.Trim() -split '\s+\*?'
        if ($f.Count -eq 2 -and $f[1] -eq $asset) { $f[0] }
      } | Select-Object -First 1
      if (-not $want) { throw "install: $asset is not in sha256sums.txt" }
      $have = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $work $asset)).Hash
      if ($have -ne $want) { throw "install: checksum mismatch for $asset" }
    }

    New-Item -ItemType Directory -Force -Path $bindir | Out-Null
    foreach ($b in $binaries) {
      Move-Item -Force -Path (Join-Path $work "$b-windows-amd64.exe") -Destination (Join-Path $bindir "$b.exe")
    }
  } finally {
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
  }
  Write-Host "installed $($binaries -join ' ') into $bindir"
  $sep = [IO.Path]::PathSeparator
  if (-not ("$sep$env:PATH$sep" -like "*$sep$bindir$sep*")) { Write-Host "add $bindir to your PATH" }
  & (Join-Path $bindir 'review.exe') version
}

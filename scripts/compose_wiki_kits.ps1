# Composite Wikipedia football-kit templates into images/clubs_kits/<Short>_<kind>.png
# Usage: powershell -ExecutionPolicy Bypass -File scripts\compose_wiki_kits.ps1 -Page "Chiangrai_United_F.C." -Short CRI
param(
  [Parameter(Mandatory = $true)][string]$Page,
  [Parameter(Mandatory = $true)][string]$Short,
  [int]$Scale = 4
)
Add-Type -AssemblyName System.Drawing
$ua = @{ "User-Agent" = "GPSL-KitSync/1.0 (https://github.com/gpsuperleague/GPSL)" }
$api = "https://en.wikipedia.org/w/api.php?action=parse&prop=text&format=json&redirects=1&page=" + [uri]::EscapeDataString($Page)
$h = (Invoke-RestMethod $api -Headers $ua).parse.text.'*'
if (-not $h) { throw "No HTML for Wikipedia page: $Page" }
$outDir = Join-Path $PSScriptRoot "..\images\clubs_kits"
$ex = 'position: relative; left: 0px; top: 0px; width: 100px; height: 135px; margin: 0 auto; padding: 0;'
$starts = @([regex]::Matches($h, [regex]::Escape($ex)) | ForEach-Object Index)
$done = @{}
for ($i = 0; $i -lt $starts.Count; $i++) {
  $pos = $starts[$i]
  $open = $h.LastIndexOf("<div", $pos)
  $end = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { [Math]::Min($h.Length, $pos + 12000) }
  $region = $h.Substring($open, $end - $open)
  $m = [regex]::Match($region, '>(Home|Away|Third) colours<', 'IgnoreCase')
  if (-not $m.Success) { continue }
  $kind = $m.Groups[1].Value.ToLower()
  if ($done[$kind]) { continue }
  $done[$kind] = $true
  $block = $region.Substring(0, $m.Index)

  $bmp = New-Object System.Drawing.Bitmap (100 * $Scale), (135 * $Scale), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.PixelOffsetMode = 'Half'
  $attr = New-Object System.Drawing.Imaging.ImageAttributes
  $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
  $n = 0
  foreach ($d in [regex]::Matches($block, '<div style="([^"]+)">((?:(?!<div)[\s\S])*?)</div>')) {
    $st = $d.Groups[1].Value
    if ($st -notmatch 'position:\s*absolute') { continue }
    $num = { param($k) if ($st -match "${k}:\s*([-\d.]+)px") { [double]$Matches[1] } else { 0 } }
    $x = [int](& $num 'left') * $Scale; $y = [int](& $num 'top') * $Scale
    $w = [Math]::Max(1, [int](& $num 'width') * $Scale); $hh = [Math]::Max(1, [int](& $num 'height') * $Scale)
    if ($st -match 'background-color:\s*(#[0-9a-fA-F]{3,6})') {
      $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Matches[1]))
      $g.FillRectangle($br, $x, $y, $w, $hh); $br.Dispose()
    }
    if ($d.Groups[2].Value -match 'src="([^"]+)"') {
      $src = ($Matches[1] -split '\?')[0]
      if ($src.StartsWith('//')) { $src = "https:$src" }
      $tmp = Join-Path $env:TEMP ("kitlayer_" + [guid]::NewGuid() + ".png")
      try {
        Invoke-WebRequest -Uri $src -OutFile $tmp -Headers $ua -UseBasicParsing
        $img = [System.Drawing.Image]::FromFile($tmp)
        $g.DrawImage($img, (New-Object System.Drawing.Rectangle $x, $y, $w, $hh), 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
        $img.Dispose()
      } catch { Write-Output "  layer failed: $src" }
      Remove-Item $tmp -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 300
    }
    $n++
  }
  $g.Dispose()

  # Wikipedia outlines are white outside the kit; flood-fill that from the edges to transparent
  $cw = $bmp.Width; $ch = $bmp.Height
  $data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $cw, $ch), 'ReadWrite', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $px = New-Object byte[] ($data.Stride * $ch)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
  $seen = New-Object bool[] ($cw * $ch)
  $q = New-Object System.Collections.Generic.Queue[int]
  for ($xx = 0; $xx -lt $cw; $xx++) { $q.Enqueue($xx); $q.Enqueue(($ch - 1) * $cw + $xx) }
  for ($yy = 0; $yy -lt $ch; $yy++) { $q.Enqueue($yy * $cw); $q.Enqueue($yy * $cw + $cw - 1) }
  while ($q.Count) {
    $p = $q.Dequeue()
    if ($seen[$p]) { continue }
    $seen[$p] = $true
    $cx = $p % $cw; $cy = [int][Math]::Floor($p / $cw)
    $o = $cx * 4 + $cy * $data.Stride
    $lo = [Math]::Min($px[$o], [Math]::Min($px[$o + 1], $px[$o + 2]))
    $hi = [Math]::Max($px[$o], [Math]::Max($px[$o + 1], $px[$o + 2]))
    $isBg = ($px[$o + 3] -lt 20) -or ($lo -ge 170 -and ($hi - $lo) -le 16)
    if (-not $isBg) { continue }
    $px[$o + 3] = 0
    if ($cx -gt 0) { $q.Enqueue($p - 1) }
    if ($cx -lt $cw - 1) { $q.Enqueue($p + 1) }
    if ($cy -gt 0) { $q.Enqueue($p - $cw) }
    if ($cy -lt $ch - 1) { $q.Enqueue($p + $cw) }
  }
  [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $data.Scan0, $px.Length)
  $bmp.UnlockBits($data)

  $out = Join-Path $outDir "${Short}_$kind.png"
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Write-Output "$kind : $n layers -> $out ($((Get-Item $out).Length) bytes)"
}
if (-not $done.Count) { Write-Output "No football-kit colours found on $Page" }

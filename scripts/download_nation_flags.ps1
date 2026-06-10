# Download 60 nation flag PNGs into images/flags/ (run from repo root).
# Source: flagcdn.com (CC0-style flag images). Re-run safe to refresh assets.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "images\flags"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$map = @{
  ARG = "ar"; FRA = "fr"; BRA = "br"; ENG = "gb-eng"; BEL = "be"
  POR = "pt"; NED = "nl"; ESP = "es"; ITA = "it"; CRO = "hr"
  URU = "uy"; MAR = "ma"; COL = "co"; GER = "de"; MEX = "mx"
  USA = "us"; SUI = "ch"; JPN = "jp"; SEN = "sn"; IRN = "ir"
  DEN = "dk"; KOR = "kr"; AUS = "au"; UKR = "ua"; TUR = "tr"
  ECU = "ec"; POL = "pl"; SRB = "rs"; WAL = "gb-wls"; CAN = "ca"
  GHA = "gh"; NOR = "no"; PAR = "py"; CRC = "cr"; EGY = "eg"
  ALG = "dz"; SCO = "gb-sct"; AUT = "at"; HUN = "hu"; CZE = "cz"
  NGA = "ng"; PAN = "pa"; TUN = "tn"; PER = "pe"; CHI = "cl"
  ROU = "ro"; SVK = "sk"; SWE = "se"; FIN = "fi"; IRL = "ie"
  CMR = "cm"; RSA = "za"; JAM = "jm"; BOL = "bo"; VEN = "ve"
  IRQ = "iq"; QAT = "qa"; KSA = "sa"; NZL = "nz"; CHN = "cn"
}

foreach ($entry in $map.GetEnumerator()) {
  $code = $entry.Key
  $slug = $entry.Value
  $url = "https://flagcdn.com/w320/$slug.png"
  $dest = Join-Path $outDir "$code.png"
  Write-Host "Downloading $code <- $url"
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

Write-Host "Done — $($map.Count) flags in $outDir"

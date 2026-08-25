<#
.SYNOPSIS
  Post-process an HTML server-check report: inject persistent checkboxes on failures.

.DESCRIPTION
  Does not change your report generator. Reads HTML + config.json, injects checkboxes
  in PowerShell (so ticks appear even if browser JS is limited), plus a small script
  so ticks persist via localStorage.

.PARAMETER InputHtml
  Path to the source HTML report.

.PARAMETER OutputHtml
  Optional output path. Default: <InputName>.checklist.html next to the input.

.PARAMETER ConfigPath
  Path to config.json (selectors). Default: config.json beside this script,
  else config.example.json.

.PARAMETER InPlace
  Overwrite the input file instead of writing a sibling .checklist.html.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InputHtml,

  [string]$OutputHtml = "",

  [string]$ConfigPath = "",

  [switch]$InPlace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$toolRoot = $PSScriptRoot
if (-not $ConfigPath) {
  $cfg = Join-Path $toolRoot "config.json"
  if (-not (Test-Path -LiteralPath $cfg)) {
    $cfg = Join-Path $toolRoot "config.example.json"
  }
  $ConfigPath = $cfg
}

if (-not (Test-Path -LiteralPath $InputHtml)) {
  throw "Input HTML not found: $InputHtml"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Config not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ns = [string]$config.storageNamespace
if (-not $ns) { $ns = "html-failure-checklist" }
$label = [string]$config.checkboxLabel
if (-not $label) { $label = "Done" }
$skipIfAnnotated = $true
if ($null -ne $config.skipIfAlreadyAnnotated) {
  $skipIfAnnotated = [bool]$config.skipIfAlreadyAnnotated
}

$html = Get-Content -LiteralPath $InputHtml -Raw -Encoding UTF8
$reportKey = [IO.Path]::GetFileName($InputHtml)

if ($skipIfAnnotated -and $html -match 'data-html-failure-checklist\s*=\s*"1"') {
  Write-Host "Already annotated — skipping (set skipIfAlreadyAnnotated false in config.json to force)."
  if ($InPlace) { return }
  if (-not $OutputHtml) {
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $InputHtml)
    $base = [IO.Path]::GetFileNameWithoutExtension($InputHtml)
    $OutputHtml = Join-Path $dir ($base + ".checklist.html")
  }
  Copy-Item -LiteralPath $InputHtml -Destination $OutputHtml -Force
  Write-Host "Copied existing annotated file to: $OutputHtml"
  return
}

# Strip a previous partial annotation so re-runs are clean
$html = [regex]::Replace(
  $html,
  '(?is)<!--\s*html-failure-checklist begin\s*-->.*?<!--\s*html-failure-checklist end\s*-->',
  ''
)
$html = [regex]::Replace(
  $html,
  '(?is)<span class="hfc-wrap"[^>]*>\s*<input[^>]*type="checkbox"[^>]*>\s*</span>',
  ''
)
$html = [regex]::Replace($html, '\s*data-html-failure-checklist="1"', '')
$html = [regex]::Replace($html, '\s*data-hfc-ready="1"', '')

# ---------------------------------------------------------------------------
# Inject checkboxes in PowerShell (reliable; does not depend on browser DOM)
# Matches "N. " issue starts after <br>, newlines, or common opening tags.
# Requires whitespace after the dot so IPs like 10.1.2.3 are ignored.
# ---------------------------------------------------------------------------
$script:HfcCount = 0

function New-HfcCheckboxHtml {
  param([string]$NumberText)
  $script:HfcCount++
  $id = '{0}:{1}:i{2}' -f $ns, $reportKey, $script:HfcCount
  $idAttr = [System.Security.SecurityElement]::Escape($id)
  $labelAttr = [System.Security.SecurityElement]::Escape($label)
  return ('<span class="hfc-wrap" data-hfc-id="{0}"><input type="checkbox" title="{1}" aria-label="{1}"></span>{2}' -f $idAttr, $labelAttr, $NumberText)
}

function Inject-BeforeNumber {
  param(
    [string]$Text,
    [string]$Pattern
  )
  $script:HfcInjectSrc = $Text
  $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  return $rx.Replace($Text, {
    param($m)
    $src = $script:HfcInjectSrc
    $start = $m.Index
    $behindLen = [Math]::Min(120, $start)
    $behind = if ($behindLen -gt 0) { $src.Substring($start - $behindLen, $behindLen) } else { '' }
    if ($behind -match 'hfc-wrap') { return $m.Value }
    $prefix = $m.Groups['prefix'].Value
    $num = $m.Groups['num'].Value
    return ($prefix + (New-HfcCheckboxHtml -NumberText $num))
  })
}

# after <br> / <BR />
$html = Inject-BeforeNumber -Text $html -Pattern '(?<prefix><br\s*/?\s*>\s*)(?<num>\d{1,3}\.\s+)'

# after opening tags (first line inside a notes/red block)
$html = Inject-BeforeNumber -Text $html -Pattern '(?<prefix><(?:font|div|span|p|td|li|pre)(?:\s[^>]*)?>\s*)(?<num>\d{1,3}\.\s+)'

# after newline (plain text breaks inside a tag)
$html = Inject-BeforeNumber -Text $html -Pattern '(?<prefix>(?<=[\r\n])\s*)(?<num>\d{1,3}\.\s+)'

Write-Host ("PowerShell injected {0} checkbox(es) into the HTML." -f $script:HfcCount)
if ($script:HfcCount -eq 0) {
  Write-Host "WARNING: No 'N. ' issue lines matched. Open the HTML in Notepad and check how failures are marked." -ForegroundColor Yellow
}

$configForJs = [ordered]@{
  storageNamespace = $ns
  checkboxLabel    = $label
  reportKey        = $reportKey
  injectedCount    = $script:HfcCount
}
$configJson = ($configForJs | ConvertTo-Json -Compress -Depth 5)

$injectCss = @'
<style id="html-failure-checklist-css">
  .hfc-wrap {
    display: inline-flex;
    align-items: flex-start;
    gap: 8px;
    margin-right: 6px;
    vertical-align: top;
  }
  .hfc-wrap input[type="checkbox"] {
    width: 16px;
    height: 16px;
    margin: 2px 0 0;
    cursor: pointer;
    flex-shrink: 0;
  }
  .hfc-done-row,
  .hfc-done-row td,
  .hfc-done,
  .hfc-issue-line.hfc-done {
    opacity: 0.55;
    text-decoration: line-through;
  }
  .hfc-toolbar {
    position: sticky;
    top: 0;
    z-index: 9999;
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    padding: 8px 12px;
    margin: 0 0 12px;
    background: #1a1a1a;
    border: 1px solid #444;
    border-radius: 6px;
    color: #ddd;
    font: 13px/1.4 Segoe UI, Arial, sans-serif;
  }
  .hfc-toolbar button {
    cursor: pointer;
    padding: 4px 10px;
    border-radius: 4px;
    border: 1px solid #666;
    background: #333;
    color: #eee;
  }
</style>
'@

# Browser script only wires persistence — boxes are already in the HTML
$injectJs = @'
<script data-html-failure-checklist="1">
(function () {
  var CFG = __HFC_CONFIG__;

  function applyDone(el, on) {
    if (!el) return;
    el.classList.toggle("hfc-done", on);
    var line = el.closest ? el.closest(".hfc-issue-line") : null;
    if (line) line.classList.toggle("hfc-done", on);
    var tr = el.closest ? el.closest("tr") : null;
    if (tr) tr.classList.toggle("hfc-done-row", on);
  }

  function updateCount() {
    var boxes = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
    var n = 0;
    for (var i = 0; i < boxes.length; i++) if (boxes[i].checked) n++;
    var el = document.getElementById("hfc-count");
    if (el) el.textContent = n + " / " + boxes.length + " ticked";
  }

  function wire() {
    if (document.documentElement.getAttribute("data-hfc-ready") === "1") return;
    document.documentElement.setAttribute("data-hfc-ready", "1");

    var bar = document.createElement("div");
    bar.className = "hfc-toolbar";
    bar.innerHTML =
      "<strong>Failure checklist</strong> " +
      "<span id=\"hfc-count\"></span> " +
      "<button type=\"button\" id=\"hfc-clear\">Clear ticks (this report)</button>";
    if (document.body) document.body.insertBefore(bar, document.body.firstChild);

    var boxes = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
    if (!boxes.length) {
      bar.innerHTML +=
        " <span style=\"color:#fc6\">No checkboxes were injected — re-run tickbox.ps1 on the original HTML.</span>";
      return;
    }

    for (var i = 0; i < boxes.length; i++) {
      (function (cb) {
        var wrap = cb.parentElement;
        var id = wrap && wrap.getAttribute("data-hfc-id");
        var on = false;
        if (id) {
          try { on = localStorage.getItem(id) === "1"; } catch (e) {}
        }
        cb.checked = on;
        applyDone(wrap, on);
        cb.addEventListener("change", function () {
          if (id) {
            try {
              if (cb.checked) localStorage.setItem(id, "1");
              else localStorage.removeItem(id);
            } catch (e) {}
          }
          applyDone(wrap, cb.checked);
          updateCount();
        });
      })(boxes[i]);
    }

    var clearBtn = document.getElementById("hfc-clear");
    if (clearBtn) {
      clearBtn.addEventListener("click", function () {
        if (!confirm("Clear all checklist ticks for this report in this browser?")) return;
        var all = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
        for (var j = 0; j < all.length; j++) {
          var c = all[j];
          var w = c.parentElement;
          var kid = w && w.getAttribute("data-hfc-id");
          if (kid) {
            try { localStorage.removeItem(kid); } catch (e) {}
          }
          c.checked = false;
          applyDone(w, false);
        }
        updateCount();
      });
    }

    updateCount();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
</script>
'@

$injectJs = $injectJs.Replace("__HFC_CONFIG__", $configJson)

$block = @"

<!-- html-failure-checklist begin -->
$injectCss
$injectJs
<!-- html-failure-checklist end -->

"@

if ($html -match '(?i)</body>') {
  $html = [regex]::Replace(
    $html,
    '</body>',
    ($block + '</body>'),
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
} else {
  $html = $html + $block
}

if ($html -notmatch '(?i)data-html-failure-checklist\s*=') {
  $html = [regex]::Replace(
    $html,
    '<html(\s[^>]*)?>',
    '<html$1 data-html-failure-checklist="1">',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

if ($InPlace) {
  $OutputHtml = $InputHtml
} elseif (-not $OutputHtml) {
  $dir = Split-Path -Parent (Resolve-Path -LiteralPath $InputHtml)
  $base = [IO.Path]::GetFileNameWithoutExtension($InputHtml)
  $OutputHtml = Join-Path $dir ($base + ".checklist.html")
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputHtml)
$outDir = Split-Path -Parent $outFull
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[IO.File]::WriteAllText($outFull, $html, $utf8NoBom)

Write-Host "Wrote: $outFull"
Write-Host "Open that file in a browser. You should see checkboxes beside each numbered issue."

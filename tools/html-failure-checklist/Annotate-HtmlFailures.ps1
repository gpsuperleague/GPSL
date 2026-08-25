<#
.SYNOPSIS
  Post-process an HTML server-check report: inject persistent checkboxes on failures.

.DESCRIPTION
  Many health-check reports BUILD the numbered red Notes lines with JavaScript at
  open-time. Those "1. … / 2. …" strings are NOT in the raw .html file.

  This tool therefore:
  1) Optionally injects checkboxes in PowerShell if static "N. " text exists.
  2) Always injects a browser script that waits for the page's own JS to render,
     then finds red numbered lines in the LIVE DOM and adds checkboxes.

.PARAMETER InputHtml
  Path to the source HTML report.

.PARAMETER OutputHtml
  Optional output path. Default: <InputName>.checklist.html next to the input.

.PARAMETER ConfigPath
  Path to config.json. Default: config.json beside this script, else example.

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
$skipIfAnnotated = $false
if ($null -ne $config.skipIfAlreadyAnnotated) {
  $skipIfAnnotated = [bool]$config.skipIfAlreadyAnnotated
}
$redHueMax = 80
if ($null -ne $config.redHueMax) { $redHueMax = [int]$config.redHueMax }
$redMinChannel = 120
if ($null -ne $config.redMinChannel) { $redMinChannel = [int]$config.redMinChannel }

function Read-ReportHtml {
  param([string]$Path)
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) { return "" }

  $encName = "UTF-8"
  $text = $null

  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $encName = "UTF-16 LE (BOM)"
    $text = [Text.Encoding]::Unicode.GetString($bytes)
  }
  elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $encName = "UTF-16 BE (BOM)"
    $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes)
  }
  elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $encName = "UTF-8 (BOM)"
    $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  }
  else {
    $sample = [Math]::Min(4000, $bytes.Length)
    $nuls = 0
    for ($i = 0; $i -lt $sample; $i++) {
      if ($bytes[$i] -eq 0) { $nuls++ }
    }
    if ($nuls -gt ($sample / 5)) {
      $encName = "UTF-16 LE (no BOM)"
      $text = [Text.Encoding]::Unicode.GetString($bytes)
    }
    else {
      $ansi = [Text.Encoding]::Default.GetString($bytes)
      $utf8 = [Text.Encoding]::UTF8.GetString($bytes)
      if ($ansi -match '(?i)<html|<body|Notes:|<script') {
        $encName = "Windows ANSI (Default)"
        $text = $ansi
      }
      else {
        $encName = "UTF-8"
        $text = $utf8
      }
    }
  }

  if ($text.IndexOf([char]0) -ge 0) {
    $text = $text.Replace([string][char]0, "")
  }

  Write-Host ("Read HTML using encoding: {0} ({1:N0} chars)" -f $encName, $text.Length)
  return $text
}

$html = Read-ReportHtml -Path $InputHtml
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

# Strip previous toolkit injection only (keep the report's own scripts)
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

# Optional: static "N. " already in the file (some reports are plain HTML)
$script:HfcCount = 0
function New-HfcCheckboxHtml {
  param([string]$NumberText)
  $script:HfcCount++
  $id = '{0}:{1}:static{2}' -f $ns, $reportKey, $script:HfcCount
  $idAttr = [System.Security.SecurityElement]::Escape($id)
  $labelAttr = [System.Security.SecurityElement]::Escape($label)
  return ('<span class="hfc-wrap" data-hfc-id="{0}"><input type="checkbox" title="{1}" aria-label="{1}"></span>{2}' -f $idAttr, $labelAttr, $NumberText)
}
function Inject-BeforeNumber {
  param([string]$Text, [string]$Pattern)
  $script:HfcInjectSrc = $Text
  $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  return $rx.Replace($Text, {
    param($m)
    $src = $script:HfcInjectSrc
    $start = $m.Index
    $behindLen = [Math]::Min(120, $start)
    $behind = if ($behindLen -gt 0) { $src.Substring($start - $behindLen, $behindLen) } else { '' }
    if ($behind -match 'hfc-wrap') { return $m.Value }
    return ($m.Groups['prefix'].Value + (New-HfcCheckboxHtml -NumberText $m.Groups['num'].Value))
  })
}

$htmlWork = $html.Replace([char]0x00A0, ' ')
$htmlWork = [regex]::Replace($htmlWork, '&nbsp;|&#160;|&#xA0;', ' ', 'IgnoreCase')
$numToken = '(?<num>(?<![\d.])\d{1,3}\.\s+)'
$htmlWork = Inject-BeforeNumber -Text $htmlWork -Pattern ('(?<prefix><br\s*/?\s*>\s*)' + $numToken)
$htmlWork = Inject-BeforeNumber -Text $htmlWork -Pattern ('(?<prefix><(?:font|div|span|p|td|li|pre)(?:\s[^>]*)?>\s*)' + $numToken)
$htmlWork = Inject-BeforeNumber -Text $htmlWork -Pattern ('(?<prefix>(?<=[\r\n])\s*)' + $numToken)
$html = $htmlWork

Write-Host ("Static file scan injected {0} checkbox(es)." -f $script:HfcCount)
if ($script:HfcCount -eq 0) {
  Write-Host "No static 'N. ' lines in the file (normal if Notes are built by JavaScript)." -ForegroundColor Cyan
  Write-Host "Browser script will wait for the page to generate Notes, then add ticks." -ForegroundColor Cyan
}

$configForJs = [ordered]@{
  storageNamespace = $ns
  checkboxLabel    = $label
  reportKey        = $reportKey
  redHueMax        = $redHueMax
  redMinChannel    = $redMinChannel
  numberPattern    = '^\s*(\d+)\.\s+'
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
  .hfc-done, .hfc-issue-line.hfc-done, .hfc-done-row, .hfc-done-row td {
    opacity: 0.55;
    text-decoration: line-through;
  }
  .hfc-toolbar {
    position: sticky;
    top: 0;
    z-index: 99999;
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

# IMPORTANT: no lookbehind regex literals (break older IE / some locked browsers at parse time)
$injectJs = @'
<script data-html-failure-checklist="1">
(function () {
  var CFG = __HFC_CONFIG__;

  function ensureToolbar() {
    var bar = document.getElementById("hfc-toolbar");
    if (bar) return bar;
    bar = document.createElement("div");
    bar.id = "hfc-toolbar";
    bar.className = "hfc-toolbar";
    bar.innerHTML =
      "<strong>Failure checklist</strong> " +
      "<span id=\"hfc-count\">waiting for Notes…</span> " +
      "<button type=\"button\" id=\"hfc-clear\">Clear ticks</button> " +
      "<button type=\"button\" id=\"hfc-rescan\">Rescan</button>";
    if (document.body) document.body.insertBefore(bar, document.body.firstChild);
    var clearBtn = document.getElementById("hfc-clear");
    if (clearBtn) {
      clearBtn.onclick = function () {
        if (!confirm("Clear all checklist ticks for this report?")) return;
        var boxes = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
        for (var i = 0; i < boxes.length; i++) {
          var cb = boxes[i];
          var wrap = cb.parentElement;
          var id = wrap && wrap.getAttribute("data-hfc-id");
          if (id) {
            try { localStorage.removeItem(id); } catch (e) {}
          }
          cb.checked = false;
          applyDone(wrap, false);
        }
        updateCount();
      };
    }
    var rescanBtn = document.getElementById("hfc-rescan");
    if (rescanBtn) rescanBtn.onclick = function () { scanAndAnnotate(true); };
    return bar;
  }

  function updateCount() {
    var boxes = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
    var n = 0;
    for (var i = 0; i < boxes.length; i++) if (boxes[i].checked) n++;
    var el = document.getElementById("hfc-count");
    if (el) el.textContent = n + " / " + boxes.length + " ticked";
  }

  function applyDone(wrap, on) {
    if (!wrap) return;
    var line = wrap.parentElement;
    if (line && line.classList) line.classList.toggle("hfc-done", on);
    wrap.classList.toggle("hfc-done", on);
    if (line && line.closest) {
      var tr = line.closest("tr");
      if (tr) tr.classList.toggle("hfc-done-row", on);
    }
  }

  function hash(s) {
    var h = 2166136261;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul ? Math.imul(h, 16777619) : (h * 16777619) | 0;
    }
    return (h >>> 0).toString(16);
  }

  function fullText(el) {
    return ((el && (el.innerText || el.textContent)) || "").replace(/\s+/g, " ").trim();
  }

  function isNumberedText(t) {
    if (!t) return false;
    t = String(t).replace(/\u00a0/g, " ").replace(/\s+/g, " ").trim();
    if (/^notes\s*:/i.test(t)) return false;
    return /^\d{1,3}\.\s+\S/.test(t);
  }

  function isReddish(el) {
    try {
      if (!el || el.nodeType !== 1) return false;
      if (el.tagName && el.tagName.toLowerCase() === "font") {
        var fc = (el.getAttribute("color") || "").toLowerCase();
        if (fc.indexOf("red") >= 0 || fc === "#ff0000" || fc === "#f00" || fc === "#c00" || fc === "#c00000") {
          return true;
        }
      }
      var st = (el.getAttribute("style") || "").toLowerCase().replace(/\s+/g, "");
      if (
        st.indexOf("color:red") >= 0 ||
        st.indexOf("color:#ff0000") >= 0 ||
        st.indexOf("color:#f00") >= 0 ||
        st.indexOf("color:#c00") >= 0 ||
        st.indexOf("color:#c00000") >= 0
      ) {
        return true;
      }
      var c = window.getComputedStyle(el).color || "";
      var m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
      if (!m) return false;
      var r = +m[1], g = +m[2], b = +m[3];
      var minR = CFG.redMinChannel != null ? CFG.redMinChannel : 120;
      var maxGB = CFG.redHueMax != null ? CFG.redHueMax : 80;
      return r >= minR && g <= maxGB && b <= maxGB && r > g + 20 && r > b + 20;
    } catch (e) {
      return false;
    }
  }

  function hasRedAncestor(el) {
    for (var p = el, i = 0; p && i < 10; p = p.parentElement, i++) {
      if (isReddish(p)) return true;
    }
    return false;
  }

  function wireCheckbox(wrap) {
    var cb = wrap.querySelector("input[type=checkbox]");
    if (!cb || cb.getAttribute("data-hfc-wired") === "1") return;
    cb.setAttribute("data-hfc-wired", "1");
    var id = wrap.getAttribute("data-hfc-id");
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
  }

  function addCheckboxBefore(node, textForId, index) {
    if (!node || !node.parentNode) return false;
    // Already has a checkbox just before / inside
    if (node.nodeType === 1) {
      if (node.querySelector && node.querySelector(".hfc-wrap")) {
        var existing = node.querySelector(".hfc-wrap");
        if (existing) wireCheckbox(existing);
        return false;
      }
    }
    var prev = node.previousSibling;
    if (prev && prev.nodeType === 1 && prev.classList && prev.classList.contains("hfc-wrap")) {
      wireCheckbox(prev);
      return false;
    }

    var id =
      (CFG.storageNamespace || "hfc") +
      ":" +
      (CFG.reportKey || "report") +
      ":d" +
      index +
      ":" +
      hash(String(textForId || "").slice(0, 240));

    var wrap = document.createElement("span");
    wrap.className = "hfc-wrap";
    wrap.setAttribute("data-hfc-id", id);
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.title = CFG.checkboxLabel || "Done";
    cb.setAttribute("aria-label", CFG.checkboxLabel || "Done");
    wrap.appendChild(cb);

    if (node.nodeType === 1) {
      if (node.firstChild) node.insertBefore(wrap, node.firstChild);
      else node.appendChild(wrap);
    } else {
      node.parentNode.insertBefore(wrap, node);
    }
    wireCheckbox(wrap);
    return true;
  }

  function splitTextNodeIntoLines(textNode) {
    var raw = textNode.nodeValue || "";
    if (!/\d{1,3}\.\s+/.test(raw)) return;
    // Split before "N. " occurrences (no lookbehind — IE-safe)
    var re = /(\d{1,3}\.\s+)/g;
    var parts = [];
    var last = 0;
    var m;
    var matches = [];
    while ((m = re.exec(raw)) !== null) {
      matches.push({ index: m.index, token: m[1] });
    }
    if (matches.length < 2 && !(matches.length === 1 && /[\r\n]/.test(raw))) {
      // single numbered line in this text node — leave as-is (handled elsewhere)
      if (matches.length === 1 && matches[0].index <= 2) return;
    }
    if (!matches.length) return;

    var frag = document.createDocumentFragment();
    for (var i = 0; i < matches.length; i++) {
      var start = matches[i].index;
      if (i === 0 && start > 0) {
        frag.appendChild(document.createTextNode(raw.slice(0, start)));
      }
      var end = i + 1 < matches.length ? matches[i + 1].index : raw.length;
      var chunk = raw.slice(start, end);
      // Prefer BR separation for readability
      if (i > 0) frag.appendChild(document.createElement("br"));
      var span = document.createElement("span");
      span.className = "hfc-issue-line";
      span.appendChild(document.createTextNode(chunk.replace(/^[\r\n]+/, "")));
      frag.appendChild(span);
    }
    textNode.parentNode.replaceChild(frag, textNode);
  }

  function collectTargets() {
    var targets = [];
    var seen = [];

    function pushUnique(el) {
      if (!el || el.nodeType !== 1) return;
      if (el.closest && el.closest("#hfc-toolbar, script, style, .hfc-wrap")) return;
      for (var i = 0; i < seen.length; i++) if (seen[i] === el) return;
      // Prefer deepest nodes: skip if we already have a child
      for (var j = 0; j < seen.length; j++) {
        if (el.contains && el.contains(seen[j])) return;
      }
      // Remove any ancestors already queued
      seen = seen.filter(function (s) { return !(s.contains && s.contains(el)); });
      targets = targets.filter(function (s) { return !(s.contains && s.contains(el)); });
      seen.push(el);
      targets.push(el);
    }

    // 1) Explode multi-issue text nodes under red-ish ancestors
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
    var textNodes = [];
    var tn;
    while ((tn = walker.nextNode())) textNodes.push(tn);
    for (var t = 0; t < textNodes.length; t++) {
      var node = textNodes[t];
      if (!node.parentElement) continue;
      if (!hasRedAncestor(node.parentElement) && !isReddish(node.parentElement)) continue;
      try { splitTextNodeIntoLines(node); } catch (e) {}
    }

    // 2) Element scan: reddish + numbered
    var all = document.body.getElementsByTagName("*");
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (/^(SCRIPT|STYLE|INPUT|BUTTON|TEXTAREA|SELECT|SVG|PATH)$/i.test(el.tagName)) continue;
      if (el.classList && (el.classList.contains("hfc-wrap") || el.id === "hfc-toolbar")) continue;
      var text = fullText(el);
      if (!isNumberedText(text.slice(0, 400))) continue;
      if (!(isReddish(el) || hasRedAncestor(el))) continue;

      // If a child is a better (also numbered) target, skip parent
      var childBetter = false;
      for (var c = 0; c < el.children.length; c++) {
        var ch = el.children[c];
        if (isNumberedText(fullText(ch).slice(0, 200)) && (isReddish(ch) || hasRedAncestor(ch))) {
          childBetter = true;
          break;
        }
      }
      if (childBetter) continue;
      pushUnique(el);
    }

    // 3) Fallback: any text node starting with N. under red ancestor
    if (targets.length < 2) {
      walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
      while ((tn = walker.nextNode())) {
        var v = (tn.nodeValue || "").replace(/\u00a0/g, " ").replace(/^\s+/, "");
        if (!/^\d{1,3}\.\s+\S/.test(v)) continue;
        if (!tn.parentElement || !hasRedAncestor(tn.parentElement)) continue;
        var parent = tn.parentElement;
        if (parent.classList && parent.classList.contains("hfc-issue-line")) {
          pushUnique(parent);
        } else {
          var span = document.createElement("span");
          span.className = "hfc-issue-line";
          parent.insertBefore(span, tn);
          span.appendChild(tn);
          pushUnique(span);
        }
      }
    }

    return targets;
  }

  function scanAndAnnotate(force) {
    ensureToolbar();
    // Wire any static checkboxes first
    var existing = document.querySelectorAll(".hfc-wrap");
    for (var e = 0; e < existing.length; e++) wireCheckbox(existing[e]);

    var targets = collectTargets();
    var added = 0;
    for (var i = 0; i < targets.length; i++) {
      if (addCheckboxBefore(targets[i], fullText(targets[i]), i)) added++;
    }
    updateCount();
    var countEl = document.getElementById("hfc-count");
    var boxes = document.querySelectorAll(".hfc-wrap input[type=checkbox]");
    if (!boxes.length && countEl) {
      countEl.textContent = "no red numbered Notes found yet — click Rescan after page finishes loading";
    }
    return boxes.length;
  }

  var tries = 0;
  var maxTries = 40; // ~20s of retries
  function boot() {
    ensureToolbar();
    var n = scanAndAnnotate(false);
    tries++;
    if (n < 1 && tries < maxTries) {
      setTimeout(boot, 500);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      setTimeout(boot, 100);
    });
  } else {
    setTimeout(boot, 100);
  }

  // Also watch for late JS that fills Notes
  try {
    var obs = new MutationObserver(function () {
      if (document.querySelectorAll(".hfc-wrap").length > 0) return;
      scanAndAnnotate(false);
    });
    if (document.body) {
      obs.observe(document.body, { childList: true, subtree: true, characterData: true });
      setTimeout(function () { try { obs.disconnect(); } catch (e) {} }, 30000);
    }
  } catch (e) {}

  window.addEventListener("load", function () {
    setTimeout(function () { scanAndAnnotate(false); }, 300);
  });
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
Write-Host "Open that checklist HTML in a browser."
Write-Host "You should see a black 'Failure checklist' bar at the top."
Write-Host "If ticks appear late, wait a moment or click Rescan after Notes finishes loading."

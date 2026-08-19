<#
.SYNOPSIS
  Post-process an HTML server-check report: inject persistent checkboxes on failures.

.DESCRIPTION
  Does not change your report generator. Reads HTML + config.json, injects a small
  script that finds failure nodes (CSS selectors) and adds localStorage-backed ticks.

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
$selectors = @($config.selectors)
$findRed = $true
if ($null -ne $config.findRedNumberedIssues) {
  $findRed = [bool]$config.findRedNumberedIssues
}
if ((-not $selectors -or $selectors.Count -eq 0) -and -not $findRed) {
  throw "Provide config.selectors and/or set findRedNumberedIssues to true."
}

$ns = [string]$config.storageNamespace
if (-not $ns) { $ns = "html-failure-checklist" }
$label = [string]$config.checkboxLabel
if (-not $label) { $label = "Done" }
$numberPattern = [string]$config.numberPattern
$skipIfAnnotated = $true
if ($null -ne $config.skipIfAlreadyAnnotated) {
  $skipIfAnnotated = [bool]$config.skipIfAlreadyAnnotated
}

$html = Get-Content -LiteralPath $InputHtml -Raw -Encoding UTF8

if ($skipIfAnnotated -and $html -match 'data-html-failure-checklist\s*=\s*"1"') {
  Write-Host "Already annotated — skipping (set skipIfAlreadyAnnotated false to force)."
  if ($InPlace) { return }
  if (-not $OutputHtml) {
    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $InputHtml)
    $base = [IO.Path]::GetFileNameWithoutExtension($InputHtml)
    $OutputHtml = Join-Path $dir ($base + ".checklist.html")
  }
  if ((Resolve-Path -LiteralPath $InputHtml).Path -ne (Join-Path (Split-Path $OutputHtml -Parent) (Split-Path $OutputHtml -Leaf))) {
    Copy-Item -LiteralPath $InputHtml -Destination $OutputHtml -Force
    Write-Host "Copied existing annotated file to: $OutputHtml"
  }
  return
}

# Embed config for the browser script (JSON-safe)
$redHueMax = 55
if ($null -ne $config.redHueMax) { $redHueMax = [int]$config.redHueMax }
$redMinChannel = 140
if ($null -ne $config.redMinChannel) { $redMinChannel = [int]$config.redMinChannel }

$configForJs = [ordered]@{
  selectors             = $selectors
  storageNamespace     = $ns
  checkboxLabel        = $label
  numberPattern        = $(if ($numberPattern) { $numberPattern } else { '^\s*(\d+)\.\s+' })
  reportKey            = [IO.Path]::GetFileName($InputHtml)
  findRedNumberedIssues = $findRed
  redHueMax            = $redHueMax
  redMinChannel        = $redMinChannel
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
  .hfc-done {
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

$injectJs = @'
<script data-html-failure-checklist="1">
(function () {
  var CFG = __HFC_CONFIG__;
  var SEL = (CFG.selectors || []).filter(Boolean).join(",");

  function hash(s) {
    var h = 2166136261;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16);
  }

  function ownText(el) {
    var t = "";
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3) t += n.nodeValue || "";
    }
    return t.replace(/\s+/g, " ").trim();
  }

  function fullText(el) {
    return (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
  }

  function isNumberedIssue(el) {
    var pat = CFG.numberPattern || "^\\s*(\\d+)\\.\\s+";
    var re;
    try { re = new RegExp(pat); } catch (e) { return false; }
    var t = ownText(el) || fullText(el);
    if (t.length > 800) return false;
    return re.test(t);
  }

  function isReddish(el) {
    try {
      // Explicit HTML attributes / inline styles (common in generated reports)
      if (el.tagName && el.tagName.toLowerCase() === "font") {
        var fc = (el.getAttribute("color") || "").trim().toLowerCase();
        if (fc === "red" || fc === "#ff0000" || fc === "#f00" || fc === "ff0000") return true;
      }
      var st = (el.getAttribute("style") || "").toLowerCase().replace(/\s+/g, "");
      if (
        st.indexOf("color:red") >= 0 ||
        st.indexOf("color:#ff0000") >= 0 ||
        st.indexOf("color:#f00") >= 0 ||
        st.indexOf("color:#c00") >= 0 ||
        st.indexOf("color:#cc0000") >= 0
      ) {
        return true;
      }

      var c = window.getComputedStyle(el).color || "";
      var m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
      if (!m) return false;
      var r = +m[1], g = +m[2], b = +m[3];
      var minR = CFG.redMinChannel != null ? CFG.redMinChannel : 140;
      var maxGB = CFG.redHueMax != null ? CFG.redHueMax : 55;
      return r >= minR && g <= maxGB && b <= maxGB && r > g + 30 && r > b + 30;
    } catch (e) {
      return false;
    }
  }

  function serverHintFor(el) {
    var cur = el;
    for (var depth = 0; depth < 12 && cur; depth++) {
      var p = cur.previousElementSibling;
      while (p) {
        if (/^H[1-6]$/i.test(p.tagName)) {
          return (p.innerText || "").trim().slice(0, 80) + "|";
        }
        p = p.previousElementSibling;
      }
      cur = cur.parentElement;
    }
    return "";
  }

  function issueId(el, index) {
    var text = fullText(el);
    var num = "";
    if (CFG.numberPattern) {
      try {
        var m = text.match(new RegExp(CFG.numberPattern));
        if (m && m[1]) num = "n" + m[1] + ":";
      } catch (e) {}
    }
    var serverHint = serverHintFor(el);
    return CFG.storageNamespace + ":" + (CFG.reportKey || "report") + ":" + num + hash(serverHint + text + "#" + index);
  }

  function storageKey(id) {
    return id;
  }

  function applyDoneClass(el, on) {
    el.classList.toggle("hfc-done", on);
    var tr = el.closest("tr");
    if (tr) tr.classList.toggle("hfc-done-row", on);
  }

  function collectNodes() {
    var set = [];
    var seen = typeof WeakSet !== "undefined" ? new WeakSet() : null;

    function add(el) {
      if (!el || el.nodeType !== 1) return;
      if (el.closest && el.closest(".hfc-toolbar, script, style")) return;
      if (seen) {
        if (seen.has(el)) return;
        seen.add(el);
      } else if (set.indexOf(el) >= 0) {
        return;
      }
      set.push(el);
    }

    if (SEL) {
      try {
        Array.prototype.forEach.call(document.querySelectorAll(SEL), add);
      } catch (e) {
        console.warn("html-failure-checklist selector error", e);
      }
    }

    if (CFG.findRedNumberedIssues !== false) {
      var all = document.body ? document.body.getElementsByTagName("*") : [];
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (/^(SCRIPT|STYLE|SVG|PATH|BUTTON|INPUT|TEXTAREA)$/i.test(el.tagName)) continue;
        if (!isNumberedIssue(el)) continue;
        if (!isReddish(el)) continue;
        var childHit = false;
        for (var c = 0; c < el.children.length; c++) {
          if (isNumberedIssue(el.children[c]) && isReddish(el.children[c])) {
            childHit = true;
            break;
          }
        }
        if (childHit) continue;
        add(el);
      }
    }

    return set.filter(function (el, i, arr) {
      return !arr.some(function (other, j) {
        return j !== i && other !== el && other.contains(el);
      });
    });
  }

  function annotate() {
    if (document.documentElement.getAttribute("data-hfc-ready") === "1") return;
    document.documentElement.setAttribute("data-hfc-ready", "1");

    var bar = document.createElement("div");
    bar.className = "hfc-toolbar";
    bar.innerHTML =
      "<strong>Failure checklist</strong>" +
      "<span id=\"hfc-count\"></span>" +
      "<button type=\"button\" id=\"hfc-clear\">Clear ticks (this report)</button>" +
      "<button type=\"button\" id=\"hfc-export\">Download HTML with ticks</button>";
    document.body.insertBefore(bar, document.body.firstChild);

    var nodes = collectNodes();
    if (!nodes.length) {
      bar.innerHTML +=
        " <span style=\"color:#fc6\">No numbered red failures found — adjust selectors in config.json</span>";
    }

    var checked = 0;
    nodes.forEach(function (el, index) {
      if (el.querySelector(":scope > .hfc-wrap, .hfc-wrap")) return;

      var id = issueId(el, index);
      var wrap = document.createElement("span");
      wrap.className = "hfc-wrap";
      wrap.setAttribute("data-hfc-id", id);

      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.title = (CFG.checkboxLabel || "Done") + " — " + id.slice(-12);
      cb.setAttribute("aria-label", CFG.checkboxLabel || "Done");

      var on = false;
      try {
        on = localStorage.getItem(storageKey(id)) === "1";
      } catch (e) {}
      cb.checked = on;
      applyDoneClass(el, on);
      if (on) checked++;

      cb.addEventListener("change", function () {
        try {
          if (cb.checked) localStorage.setItem(storageKey(id), "1");
          else localStorage.removeItem(storageKey(id));
        } catch (e) {}
        applyDoneClass(el, cb.checked);
        updateCount();
      });

      wrap.appendChild(cb);
      if (el.firstChild) el.insertBefore(wrap, el.firstChild);
      else el.appendChild(wrap);
    });

    function updateCount() {
      var total = nodes.length;
      var n = 0;
      nodes.forEach(function (el) {
        var cb = el.querySelector(".hfc-wrap input[type=checkbox]");
        if (cb && cb.checked) n++;
      });
      var el = document.getElementById("hfc-count");
      if (el) el.textContent = n + " / " + total + " ticked";
    }

    document.getElementById("hfc-clear").addEventListener("click", function () {
      if (!confirm("Clear all checklist ticks for this report in this browser?")) return;
      nodes.forEach(function (el) {
        var wrap = el.querySelector(".hfc-wrap");
        var id = wrap && wrap.getAttribute("data-hfc-id");
        var cb = wrap && wrap.querySelector("input");
        if (id) {
          try { localStorage.removeItem(storageKey(id)); } catch (e) {}
        }
        if (cb) cb.checked = false;
        applyDoneClass(el, false);
      });
      updateCount();
    });

    document.getElementById("hfc-export").addEventListener("click", function () {
      var clone = document.documentElement.cloneNode(true);
      clone.querySelectorAll(".hfc-wrap input[type=checkbox]").forEach(function (cb) {
        if (cb.checked) cb.setAttribute("checked", "checked");
        else cb.removeAttribute("checked");
      });
      var htmlOut = "<!DOCTYPE html>\n" + clone.outerHTML;
      var blob = new Blob([htmlOut], { type: "text/html;charset=utf-8" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = (CFG.reportKey || "report").replace(/\.html$/i, "") + ".ticked.html";
      a.click();
      URL.revokeObjectURL(a.href);
    });

    updateCount();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", annotate);
  } else {
    annotate();
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

# Mark document for skip detection (first <html> only)
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
Write-Host "Open in a browser and tick failures. Ticks persist via localStorage for this report name."

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

  function numberRe() {
    try {
      return new RegExp(CFG.numberPattern || "^\\s*(\\d+)\\.\\s+");
    } catch (e) {
      return /^\s*(\d+)\.\s+/;
    }
  }

  function textLooksNumbered(t) {
    if (!t) return false;
    t = String(t).replace(/\s+/g, " ").trim();
    if (!t || t.length > 2000) return false;
    // Skip labels like "Notes:" that sit in the same red block
    if (/^notes\s*:/i.test(t) && !numberRe().test(t)) return false;
    return numberRe().test(t);
  }

  function isNumberedIssue(el) {
    return textLooksNumbered(ownText(el) || fullText(el));
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

  function nodesText(nodes) {
    var t = "";
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.nodeType === 3) t += n.nodeValue || "";
      else if (n.nodeType === 1) t += n.innerText || n.textContent || "";
    }
    return t.replace(/\s+/g, " ").trim();
  }

  /**
   * Many reports wrap ALL failures in one red <font>/<div> with <br> between
   * lines (and often a "Notes:" line first). Split into one target per "N. …" line.
   */
  function splitMultiLineRedBlock(el) {
    if (!el || !el.childNodes || !el.childNodes.length) return null;

    // Split text nodes that contain multiple numbered lines (newline-separated)
    var kids = Array.prototype.slice.call(el.childNodes);
    for (var ki = 0; ki < kids.length; ki++) {
      var node = kids[ki];
      if (node.nodeType !== 3) continue;
      var raw = node.nodeValue || "";
      if (!/\n/.test(raw)) continue;
      var lines = raw.split(/\r?\n/);
      var numberedLines = 0;
      for (var lj = 0; lj < lines.length; lj++) {
        if (textLooksNumbered(lines[lj])) numberedLines++;
      }
      if (numberedLines < 2) continue;
      var frag = document.createDocumentFragment();
      for (var li = 0; li < lines.length; li++) {
        if (li > 0) frag.appendChild(document.createElement("br"));
        frag.appendChild(document.createTextNode(lines[li]));
      }
      el.replaceChild(frag, node);
    }

    // Group child nodes by <br>
    var groups = [];
    var cur = [];
    function flush() {
      if (cur.length) {
        groups.push(cur);
        cur = [];
      }
    }
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 1 && /^br$/i.test(n.tagName)) {
        flush();
      } else {
        cur.push(n);
      }
    }
    flush();

    var numberedGroups = groups.filter(function (g) {
      return textLooksNumbered(nodesText(g));
    });
    if (numberedGroups.length < 2) return null;

    var targets = [];
    for (var g = 0; g < numberedGroups.length; g++) {
      var nodes = numberedGroups[g];
      if (!nodes.length) continue;
      // Already wrapped?
      if (
        nodes.length === 1 &&
        nodes[0].nodeType === 1 &&
        nodes[0].classList &&
        nodes[0].classList.contains("hfc-issue-line")
      ) {
        targets.push(nodes[0]);
        continue;
      }
      var span = document.createElement("span");
      span.className = "hfc-issue-line";
      el.insertBefore(span, nodes[0]);
      for (var ni = 0; ni < nodes.length; ni++) {
        span.appendChild(nodes[ni]);
      }
      targets.push(span);
    }
    return targets.length ? targets : null;
  }

  function expandTargets(el) {
    var split = splitMultiLineRedBlock(el);
    if (split && split.length) return split;
    // Single red node: only keep if it looks like a numbered issue
    if (isNumberedIssue(el) || textLooksNumbered(fullText(el).slice(0, 200))) {
      // If fullText has many numbered lines but we couldn't split (odd markup),
      // still avoid treating "Notes:" alone as an issue
      var ft = fullText(el);
      var hits = ft.match(/(?:^|\s)(\d+)\.\s+/g);
      if (hits && hits.length >= 2) {
        // Last resort: don't annotate the giant parent (one tick for all)
        return [];
      }
      if (textLooksNumbered(ownText(el) || ft)) return [el];
    }
    return [];
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

    function addExpanded(el) {
      var parts = expandTargets(el);
      for (var i = 0; i < parts.length; i++) add(parts[i]);
    }

    if (SEL) {
      try {
        Array.prototype.forEach.call(document.querySelectorAll(SEL), addExpanded);
      } catch (e) {
        console.warn("html-failure-checklist selector error", e);
      }
    }

    if (CFG.findRedNumberedIssues !== false) {
      var all = document.body ? document.body.getElementsByTagName("*") : [];
      // Snapshot first — splitting mutates the DOM
      var snapshot = [];
      for (var i = 0; i < all.length; i++) snapshot.push(all[i]);
      for (var si = 0; si < snapshot.length; si++) {
        var el = snapshot[si];
        if (!el || !el.parentNode) continue;
        if (/^(SCRIPT|STYLE|SVG|PATH|BUTTON|INPUT|TEXTAREA)$/i.test(el.tagName)) continue;
        if (el.classList && el.classList.contains("hfc-issue-line")) {
          add(el);
          continue;
        }
        if (!isReddish(el)) continue;
        // Prefer splitting multi-line red parents; skip if a child is also a red multi-line block
        var childHit = false;
        for (var c = 0; c < el.children.length; c++) {
          var ch = el.children[c];
          if (ch.classList && ch.classList.contains("hfc-issue-line")) {
            childHit = true;
            break;
          }
          if (isNumberedIssue(ch) && isReddish(ch)) {
            childHit = true;
            break;
          }
        }
        if (childHit) continue;
        addExpanded(el);
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

# HTML Failure Checklist Annotator

Standalone post-processor for PowerShell (or other) **HTML output files** that list
server checks and highlight failures. It does **not** replace your existing script —
you run it **after** the report is generated.

## What it does

1. Reads an HTML report.
2. Finds each “highlighted failure” using CSS selectors you configure.
3. Injects a **checkbox** before each match.
4. Writes a new HTML file (or overwrites if you choose) with a small script so ticks
   **persist in the browser** (`localStorage`) when you reopen the same file path/name.

## Important: the report is HTML markup (not plain text)

When you copy failures into Word/email they look like:

`1. The drive D: has less than 25 percent free disk space`

In the **raw .html file** those lines are wrapped in tags, for example:

```html
<font color="red">1. The drive D: has less than 25 percent free disk space</font><br>
```

or

```html
<span style="color:#FF0000">1. …</span>
```

The annotator runs **in the browser against that HTML**, so it targets the tagged red numbered lines — not your plain-text paste.

### If ticks don’t appear

Do **not** send work hostnames. From the raw file (Notepad / View Source), copy **one** failure line **including the tags**, with secrets replaced, e.g.:

```html
<font color="red">1. [REDACTED ISSUE TEXT]</font><br>
```

That single redacted line is enough to lock the selectors.

## Quick start

```powershell
cd path\to\html-failure-checklist

# Copy config and adjust selectors if needed
Copy-Item config.example.json config.json

# Annotate a report (output next to input by default)
.\Annotate-HtmlFailures.ps1 -InputHtml 'C:\Reports\scan.html'

# Custom output path
.\Annotate-HtmlFailures.ps1 -InputHtml '.\sample-redacted.html' -OutputHtml '.\sample-redacted.checklist.html'
```

Open the **checklist** HTML in a browser. Tick boxes; refresh — ticks should remain
(same browser, same file name / storage key).

## Config (`config.json`)

| Key | Meaning |
|-----|---------|
| `selectors` | CSS selectors for failure nodes (tried in order; all matches annotated) |
| `numberPattern` | Optional regex to detect “numbered issue” text (for IDs) |
| `checkboxLabel` | Accessible label prefix |
| `storageNamespace` | Prefix for `localStorage` keys |

## Updating when your PowerShell HTML changes

Only update **`config.json` selectors** (and maybe `numberPattern`).  
You usually **do not** need to change `Annotate-HtmlFailures.ps1` unless the report
stops being HTML or failures are no longer in the DOM as elements.

## Privacy

- Keep real reports off shared repos.
- Use `sample-redacted.html` as a shape reference only.
- This tool only rewrites local files you point it at.

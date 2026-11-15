#!/bin/sh
# Build public/index.html: a list of every HTML/PDF page, newest first.
#
# Each row records its owner (the top-level folder) and the page's <title>, so the
# page can filter by person and fuzzy-search on file name + title without
# downloading any of the pages.
#
# Runs in the Pages workflow (Ubuntu) and on macOS for local testing.
# Usage: .ci/build_index.sh [output-file]   (default: public/index.html)
set -eu

out="${1:-public/index.html}"
mkdir -p "$(dirname "$out")"

# Escape text for use inside HTML text or a double-quoted attribute.
esc() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Print the <title> text of an HTML file (empty if none). Reads only the first 64 KB,
# since some pages are many MB of inlined data.
title_of() {
  head -c 65536 "$1" | tr '\n\r\t' '   ' | awk '
    {
      low = tolower($0)
      i = index(low, "<title")
      if (!i) exit
      rest = substr($0, i)
      j = index(rest, ">")
      if (!j) exit
      rest = substr(rest, j + 1)
      k = index(tolower(rest), "</title")
      if (!k) exit
      t = substr(rest, 1, k - 1)
      gsub(/  +/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
      print t
      exit
    }'
}

# Format a unix timestamp in Pacific time (GNU/busybox `date -d`, else BSD `date -r`).
fmt_date() {
  TZ='America/Los_Angeles' date -d "@$1" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
    || TZ='America/Los_Angeles' date -r "$1" '+%Y-%m-%d %H:%M %Z'
}

rows="$(mktemp)"
trap 'rm -f "$rows"' EXIT

find . \( -name '*.html' -o -name '*.pdf' \) -not -path './public/*' -not -path './.git/*' -not -path './.github/*' \
  | while IFS= read -r f; do
      ts="$(git log -1 --format='%at' -- "$f")"
      # Files never committed have no date; they would not be deployed anyway.
      [ -n "$ts" ] || continue
      rel="${f#./}"
      name="${rel##*/}"
      case "$rel" in
        */*) dir="${rel%/*}"; user="${rel%%/*}" ;;
        *) dir=""; user="(root)" ;;
      esac
      ext="${name##*.}"
      title=""
      [ "$ext" = "html" ] && title="$(title_of "$f")"

      label="$(esc "$name")"
      [ -n "$dir" ] && label="<span class=\"path\">$(esc "$dir")/</span>$label"
      title_html=""
      [ -n "$title" ] && title_html="<div class=\"title\">$(esc "$title")</div>"

      printf '%s\t<tr data-user="%s"><td><a href="%s">%s</a>%s</td><td><span class="type">%s</span></td><td class="date">%s</td></tr>\n' \
        "$ts" "$(esc "$user")" "$(esc "$rel")" "$label" "$title_html" "$ext" "$(fmt_date "$ts")"
    done > "$rows"

{
  cat <<'HEADER'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pages</title>
<style>
  :root { --fg: #222; --muted: #666; --faint: #999; --line: #eee; --line2: #ddd; --link: #1a73e8; --bg: #fff; --mark: #fff3b0; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #ddd; --muted: #aaa; --faint: #888; --line: #2a2a2a; --line2: #3a3a3a; --link: #8ab4f8; --bg: #121212; --mark: #5a4a00; }
  }
  body { font-family: sans-serif; max-width: 900px; margin: 40px auto; padding: 0 16px; color: var(--fg); background: var(--bg); }
  a { text-decoration: none; color: var(--link); }
  a:hover { text-decoration: underline; }
  .controls { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 8px; }
  .controls select, .controls input { font: inherit; padding: 6px 8px; border: 1px solid var(--line2); border-radius: 4px; background: var(--bg); color: var(--fg); }
  .controls input { flex: 1; min-width: 200px; }
  .count { color: var(--faint); font-size: 0.9em; margin-bottom: 12px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { border-bottom: 2px solid var(--line2); color: var(--muted); }
  .path { color: var(--muted); font-size: 0.9em; }
  .title { color: var(--muted); font-size: 0.85em; margin-top: 2px; }
  .date { color: var(--faint); white-space: nowrap; }
  .type { font-size: 0.8em; color: var(--faint); border: 1px solid var(--line2); border-radius: 3px; padding: 1px 5px; }
  mark { background: var(--mark); color: inherit; }
</style>
</head>
<body>
<h1>Pages</h1>
<div class="controls">
  <select id="user" aria-label="Show pages from"><option value="">Everyone</option></select>
  <input id="q" type="search" placeholder="Fuzzy search file name or title  ( / to focus )" autocomplete="off">
</div>
<div class="count" id="count"></div>
<table>
<thead><tr><th>File</th><th>Type</th><th>Last Modified</th></tr></thead>
<tbody id="rows">
HEADER
  sort -rn "$rows" | cut -f2-
  cat <<'FOOTER'
</tbody>
</table>
<script>
(function () {
  var KEY = "pages-user";
  var tbody = document.getElementById("rows");
  var sel = document.getElementById("user");
  var q = document.getElementById("q");
  var count = document.getElementById("count");

  // Read each row once: owner, the visible label/title, and the text we search.
  var items = Array.prototype.map.call(tbody.rows, function (tr, i) {
    var a = tr.querySelector("a");
    var t = tr.querySelector(".title");
    var path = a.getAttribute("href");
    var title = t ? t.textContent : "";
    return {
      tr: tr, order: i, user: tr.dataset.user, a: a, t: t,
      aHtml: a.innerHTML, tText: title,
      hay: (path + " " + title).toLowerCase(),
      pathLen: path.length
    };
  });

  // Fill the dropdown with each person and how many pages they have.
  var counts = {};
  items.forEach(function (it) { counts[it.user] = (counts[it.user] || 0) + 1; });
  Object.keys(counts).sort().forEach(function (u) {
    var o = document.createElement("option");
    o.value = u; o.textContent = u + " (" + counts[u] + ")";
    sel.appendChild(o);
  });

  function load() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function save(v) { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY); } catch (e) {} }

  // ?user=terryk&q=foo in the URL wins; otherwise use the last person picked here.
  var params = new URLSearchParams(location.search);
  var startUser = params.has("user") ? params.get("user") : load();
  if (startUser && counts[startUser]) sel.value = startUser;
  if (params.has("q")) q.value = params.get("q");

  // Score one query word against the text. Plain substring matches beat scattered
  // letters; earlier and tighter matches score higher. Returns null when the
  // letters do not all appear in order.
  function scoreWord(w, hay) {
    var at = hay.indexOf(w);
    if (at >= 0) {
      var wordStart = at === 0 || /[^a-z0-9]/.test(hay[at - 1]);
      return { score: 1000 + (wordStart ? 200 : 0) - at, hits: range(at, w.length) };
    }
    var hits = [], pos = 0, gaps = 0;
    for (var i = 0; i < w.length; i++) {
      var p = hay.indexOf(w[i], pos);
      if (p < 0) return null;
      if (hits.length) gaps += p - pos;
      hits.push(p); pos = p + 1;
    }
    return { score: 500 - gaps * 5 - hits[0], hits: hits };
  }
  function range(s, n) { var r = []; for (var i = 0; i < n; i++) r.push(s + i); return r; }

  function match(words, it) {
    var total = 0, hits = [];
    for (var i = 0; i < words.length; i++) {
      var m = scoreWord(words[i], it.hay);
      if (!m) return null;
      total += m.score; hits = hits.concat(m.hits);
    }
    return { score: total - it.pathLen * 0.01, hits: hits };
  }

  // Wrap matched characters of `text` (which starts at `offset` in hay) in <mark>.
  function mark(text, offset, set) {
    var out = "", open = false;
    for (var i = 0; i < text.length; i++) {
      var on = set[offset + i];
      if (on && !open) { out += "<mark>"; open = true; }
      if (!on && open) { out += "</mark>"; open = false; }
      out += text[i].replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; });
    }
    return open ? out + "</mark>" : out;
  }

  function render() {
    var user = sel.value;
    var words = q.value.toLowerCase().split(/\s+/).filter(Boolean);
    var shown = [];
    items.forEach(function (it) {
      it.a.innerHTML = it.aHtml;
      if (it.t) it.t.textContent = it.tText;
      if (user && it.user !== user) { it.tr.hidden = true; return; }
      var m = words.length ? match(words, it) : { score: 0, hits: [] };
      it.tr.hidden = !m;
      if (!m) return;
      it.score = m.score;
      if (words.length) {
        var set = {}; m.hits.forEach(function (h) { set[h] = true; });
        var path = it.a.getAttribute("href");
        var cut = path.lastIndexOf("/") + 1;
        it.a.innerHTML = (cut ? '<span class="path">' + mark(path.slice(0, cut), 0, set) + "</span>" : "") +
          mark(path.slice(cut), cut, set);
        if (it.t) it.t.innerHTML = mark(it.tText, path.length + 1, set);
      }
      shown.push(it);
    });
    // Best match first while searching; newest first otherwise.
    shown.sort(words.length ? function (x, y) { return y.score - x.score || x.order - y.order; }
                            : function (x, y) { return x.order - y.order; });
    shown.forEach(function (it) { tbody.appendChild(it.tr); });
    count.textContent = shown.length + " of " + items.length + " pages" + (user ? " from " + user : "");

    var p = new URLSearchParams();
    if (user) p.set("user", user);
    if (q.value) p.set("q", q.value);
    var s = p.toString();
    history.replaceState(null, "", s ? "?" + s : location.pathname);
  }

  sel.addEventListener("change", function () { save(sel.value); render(); });
  q.addEventListener("input", render);
  document.addEventListener("keydown", function (e) {
    if (e.key === "/" && document.activeElement !== q) { e.preventDefault(); q.focus(); }
    if (e.key === "Escape" && document.activeElement === q) { q.value = ""; render(); }
  });
  render();
})();
</script>
</body>
</html>
FOOTER
} > "$out"

const tokenStart = "\uE000MKM";
const tokenEnd = "\uE001";

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function safeMarkdownURL(value) {
  try {
    const url = new URL(String(value).trim());
    return ["http:", "https:", "mailto:"].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

function renderInlineMarkdown(value) {
  const tokens = [];
  const preserve = (html) => {
    const token = `${tokenStart}${tokens.length}${tokenEnd}`;
    tokens.push(html);
    return token;
  };

  let source = String(value);
  source = source.replace(/`([^`\n]+)`/g, (_match, code) => (
    preserve(`<code>${escapeHTML(code)}</code>`)
  ));
  source = source.replace(
    /\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g,
    (_match, label, destination) => {
      const url = safeMarkdownURL(destination);
      if (!url) return `${label} (${destination})`;
      return preserve(
        `<a href="${escapeHTML(url)}" target="_blank" rel="noopener noreferrer">${escapeHTML(label)}</a>`
      );
    }
  );

  let html = escapeHTML(source)
    .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
    .replace(/__([^_\n]+)__/g, "<strong>$1</strong>")
    .replace(/~~([^~\n]+)~~/g, "<del>$1</del>")
    .replace(/\*([^*\n]+)\*/g, "<em>$1</em>");

  html = html.replace(
    new RegExp(`${tokenStart}(\\d+)${tokenEnd}`, "g"),
    (_match, index) => tokens[Number(index)] ?? ""
  );
  return html;
}

function isHorizontalRule(line) {
  return /^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/.test(line);
}

function isBlockStart(lines, index) {
  const line = lines[index] ?? "";
  if (/^\s*$/.test(line)) return true;
  if (/^\s{0,3}```/.test(line)) return true;
  if (/^\s{0,3}#{1,6}\s+/.test(line)) return true;
  if (/^\s*>\s?/.test(line)) return true;
  if (/^\s*[-+*]\s+/.test(line)) return true;
  if (/^\s*\d+[.)]\s+/.test(line)) return true;
  return isHorizontalRule(line);
}

/**
 * Render the Markdown subset commonly emitted by local language models.
 * Raw HTML is intentionally unsupported: all model output is escaped first.
 */
export function renderMarkdown(value) {
  const source = String(value ?? "").replace(/\r\n?/g, "\n");
  if (!source) return "";

  const lines = source.split("\n");
  const output = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (/^\s*$/.test(line)) {
      index += 1;
      continue;
    }

    const fence = line.match(/^\s{0,3}```\s*([\w+-]*)\s*$/);
    if (fence) {
      const codeLines = [];
      index += 1;
      while (index < lines.length && !/^\s{0,3}```\s*$/.test(lines[index])) {
        codeLines.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      const language = fence[1]
        ? ` class="language-${escapeHTML(fence[1])}"`
        : "";
      output.push(`<pre><code${language}>${escapeHTML(codeLines.join("\n"))}</code></pre>`);
      continue;
    }

    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$/);
    if (heading) {
      const level = heading[1].length;
      output.push(`<h${level}>${renderInlineMarkdown(heading[2])}</h${level}>`);
      index += 1;
      continue;
    }

    if (isHorizontalRule(line)) {
      output.push("<hr>");
      index += 1;
      continue;
    }

    if (/^\s*>\s?/.test(line)) {
      const quoteLines = [];
      while (index < lines.length && /^\s*>\s?/.test(lines[index])) {
        quoteLines.push(lines[index].replace(/^\s*>\s?/, ""));
        index += 1;
      }
      output.push(`<blockquote>${renderMarkdown(quoteLines.join("\n"))}</blockquote>`);
      continue;
    }

    if (/^\s*[-+*]\s+/.test(line)) {
      const items = [];
      while (index < lines.length) {
        const item = lines[index].match(/^\s*[-+*]\s+(.+)$/);
        if (!item) break;
        items.push(`<li>${renderInlineMarkdown(item[1])}</li>`);
        index += 1;
      }
      output.push(`<ul>${items.join("")}</ul>`);
      continue;
    }

    if (/^\s*\d+[.)]\s+/.test(line)) {
      const items = [];
      while (index < lines.length) {
        const item = lines[index].match(/^\s*\d+[.)]\s+(.+)$/);
        if (!item) break;
        items.push(`<li>${renderInlineMarkdown(item[1])}</li>`);
        index += 1;
      }
      output.push(`<ol>${items.join("")}</ol>`);
      continue;
    }

    const paragraph = [];
    while (index < lines.length && (paragraph.length === 0 || !isBlockStart(lines, index))) {
      paragraph.push(lines[index]);
      index += 1;
    }
    output.push(`<p>${paragraph.map(renderInlineMarkdown).join("<br>")}</p>`);
  }

  return output.join("");
}

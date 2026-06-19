// Markdown.jsx — a tiny block-level markdown renderer (no heavy dep). Handles
// headings (#, ##, ###), paragraphs, **bold**, unordered/ordered lists, and
// [links](url). Inline parsing is regex-split so no dangerouslySetInnerHTML.
import { Fragment } from 'react';

// Inline: split on **bold** and [text](href), keep the rest as plain text.
function inline(text) {
  const parts = [];
  const re = /(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)]+\))/g;
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) parts.push(text.slice(last, m.index));
    if (m[1]) parts.push(<strong key={m.index}>{m[1].slice(2, -2)}</strong>);
    else {
      const label = m[2].slice(1, m[2].indexOf(']'));
      const href = m[2].slice(m[2].indexOf('(') + 1, -1);
      const ext = /^https?:/.test(href);
      parts.push(
        <a key={m.index} href={href} {...(ext ? { target: '_blank', rel: 'noreferrer' } : {})}
          className="font-bold text-ocean-teal underline">{label}</a>,
      );
    }
    last = re.lastIndex;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts.map((p, i) => <Fragment key={i}>{p}</Fragment>);
}

/** Render a markdown string into styled ocean-palette blocks. */
export default function Markdown({ children, className = '' }) {
  const lines = (children || '').replace(/\r\n/g, '\n').split('\n');
  const blocks = [];
  let list = null;
  const flush = () => { if (list) { blocks.push(list); list = null; } };
  lines.forEach((raw, i) => {
    const line = raw.trim();
    if (!line) { flush(); return; }
    const h = /^(#{1,3})\s+(.*)$/.exec(line);
    const ul = /^[-*]\s+(.*)$/.exec(line);
    const ol = /^\d+\.\s+(.*)$/.exec(line);
    if (h) {
      flush();
      const cls = ['text-3xl mt-8', 'text-2xl mt-7', 'text-xl mt-6'][h[1].length - 1];
      const Tag = `h${h[1].length}`;
      blocks.push(<Tag key={i} className={`${cls} font-black text-ocean`}>{inline(h[2])}</Tag>);
    } else if (ul || ol) {
      const item = <li key={i} className="ml-1">{inline((ul || ol)[1])}</li>;
      const tag = ol ? 'ol' : 'ul';
      if (list && list.type === tag) list = { ...list, props: { ...list.props, children: [...list.props.children, item] } };
      else { flush(); const Tag = tag; list = <Tag key={`l${i}`} className={`${ol ? 'list-decimal' : 'list-disc'} space-y-1 pl-6 text-ocean-mid`}>{[item]}</Tag>; }
    } else {
      flush();
      blocks.push(<p key={i} className="leading-8 text-ocean-mid">{inline(line)}</p>);
    }
  });
  flush();
  return <div className={`space-y-4 ${className}`}>{blocks}</div>;
}

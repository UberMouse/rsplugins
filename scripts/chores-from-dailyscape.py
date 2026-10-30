#!/usr/bin/env python3
"""Generate the Chore Tracker's chore list from dailyscape's dailyscape.js.

Usage: python3 -I scripts/chores-from-dailyscape.py DAILYSCAPE_JS OUT_LUA

Source: https://github.com/dailyscape/dailyscape.github.io (MIT), file dailyscape.js, pinned
at commit f6a503cb3480ede1dfe1fe9d17867999939598c9. To regenerate, fetch that commit's file
into a fresh directory outside the repo and run the script on it:

    d=$(mktemp -d)
    curl -sSL -o "$d/dailyscape.js" https://raw.githubusercontent.com/dailyscape/dailyscape.github.io/f6a503cb3480ede1dfe1fe9d17867999939598c9/dailyscape.js
    python3 -I scripts/chores-from-dailyscape.py "$d/dailyscape.js" plugins/chore-tracker/data/chores.lua

dailyscape.js is downloaded code, so it is never executed: a small tokenizer reads only the
object-literal subset its five chore tables use (quoted keys, bare identifier and integer
keys, single- and double-quoted strings with escapes, // and /* */ comments, trailing commas,
numbers, true and false, nested arrays and objects). Anything else, a duplicate key, or a
chore field of the wrong type stops the script with a non-zero exit and a message naming the
table and key, and no output is written.

Each chore becomes { id, name, period, shop, url, desc, links }:
- tables rs3daily, rs3dailyshops, rs3weekly, rs3weeklyshops and rs3monthly, in that order,
  and keys in file order; shop is true for the two *shops tables;
- desc: each <a href="...">text</a> becomes its text, and its href is added to links; every
  <br> (any case, or <br/>, <br />) becomes <br>, which ui.Text renders; other tags are
  stripped; &amp; &lt; &gt; &quot; &#39; become & < > " ', &nbsp; becomes a plain space (the
  game font may not draw U+00A0), and any other entity is an error;
- http:// in a url or link becomes https:// (all four such links at the pinned commit serve
  https), and any url that then doesn't start with https:// is an error;
- every other field (inputs, outputs, short...) is dropped.

The output depends only on the input, so running the script twice gives identical bytes. It is
laid out the way stylua formats it, so the gate's stylua --check passes without reformatting.
"""

import re
import sys

SOURCE_URL = "https://github.com/dailyscape/dailyscape.github.io"
COMMIT = "f6a503cb3480ede1dfe1fe9d17867999939598c9"
RAW_URL = (
    f"https://raw.githubusercontent.com/dailyscape/dailyscape.github.io/{COMMIT}/dailyscape.js"
)

# (table name in dailyscape.js, period, shop)
TABLES = (
    ("rs3daily", "daily", False),
    ("rs3dailyshops", "daily", True),
    ("rs3weekly", "weekly", False),
    ("rs3weeklyshops", "weekly", True),
    ("rs3monthly", "monthly", False),
)

# dailyscape's LICENSE at the pinned commit, reproduced in the generated file as MIT requires.
LICENSE = """\
MIT License

Copyright (c) 2021 607ch00

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

COLUMN_WIDTH = 100  # stylua.toml


class Refused(Exception):
    """The input isn't what the script understands; the message says where."""


# ---------------------------------------------------------------------------------------------
# Tokenizer and parser for the object-literal subset.

PUNCT = set("{}[]:,;")
IDENT = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
NUMBER = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "b": "\b",
    "f": "\f",
    "v": "\v",
    "0": "\0",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "/": "/",
}


class Parser:
    """Reads one JS value at a time from `text`, starting at `pos`."""

    def __init__(self, text, pos, where):
        self.text = text
        self.pos = pos
        self.where = where  # [table, key, ...] for error messages

    def fail(self, msg):
        line = self.text.count("\n", 0, self.pos) + 1
        raise Refused(f"{' > '.join(self.where)} (line {line}): {msg}")

    def skip(self):
        """Skip whitespace and comments."""
        text = self.text
        while self.pos < len(text):
            c = text[self.pos]
            if c.isspace():
                self.pos += 1
            elif text.startswith("//", self.pos):
                end = text.find("\n", self.pos)
                self.pos = len(text) if end < 0 else end
            elif text.startswith("/*", self.pos):
                end = text.find("*/", self.pos + 2)
                if end < 0:
                    self.fail("unterminated /* comment")
                self.pos = end + 2
            else:
                return

    def peek(self):
        self.skip()
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.fail(f"expected {ch!r}, found {self.peek() or 'end of file'!r}")
        self.pos += 1

    def string(self):
        quote = self.text[self.pos]
        self.pos += 1
        out = []
        text = self.text
        while True:
            if self.pos >= len(text) or text[self.pos] == "\n":
                self.fail("unterminated string")
            c = text[self.pos]
            if c == quote:
                self.pos += 1
                return "".join(out)
            if c == "\\":
                e = text[self.pos + 1 : self.pos + 2]
                if e in SIMPLE_ESCAPES:
                    out.append(SIMPLE_ESCAPES[e])
                    self.pos += 2
                elif e == "u" and (cp := self.hex4(self.pos + 2)) is not None:
                    self.pos += 6
                    # JS strings are UTF-16, so a character outside the BMP is written as a
                    # high+low surrogate pair; join it. A lone surrogate has no UTF-8 encoding.
                    if 0xD800 <= cp <= 0xDBFF:
                        low = self.hex4(self.pos + 2) if text.startswith("\\u", self.pos) else None
                        if low is None or not 0xDC00 <= low <= 0xDFFF:
                            self.fail(f"lone surrogate escape \\u{cp:04x}")
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                        self.pos += 6
                    elif 0xDC00 <= cp <= 0xDFFF:
                        self.fail(f"lone surrogate escape \\u{cp:04x}")
                    out.append(chr(cp))
                else:
                    self.fail(f"unsupported string escape \\{e}")
            else:
                out.append(c)
                self.pos += 1

    def hex4(self, at):
        """The code unit of the four hex digits at `at`, or None if they aren't there."""
        digits = self.text[at : at + 4]
        return int(digits, 16) if re.fullmatch(r"[0-9a-fA-F]{4}", digits) else None

    def value(self):
        c = self.peek()
        if c == "{":
            return self.obj()
        if c == "[":
            return self.array()
        if c in ('"', "'"):
            return self.string()
        m = NUMBER.match(self.text, self.pos)
        if m:
            self.pos = m.end()
            s = m.group()
            return float(s) if any(ch in s for ch in ".eE") else int(s)
        m = IDENT.match(self.text, self.pos)
        if m and m.group() in ("true", "false"):
            self.pos = m.end()
            return m.group() == "true"
        self.fail(f"unsupported value starting {self.text[self.pos : self.pos + 20]!r}")

    def key(self):
        c = self.peek()
        if c in ('"', "'"):
            return self.string()
        # Bare keys can be numbers too (outputs_max maps item ids to quantities).
        m = IDENT.match(self.text, self.pos) or re.compile(r"\d+").match(self.text, self.pos)
        if not m:
            self.fail(f"unsupported key starting {self.text[self.pos : self.pos + 20]!r}")
        self.pos = m.end()
        return m.group()

    def obj(self):
        """An object as a dict, which keeps file order."""
        self.expect("{")
        pairs = {}
        while self.peek() != "}":
            k = self.key()
            if k in pairs:
                self.fail(f"duplicate key {k!r}")
            self.where.append(k)
            self.expect(":")
            pairs[k] = self.value()
            self.where.pop()
            if self.peek() != ",":
                break
            self.pos += 1
        self.expect("}")
        return pairs

    def array(self):
        self.expect("[")
        items = []
        while self.peek() != "]":
            self.where.append(f"[{len(items) + 1}]")
            items.append(self.value())
            self.where.pop()
            if self.peek() != ",":
                break
            self.pos += 1
        self.expect("]")
        return items


def read_table(text, name):
    """The (key, value) pairs of `var <name> = { ... };`."""
    starts = list(re.finditer(rf"\b(?:var|let|const)\s+{name}\s*=", text))
    if len(starts) != 1:
        raise Refused(f"{name}: expected one declaration, found {len(starts)}")
    p = Parser(text, starts[0].end(), [name])
    if p.peek() != "{":
        p.fail("is not an object literal")
    pairs = p.obj()
    p.expect(";")
    return list(pairs.items())


# ---------------------------------------------------------------------------------------------
# Turning dailyscape's HTML desc into plain text.

ANCHOR = re.compile(r"<a\b([^>]*)>(.*?)</a\s*>", re.IGNORECASE | re.DOTALL)
HREF = re.compile(r"""\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.IGNORECASE)
BR = re.compile(r"<br\s*/?\s*>", re.IGNORECASE)
TAG = re.compile(r"</?[A-Za-z][^>]*>")
TAG_START = re.compile(r"<[A-Za-z/!]")
ENTITY = re.compile(r"&(#?\w+);")
ENTITIES = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "#39": "'", "nbsp": " "}
BR_MARK = "\0"  # stands in for <br> while other tags are stripped and entities decoded


def decode(s, where):
    def one(m):
        if m.group(1) not in ENTITIES:
            raise Refused(f"{where}: unsupported entity {m.group()}")
        return ENTITIES[m.group(1)]

    # One pass, so "&amp;lt;" becomes "&lt;" and not "<".
    return ENTITY.sub(one, s)


def https(url, where):
    if url.startswith("http://"):
        url = "https://" + url[len("http://") :]
    if not url.startswith("https://"):
        raise Refused(f"{where}: url {url!r} is not http(s)")
    return url


def convert_desc(html, where):
    """(plain-text desc keeping only <br>, [link hrefs in order])."""
    if BR_MARK in html:
        raise Refused(f"{where}: desc contains a NUL character")
    links = []

    def anchor(m):
        href = HREF.search(m.group(1))
        if not href:
            raise Refused(f"{where}: <a> without an href")
        links.append(https(decode(href.group(1) or href.group(2) or "", where), where))
        return m.group(2)

    text = ANCHOR.sub(anchor, html)
    text = BR.sub(BR_MARK, text)
    text = TAG.sub("", text)
    text = decode(text, where)
    # Decoding can turn &lt;b&gt; back into a tag. A bare < ("run < 37 minutes") is plain text.
    if TAG_START.search(text):
        raise Refused(f"{where}: desc has a tag left after stripping: {text!r}")
    return text.replace(BR_MARK, "<br>"), links


# ---------------------------------------------------------------------------------------------
# Building the chores and writing Lua.


def chores_from(text):
    chores, ids = [], set()
    for name, period, shop in TABLES:
        for key, fields in read_table(text, name):
            where = f"{name} > {key}"
            if not isinstance(fields, dict):
                raise Refused(f"{where}: is not an object")
            if key in ids:
                raise Refused(f"{where}: id already used by an earlier table")
            ids.add(key)
            f = fields
            for field in ("task", "url"):
                if not isinstance(f.get(field), str) or f[field] == "":
                    raise Refused(f"{where}: {field} is missing or not a string")
            desc = f.get("desc", "")
            if not isinstance(desc, str):
                raise Refused(f"{where}: desc is not a string")
            desc, links = convert_desc(desc, where)
            chores.append(
                {
                    "id": key,
                    "name": f["task"],
                    "period": period,
                    "shop": shop,
                    "url": https(f["url"], where),
                    "desc": desc,
                    "links": links,
                }
            )
    return chores


def lua_string(s):
    """A Lua string literal, quoted the way stylua's AutoPreferDouble would leave it."""
    quote = "'" if '"' in s and "'" not in s else '"'
    out = []
    for ch in s:
        if ch == "\\" or ch == quote:
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append(f"\\{ord(ch):03d}")
        else:
            out.append(ch)
    return quote + "".join(out) + quote


def render(chores):
    lines = [
        "-- Generated by scripts/chores-from-dailyscape.py, do not edit.",
        "--",
        f"-- Source: {SOURCE_URL}, dailyscape.js at commit",
        f"-- {COMMIT}. To regenerate:",
        "--   d=$(mktemp -d)",
        f'--   curl -sSL -o "$d/dailyscape.js" {RAW_URL}',
        '--   python3 -I scripts/chores-from-dailyscape.py "$d/dailyscape.js" plugins/chore-tracker/data/chores.lua',
        "--",
        "-- The chore list is from dailyscape, used under its MIT licence:",
        "--",
    ]
    lines += [("-- " + l).rstrip() for l in LICENSE.splitlines()]
    lines += ["", "---@type Chore[]", "return {"]
    for c in chores:
        lines.append("    {")
        for field in ("id", "name", "period"):
            lines.append(f"        {field} = {lua_string(c[field])},")
        lines.append(f"        shop = {'true' if c['shop'] else 'false'},")
        for field in ("url", "desc"):
            lines.append(f"        {field} = {lua_string(c[field])},")
        links = [lua_string(l) for l in c["links"]]
        one_line = (
            "        links = { " + ", ".join(links) + " }," if links else "        links = {},"
        )
        # stylua keeps a table on one line only while it fits.
        if len(one_line) <= COLUMN_WIDTH:
            lines.append(one_line)
        else:
            lines.append("        links = {")
            lines += [f"            {l}," for l in links]
            lines.append("        },")
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    _, src, out = argv
    with open(src, encoding="utf-8") as f:
        text = f.read()
    try:
        lua = render(chores_from(text))
    except Refused as e:
        print(f"chores-from-dailyscape: {e}", file=sys.stderr)
        return 1
    # Encode before opening, so a failure can't leave a truncated output file behind.
    data = lua.encode("utf-8")
    with open(out, "wb") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

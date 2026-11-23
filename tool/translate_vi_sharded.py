#!/usr/bin/env python3
"""One-off Vietnamese ARB drafting tool. Review generated text before PR."""
import concurrent.futures
import os
import json
import re
import threading
import time
from collections import Counter
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "lib/l10n/app_en.arb"
DST = ROOT / "lib/l10n/app_vi.arb"
SOURCE = json.loads(SRC.read_text(encoding="utf-8"))
OVERRIDES = json.loads((ROOT / "tool/vi_review_overrides.json").read_text(encoding="utf-8"))
_tls = threading.local()
_lock = threading.Lock()
_cache = {}
_failures = []
_stats = Counter()
ICU_HEAD = re.compile(r"^\s*([A-Za-z_]\w*)\s*,\s*(plural|select|selectordinal)\s*,", re.S)
OPTION = re.compile(r"\s*(=?[\w.-]+)\s*\{", re.S)
PROTECTED = re.compile(
    r"(\{[A-Za-z_]\w*\}|https?://[^\s<>'\"]+|"
    r"(?<!\w)<[A-Za-z][\w.-]*>|"
    r"\x60[^\x60]+\x60|"
    r"(?<!\w)%(?:\d+\$)?[sd])"
)
ONLY_NONWORDS = re.compile(r"^[\s\W\d_]*$", re.U)


def session():
    if not hasattr(_tls, "session"):
        _tls.session = requests.Session()
        _tls.session.headers.update({
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36"
        })
    return _tls.session


def remote_translate(text):
    for attempt in range(9):
        try:
            r = session().get(
                "https://translate.googleapis.com/translate_a/single",
                params={"client": "gtx", "sl": "en", "tl": "vi", "dt": "t", "q": text},
                timeout=35,
            )
            r.raise_for_status()
            result = r.json()
            translated = "".join(str(part[0] or "") for part in result[0])
            if translated:
                return translated
            raise ValueError("Empty translation response")
        except Exception as e:
            if attempt == 8:
                raise RuntimeError(f"Translation service error: {e}") from e
            time.sleep(min(20, 0.8 * (1.8 ** attempt)))


def translate_plain(text):
    if not text or ONLY_NONWORDS.fullmatch(text):
        return text
    with _lock:
        if text in _cache:
            return _cache[text]

    protected = []
    def mask(m):
        ident = len(protected)
        protected.append(m.group(0))
        return f"ZXQKEEP{ident}QXZ"

    masked = PROTECTED.sub(mask, text)
    if ONLY_NONWORDS.fullmatch(masked):
        return text

    try:
        translated = remote_translate(masked)
        for index, original in enumerate(protected):
            pat = re.compile(r"ZXQ\s*KEEP\s*" + str(index) + r"\s*QXZ", re.I)
            translated, count = pat.subn(lambda _: original, translated)
            if count != 1:
                raise ValueError(f"Missing placeholder {index}: {translated!r}")
        actual = Counter(re.findall(r"\{[A-Za-z_]\w*\}", translated))
        expected = Counter(re.findall(r"\{[A-Za-z_]\w*\}", text))
        if actual != expected:
            raise ValueError(f"Placeholder mismatch: {text!r} / {translated!r}")
        left = len(text) - len(text.lstrip())
        right = len(text) - len(text.rstrip())
        translated = text[:left] + translated.strip() + (text[len(text) - right:] if right else "")
        with _lock:
            _cache[text] = translated
            _stats["translated"] += 1
        return translated
    except Exception as e:
        with _lock:
            _failures.append((text[:150], str(e)[:200]))
        return text


def matched_closing(s, start):
    depth = 0
    for j in range(start, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    raise ValueError(f"Unbalanced braces: {s[:120]!r}")


def build_icu(inside):
    header = ICU_HEAD.match(inside)
    if header is None:
        return None
    var, kind = header.group(1, 2)
    tail = inside[header.end():]
    offset = ""
    prefix = re.match(r"\s*(offset:\d+)\s*", tail)
    if prefix:
        offset = prefix.group(1) + " "
        tail = tail[prefix.end():]
    options = []
    pos = 0
    while pos < len(tail):
        m = OPTION.match(tail, pos)
        if not m:
            if tail[pos:].strip():
                raise ValueError(f"Cannot parse ICU option: {tail[pos:pos+80]!r}")
            break
        key = m.group(1)
        open_at = m.end() - 1
        end = matched_closing(tail, open_at)
        child = translate_message(tail[open_at + 1:end])
        options.append(f"{key}{{{child}}}")
        pos = end + 1
    if not options or not any(x.startswith("other{") for x in options):
        raise ValueError(f"ICU missing other branch: {inside[:100]!r}")
    return "{" + var + ", " + kind + ", " + offset + " ".join(options) + "}"


def translate_message(raw):
    pieces = []
    current = []
    i = 0
    while i < len(raw):
        if raw[i] == "{":
            try:
                end = matched_closing(raw, i)
            except ValueError:
                current.append(raw[i])
                i += 1
                continue
            content = raw[i + 1:end]
            if ICU_HEAD.match(content):
                if current:
                    pieces.append(("text", "".join(current)))
                    current = []
                pieces.append(("icu", build_icu(content)))
                i = end + 1
                continue
        current.append(raw[i])
        i += 1
    if current:
        pieces.append(("text", "".join(current)))
    return "".join(chunk if kind == "icu" else translate_plain(chunk) for kind, chunk in pieces)


def run_item(item):
    key, value = item
    if key in OVERRIDES:
        return key, OVERRIDES[key]
    if not isinstance(value, str):
        raise TypeError(f"{key}: expected string")
    try:
        return key, translate_message(value)
    except Exception as e:
        with _lock:
            _failures.append((key, str(e)[:200]))
        return key, value


def main():
    items = [(key, val) for key, val in SOURCE.items() if not key.startswith("@")]
    index = int(os.environ["SHARD_INDEX"])
    total = int(os.environ["SHARD_COUNT"])
    items = [item for i, item in enumerate(items) if i % total == index]
    out = {"@@locale": "vi"}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for i, (key, translation) in enumerate(pool.map(run_item, items), 1):
            out[key] = translation
            if i % 200 == 0:
                print(f"Translated {i}/{len(items)}; cached={len(_cache)}; errors={len(_failures)}", flush=True)
    DST.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Source keys: {len(items)}; target keys: {len(out)-1}; failures: {len(_failures)}")
    for err in _failures[:50]:
        print("FAILED:", err, flush=True)
    if _failures:
        raise SystemExit(f"{len(_failures)} translation errors: review logs and rerun")


if __name__ == "__main__":
    main()

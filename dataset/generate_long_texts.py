#!/usr/bin/env python3
"""
Generate random long texts (1000+ words each) and write to a file.
Downloads from Project Gutenberg or falls back to random word generation.
"""

from __future__ import annotations

import argparse
import os
import re
import random
import urllib.request
import urllib.error

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEXTS_FILE = os.path.join(SCRIPT_DIR, "1000_long.txt")


# Project Gutenberg plain text URLs (public domain books)
GUTENBERG_BOOKS = [
    "https://www.gutenberg.org/cache/epub/1342/pg1342.txt",   # Pride and Prejudice
    "https://www.gutenberg.org/cache/epub/11/pg11.txt",       # Alice in Wonderland
    "https://www.gutenberg.org/cache/epub/1661/pg1661.txt",   # Sherlock Holmes
    "https://www.gutenberg.org/cache/epub/84/pg84.txt",       # Frankenstein
    "https://www.gutenberg.org/cache/epub/98/pg98.txt",       # Tale of Two Cities
]

# Fallback: common words for random generation (first 500 of common English words)
COMMON_WORDS = """
the be to of and a in that have i it for not on with he as you do at this
but his by from they we say her she or an will my one all would there their
what so up out if about who get which go me when make can like time no just
him know take people into year your good some could them see other than then
now look only come its over think also back after use two how our work first
well way even new want because any these give day most us is been has had
did may made off must through before between under again where much should
never last right found still next old any many such here same another while
always those both each few more during before yourself down own same much
very through both between under again where until without before during
""".split()


def download_text(url, timeout=30):
    """Download text from URL, return raw string or None on failure."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Python-Script/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, Exception) as e:
        print(f"Download failed ({url}): {e}")
        return None


def strip_gutenberg_boilerplate(text):
    """Remove Gutenberg header/footer."""
    start_markers = [
        "*** START OF",
        "*END*THE SMALL PRINT",
        "Produced by",
    ]
    end_markers = [
        "*** END OF",
        "***END OF",
        "End of Project Gutenberg",
        "End of the Project Gutenberg",
    ]
    lower = text.lower()
    start = 0
    for m in start_markers:
        i = text.find(m)
        if i != -1:
            # Find next newline to skip the marker line
            nl = text.find("\n", i)
            start = nl + 1 if nl != -1 else i + len(m)
            break

    end = len(text)
    for m in end_markers:
        i = lower.find(m.lower())
        if i != -1:
            end = i
            break

    return text[start:end].strip()


def split_into_chunks(text, min_words=1000):
    """Split text into chunks of at least min_words."""
    words = text.split()
    chunks = []
    for i in range(0, len(words), min_words):
        chunk = words[i : i + min_words]
        if len(chunk) >= min_words:
            chunks.append(" ".join(chunk))
    return chunks


def generate_random_text(min_words=100, word_list=None):
    """Generate random text from word list."""
    words = word_list or COMMON_WORDS
    selected = random.choices(words, k=min_words)
    result = []
    for i, w in enumerate(selected):
        if result and i % 20 == 19:  # Period every ~20 words
            result.append(".")
        result.append(w)
    result.append(".")
    text = " ".join(result)
    return re.sub(r"\s*\.\s*", ". ", text).strip()


def normalize_text_line(text: str) -> str:
    return " ".join(text.split())


def load_texts_from_file(filepath: str, min_words: int = 1) -> list[str]:
    """Load one text per line from a file."""
    texts: list[str] = []
    with open(filepath, encoding="utf-8") as f:
        for line in f:
            line = normalize_text_line(line.strip())
            if line and len(line.split()) >= min_words:
                texts.append(line)
    return texts


def normalize_document(text: str, min_words: int) -> str:
    """Return a single-line document with exactly min_words words."""
    words = text.split()
    if len(words) >= min_words:
        return " ".join(words[:min_words])

    if not words:
        return generate_random_text(min_words)

    while len(words) < min_words:
        words.extend(text.split())
    return " ".join(words[:min_words])


def load_document_source_pool(
    min_words: int = 1000,
    use_download: bool = True,
    texts_file: str | None = DEFAULT_TEXTS_FILE,
) -> list[str]:
    """
    Load benchmark documents from real-word sources.

    Priority:
      1) texts_file (default: dataset/1000_long.txt)
      2) Project Gutenberg downloads
      3) random text built from COMMON_WORDS
    """
    source_texts: list[str] = []

    if texts_file and os.path.isfile(texts_file):
        source_texts = load_texts_from_file(texts_file, min_words=1)
        if source_texts:
            print(f"Loaded {len(source_texts)} text(s) from {texts_file}")

    if not source_texts and use_download:
        print("Attempting to download from Project Gutenberg...")
        source_texts = fetch_long_texts_from_gutenberg(10, min_words)

    if not source_texts:
        print("Generating fallback text from common English words...")
        source_texts = [generate_random_text(min_words)]

    return [normalize_document(text, min_words) for text in source_texts]


def fetch_long_texts_from_gutenberg(num_texts, min_words=1000):
    """Download books, split into chunks, return list of texts."""
    all_chunks = []
    for url in GUTENBERG_BOOKS:
        if len(all_chunks) >= num_texts:
            break
        raw = download_text(url)
        if not raw:
            continue
        text = strip_gutenberg_boilerplate(raw)
        chunks = split_into_chunks(text, min_words)
        all_chunks.extend(chunks)
        print(f"  Fetched {len(chunks)} chunk(s) from {url.split('/')[-1]}")

    return all_chunks[:num_texts]


def main():
    parser = argparse.ArgumentParser(
        description="Generate random long texts (1000+ words each) and write to a file."
    )
    parser.add_argument(
        "filename",
        help="Output file path",
    )
    parser.add_argument(
        "-n", "--num",
        type=int,
        required=True,
        help="Number of texts to generate",
    )
    parser.add_argument(
        "--min-words",
        type=int,
        default=1000,
        help="Minimum word count per text (default: 1000)",
    )
    parser.add_argument(
        "--no-download",
        action="store_true",
        help="Skip download; use random word generation only",
    )
    args = parser.parse_args()

    texts = load_document_source_pool(
        min_words=args.min_words,
        use_download=not args.no_download,
        texts_file=None if args.no_download else DEFAULT_TEXTS_FILE,
    )

    while len(texts) < args.num:
        texts.extend(
            load_document_source_pool(
                min_words=args.min_words,
                use_download=not args.no_download,
                texts_file=None,
            )
        )

    texts = texts[: args.num]

    # Write to file: one text per line (escape newlines within text)
    with open(args.filename, "w", encoding="utf-8") as f:
        for text in texts:
            f.write(normalize_text_line(text) + "\n")

    print(f"Wrote {len(texts)} texts to {args.filename}")
    word_counts = [len(t.split()) for t in texts]
    print(f"Word count range: {min(word_counts)} - {max(word_counts)}")


if __name__ == "__main__":
    main()

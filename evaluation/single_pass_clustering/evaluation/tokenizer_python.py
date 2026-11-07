"""Python counterpart of PostgreSQL's to_tsvector('english', txt), used by the
external Python pipeline of the comparison (COMPARISON.md).

Steps: lowercase, split on non-alphanumeric characters, drop PostgreSQL's English
stop words (tsearch_data/english.stop), stem with the Snowball English stemmer
(PyStemmer, the same algorithm as PostgreSQL's english_stem).

On the synthetic datasets it yields exactly the same terms and counts as
to_tsvector (see check_tokenizer.py). On real text it differs for tokens that
PostgreSQL's parser treats specially (URLs, e-mail addresses, hyphenated words,
decimal numbers, abbreviations such as U.S.).
"""
import re
import subprocess
from collections import Counter
from pathlib import Path

import Stemmer  # pip install PyStemmer


def _default_stopfile() -> Path:
    share = subprocess.run(["pg_config", "--sharedir"], capture_output=True,
                           text=True, check=True).stdout.strip()
    return Path(share) / "tsearch_data" / "english.stop"


class Tokenizer:
    _split = re.compile(r"[^0-9a-z]+")

    def __init__(self, stopfile=None):
        self.stop = set(Path(stopfile or _default_stopfile()).read_text().split())
        self.stem = Stemmer.Stemmer("english").stemWord

    def __call__(self, text: str) -> Counter:
        return Counter(self.stem(w) for w in self._split.split(text.lower())
                       if w and w not in self.stop)

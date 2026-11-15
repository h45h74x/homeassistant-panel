"""Pairing passphrase: 5 words from a filtered EFF list, hyphenated."""
import hmac
import re
import secrets
from pathlib import Path

_WORDS = (Path(__file__).parent / "wordlist.txt").read_text().split()


def generate() -> str:
    return "-".join(secrets.choice(_WORDS) for _ in range(5))


def normalize(raw: str) -> str:
    return re.sub(r"[\s-]+", "", raw.lower())


def matches(stored: str, presented: str) -> bool:
    return hmac.compare_digest(normalize(stored).encode(), normalize(presented).encode())

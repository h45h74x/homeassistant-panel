"""Pairing passphrase: 5 words from a filtered EFF list, hyphenated."""
import hmac
import re
import secrets
from pathlib import Path

_WORDS = (Path(__file__).parent / "wordlist.txt").read_text().split()


def generate() -> str:
    return "-".join(secrets.choice(_WORDS) for _ in range(5))


def normalize(raw: str) -> str:
    return re.sub(r"[ \t\r\n-]+", "", raw.lower())  # exactly the contract's set


def matches(stored: str, presented: str) -> bool:
    if not isinstance(stored, str) or not isinstance(presented, str):
        return False
    a = normalize(stored).encode("utf-8", "surrogateescape")  # raw header bytes arrive as lone surrogates
    b = normalize(presented).encode("utf-8", "surrogateescape")
    return bool(a) and hmac.compare_digest(a, b)

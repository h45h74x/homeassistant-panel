import json
import re
from pathlib import Path

from custom_components.panel_control import passphrase

ROOT = Path(__file__).parent.parent
WORDS = (ROOT / "custom_components/panel_control/wordlist.txt").read_text().split()


def test_wordlist():
    assert len(WORDS) == 674
    assert all(re.fullmatch("[a-z]{3,7}", w) for w in WORDS)
    assert len(set(WORDS)) == 674
    assert len({w[:3] for w in WORDS}) == 674


def test_generate():
    p = passphrase.generate()
    parts = p.split("-")
    assert len(parts) == 5 and all(x in WORDS for x in parts)


def test_normalize_vectors():
    vectors = json.loads((ROOT / "contract/fixtures/passphrase-normalization.json").read_text())
    for v in vectors:
        assert passphrase.normalize(v["input"]) == v["normalized"]


def test_matches():
    stored = "maple-orbit-tiger-quilt-ember"
    assert passphrase.matches(stored, " MAPLE orbit-Tiger quilt ember\n")
    assert not passphrase.matches(stored, "maple-orbit-tiger-quilt")
    assert not passphrase.matches(stored, "")

import json
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
FIX = ROOT / "fixtures"
ORDER = {
    "hello-response": ["contract", "heartbeat_s", "poll_wait_s", "config"],
    "config": ["config_rev", "enabled", "interval_s"],
    "state-response": ["config_rev"],
    "commands": ["config_rev", "commands"],
}
CMD_ORDER = ["id", "capability", "value", "issued_at"]
VALUE_RE = re.compile(r'"value":(null|true|false|-?[0-9]+(\.[0-9]+)?)[,}]')


def agent_fixtures():
    out = []
    for prefix in ORDER:
        out += sorted((FIX / "valid").glob(prefix + "-*.json"))
    return out


def commands_fixtures():
    return sorted((FIX / "valid").glob("commands-*.json"))


def prefix_of(f):
    return max((p for p in ORDER if f.name.startswith(p + "-")), key=len)


@pytest.mark.parametrize("f", agent_fixtures(), ids=lambda f: f.name)
def test_agent_parsed_fixtures_are_compact(f):
    text = f.read_text()
    assert text.endswith("\n") and "\n" not in text[:-1]
    data = json.loads(text)
    assert list(data) == ORDER[prefix_of(f)]
    assert json.dumps(data, separators=(",", ":")) == text[:-1]
    for c in data.get("commands", []):
        assert list(c) == CMD_ORDER


def readme_extractor():
    m = re.search(r"## Parsing commands without jq\n.*?```sh\n(.*?)\n```", (ROOT / "README.md").read_text(), re.S)
    assert m
    return m.group(1)


@pytest.mark.parametrize("f", commands_fixtures(), ids=lambda f: f.name)
def test_commands_sed_extractable(f):
    out = subprocess.run(["sh", "-c", readme_extractor()], input=f.read_text(), capture_output=True, text=True, check=True).stdout
    want = ""
    for c in json.loads(f.read_text())["commands"]:
        v = c["value"]
        v = "null" if v is None else str(v).lower() if isinstance(v, bool) else str(v)
        want += "%s %s %s\n" % (c["id"], c["capability"], v)
    assert out == want


def test_command_values_numeric_form():
    assert commands_fixtures()
    for f in commands_fixtures():
        assert VALUE_RE.search(f.read_text()) or '"commands":[]' in f.read_text()
    bad = sorted((FIX / "wire-invalid").glob("commands-*.json"))
    assert [f.name for f in bad] == ["commands-exponent.json", "commands-nan.json"]
    for f in bad:
        assert not VALUE_RE.search(f.read_text()), f.name


def test_passphrase_vectors():
    vectors = json.loads((FIX / "passphrase-normalization.json").read_text())
    assert len(vectors) >= 8
    for v in vectors:
        assert re.fullmatch(r"[a-z]+(-[a-z]+){4}", v["normalized"]), v
        assert re.sub(r"[\s-]", "", v["input"]).lower() == v["normalized"].replace("-", ""), v

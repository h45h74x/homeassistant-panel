import json
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).parent.parent
SCHEMAS = {p.name[: -len(".schema.json")]: json.loads(p.read_text()) for p in (ROOT / "schema").glob("*.schema.json")}
CATALOG_IDS = [c["id"] for c in json.loads((ROOT / "catalog.json").read_text())["capabilities"]]


# fixtures are named commands-*, the schema is commands-response
ALIASES = {"commands": "commands-response"}


def schema_for(fixture):
    # longest schema name that is a prefix of the file name followed by "-"
    names = [n for n in SCHEMAS if fixture.name.startswith(n + "-")]
    names += [ALIASES[a] for a in ALIASES if fixture.name.startswith(a + "-") and not fixture.name.startswith(ALIASES[a] + "-")]
    assert names, fixture.name
    return SCHEMAS[max(names, key=len)]


def fixtures(kind):
    return sorted((ROOT / "fixtures" / kind).glob("*.json"))


def walk_enums(node):
    if isinstance(node, dict):
        if "enum" in node and set(node["enum"]) >= {"brightness"}:
            yield node["enum"]
        for v in node.values():
            yield from walk_enums(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk_enums(v)


def test_have_fixtures():
    assert len(SCHEMAS) == 7 and fixtures("valid") and fixtures("invalid")


@pytest.mark.parametrize("f", fixtures("valid"), ids=lambda f: f.name)
def test_valid(f):
    jsonschema.validate(json.loads(f.read_text()), schema_for(f))


@pytest.mark.parametrize("f", fixtures("invalid"), ids=lambda f: f.name)
def test_invalid(f):
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(json.loads(f.read_text()), schema_for(f))


def test_schema_ids_match_catalog():
    found = {}
    for name, schema in SCHEMAS.items():
        for enum in walk_enums(schema):
            assert enum == CATALOG_IDS, name
            found[name] = found.get(name, 0) + 1
    assert found == {"hello": 1, "hello-response": 2, "config": 2, "state": 1, "commands-response": 1}


def test_hello_capability_ids_unique():
    for f in fixtures("valid"):
        if f.name.startswith("hello-") and "response" not in f.name:
            ids = [c["id"] for c in json.loads(f.read_text())["capabilities"]]
            assert len(ids) == len(set(ids)), f.name

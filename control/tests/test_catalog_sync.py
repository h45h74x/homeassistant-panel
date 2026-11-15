from pathlib import Path

ROOT = Path(__file__).parent.parent


def test_catalog_in_sync():
    a = (ROOT / "custom_components/panel_control/catalog.json").read_bytes()
    assert a == (ROOT / "contract/catalog.json").read_bytes()

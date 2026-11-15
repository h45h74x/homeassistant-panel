DOMAIN = "panel_control"


def hello_signal(device_id: str) -> str:
    """Sent after a hello was applied: platforms add entities, entities refresh. The availability tick reuses the state signal."""
    return f"{DOMAIN}_hello_{device_id}"

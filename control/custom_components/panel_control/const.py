DOMAIN = "panel_control"


def hello_signal(device_id: str) -> str:
    """Sent after a hello was applied and by the availability tick: platforms add entities, entities refresh."""
    return f"{DOMAIN}_hello_{device_id}"

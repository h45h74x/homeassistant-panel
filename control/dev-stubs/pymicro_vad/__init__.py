"""DEV-ONLY stub. Real pymicro-vad has no wheel for Python 3.14 and needs g++ to build. HA imports it only
for its voice assistant (assist_pipeline), which the interim dev HA never uses. Never ships in the integration."""


class MicroVad:
    def __init__(self, *args, **kwargs):
        raise RuntimeError("pymicro_vad is a dev stub (voice assistant is unavailable in the dev HA)")

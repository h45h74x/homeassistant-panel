"""Test client replaying the contract fixtures; success bodies are checked against the schemas."""
import json
from pathlib import Path

import jsonschema

CONTRACT = Path(__file__).resolve().parents[1] / "contract"


def _schema(name):
    return json.loads((CONTRACT / "schema" / f"{name}.schema.json").read_text())


class FakeDevice:
    def __init__(self, client, base: str, token: str):
        self.client, self.base, self.token = client, base, token

    def _headers(self):
        return {"Authorization": f"Bearer {self.token}"}

    async def _finish(self, resp, schema):
        raw = await resp.text()
        data = json.loads(raw)
        if resp.status == 200:
            jsonschema.validate(data, _schema(schema))
        else:
            jsonschema.validate(data, _schema("error"))
        return resp.status, data, raw

    async def hello(self, fixture="hello-ey21"):
        if isinstance(fixture, str):
            fixture = json.loads((CONTRACT / "fixtures" / "valid" / f"{fixture}.json").read_text())
        resp = await self.client.post(f"{self.base}/hello", json=fixture, headers=self._headers())
        return await self._finish(resp, "hello-response")

    async def state(self, values, acks=(), time=1763200000, body=None):
        body = body if body is not None else {"time": time, "values": values, "acks": list(acks)}
        resp = await self.client.post(f"{self.base}/state", json=body, headers=self._headers())
        return await self._finish(resp, "state-response")

    async def commands(self, wait=0):
        resp = await self.client.get(f"{self.base}/commands", params={"wait": wait},
                                     headers=self._headers())
        return await self._finish(resp, "commands-response")

    async def config(self):
        resp = await self.client.get(f"{self.base}/config", headers=self._headers())
        return await self._finish(resp, "config")

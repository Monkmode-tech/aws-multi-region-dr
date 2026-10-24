import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock

HANDLER = Path(__file__).resolve().parent.parent / "app" / "handler.py"
spec = importlib.util.spec_from_file_location("dr_handler", HANDLER)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeTable:
    def __init__(self, fail=False):
        self.items = {}
        self.fail = fail

    def get_item(self, Key):
        if self.fail:
            raise RuntimeError("dynamodb unavailable")
        item = self.items.get(Key["id"])
        return {"Item": item} if item else {}

    def put_item(self, Item):
        self.items[Item["id"]] = Item

    def scan(self, Limit):
        return {"Items": list(self.items.values())[:Limit]}


def call(route, body=None, path_id=None, tbl=None, raw_body=None):
    event = {"routeKey": route}
    if body is not None:
        event["body"] = json.dumps(body)
    if raw_body is not None:
        event["body"] = raw_body
    if path_id is not None:
        event["pathParameters"] = {"id": path_id}
    res = mod.handler(event, tbl=tbl if tbl is not None else FakeTable())
    return res["statusCode"], json.loads(res["body"]), res["headers"]


class Health(unittest.TestCase):
    def test_healthy_region(self):
        status, body, headers = call("GET /health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertIn("x-served-by-region", headers)

    def test_table_failure_makes_region_unhealthy(self):
        status, body, _ = call("GET /health", tbl=FakeTable(fail=True))
        self.assertEqual(status, 503)
        self.assertEqual(body["status"], "degraded")

    def test_fault_injection(self):
        with mock.patch.dict(os.environ, {"FAULT_MODE": "fail"}):
            status, body, _ = call("GET /health")
        self.assertEqual(status, 503)
        self.assertEqual(body["status"], "fault-injected")


class Items(unittest.TestCase):
    def test_create_list_and_get(self):
        tbl = FakeTable()
        status, created, _ = call("POST /items", {"note": "first", "seq": 1}, tbl=tbl)
        self.assertEqual(status, 201)
        self.assertEqual(created["seq"], 1)
        self.assertIn("written_region", created)

        status, listed, _ = call("GET /items", tbl=tbl)
        self.assertEqual(status, 200)
        self.assertEqual(listed["count"], 1)

        status, fetched, _ = call("GET /items/{id}", path_id=created["id"], tbl=tbl)
        self.assertEqual(status, 200)
        self.assertEqual(fetched["note"], "first")

    def test_list_hides_health_sentinel(self):
        tbl = FakeTable()
        tbl.items[mod.SENTINEL_ID] = {"id": mod.SENTINEL_ID}
        _, listed, _ = call("GET /items", tbl=tbl)
        self.assertEqual(listed["count"], 0)

    def test_validation(self):
        self.assertEqual(call("POST /items", raw_body="not json")[0], 400)
        self.assertEqual(call("POST /items", raw_body="[1, 2]")[0], 400)
        self.assertEqual(call("POST /items", {"note": "x" * 281})[0], 400)
        self.assertEqual(call("POST /items", {"note": "ok", "seq": -1})[0], 400)
        self.assertEqual(call("POST /items", {"note": "ok", "seq": True})[0], 400)
        self.assertEqual(call("GET /items/{id}", path_id="../etc/passwd")[0], 400)

    def test_missing_item_and_unknown_route(self):
        self.assertEqual(call("GET /items/{id}", path_id="00000000-0000-0000-0000-000000000000")[0], 404)
        self.assertEqual(call("DELETE /items")[0], 404)

    def test_unexpected_errors_do_not_leak_details(self):
        status, body, _ = call("GET /items/{id}", path_id="00000000-0000-0000-0000-000000000000",
                               tbl=FakeTable(fail=True))
        self.assertEqual(status, 500)
        self.assertEqual(body["error"], "internal error")
        self.assertNotIn("dynamodb", json.dumps(body))


if __name__ == "__main__":
    unittest.main()

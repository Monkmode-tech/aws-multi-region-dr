"""Multi-region "orders ledger" API, deployed identically in both regions.

Routes (API Gateway HTTP API, payload format 2.0):
    GET  /health        200 {"status": "ok", "region": ...} - used by Route 53
    GET  /items         latest items (any region wrote them)
    POST /items         {"note": "...", "seq": 1}  -> 201 with the stored item
    GET  /items/{id}    one item, or 404

Every item records the region that wrote it, so after a failover you can see
which writes came from where - and the game-day script uses `seq` to measure
data loss (RPO).

Fault injection for game days: setting FAULT_MODE=fail makes /health return 503,
simulating an unhealthy region without touching anything else.
"""

from __future__ import annotations

import json
import logging
import os
import re
import uuid
from datetime import UTC, datetime
from typing import Any

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "unknown")
SENTINEL_ID = "__health__"
ID_PATTERN = re.compile(r"^[0-9a-f-]{36}$")
MAX_NOTE = 280

_table = None


def table():
    """DynamoDB table in *this* region (global-table replica), created lazily."""
    global _table
    if _table is None:
        import boto3  # imported lazily so unit tests run without the AWS SDK

        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "x-served-by-region": REGION,
            "cache-control": "no-store",
        },
        "body": json.dumps(body, default=str),
    }


def health(tbl: Any) -> dict[str, Any]:
    if os.environ.get("FAULT_MODE") == "fail":
        return response(503, {"status": "fault-injected", "region": REGION})
    try:
        # A real dependency check: the regional table must answer a read.
        tbl.get_item(Key={"id": SENTINEL_ID})
    except Exception as exc:  # noqa: BLE001 - any failure means unhealthy
        LOG.error(json.dumps({"msg": "health check failed", "error": str(exc)}))
        return response(503, {"status": "degraded", "region": REGION})
    return response(200, {"status": "ok", "region": REGION})


def parse_body(event: dict[str, Any]) -> dict[str, Any] | None:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return body if isinstance(body, dict) else None


def create_item(tbl: Any, event: dict[str, Any]) -> dict[str, Any]:
    body = parse_body(event)
    if body is None:
        return response(400, {"error": "body must be a JSON object"})
    note = body.get("note", "")
    seq = body.get("seq")
    if not isinstance(note, str) or len(note) > MAX_NOTE:
        return response(400, {"error": f"note must be a string of at most {MAX_NOTE} characters"})
    if seq is not None and (not isinstance(seq, int) or isinstance(seq, bool) or seq < 0):
        return response(400, {"error": "seq must be a non-negative integer"})

    item = {
        "id": str(uuid.uuid4()),
        "note": note,
        "written_region": REGION,
        "created_at": datetime.now(UTC).isoformat(timespec="milliseconds"),
    }
    if seq is not None:
        item["seq"] = seq
    tbl.put_item(Item=item)
    return response(201, item)


def list_items(tbl: Any) -> dict[str, Any]:
    # Demo-sized table: a bounded scan is fine. A real ledger would query a GSI.
    result = tbl.scan(Limit=50)
    items = [i for i in result.get("Items", []) if i.get("id") != SENTINEL_ID]
    items.sort(key=lambda i: i.get("created_at", ""), reverse=True)
    return response(200, {"region": REGION, "count": len(items), "items": items[:20]})


def get_item(tbl: Any, item_id: str) -> dict[str, Any]:
    if not ID_PATTERN.match(item_id):
        return response(400, {"error": "invalid id"})
    found = tbl.get_item(Key={"id": item_id}).get("Item")
    if not found:
        return response(404, {"error": "not found"})
    return response(200, found)


def handler(event: dict[str, Any], context: Any = None, tbl: Any = None) -> dict[str, Any]:
    tbl = tbl if tbl is not None else table()
    route = event.get("routeKey", "")
    try:
        if route == "GET /health":
            return health(tbl)
        if route == "POST /items":
            return create_item(tbl, event)
        if route == "GET /items":
            return list_items(tbl)
        if route == "GET /items/{id}":
            return get_item(tbl, (event.get("pathParameters") or {}).get("id", ""))
        return response(404, {"error": "not found"})
    except Exception as exc:  # noqa: BLE001 - never leak internals to clients
        LOG.error(json.dumps({"msg": "unhandled error", "route": route, "error": str(exc)}))
        return response(500, {"error": "internal error", "region": REGION})

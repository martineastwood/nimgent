#!/usr/bin/env python3
import json
import sys


subscriptions = set()
tasks = {}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def result(request_id, fields=None, result_type="complete"):
    value = {"resultType": result_type}
    if fields:
        value.update(fields)
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


def error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def dispatch(request):
    method = request["method"]
    request_id = request.get("id")
    params = request.get("params", {})
    if method == "server/discover":
        result(request_id, {
            "supportedVersions": ["2026-07-28"],
            "_meta": {"io.modelcontextprotocol/serverInfo": {
                "name": "fixture", "version": "1.0"}},
            "capabilities": {"tools": {"listChanged": True},
                             "resources": {"listChanged": True,
                                            "subscribe": True},
                             "prompts": {"listChanged": True},
                             "completions": {},
                             "extensions": {"io.modelcontextprotocol/tasks": {}}},
        })
    elif method == "tools/list":
        page = params.get("cursor")
        tools = [{"name": "echo", "description": "Echo", "title": "Echo",
                  "inputSchema": {"type": "object"}},
                 {"name": "ask", "description": "Ask", "inputSchema": {"type": "object"}},
                 {"name": "progress", "description": "Progress", "inputSchema": {"type": "object"}},
                 {"name": "change", "description": "Change", "inputSchema": {"type": "object"}},
                 {"name": "task", "description": "Task", "inputSchema": {"type": "object"}}]
        index = int(page) if page else 0
        fields = {"tools": tools[index:index + 2]}
        if index + 2 < len(tools):
            fields["nextCursor"] = str(index + 2)
        result(request_id, fields)
    elif method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments", {})
        if name == "ask" and "inputResponses" not in params:
            result(request_id, {
                "inputRequests": {"question": {"method": "elicitation/create",
                                                  "params": {"mode": "form",
                                                             "message": "Continue?",
                                                             "requestedSchema": {
                                                                 "type": "object"}}}},
                "requestState": "fixture-state"
            }, "input_required")
        elif name == "ask":
            answer = params["inputResponses"]["question"]["content"].get("answer", "")
            result(request_id, {"content": [{"type": "text", "text": answer}]})
        elif name == "progress":
            token = params.get("_meta", {}).get("progressToken")
            if token is not None:
                send({"jsonrpc": "2.0", "method": "notifications/progress",
                      "params": {"progressToken": token, "progress": 1,
                                  "total": 1, "message": "done"}})
            result(request_id, {"content": [{"type": "text", "text": "ok"}]})
        elif name == "change":
            for subscription_id in subscriptions:
                send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                      "params": {"_meta": {
                          "io.modelcontextprotocol/subscriptionId": subscription_id}}})
            result(request_id, {"content": [{"type": "text", "text": "changed"}]})
        elif name == "task":
            task_id = "fixture-task"
            tasks[task_id] = {"taskId": task_id, "status": "working",
                              "createdAt": "2026-09-15T00:00:00Z",
                              "lastUpdatedAt": "2026-09-15T00:00:00Z",
                              "ttlMs": 1000, "pollIntervalMs": 1}
            result(request_id, tasks[task_id], "task")
        else:
            result(request_id, {"content": [{"type": "text",
                                              "text": arguments.get("text", "ok")}]})
    elif method == "resources/list":
        result(request_id, {"resources": [{"uri": "memo://today", "name": "Today",
                                            "mimeType": "text/plain", "size": 3}]})
    elif method == "resources/templates/list":
        result(request_id, {"resourceTemplates": [{"uriTemplate": "memo://{id}",
                                                    "name": "Memo"}]})
    elif method == "resources/read":
        result(request_id, {"contents": [{"uri": params["uri"],
                                           "mimeType": "text/plain", "text": "memo"}],
                            "ttlMs": 10, "cacheScope": "private"})
    elif method == "prompts/list":
        result(request_id, {"prompts": [{"name": "review", "description": "Review",
                                         "arguments": [{"name": "code", "required": True}]}]})
    elif method == "prompts/get":
        result(request_id, {"description": "Review", "messages": [{
            "role": "user", "content": {"type": "text", "text": params.get("arguments", {}).get("code", "")}}]})
    elif method == "completion/complete":
        result(request_id, {"completion": {"values": ["one", "two"],
                                             "total": 2, "hasMore": False}})
    elif method == "tasks/get":
        result(request_id, tasks.get(params["taskId"], {"taskId": params["taskId"],
                                                         "status": "completed"}))
    elif method in ("tasks/update", "tasks/cancel"):
        result(request_id, {})
    elif method == "subscriptions/listen":
        subscriptions.add(request_id)
        send({"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
              "params": {"_meta": {
                  "io.modelcontextprotocol/subscriptionId": request_id},
                        "notifications": params.get("notifications", {})}})
    elif method == "notifications/cancelled":
        subscriptions.discard(params.get("requestId"))
    elif request_id is not None:
        error(request_id, -32601, "Method not found")


for line in sys.stdin:
    if line.strip():
        dispatch(json.loads(line))

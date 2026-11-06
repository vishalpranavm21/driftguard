"""DriftGuard control panel: run the demo without a terminal.

Each button runs the REAL project command in the background and streams its output
to the browser with Server-Sent Events. Only one action runs at a time.
The page also polls /api/state every 3 seconds for live cluster state.

Run:  cd dashboard && uvicorn app:app --host 127.0.0.1 --port 8090
It binds to 127.0.0.1 on purpose: the buttons run shell commands, so never expose it.
"""
import asyncio
import json
import os
import pathlib
import re
import subprocess
import threading
import time
import urllib.request

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENGINE_URL = os.getenv("ENGINE_URL", "http://localhost:8088")
REGISTRY = os.getenv("REGISTRY_URL", "http://localhost:5000")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

ACTIONS = {
    "k8s-drift": {
        "title": "Simulate Kubernetes drift",
        "cmd": r"""
echo '$ kubectl -n apps scale deploy demo --replicas=5     # manual change = drift'
kubectl -n apps scale deploy demo --replicas=5
sleep 6
kubectl -n apps get deploy demo
echo
echo '$ flux reconcile kustomization flux-system --with-source   # Flux re-applies Git'
flux reconcile kustomization flux-system --with-source --timeout 60s || true
sleep 8
kubectl -n apps get deploy demo
echo '>>> Self-healed: replicas are back to the value in Git (2).'
""",
    },
    "deploy-safe": {"title": "Deploy safe image", "cmd": "bash scripts/build.sh safe"},
    "deploy-risky": {"title": "Deploy risky image", "cmd": "bash scripts/build.sh risky"},
    "infra-drift": {
        "title": "Simulate infra drift + heal",
        "cmd": r"""
echo '$ kubectl -n platform patch configmap app-config  allowed_origins="*"   # manual change = drift'
kubectl -n platform patch configmap app-config --type merge -p '{"data":{"allowed_origins":"*"}}'
kubectl -n platform get configmap app-config -o jsonpath='{.data}'; echo
echo
echo '$ bash scripts/plan.sh'
bash scripts/plan.sh
""",
    },
    "infra-risky": {"title": "Try risky infra change", "cmd": "bash scripts/demo-risky-infra.sh"},
}

app = FastAPI(title="DriftGuard control panel")


# ------------------------------------------------------------------ jobs
class Job:
    def __init__(self, action: str):
        self.id = f"{action}-{int(time.time() * 1000)}"
        self.action = action
        self.title = ACTIONS[action]["title"]
        self.lines: list[str] = []
        self.rc: int | None = None
        self.started = time.time()
        self.ended: float | None = None


LOCK = threading.Lock()
CURRENT: Job | None = None   # the running (or most recent) job
JOBS: dict[str, Job] = {}


def _run(job: Job):
    main_tf = ROOT / "infra" / "main.tf"
    original_tf = main_tf.read_text()
    env = {**os.environ, "ENGINE_URL": ENGINE_URL, "TERM": "dumb", "NO_COLOR": "1"}
    try:
        proc = subprocess.Popen(
            ["bash", "-c", ACTIONS[job.action]["cmd"]], cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            text=True, bufsize=1, errors="replace")
        for line in proc.stdout:
            job.lines.append(ANSI.sub("", line.rstrip("\n")))
        job.rc = proc.wait()
    except Exception as e:  # noqa: BLE001
        job.lines.append(f"!!! dashboard error: {e}")
        job.rc = 1
    finally:
        # Safety net: whatever happened, infra/main.tf must end up exactly as it started.
        if main_tf.read_text() != original_tf:
            main_tf.write_text(original_tf)
            job.lines.append(">>> dashboard restored infra/main.tf")
        job.ended = time.time()


@app.post("/api/run/{action}")
def run(action: str):
    global CURRENT
    if action not in ACTIONS:
        raise HTTPException(404, "unknown action")
    with LOCK:
        if CURRENT and CURRENT.rc is None:
            raise HTTPException(409, f"'{CURRENT.title}' is still running")
        job = Job(action)
        CURRENT = job
        JOBS[job.id] = job
    threading.Thread(target=_run, args=(job,), daemon=True).start()
    return {"job": job.id, "title": job.title}


@app.get("/api/stream/{job_id}")
async def stream(job_id: str):
    job = JOBS.get(job_id)
    if not job:
        raise HTTPException(404, "unknown job")

    async def events():
        sent = 0
        while True:
            while sent < len(job.lines):
                yield f"data: {json.dumps(job.lines[sent])}\n\n"
                sent += 1
            if job.rc is not None and sent >= len(job.lines):
                yield f"event: done\ndata: {json.dumps({'rc': job.rc, 'seconds': round(job.ended - job.started)})}\n\n"
                return
            yield ": keep-alive\n\n"
            await asyncio.sleep(0.3)

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ------------------------------------------------------------------ live state
def _sh(cmd: list[str], timeout=8) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:  # noqa: BLE001
        return ""


def _http_json(url: str, timeout=2, method="GET", headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r, (json.loads(r.read() or b"null") if method == "GET" else None)


DIGEST_TO_TAG: dict[str, str] = {}
SEEN_TAGS: set[str] = set()


def _tag_for(digest: str) -> str | None:
    """Map an image digest back to its human tag (safe-<ts> / risky-<ts>) via the registry."""
    if digest in DIGEST_TO_TAG:
        return DIGEST_TO_TAG[digest]
    try:
        _, data = _http_json(f"{REGISTRY}/v2/demo/tags/list")
        accept = ",".join(["application/vnd.oci.image.index.v1+json",
                           "application/vnd.oci.image.manifest.v1+json",
                           "application/vnd.docker.distribution.manifest.list.v2+json",
                           "application/vnd.docker.distribution.manifest.v2+json"])
        for tag in data.get("tags") or []:
            if tag in SEEN_TAGS or tag.startswith("sha256-"):
                continue
            r, _ = _http_json(f"{REGISTRY}/v2/demo/manifests/{tag}", method="HEAD",
                              headers={"Accept": accept})
            DIGEST_TO_TAG[r.headers.get("Docker-Content-Digest", "")] = tag
            SEEN_TAGS.add(tag)
    except Exception:  # noqa: BLE001
        pass
    return DIGEST_TO_TAG.get(digest)


def _pods():
    raw = _sh(["kubectl", "-n", "apps", "get", "pods", "-o", "json"])
    out = []
    for p in (json.loads(raw)["items"] if raw else []):
        image = p["spec"]["containers"][0]["image"]
        digest = image.split("@", 1)[1] if "@" in image else ""
        cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
        state = next(iter(cs.get("state", {}) or {}), "")
        status = p["status"].get("phase", "?")
        if p["metadata"].get("deletionTimestamp"):
            status = "Terminating"
        elif state == "waiting":
            status = cs["state"]["waiting"].get("reason", "Waiting")
        out.append({
            "name": p["metadata"]["name"],
            "tag": (_tag_for(digest) if digest else image.rsplit(":", 1)[-1]) or "?",
            "digest": digest[:19],
            "status": status,
            "ready": bool(cs.get("ready")),
            "node": p["spec"].get("nodeName", ""),
            "created": p["metadata"]["creationTimestamp"],
        })
    return sorted(out, key=lambda x: x["created"], reverse=True)


def _denials():
    raw = _sh(["kubectl", "get", "events", "-A", "--field-selector", "reason=PolicyViolation", "-o", "json"])
    items = json.loads(raw)["items"] if raw else []
    out = []
    for e in items:
        msg = e.get("message", "")
        if "blocked" not in msg and "fail" not in msg:
            continue
        rule = re.search(r"\[([^\]]+)\]", msg)
        digest = re.search(r"sha256:[0-9a-f]{64}", msg)
        out.append({
            "time": e.get("lastTimestamp") or e.get("eventTime") or e["metadata"]["creationTimestamp"],
            "policy": e["involvedObject"].get("name", ""),
            "rule": rule.group(1) if rule else "",
            "tag": (_tag_for(digest.group(0)) if digest else None) or "",
            "count": e.get("count") or (e.get("series") or {}).get("count") or 1,
            "message": msg[:400],
        })
    # Kyverno emits one event per admission attempt (Flux dry-run + apply): keep the newest per image+rule
    seen, unique = set(), []
    for d in sorted(out, key=lambda x: x["time"], reverse=True):
        key = (d["rule"], d["tag"] or d["message"][:120])
        if key not in seen:
            seen.add(key)
            unique.append(d)
    return unique[:5]


def _configmap():
    raw = _sh(["kubectl", "-n", "platform", "get", "configmap", "app-config", "-o", "jsonpath={.data}"])
    try:
        return json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return None


def _flux():
    raw = _sh(["kubectl", "-n", "flux-system", "get", "kustomization", "flux-system", "-o", "json"])
    if not raw:
        return None
    st = json.loads(raw).get("status", {})
    ready = next((c for c in st.get("conditions", []) if c["type"] == "Ready"), {})
    return {"ready": ready.get("status"), "reason": ready.get("reason"),
            "message": ready.get("message", "")[:300], "revision": st.get("lastAppliedRevision", "")}


def _risk():
    try:
        _, last = _http_json(f"{ENGINE_URL}/last")
        if last and "risk_score" in last:
            return {"source": "engine", **last}
    except Exception:  # noqa: BLE001
        pass
    f = ROOT / "infra" / "risk.json"   # fallback: last plan.sh result
    if f.exists():
        try:
            return {"source": "infra/risk.json", **json.loads(f.read_text())}
        except json.JSONDecodeError:
            pass
    return None


def _engine():
    try:
        _, h = _http_json(f"{ENGINE_URL}/healthz")
        return h
    except Exception:  # noqa: BLE001
        return None


CACHE = {"t": 0.0, "data": None}
CACHE_LOCK = threading.Lock()


@app.get("/api/state")
def state():
    with CACHE_LOCK:   # many tabs / fast polling -> at most one kubectl round per 2 s
        if time.time() - CACHE["t"] > 2 or CACHE["data"] is None:
            CACHE["data"] = {
                "pods": _pods(), "denials": _denials(), "configmap": _configmap(),
                "flux": _flux(), "risk": _risk(), "engine": _engine(),
            }
            CACHE["t"] = time.time()
        data = dict(CACHE["data"])
    job = CURRENT
    data["job"] = None if job is None else {
        "id": job.id, "title": job.title, "running": job.rc is None, "rc": job.rc}
    return data


@app.get("/")
def index():
    return FileResponse(pathlib.Path(__file__).parent / "index.html")

#!/usr/bin/env python3
"""이전 리허설 제어판. 표준 라이브러리만 쓴다.

    python3 poc/demo/panel/server.py        → http://localhost:8091

1초마다 컨테이너, HAProxy, PgBouncer, pg-a/pg-b의 복제 상태, 채팅 통계, 부하 생성기 기록을 모아 두고,
버튼을 누르면 poc/demo/bin/의 스크립트(prepare, migrate, rollback, verify)를 실행한다.
에이전트(데모 앱 저장소의 agents/chatbots.py)는 이 서버가 자식 프로세스로 띄우고 끈다.
"""

import collections
import glob
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
DEMO = HERE.parent
RESULTS = DEMO.parent / "cdc" / "results"
APP_SRC = pathlib.Path(os.environ.get("DEMO_APP_SRC", "~/workspace/jackal-demo-app")).expanduser()
DEMO_PORT = int(os.environ.get("DEMO_PORT", "8090"))
PANEL_PORT = int(os.environ.get("PANEL_PORT", "8091"))
HAPROXY_RUNTIME = int(os.environ.get("HAPROXY_RUNTIME_PORT", "9999"))
PROJECT = "cdc-poc"
HISTORY_SEC = 300
ANSI = re.compile(r"\x1b\[[0-9;]*m")

lock = threading.Lock()
state: dict = {}
history = collections.deque(maxlen=HISTORY_SEC)  # 1초마다 한 점
log_lines: list = []  # (seq, t, text)
events: list = []  # 단계 표시: {t, job, label}
results = {"agents": None, "loadgen": None, "lost": None, "compare": None, "verify_t": None}


def add_log(text: str) -> None:
    with lock:
        log_lines.append((len(log_lines), time.time(), text))
        del log_lines[:-2000]


# ───────────────────────── 수집 ─────────────────────────

def run(args, timeout=8):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (subprocess.TimeoutExpired, OSError):
        return -1, ""


def containers() -> dict:
    _, out = run(["docker", "ps", "-a", "--filter", f"label=com.docker.compose.project={PROJECT}",
                  "--format", "{{json .}}"])
    res = {}
    for line in out.splitlines():
        d = json.loads(line)
        svc = d["Names"].removeprefix(f"{PROJECT}-").rsplit("-", 1)[0]
        res[svc] = {"state": d["State"], "status": d["Status"]}
    return res


NODE_SQL = """
select json_build_object(
  'size', pg_database_size(current_database()),
  'tables', (select coalesce(json_object_agg(c.relname, pg_total_relation_size(c.oid)), '{}')
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r'),
  'subs', (select coalesce(json_agg(json_build_object(
              'name', s.subname, 'enabled', s.subenabled,
              'rels', (select coalesce(json_object_agg(r.srrelid::regclass::text, r.srsubstate), '{}')
                       from pg_subscription_rel r where r.srsubid = s.oid))), '[]')
           from pg_subscription s),
  'slots', (select coalesce(json_agg(json_build_object(
              'name', slot_name, 'active', active,
              'lag', pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn),
              'retained', pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))), '[]')
            from pg_replication_slots),
  'copying', (select coalesce(json_object_agg(relid::regclass::text, tuples_processed), '{}')
              from pg_stat_progress_copy)
)
"""


def node(name: str):
    rc, out = run(["docker", "exec", f"{PROJECT}-{name}-1", "psql", "-U", "postgres", "-d", "app",
                   "-XAtc", NODE_SQL], timeout=5)
    if rc != 0 or not out.strip():
        return None
    return json.loads(out)


def pgb_target():
    rc, out = run(["docker", "exec", f"{PROJECT}-pgbouncer-1", "cat",
                   "/etc/pgbouncer/runtime/databases.ini"], timeout=3)
    m = re.search(r"host=(\S+)", out)
    return m.group(1) if rc == 0 and m else None


def haproxy() -> dict:
    try:
        with socket.create_connection(("127.0.0.1", HAPROXY_RUNTIME), timeout=1) as s:
            s.sendall(b"show stat\n")
            buf = b""
            while chunk := s.recv(65536):
                buf += chunk
    except OSError:
        return {}
    lines = buf.decode().splitlines()
    if not lines or not lines[0].startswith("# "):
        return {}
    header = lines[0][2:].split(",")
    res = {}
    for line in lines[1:]:
        row = dict(zip(header, line.split(",")))
        if row.get("pxname") == "app" and row.get("svname", "").startswith("app-"):
            res[row["svname"]] = {"status": row["status"], "weight": int(row["weight"] or 0),
                                  "requests": int(row["stot"] or 0), "sessions": int(row["scur"] or 0)}
    return res


def chat_stats():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{DEMO_PORT}/api/stats", timeout=1) as r:
            return json.load(r)
    except Exception:
        return None


def loadgen_last():
    p = RESULTS / "loadgen-timeline.jsonl"
    try:
        with open(p, "rb") as f:
            f.seek(max(0, p.stat().st_size - 400))
            last = f.read().decode(errors="ignore").strip().splitlines()[-1]
        d = json.loads(last)
        return d if time.time() - d["t"] < 3 else None
    except Exception:
        return None


def switchovers():
    res = []
    for p in sorted(glob.glob(str(RESULTS / "switchover-*.json")), key=os.path.getmtime):
        try:
            d = json.load(open(p))
            d["t"] = os.path.getmtime(p)
            res.append(d)
        except Exception:
            pass
    return res


def replication(nodes: dict, primary):
    """주 DB에서 나가는 복제 한 줄기를 단계로 요약한다."""
    if not primary or primary not in ("pg-a", "pg-b"):
        return None
    other = "pg-b" if primary == "pg-a" else "pg-a"
    src, dst = nodes.get(primary), nodes.get(other)
    if not src or not dst:
        return None
    sub = next((s for s in dst["subs"] if s["name"] == "mig_from_" + primary.replace("-", "_")), None)
    slot = next((s for s in src["slots"] if sub and s["name"] == sub["name"]), None)
    tables = []
    for t, b in sorted(src["tables"].items(), key=lambda kv: -kv[1]):
        state_ = (sub or {}).get("rels", {}).get(t) if sub else None
        tables.append({"name": t, "src": b, "dst": dst["tables"].get(t), "state": state_,
                       "copying_rows": dst["copying"].get(t)})
    if not dst["tables"]:
        phase = "none"
    elif not sub:
        phase = "schema"
    else:
        states = list(sub["rels"].values())
        lag = slot["lag"] if slot and slot["lag"] is not None else -1
        if not sub["enabled"]:
            phase = "disabled"
        elif any(s in "idf" for s in states):
            phase = "copying"
        elif any(s != "r" for s in states) or lag < 0 or lag > 1_000_000:
            phase = "catching_up"
        else:
            phase = "streaming"
    return {"src": primary, "dst": other, "phase": phase, "sub": sub and sub["name"],
            "lag": slot and slot["lag"], "retained": slot and slot["retained"], "slot_active": slot and slot["active"],
            "src_size": src["size"], "dst_size": dst["size"], "tables": tables}


def sampler():
    while True:
        t0 = time.time()
        c = containers()
        nodes = {n: node(n) for n in ("pg-a", "pg-b") if c.get(n, {}).get("state") == "running"}
        primary = pgb_target() if c.get("pgbouncer", {}).get("state") == "running" else None
        snap = {
            "t": t0, "containers": c, "primary": primary, "haproxy": haproxy(), "chat": chat_stats(),
            "loadgen": loadgen_last(), "replication": replication(nodes, primary), "switchovers": switchovers(),
            "agents": agents.status(), "job": job_status(), "demo_port": DEMO_PORT,
        }
        rep = snap["replication"] or {}
        lg = snap["loadgen"] or {}
        point = {"t": round(t0, 1), "lag": rep.get("lag"), "ok": lg.get("ok"), "err": lg.get("err"),
                 "max_ms": lg.get("max_ms"), "chat": (snap["chat"] or {}).get("total"),
                 "primary": primary}
        with lock:
            state.clear()
            state.update(snap)
            history.append(point)
        time.sleep(max(0.2, 1.0 - (time.time() - t0)))


# ───────────────────────── 작업 ─────────────────────────

job = {"name": None, "proc": None, "started": None, "ended": None, "rc": None}


def job_status():
    return {k: job[k] for k in ("name", "started", "ended", "rc")} | {"running": job["proc"] is not None}


STEP = re.compile(r"▶ (.*)")
SW_STEP = re.compile(r"\] (\d\. .*|완료: .*|ERROR: .*)")


def start_job(name: str, cmd: list, env: dict | None = None, after=None) -> bool:
    with lock:
        if job["proc"] is not None:
            return False
        proc = subprocess.Popen(cmd, cwd=DEMO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                env=os.environ | {"DEMO_PORT": str(DEMO_PORT)} | (env or {}), bufsize=1)
        job.update(name=name, proc=proc, started=time.time(), ended=None, rc=None)
        events.append({"t": time.time(), "job": name, "label": "시작", "kind": "job"})

    def reader():
        add_log(f"━━━ {name}: {' '.join(cmd)}")
        out = []
        for raw in proc.stdout:
            line = ANSI.sub("", raw.rstrip("\n"))
            out.append(line)
            add_log(line)
            m = STEP.search(line)
            sw = SW_STEP.search(line)
            if m or sw:
                with lock:
                    events.append({"t": time.time(), "job": name, "label": (m or sw).group(1),
                                   "kind": "step" if m else "switchover"})
        rc = proc.wait()
        add_log(f"━━━ {name} 종료 (exit {rc})")
        if after:
            after(out, rc)
        with lock:
            job.update(proc=None, ended=time.time(), rc=rc)
            events.append({"t": time.time(), "job": name, "label": "끝" if rc == 0 else f"실패 (exit {rc})",
                           "kind": "job"})

    threading.Thread(target=reader, daemon=True).start()
    return True


def after_verify(out, rc):
    text = "\n".join(out)
    m = re.search(r'\{"node":.*\}', text)
    results["lost"] = json.loads(m.group(0)) if m else None
    results["compare"] = "일치" if "일치:" in text else ("불일치" if "불일치" in text else None)
    try:
        results["loadgen"] = json.load(open(RESULTS / "loadgen-summary.json"))
    except Exception:
        results["loadgen"] = None
    results["verify_t"] = time.time()


# ───────────────────────── 에이전트 ─────────────────────────

class Agents:
    def __init__(self):
        self.proc = None
        self.started = None
        self.offline = False
        self.messages = collections.deque(maxlen=50)

    def status(self):
        return {"running": self.proc is not None, "started": self.started, "offline": self.offline,
                "has_key": (APP_SRC / "agents" / ".env").exists()}

    def start(self, offline: bool) -> bool:
        if self.proc is not None:
            return False
        env_file = APP_SRC / "agents" / ".env"
        offline = offline or not env_file.exists()
        cmd = ["uv", "run"] + (["--env-file", ".env"] if env_file.exists() else []) + \
              ["chatbots.py", "--url", f"http://localhost:{DEMO_PORT}",
               "--metrics-url", f"http://localhost:{PANEL_PORT}/api/metrics"] + (["--offline"] if offline else [])
        self.proc = subprocess.Popen(cmd, cwd=APP_SRC / "agents", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1, start_new_session=True)
        self.started, self.offline = time.time(), offline
        results["agents"] = None
        add_log(f"━━━ 에이전트 시작 ({'준비된 대사' if offline else 'Claude'})")
        threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()
        return True

    def _read(self, proc):
        tail = []
        for raw in proc.stdout:
            line = raw.rstrip("\n")
            tail = (tail + [line])[-40:]
            if "HTTP Request" in line or line.startswith("    └"):
                continue
            add_log("🤖 " + line)
        proc.wait()
        # 종료 시 마지막에 JSON 집계를 출력한다
        text = "\n".join(tail)
        i = text.rfind("\n{")
        try:
            results["agents"] = json.loads(text[i + 1:] if i >= 0 else text[text.index("{"):])
        except Exception:
            pass
        add_log(f"━━━ 에이전트 종료 {json.dumps(results['agents'], ensure_ascii=False) if results['agents'] else ''}")
        self.proc = None

    def stop(self, wait=True):
        p = self.proc
        if p is None:
            return
        try:
            os.killpg(p.pid, signal.SIGINT)
        except ProcessLookupError:
            return
        if wait:
            for _ in range(150):
                if self.proc is None:
                    return
                time.sleep(0.1)
            os.killpg(p.pid, signal.SIGKILL)


agents = Agents()


# ───────────────────────── 에이전트용 지표 ─────────────────────────

PHASE_KO = {"none": "준비 전", "schema": "스키마만 복사됨", "copying": "초기 복사 중", "catching_up": "변경 따라잡는 중",
            "streaming": "실시간 동기화", "disabled": "꺼짐"}


def stage(s: dict) -> str:
    """지금 이전이 어디까지 왔는지 한 문장으로 설명한다. 에이전트가 정상 과정을 사고로 오해하지 않게 한다."""
    j = s.get("job") or {}
    if j.get("running") and j.get("name") in ("이전", "되돌리기", "환경 준비"):
        last = next((e["label"] for e in reversed(events) if e["job"] == j["name"] and e["kind"] != "job"), "시작")
        return f"{j['name']} 작업 진행 중. 현재 단계: {last}"
    p, h = s.get("primary"), s.get("haproxy") or {}
    wa, wb = h.get("app-a", {}).get("weight", 0), h.get("app-b", {}).get("weight", 0)
    rep = s.get("replication") or {}
    if p == "pg-a" and wb == 0:
        return f"이전 전. 앱 env-a, DB pg-a. pg-a → pg-b 복제 {PHASE_KO.get(rep.get('phase'), '-')}"
    if p == "pg-a":
        return "Phase A 진행 상태. 앱 트래픽을 env-b로 옮기는 중이고 DB는 아직 pg-a (앱 먼저, DB 나중이 정상 순서)"
    if p == "pg-b" and wa == 0:
        return "이전 완료. 앱 env-b, DB pg-b. 롤백에 대비해 pg-b → pg-a 역방향 복제 유지 중"
    if p == "pg-b":
        return "DB는 pg-b로 전환됨. 앱 트래픽 일부가 아직 env-a"
    return "환경이 준비되지 않음"


def metrics() -> dict:
    with lock:
        s = dict(state)
        hist = list(history)
    if not s:
        return {}
    now = time.time()
    last60 = [p for p in hist if now - p["t"] <= 60]
    lg = s.get("loadgen") or {}
    rep = s.get("replication") or {}
    sw = (s.get("switchovers") or [None])[-1]
    h = s.get("haproxy") or {}
    c = s.get("containers") or {}
    return {
        "time": time.strftime("%H:%M:%S"),
        "stage": stage(s),
        "primary_db": s.get("primary"),
        "apps": {a: {"weight": h.get(a, {}).get("weight"),
                     "status": h.get(a, {}).get("status") if c.get(a, {}).get("state") == "running" else "stopped"}
                 for a in ("app-a", "app-b")},
        "replication": rep and {"direction": f"{rep.get('src')} -> {rep.get('dst')}",
                                "phase": PHASE_KO.get(rep.get("phase"), rep.get("phase")),
                                "lag_bytes": rep.get("lag"), "retained_wal_bytes": rep.get("retained")},
        "last_switchover": sw and {"direction": f"{sw['from']} -> {sw['to']}", "write_pause_ms": sw["write_pause_ms"],
                                   "checksum_ms": sw.get("steps_ms", {}).get("verify"),
                                   "seconds_ago": round(now - sw["t"])},
        "switchover_count": len(s.get("switchovers") or []),
        "db_load": lg and {"tx_per_sec": lg.get("ok"), "p50_ms_60s": lg.get("p50_60s"), "p95_ms_60s": lg.get("p95_60s"),
                           "p99_ms_60s": lg.get("p99_60s"),
                           "max_ms_60s": round(max((p["max_ms"] or 0) for p in last60), 1) if last60 else None,
                           "errors_60s": sum((p["err"] or 0) for p in last60)},
        "chat_messages": s.get("chat"),
    }


# ───────────────────────── 동작 ─────────────────────────

def action(name: str, body: dict):
    if name == "agents-start":
        return agents.start(bool(body.get("offline")))
    if name == "agents-stop":
        threading.Thread(target=agents.stop, daemon=True).start()
        return True
    if name == "prepare":
        agents.stop()
        results.update(agents=None, loadgen=None, lost=None, compare=None, verify_t=None)
        with lock:
            history.clear()
            events.clear()
        return start_job("환경 준비", ["bin/prepare"],
                         {"SCALE": str(int(body.get("scale", 1))), "RATE": str(int(body.get("rate", 50)))})
    if name == "migrate":
        return start_job("이전", ["bin/migrate"])
    if name == "rollback":
        return start_job("되돌리기", ["bin/rollback"])
    if name == "verify":
        def go():
            agents.stop()
            start_job("검증", ["bin/verify"], after=after_verify)
        threading.Thread(target=go, daemon=True).start()
        return True
    if name == "load-start":
        return start_job("부하 시작", ["bin/demo", "--profile", "load", "up", "-d", "--build", "--no-deps", "loadgen"],
                         {"RATE": str(int(body.get("rate", 50)))})
    if name == "load-stop":
        return start_job("부하 중지", ["bin/demo", "--profile", "load", "stop", "loadgen"])
    if name == "weight":
        return start_job("가중치", ["bin/weight", str(int(body["a"])), str(int(body["b"]))])
    if name == "app-a-start":
        return start_job("app-a 시작", ["bin/demo", "start", "app-a"])
    if name == "app-a-stop":
        return start_job("app-a 종료", ["bin/demo", "stop", "app-a"])
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path, _, qs = self.path.partition("?")
        if path in ("/", "/index.html"):
            return self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/metrics":
            return self.send(200, metrics())
        if path == "/api/state":
            since = int(dict(p.split("=", 1) for p in qs.split("&") if "=" in p).get("log", -1))
            with lock:
                body = dict(state) | {
                    "history": list(history), "events": list(events), "results": dict(results),
                    "log": [l for l in log_lines if l[0] > since][-500:],
                }
            return self.send(200, body)
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if not self.path.startswith("/api/action/"):
            return self.send(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        ok = action(self.path.removeprefix("/api/action/"), body)
        if ok is None:
            return self.send(404, {"error": "unknown action"})
        self.send(200 if ok else 409, {"ok": ok, "error": None if ok else "다른 작업이 실행 중입니다"})


def main():
    threading.Thread(target=sampler, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PANEL_PORT), Handler)
    print(f"제어판: http://localhost:{PANEL_PORT}  (채팅 http://localhost:{DEMO_PORT})", flush=True)

    def shutdown(*_):
        agents.stop(wait=False)
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    srv.serve_forever()


if __name__ == "__main__":
    main()

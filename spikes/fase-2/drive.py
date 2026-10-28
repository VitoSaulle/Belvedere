import json, os, subprocess, sys, time, threading
proj = sys.argv[1]; extra = sys.argv[2:]
env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE") or k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"))}
cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--include-partial-messages", "--model", "haiku", "--permission-prompt-tool", "stdio"] + extra
p = subprocess.Popen(cmd, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
log = open(os.path.join(os.path.dirname(__file__), "out.jsonl"), "w")
def send(o):
    p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush(); log.write(">> " + json.dumps(o) + "\n")
send({"type": "control_request", "request_id": "init1", "request": {"subtype": "initialize"}})
send({"type": "user", "message": {"role": "user", "content": "Esegui con il tool Bash esattamente: touch spike-ok. Poi rispondi 'fatto'."}})
t0 = time.time()
for line in p.stdout:
    log.write(line); log.flush()
    try: o = json.loads(line)
    except Exception: continue
    t = o.get("type"); st = o.get("subtype") or (o.get("event", {}) or {}).get("type")
    if t == "stream_event": continue
    print(round(time.time() - t0, 1), t, st, json.dumps(o)[:260])
    if t == "control_request" and o["request"].get("subtype") == "can_use_tool":
        send({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"],
              "response": {"behavior": "allow", "updatedInput": o["request"]["input"]}}})
    if t == "result":
        p.stdin.close()
p.wait(30)
print("exit", p.returncode, p.stderr.read()[:500])

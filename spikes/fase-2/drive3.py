import json, os, subprocess, sys, time, queue, threading
proj = sys.argv[1]; extra = sys.argv[2:]
env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE") or k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"))}
cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--model", "haiku", "--permission-prompt-tool", "stdio"] + extra
p = subprocess.Popen(cmd, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
log = open(os.path.join(os.path.dirname(__file__), "out3.jsonl"), "w")
t0 = time.time()
def send(o):
    p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush(); log.write(">> " + json.dumps(o) + "\n")
    print(round(time.time()-t0,1), ">>", json.dumps(o)[:160])
def user(text): send({"type": "user", "message": {"role": "user", "content": text}})
decide = {}
def pump(until, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        try: line = q.get(timeout=0.5)
        except queue.Empty: continue
        log.write(line); log.flush()
        try: o = json.loads(line)
        except Exception: continue
        t = o.get("type"); st = o.get("subtype")
        if t == "assistant":
            for c in o["message"]["content"]:
                if c["type"] == "text": print(round(time.time()-t0,1), "TEXT", c["text"][:200])
                if c["type"] == "tool_use": print(round(time.time()-t0,1), "TOOL", c["name"], json.dumps(c["input"])[:150])
        elif t == "user":
            c = o["message"]["content"]
            print(round(time.time()-t0,1), "USER", json.dumps(c)[:200])
        elif t == "control_request":
            r = o["request"]; print(round(time.time()-t0,1), "CREQ", r.get("subtype"), r.get("tool_name"), json.dumps(r.get("input"))[:200])
            if r.get("subtype") == "can_use_tool":
                send({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"], "response": decide["fn"](r)}})
        elif t in ("result",) or (t == "system" and st not in ("hook_started", "hook_response", "thinking_tokens", "status")) or t == "control_response":
            print(round(time.time()-t0,1), t, st, json.dumps(o)[:300])
        if until(o): return o
    print("TIMEOUT")
is_result = lambda o: o.get("type") == "result"
send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}})
decide["fn"] = lambda r: (print("ASKINPUT", json.dumps(r["input"])[:600]) or {"behavior": "allow", "updatedInput": {**r["input"], "answers": {r["input"]["questions"][0]["question"]: r["input"]["questions"][0]["options"][1]["label"]}}}) if r["tool_name"] == "AskUserQuestion" else {"behavior": "allow", "updatedInput": r["input"]}
user("Qual era il nome del file che hai creato prima? Poi usa il tool AskUserQuestion per chiedermi se preferisco 'rosso' o 'blu' e dimmi cosa ho scelto."); pump(is_result, 90)
p.stdin.close(); p.wait(30); print("exit", p.returncode, p.stderr.read()[-400:])

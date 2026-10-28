import json, os, subprocess, sys, time, queue, threading
proj = sys.argv[1]; extra = sys.argv[2:]
env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE") or k in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"))}
cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--model", "haiku", "--permission-prompt-tool", "stdio"] + extra
p = subprocess.Popen(cmd, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
log = open(os.path.join(os.path.dirname(__file__), "out2.jsonl"), "w")
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
# 1 deny
decide["fn"] = lambda r: {"behavior": "deny", "message": "Negato dall'utente in Belvedere"}
user("Esegui con Bash: touch negato.txt"); pump(is_result)
# 2 always: allow + updatedPermissions
decide["fn"] = lambda r: {"behavior": "allow", "updatedInput": r["input"], "updatedPermissions": [s for s in r.get("permission_suggestions", []) if s.get("type") == "addRules"]}
user("Ora esegui con Bash: touch sempre.txt"); pump(is_result)
# 3 slash command as text
user("/context"); pump(is_result, 30)
# 4 set model via control
send({"type": "control_request", "request_id": "m", "request": {"subtype": "set_model", "model": "sonnet"}}); pump(lambda o: o.get("type") == "control_response", 10)
user("Che modello sei? Rispondi in 5 parole."); pump(is_result)
# 5 interrupt
decide["fn"] = lambda r: {"behavior": "allow", "updatedInput": r["input"]}
user("Esegui con Bash: sleep 20 && echo fine"); time.sleep(6)
send({"type": "control_request", "request_id": "x", "request": {"subtype": "interrupt"}}); pump(is_result, 30)
p.stdin.close(); p.wait(30); print("exit", p.returncode, p.stderr.read()[-400:])

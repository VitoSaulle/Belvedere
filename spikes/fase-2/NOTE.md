# Spike fase 2 — `claude -p` in stream-json (2026-10-28, Claude Code 2.1.312)

Comando: `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model haiku --permission-prompt-tool stdio`.
Driver: `drive.py`, `drive2.py`, `drive3.py`. Registrazioni ripulite (niente account, percorsi anonimi): `*.jsonl`; le righe che iniziano con `>> ` sono quelle scritte su stdin.

Verificato sul campo:

- **Init**: `{"type":"control_request","request_id":"i","request":{"subtype":"initialize"}}` → `control_response` con `commands[{name,description,argumentHint}]`, `models[]`, `current_permission_mode`, `account` (da non salvare né mostrare). Poi `system/init` con `session_id`, `model`, `permissionMode`, `cwd`, `tools`, `mcp_servers[{name,status}]`, `slash_commands`, `terminal_slash_commands` (es. `doctor`, `color`, `focus`, `reload-plugins`). `system/init` si ripete a ogni turno.
- **Messaggio utente**: `{"type":"user","message":{"role":"user","content":"testo"}}`. Il processo resta vivo tra un turno e l'altro; ogni turno finisce con `result`.
- **Permessi**: `control_request` `subtype:"can_use_tool"` con `tool_name`, `input`, `description`, `permission_suggestions[]`, `blocked_path`, `tool_use_id`. Risposta: `{"type":"control_response","response":{"subtype":"success","request_id":…,"response":{"behavior":"allow","updatedInput":<input>}}}` oppure `{"behavior":"deny","message":"…"}` (diventa un `tool_result` con `is_error:true` e quel testo).
- **Sempre in questo progetto**: `allow` con `"updatedPermissions":[<suggestion di tipo addRules, destination localSettings>]` → Claude Code scrive da sé `.claude/settings.local.json` del progetto (`permissions.allow`). Belvedere non deve scrivere il file.
- **AskUserQuestion**: arriva come `can_use_tool` con `input.questions[{question,header,options[{label,description}],multiSelect}]`; si risponde `allow` con `updatedInput = input + "answers": {"<question>": "<label>"}`.
- **Slash command come testo** (`/context`): risposta in un messaggio assistant di testo e `result` con `num_turns: 0`.
- **Cambio modello**: `control_request` `subtype:"set_model","model":"sonnet"` → `control_response` `{"model":"claude-sonnet-5-5"}` più un messaggio `user` con `<local-command-stdout>…</local-command-stdout>`.
- **Interruzione**: `control_request` `subtype:"interrupt"` → `control_response` `{"still_queued":[]}`, messaggio `user` `[Request interrupted by user]`, `result` `subtype:"error_during_execution"`.
- **Ripresa**: `--resume <session_id>` con gli stessi flag riprende la conversazione (il modello ricorda i turni precedenti).
- **Limiti del piano**: `rate_limit_event.rate_limit_info.unifiedWindows.{five_hour,seven_day}.{utilization (0…1), resetsAt (epoch s)}` → anche le sessioni di Belvedere aggiornano i limiti.
- **Costo e contesto**: `result.total_cost_usd`, `result.modelUsage.<modello>.contextWindow`, `result.usage.iterations[-1]` (input + cache read + cache creation = contesto dell'ultima chiamata).
- **Testo in streaming**: `stream_event` con `event.type == "content_block_delta"` e `event.delta.type == "text_delta"` (`event.delta.text`).
- **Hook**: con `-p` i hook di `settings.json` girano tutti, **compreso `PermissionRequest`**, in parallelo a `can_use_tool`. Belvedere deve ignorare i propri hook di permesso per le sessioni che ha lanciato, altrimenti la stessa richiesta compare due volte.
- **Worktree**: `-w, --worktree [name]` crea un worktree git per la sessione.

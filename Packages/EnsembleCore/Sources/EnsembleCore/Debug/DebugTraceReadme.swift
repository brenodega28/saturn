#if DEBUG
enum DebugTraceReadme {
    static let text = #"""
    # Ensemble debug logs

    Written only by DEBUG builds of Ensemble, for an agent that studies how Ensemble's agents and workflow runs behave
    and suggests changes to its UI, permissions, prompts and context that make runs cheaper and better.
    Release builds never write here. Nothing in this folder is read back by the app.

    ## Layout

    ```
    debug-logs/
      README.md                                   this file, rewritten on every app launch
      runs/<runId>-<run title slug>/
        trace.jsonl                               orchestration events for the run
        agents/<agentId>-<agent name slug>.jsonl  stream and summaries of every agent attached to the run
      chats/<agentId>-<agent name slug>/
        agent.jsonl                               agents that are not in a run: direct-chat agents and request leads
      prompts/<hash>.md                           each distinct prompt, stored once
    ```

    - An agent belongs to a run when its `runId` is set. A request lead chats in `chats/` until the user starts a run;
      from then on its events go to that run's `agents/` folder.
    - Chat messages (`chat_message`) are written inline in the agent's own file, so they sit next to the
      `turn_summary` of the turn that answered them. Join on `agentId` and order by `at`.
    - `prompts/<hash>.md` holds the full text of system prompts, turn prompts (tasks, handoff messages, chat turns),
      run briefs, and step inputs or outputs too long to inline. `<hash>` is the first 16 hex characters of the SHA-256
      of the UTF-8 text. Events reference them with fields ending in `Hash` (and `"prompt:<hash>"` inside `arguments`).

    ## Common fields

    Every line is one JSON object with keys sorted alphabetically.

    - `type`: the event type, listed below.
    - `at`: ISO-8601 timestamp with milliseconds.
    - `runId`: the run, when known.
    - `stepId`: the workflow step id (for example `plan`, `build`, `review`, `_end`), when known. `runStepId` is the
      database row of that step attempt; each iteration or retry of a step gets a new row.
    - `agentId`, `agentName`: on every agent event, and on run events caused by one agent. `taskId` is the request
      an agent leads.

    ## Agent events (runs/*/agents/*.jsonl and chats/*/agent.jsonl)

    - `launch`: one Claude Code process started for one turn. `role`, `model`, `readOnly`, `cwd`, `worktree`,
      `branch`, `executable`, `arguments` (full argv; the system prompt is replaced by `prompt:<hash>`),
      `extraAllowedTools`, `additionalDirectories`, `envVarNames` (names only, never values), `session`
      (`mode` new or resume, `id`), `systemPromptHash`, `turnPromptHash`, `imageCount`.
    - `session_init`: Claude Code's `system/init` line. `claudeCodeVersion`, `apiKeySource`, `model`, `cwd`,
      `permissionMode`, `tools`, `mcpServers`, `slashCommands`, `sessionId`.
    - `raw`: one line of the stream. `direction` is `stdin` (the user turn Ensemble sent, image data omitted) or
      `stdout` (every line Claude Code printed, including ones Ensemble ignores). `transcribed` is false when the line
      was not copied to Ensemble's own transcript (rate-limit notices, compaction and other system lines).
      `line` is the parsed JSON; in `user` lines (tool results and sent turns) every string over 2048 UTF-8 bytes is
      replaced by `{"preview": <first 2048 characters>, "originalLength": <characters>}`. Lines that are not JSON
      appear as `text` (cut at 2048 with `originalLength`).
    - `turn_summary`: written when a turn's `result` line arrives. `durationMS` (Claude Code's), `wallClockMS`
      (from launch), `costUSD` (this turn; `processTotalCostUSD` is Claude Code's `total_cost_usd`, which carries the session's earlier spend over a resume), `inputTokens`,
      `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, `apiCalls` (distinct assistant message ids),
      `toolCalls` (count by tool name), `toolCallTotal`, `failedToolCalls` (`tool`, `toolUseId`, `error` preview of
      results with is_error), `permissionDenials` (`tool`, `toolUseId`, `input`: what was blocked), `interrupted`,
      `subtype`, `isError`, `numTurns`, `model`, `contextTokens` (input + cache read + cache write tokens of the last
      assistant message: an estimate of the context size at the end of the turn).
    - `lifecycle`: `event` is one of started, resumed, paused, stopped, restarted, interrupted, takenOver,
      handedBack, failed, queued (waiting for the project's concurrency limit) or dequeued (its queued turn started).
      `status` is the agent status after the change, `detail` the message (for example the failure reason).
    - `process_exited`: `exitCode`, `stderr` (first 2048 characters), `stderrLength`.
    - `chat_message`: `direction` is `user_to_agent` or `agent_to_user`, `chat` is `direct` (Agents chat) or
      `lead` (request chat), `text` (cut at 8192 bytes, with `originalLength` when cut).
    - `handoff`, `question_relayed`, `question_answered`: as below, for agents that are not in a run.

    ## Run events (runs/*/trace.jsonl)

    - `run_started`: `workflow`, `workflowVersion`, `title`, `taskId`, `projectId`, `budgetUSD`, `endAction`,
      `steps`, `firstStep`, `briefHash`, `briefPreview`.
    - `step_started`: `kind` (agent, spawn, condition, approval, notify, end), `role`, `iteration`, `attempt`,
      `start` (fresh, retry, resume), `status`, and `input` (inline JSON) or `inputHash` + `inputLength`. The input
      holds the task, the plan, the latest verdict, loop-back feedback and earlier steps' outputs: the handoff payload.
    - `agent_assigned`: an agent was given work for the step. `agentName`, `role`, `model`, `readOnly`, `branch`,
      `agentLog` (path of its file, relative to this folder's root), `messageHash` + `messageLength` (the message it
      was sent; the matching `launch` has the same `turnPromptHash` unless turns were joined).
    - `handoff`: an agent called an Ensemble tool. `tool` (submit_plan, submit_verdict, submit_result, create_pin,
      ask_human, message_agent, propose_run, ...), `payload`.
    - `step_finished`: `status` (succeeded, failed, cancelled), `outcome`, `costUSD`, `iteration`, `durationMS`,
      `outputPreview`, and `output` (inline JSON) or `outputHash` + `outputLength`.
    - `condition_evaluated`: `expression` (the step's condition), `labels`, `diff`, `outcomes` (latest outcome per
      step), `result`.
    - `routed`: `from`, `to`, `outcome`, `isLoopBack`, `loopCount` (times this route was taken), `maxLoops`,
      `nextIteration`, `feedback` (what a loop-back sends to the earlier step).
    - `hold`: the run waits for the user and a chat request was created. `reason` (plan_approval, approval,
      loop_limit, step_budget, run_budget, step_failed, timed_out), `requestKind`, `requestId`, `outcome`, `title`,
      `body`.
    - `chat_request`: a chat request created without holding the run (notify steps). `kind`, `title`, `body`.
    - `hold_resolved`: the user answered a hold. `reason`, `decision` (approved, rejected, changes_requested,
      continue, retry, fail), `response` (the user's text, such as a rejection note or change request), `waitMS`
      (since the inbox item was created), `requestId`.
    - `budget`: `event` exceeded (with `runCostUSD`, `runBudgetUSD`) or decision (`proceed`, `previousBudgetUSD`,
      `newBudgetUSD`, `runCostUSD`).
    - `step_failed`: `error`, `errorType`, `onFailure` (the step's setting), `attempt`.
    - `failure_action`: what the engine did next: `action` retry, fail, ask, or ask_after_timeout.
    - `question_relayed`: an agent called ask_human. `target` lead (batched to the request lead) or user (inbox),
      `body`, `questions`.
    - `questions_delivered`: a batch of relayed questions was sent. `target` lead or user_chat, `count`, `agents`,
      `agentIds`.
    - `question_answered`: `via` lead (its message_agent reply) or user (inbox answer), `answer`, `waitMS` (since the
      question was asked).
    - `run_control`: `action` pause, resume, cancel, retry_step or recover, with the resulting `status`.
    - `run_finished`: `status` (succeeded, failed, cancelled), `totalCostUSD`, `durationMS`, `outcome`, `lastError`,
      `pushedAt`, `deliveryBranch`, `iterationsPerStep` (highest iteration per step), `rowsPerStep` (attempts
      per step, counting retries).

    ## Retention

    The folder is capped at 1 GB. At launch, and at most once a minute or after every 8 MB written, Ensemble deletes
    whole `runs/*` and `chats/*` folders, the least recently modified first, until the total fits. Folders written
    since the last check go last. Then it deletes prompt files last used more than 10 minutes before the oldest
    remaining folder was created. A prompt file's modification date marks its last use: it is refreshed when an event
    references it again, at most once every 10 minutes.
    """#
}
#endif

# Hat: Self-Verify (add-on)

Before reporting DONE on any non-trivial task, spawn a reviewer sub-agent
to audit your work. Optionally spawn a QA sub-agent for real-env
verification. This is the reflection loop — you own the sub-agents and
are responsible for their output.

## When to self-verify

- You wrote code that will be merged, deployed, or depended on
- The task was non-trivial (more than a small isolated change)
- No reviewer exists in the roster — check first:

```bash
bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role reviewer
```

If a reviewer exists: **message them directly instead of spawning**.
Spawning a duplicate wastes a pane.

## When to skip self-verify

- The change was minor and you are certain of correctness
- An existing reviewer or QA is already in the roster
- The task was explicitly scoped as exploratory / throwaway

---

## The review loop

### 1. Spawn a reviewer sub-agent

```bash
add-agent reviewer claude --parent <your_id> --id <your_id>.reviewer
```

### 2. Send a REVIEW_REQUEST

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" send <your_id>.reviewer REVIEW_REQUEST \
  "Task: <task_id or description>
Files changed: <list of files>
Contract ref: <.agents/contracts/<name>.md or 'none'>
What I tested: <env, commands run, output seen>
Key concerns: <anything you're unsure about>" \
  --from <your_id>
```

### 3. Wait for VERDICT

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox <your_id>
```

- **PASS** → proceed to step 5
- **FAIL** / **PARTIAL** → address every finding, then loop back to step 2
- If the reviewer raises a blocker you cannot resolve:
  block the task and escalate to the orchestrator (or human) rather than
  shipping anyway

### 4. Iterate until PASS

Each re-review cycle:
1. Make the changes
2. Re-test
3. Re-send REVIEW_REQUEST with "Re-review: addressed <finding summary>"

### 5. Tear down the reviewer

```bash
remove-agent <your_id>.reviewer
```

---

## Optional: QA sub-agent for real-env verification

Use this when the task has side effects that need real-environment
confirmation: migrations, API changes, infra changes, anything that
could break prod silently.

```bash
add-agent qa claude --parent <your_id> --id <your_id>.qa

bash "$ORCHESTRATION_HOME/lib/protocol.sh" send <your_id>.qa TASK \
  "Verify: <what to test>
Environment: <dev/staging/local>
Expected behaviour: <what should happen>
Pass criteria: <explicit definition of done>" \
  --from <your_id>

# Wait for DONE, check inbox
bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox <your_id>

# Tear down
remove-agent <your_id>.qa
```

---

## Reporting up

Once reviewer (and optional QA) have passed, report DONE to the
orchestrator. **Include what the sub-agents verified** — the orchestrator
sees only you; you own their output.

```bash
bash "$ORCHESTRATION_HOME/lib/tasks.sh" complete <task_id> <your_id> \
  --note "Reviewed by <your_id>.reviewer: PASS. QA verified on <env>."

ORCH=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role orchestrator | head -1)
if [[ -n "$ORCH" ]]; then
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" send "$ORCH" DONE \
    "Task: <id>
Changed: <files>
Review: PASS (<your_id>.reviewer)
QA: <PASS on <env> / skipped — why>
Unresolved: none" \
    --from <your_id>
fi
```

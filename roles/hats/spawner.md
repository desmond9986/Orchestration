# Hat: Spawner (add-on)

You can spawn sub-agents on demand. Use this when you need specialized
help your team doesn't currently provide, or when parallel exploration
would speed things up.

## When to spawn a sub-agent

- You need a QA check but no QA exists
- You need to explore several alternatives in parallel
- You need a one-off review but your team has no reviewer
- Your task has become large enough to benefit from a sub-coder

## When NOT to spawn

- The work is small enough to do yourself
- An existing agent in the roster already has the right role — message
  them instead
- You're spawning to avoid owning the problem — don't

## How to spawn

```bash
# add-agent creates a new agent in the current session and injects the role + protocol.
# Use --parent <your_id> so the hierarchy is tracked.
add-agent <role> <model> --parent <your_id> --id <your_id>.<role>
```

Example: if you are `coder-1` and need a QA check:

```bash
add-agent qa claude --parent coder-1 --id coder-1.qa
```

The sub-agent appears in the roster with `parent=coder-1`.

## Delegating work to your sub-agent

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" send <sub_id> TASK \
  "<what you want them to do>" --from <your_id>
```

Wait for their `DONE` (check your inbox), then incorporate or report up.

## Tearing down

When you're finished with the sub-agent, remove them:

```bash
remove-agent <sub_id>
```

You are responsible for cleanup. Leaving zombie panes clutters the
session.

## Reporting up

Your sub-agent's work is your responsibility. When you report DONE to the
orchestrator, include what your sub-agent did and verified, as if you did
it yourself. The orchestrator sees only you; you own the sub-agent's
output.

# Pattern Selection

## Quick chooser

Use this order:
1. If task is small and sequential: `lonely-coder`.
2. If task is single-track but needs review: `review-loop`.
3. If task is broad and parallelizable: `swarm` or `ship-it`.
4. If task needs design first: `plan-execute`.
5. If root cause is unknown bug: `debug-squad`.
6. If you only need research/design output: `spike`.

## Tradeoffs

- More agents improve parallelism but increase coordination overhead.
- Dedicated review (`review-loop`, `ship-it`) improves quality consistency.
- Design-first patterns (`plan-execute`, `pipeline`) reduce mid-implementation thrash.

## Practical recommendation

Default to `lean` unless there is a clear reason to move up/down complexity.

## Patterns reference

| Pattern | Best fit | Main risk |
|---|---|---|
| `lonely-coder` | tight loop, small change | missed review issues |
| `lean` | general feature work | orchestrator bottleneck if overloaded |
| `review-loop` | focused quality gate | less parallel throughput |
| `swarm` | broad independent subtasks | drift/inconsistency between coders |
| `ship-it` | parallel work + unified review | higher token/runtime cost |
| `plan-execute` | architecture-sensitive implementation | extra upfront planning time |
| `pipeline` | strict staged delivery | slower overall latency |
| `debug-squad` | complex bug/root cause unknown | team can idle if scope unclear |
| `spike` | discovery/design | no direct implementation output |
| `full-team` | high-stakes large change | heavy coordination overhead |
| `freeform` | custom orchestration | manual configuration mistakes |

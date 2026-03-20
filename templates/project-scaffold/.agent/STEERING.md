# Orchestrator Steering

Edit this file to redirect the Orchestrator mid-run.
The Orchestrator reads this at the START of every iteration.

Current directive: **continue**

<!--
Options:
- "continue"                          → proceed normally
- "stop"                              → finish current task, stop loop
- "pause"                             → finish current task, stop, alert PM
- "reprioritize: task-005 first"      → move task-005 to top of queue
- "skip: task-003"                    → mark task-003 as skipped
- "focus: only auth tasks"            → filter to matching tasks only
- Any custom instructions             → orchestrator follows, then resumes
-->

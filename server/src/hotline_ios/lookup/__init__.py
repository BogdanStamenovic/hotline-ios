"""Mid-call lookups for duplex calls: a watcher on his side of the line decides when a
question needs Claude, an answerer replies from the calling agent's context file (plus a
read-only, sandboxed bash), and the answer is teacher-forced into PersonaPlex.

See docs/DUPLEX-CALLS.md for the context-file format and the measurements behind the design.
"""

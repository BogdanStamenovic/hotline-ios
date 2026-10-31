"""What hotline-calld does to this daemon when it rings him, for the app tests.

Rings are placed by hotline-calld now (the hotline-call repository). It writes
each call into this daemon's store through `/api/v1/conversations/*`, and these
tests drive that seam the same way, over real HTTP, instead of placing a call.
"""

import uuid


def ring(post, port, reason, *, agent=None, source="Claude", context=""):
    """Open a ring conversation the way hotline-calld's AppMirror does."""
    conversation = uuid.uuid4().hex[:12]
    post(port, "/api/v1/conversations/open",
         {"conversation": conversation, "agent": agent, "kind": "ring"})
    post(port, "/api/v1/conversations/append",
         {"conversation": conversation, "kind": "claude", "text": f"{source}: {reason}"})
    if context:
        post(port, "/api/v1/conversations/append",
             {"conversation": conversation, "kind": "summary", "text": context})
    return {"conversation": conversation, "call_id": conversation}

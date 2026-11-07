# UI reference gap — updated board implementation

Go now has a multi-column board, project/search filters, mobile task details,
plans/checklists, authored worklogs, threaded comments, activity, linked PRs and
walkthroughs. UI and CLI use the same durable backend. See
[the guide](GO_BOARD_GUIDE.md) and [support matrix](GO_BOARD_COMPATIBILITY.md).

This is comparable board functionality, not full visual or runtime parity with
Linear or the README video. Plans/comments are operator authored. PR links and
imported reports are labeled unverified. Fixture workers are timers. Optional
GitLab discovery reads real issue metadata, but Go cannot run real agents.

Remaining gaps include real orchestrator dispatch/worker observations, provider
comments and MR discovery, arbitrary pagination, provider stage writes, multi-user
authorization, multi-tenant scheduling and verified merges. These require an
explicit integration contract with the existing execution owner; a second Go
scheduler is not introduced. No live provider credentials were used in tests.

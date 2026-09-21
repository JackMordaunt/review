# Commit hygiene

You are given a commit message, the per-file statistics, and the subjects of recent
commits in the same repository.

- `message-omits-a-change` — the diff contains a change the message does not
  describe. A rename swept into a commit about something else is the common case.
- `message-claims-more` — the message describes work the diff does not contain.
- `two-changes` — the diff is two unrelated changes that should be two commits.
  Judge by whether one could be reverted without the other.
- `subject-not-local-style` — the subject departs from the convention visible in the
  recent subjects you were given. Follow what the repository does, not a house style
  from elsewhere; if the recent subjects disagree with each other, say nothing.
- `body-explains-what-not-why` — the body restates what the diff shows instead of
  saying why it was done.

The statistics are enough to notice a commit doing two things. Do not ask to see more.

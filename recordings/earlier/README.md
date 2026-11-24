# Answers recorded for earlier requests

Each folder holds real model answers and the two files the request they answered was built from: the prompt and the
findings summary. A test rebuilds each request from these two files with the current code and checks its sha256, so
the answers still earn the label "Recorded" against the request they answered. They are kept for what they show about
the checks (docs/DESIGN.md); the demo does not use them.

- `first-request/`: two answers to the request with sha256
  12363a8e5f91e572a60ea8d0beb5397eac8a7969bace6f5d1917612caa2d1fea, the five-rule version on the thirteen accounts
  (`first-request/prompt-brief.txt` and `first-request/findings-summary.json`).
- `second-request/`: two answers to the request with sha256
  4a66f63a742bf321c950aa8618353c595d3a158e464fc9609cb21e8db5391cee, the eight-rule version on the invented tenant as
  it stood before the request changed (`second-request/prompt-brief.txt` and `second-request/findings-summary.json`).

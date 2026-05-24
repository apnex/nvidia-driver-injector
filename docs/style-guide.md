# Documentation style guide

Running record of doc-style decisions made on this project. Apply
uniformly to new docs; reference by rule ID in commit messages when
applying. Forward-applicable to consumer-side docs (vLLM repo, kate
repo) and any future repos.

Each rule has: **statement**, **rationale**, **good/bad examples**,
**origin** (which finding surfaced it).

---

## S1 — Prerequisites: explicit, cluster-agnostic, assumes authenticated kubectl

**Statement.** Every workflow doc that uses `kubectl` must state in
its prerequisites:

1. Steps work on **any Kubernetes cluster** (k3s, kind, kubeadm, EKS,
   GKE, RKE2, …). k3s is the project's reference setup on this
   single-host deployment, not a requirement.
2. The doc **assumes authenticated kubectl** — `kubectl get nodes`
   returns 0 without flags. How the operator achieved that (kubeconfig
   path, sudo, RBAC, etc.) is out of scope for the doc.

**Rationale.** Tying the docs to k3s specifically excludes operators
on other Kubernetes distributions for no functional reason — the
patches + the consumer contract are pure Kubernetes constructs.
Authenticated-kubectl is the standard contract for any k8s doc; not
restating "set KUBECONFIG=..." in every doc avoids drift and matches
operator expectations.

**Example — bad:**

> Path B: k3s installed (`systemctl is-active k3s`) **and**
> `nvidia-container-toolkit` installed.

**Example — good:**

> Path B: **Kubernetes cluster** (any distribution) with kubectl
> authenticated against it. Verify:
> ```bash
> kubectl get nodes
> ```
> Reference setup: k3s on a single host. Also requires
> `nvidia-container-toolkit` installed on the host.

**Origin.** 2026-05-24 strict-mode test-drive of the teardown workflow
surfaced that KUBECONFIG was undocumented across all user-facing docs
AND the prereq tied the workflow gratuitously to k3s.

---

## S2 — Runnable workflow steps belong in code blocks

**Statement.** Any command the reader is expected to **execute as a
workflow step** must appear in a fenced code block. Inline backtick
mentions of commands in prose are fine when they're **referencing**
(what does this command do? what flag should I think about?) rather
than **directing** (now type this).

The distinguishing test: would the operator copy-paste this to run
right now, as part of the linear workflow being described? If yes →
code block. If they're just being told a command exists for
context/troubleshooting/identification → inline backticks fine.

**Rationale.** Code blocks signal "copy and execute"; inline backticks
signal "this is the name of a thing." Mixing them confuses
copy-pasters, breaks code-block tooling (syntax highlighting, copy
buttons, doc renderers), and turns a workflow doc into a prose
treasure hunt.

**Example — bad (workflow step in prose):**

> To verify the cluster is healthy, run `kubectl get nodes` and check
> STATUS is Ready.

**Example — good (workflow step in code block):**

> To verify the cluster is healthy:
> ```bash
> kubectl get nodes
> ```
> Expect a node with STATUS=Ready.

**Example — also good (reference mention, no execution implied):**

> The `kubectl rollout status` command is documented to take up to
> 60 seconds before declaring failure.

**Origin.** 2026-05-24 strict-mode test-drive — operator following
docs verbatim shouldn't have to interpret prose to extract the next
command to type.

---

## Conventions used so far (back-fill candidates)

These are existing patterns in the live docs. Not every one is a
codified rule yet — listed here so they're visible for future
codification or back-fill.

- **Four-journey README pattern** (install / use / test / remove)
  applied to top-level READMEs.
- **Path A vs Path B labeling** for dual-substrate workflows
  (docker-compose vs k3s). Each path is independently followable;
  shared prerequisites + steps are factored out.
- **Producer / consumer split**: producer (driver-injector) publishes
  contract + DaemonSet; consumer (vLLM, kate, …) owns its own
  Deployment + Service + state. Contract lives in producer repo;
  implementation lives in consumer repo.
- **Frozen-history rule**: design-record artifacts under
  `docs/superpowers/plans/` + `docs/superpowers/specs/` + per-patch
  `intents/reviews/improvements/` are NOT rewritten on policy
  changes. Rewriting them would falsify the historical record.
- **Honest yield reporting**: status summaries lead with bug count
  + drift findings before architecture / philosophy.
- **`reviewer:` frontmatter is artifact-authorship**, distinct from
  git commit attribution. Per
  `feedback_no_claude_attribution_in_commits` memory: no
  `Co-Authored-By: Claude` trailers in commits; `reviewer: <name>` in
  catalog frontmatter is the documented artifact-attribution pattern.

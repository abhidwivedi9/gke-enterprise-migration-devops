# Interview Guide

How to talk about this project.

**The framing that works:** you are not presenting a demo you built. You are
describing a migration you supported and the operational system you built around
it. The interesting part is never the YAML — it's the decisions, the trade-offs,
and the failures you can describe from having caused them on purpose.

---

# The 5-minute version

> **"In this project I supported the migration of an existing enterprise
> application — an order-retrieval API — from on-premises VMs to GCP and GKE, and
> then owned its operational lifecycle afterwards.**
>
> **The starting point** was two VMs behind an F5, deployed by `scp` and
> `systemctl restart`. No rollback beyond keeping the previous tarball. No
> autoscaling. No real way to answer "what version is running?" — you SSH'd in
> and read a file. Deploys dropped in-flight requests.
>
> **The target** is a zonal GKE cluster, VPC-native with private nodes,
> deployed by Helm from GitHub Actions. Terraform provisions the network, the
> cluster, Artifact Registry, and least-privilege IAM.
>
> **Three decisions I'd call out:**
>
> **First, keyless authentication throughout.** CI authenticates to GCP via
> Workload Identity Federation, and pods authenticate via Workload Identity.
> There isn't a service-account JSON key anywhere in the project. A key never
> expires, works from anywhere, and is the most common root cause of real GCP
> compromises — the only way to guarantee one doesn't leak is not to have one.
>
> **Second, cost is a design constraint, not an afterthought.** Zonal rather than
> regional, because a regional cluster runs the node pool in three zones and
> triples the compute bill. Spot VMs. Private Google Access instead of Cloud NAT
> — that's a security improvement that also saves about $32 a month. Every
> expensive option is behind a flag that defaults to off, and there's a teardown
> script that destroys via Terraform and then *independently verifies* nothing
> survived, because Terraform only knows about what's in its state file.
>
> **Third — and this is the part I'd actually want to talk about — version
> verification.** A deployment can report SUCCESS at every layer and still run
> the wrong code. Helm says deployed, the Deployment says 3/3, the pipeline is
> green, and the application is serving last week's build. So I wrote a script
> that walks nine layers — git commit, registry digest, Helm release, Deployment
> spec, ReplicaSet, pod spec, the *running container's* image digest, and finally
> the application's own `/version` endpoint — and refuses to agree with any of
> them until the running process confirms it. It's a gate in the pipeline, so
> SUCCESS means something.
>
> **On the operations side** there are runbooks for troubleshooting, rollback and
> incident response, a Cloud Monitoring dashboard with eight alert policies, and a
> failure lab with fifteen injectable failures — CrashLoopBackOff, OOMKilled,
> readiness failures, a PDB that blocks node drains, an HPA that silently never
> scales.
>
> **What I validated and what I didn't:** everything runs on a local kind
> cluster, and I verified it there — the Helm deploy, HPA scaling with live
> metrics, and a full bad-release-to-rollback cycle where I injected a 30% error
> rate, confirmed every probe stayed green, rolled back, and confirmed recovery.
> The GKE-specific pieces are schema-valid and reviewed but not applied against a
> live project, because the billing account I had available was closed. The
> repository says exactly that rather than implying otherwise."**

**Why this works:** it opens with the problem, names concrete trade-offs with
reasons, has one genuinely interesting technical idea at its centre, and ends by
distinguishing what was proven from what wasn't. That last part reads as
seniority, not as a gap.

---

# The 15-minute deep dive

## 1. The migration (2 min)

Lead with **discovery**, because that's where migrations actually succeed or
fail.

> "The first question I ask is whether the workload is genuinely stateless.
> Local file writes, in-memory sessions, singleton background jobs — any of those
> turn a two-week migration into a six-month one. This one was clean.
>
> Three things from discovery that nearly always bite:
>
> — **The pod CIDR is not the node CIDR.** Every firewall rule written against
> the old VM subnet has to be rewritten against the pod secondary range.
> Otherwise you get connection timeouts that look like application bugs.
>
> — **Third parties allowlisting your old egress IP.** Payments fail at cutover
> and nobody remembers why.
>
> — **The DNS TTL.** If it's 3600 seconds, a rollback that requires a DNS change
> takes an hour. That isn't a rollback, it's an outage with extra steps. You lower
> it 24 hours ahead.
>
> Cutover was staged: deploy with no traffic, then 10% by DNS weight, then 50%,
> then 100% — and the old VMs stay running for two weeks. Rollback is a DNS weight
> change. That's the cheapest insurance in the project."

## 2. Infrastructure (3 min)

Pick the decisions with real trade-offs.

> "**Zonal, not regional.** Regional replicates the control plane across three
> zones *and* runs your node pool in each — so `node_count = 1` becomes three VMs.
> Regional is right for production; zonal is right for a cost-controlled
> rehearsal. I'd say that explicitly rather than pretend zonal is production-grade.
>
> **VPC-native with two secondary ranges** — one for pods, one for services.
> The thing people get wrong is that **secondary ranges can't be resized in place
> while in use**. Undersize them and you rebuild the cluster to grow. I sized pods
> at a /14, which supports about a thousand nodes and costs nothing.
>
> **Private nodes with Private Google Access, and no Cloud NAT.** Nodes have no
> external IP but still reach Artifact Registry and Cloud Logging over Google's
> internal network. Security improvement, and it avoids a $32/month NAT gateway.
>
> **Least-privilege node service account.** GKE defaults to the Compute Engine
> default SA, which has project-wide Editor. Any pod that escapes its container,
> or just reads the node metadata endpoint, inherits that. Replacing it with an SA
> that has four narrow roles is the highest-value, lowest-effort GKE hardening
> step there is."

## 3. The pipeline (3 min)

> "Build, test, scan, push, deploy, **verify**, validate.
>
> The build bakes identity in via `--build-arg` — version, commit, branch,
> timestamp — and then *asserts* the baked-in version matches what was requested.
> That catches a broken ARG/ENV chain in seconds instead of during a production
> version check.
>
> Auth is OIDC. GitHub mints a token describing the exact repo and ref; GCP
> validates it against an attribute condition and exchanges it for a one-hour
> token. **The attribute condition is the critical line** — without it, any
> GitHub repository on the internet can mint a token your provider accepts.
>
> After the push, the pipeline resolves the **digest** and deploys by digest, not
> tag. Combined with immutable tags on the registry, that makes the deploy
> byte-for-byte deterministic.
>
> `helm upgrade --wait --atomic`. Without `--wait`, Helm returns 0 the moment the
> API server accepts the YAML — it never looks at whether pods started. `--atomic`
> rolls back automatically if they don't.
>
> Then version verification, then a smoke test that issues **twenty** requests
> against a business endpoint. Not one. One request against a 30% failure rate
> passes 70% of the time — that's a real detection gap, and it's how a bad release
> gets through a green pipeline."

## 4. Version verification (3 min) — spend the most time here

> "Every layer reports on its own job, and every one can be truthfully green
> while the wrong code is running.
>
> GitHub Actions asserts that every step exited zero. `docker push` asserts bytes
> were uploaded — not that the tag still points at them. `helm upgrade` asserts
> the API server accepted the manifests. `rollout status` asserts the new
> ReplicaSet reached its count — not that the ReplicaSet references the image you
> meant. None of them answers *is version 2.4.17 serving requests right now?*
>
> There are about nine ways it goes wrong. The mutable tag overwritten by a
> re-run. `imagePullPolicy: IfNotPresent` reusing a cached layer, so the node
> never contacts the registry. Bumping `appVersion` in Chart.yaml, which changes
> what Helm *reports* and nothing about what runs. And the nastiest one: a
> half-finished rollout, where some pods are new and some are old, so the bug is
> fixed two times in three and averaged dashboards hide it entirely.
>
> The detail I'd want an interviewer to hear: in the pod status there are two
> different fields. `.spec.containers[0].image` is what was **requested**.
> `.status.containerStatuses[0].imageID` is the digest the kubelet actually
> **resolved and started**. When a mutable tag has been overwritten, those
> disagree, and only `imageID` tells the truth.
>
> And the prevention: immutable tags, digest-pinned deploys, a `/version`
> endpoint baked at build time, and a pipeline gate that fails when they
> disagree."

## 5. Operations and failure (3 min)

Lead with the incident you can describe in detail.

> "The scenario I'd pick is: users report intermittent 500s, and every Kubernetes
> signal is green. Pods Ready, probes returning 200, `kubectl get pods` says
> nothing is wrong.
>
> I built that as a failure-lab scenario and ran it. 30% of requests returning
> 500, two healthy pods, both probes green.
>
> The method is to quantify first — what percentage, since when, which endpoints
> — and then walk the request path in order: load balancer, ingress, **Service
> endpoints**, pods, container resources, application logs, dependency. Endpoints
> is the highest-yield check: one line tells you whether traffic is routed at all,
> and *fewer endpoints than replicas* is the classic cause of intermittent
> failures.
>
> Because the app logs structured JSON, one query splits the diagnosis:
> group the 500s by pod. One pod failing means restart it and look at its node.
> All pods means a bad version or a shared dependency.
>
> Then: **roll back first, root-cause second.** I timed it — three minutes from
> decision to a confirmed 60-out-of-60 success rate. You can debug a bad image at
> leisure once it's out of production.
>
> The lesson I'd draw is that Kubernetes health tells you the *platform* is happy.
> It says nothing about whether users are being served. Which is why the most
> important alert in the whole project is on the 5xx rate, not on pod health."

## 6. Probes — worth 60 seconds if asked (1 min)

> "Three probes, three different questions, and using one endpoint for all three
> is the most common mistake.
>
> Startup: has it booted? While it's failing, liveness and readiness are
> suspended — that's what lets a slow-booting app coexist with an aggressive
> liveness probe.
>
> Liveness: is the process wedged? Failing it restarts the container, so it must
> be forgiving, and it must **never check a dependency**. If it did, a database
> blip would restart every replica simultaneously and turn a partial outage into a
> total one.
>
> Readiness: should traffic come here right now? This *should* check dependencies,
> because failing it is cheap — the pod leaves the Service but stays alive and
> recovers."

---

## The three stories to have ready

Interviews reward specifics. Have these at your fingertips:

**1. The 30%-error rollback.** Injected the failure, measured 17 failures out of
60 with both probes green, rolled back, measured 60 out of 60. Three minutes.
Names the detection gap: a one-request smoke test would have passed.

**2. The exit-code correction.** The app calls `sys.exit(1)`. The container
reports exit **3**, because uvicorn catches `SystemExit` and exits with its own
code. So you can't diagnose from an application exit code when a supervisor sits
between the code and PID 1 — only 137 (SIGKILL/OOM) and 143 (SIGTERM), which
originate outside the process, are reliable. *You only learn that by running it.*

**3. The awk bug in your own dashboard.** `kubectl get hpa --no-headers` prints
TARGETS as `cpu: 12%/70%` — two whitespace-separated tokens — so every positional
column after it silently shifted. Fixed with `-o jsonpath`. It's a good story
because it's the kind of bug that only appears when you actually run your tooling,
and the fix is a general principle: never parse kubectl output positionally.

---

## Questions to ask them

These signal that you've operated systems rather than built demos:

- "How do you verify that the version you intended is the version running?"
- "What's your rollback time, and when did you last actually measure it?"
- "Do you alert on error rate, or on pod health?"
- "Are your image tags immutable?"
- "How does CI authenticate to the cloud — keys, or workload identity?"
- "What happens if a node drain hangs during a cluster upgrade?"
- "Who decides to roll back during an incident?"

---

## Traps, and how to handle them

**"Why not Autopilot?"**
> "Autopilot is genuinely the better default for most teams — Google manages
> nodes, you pay per pod, and there's less to get wrong. I chose Standard
> deliberately because the node-level concerns are the thing I wanted to
> demonstrate: node service accounts, Workload Identity metadata mode, Spot VMs,
> taints, drains. On Autopilot most of that is abstracted away."

**"This is quite small for an enterprise migration."**
> "It is, deliberately. The scope I cut was breadth — one service, no data tier,
> single region. What I kept was the full operational depth: the pipeline, the
> verification, the failure modes, the runbooks. Adding a second service teaches
> you nothing new; adding a database or multi-region does, and I'd call those out
> as the honest next steps rather than pretend they're covered."

**"Did you actually deploy this to GCP?"**
> "No, and the repository says so explicitly. The billing account available to me
> was closed, so no resources could be created. Everything that could be verified
> locally was — the Helm deploy on a three-node kind cluster, HPA scaling with
> live metrics, the failure scenarios, a real rollback cycle. The GKE-specific
> Terraform passes `terraform validate` against the real provider schema, which
> caught an actual error, but it hasn't been applied. I'd rather say that than
> claim a deployment I didn't do."

That last answer is worth practising. **Being precise about what you have and
haven't proven is a senior trait**, and interviewers notice when someone
volunteers it rather than being caught out.

---

## What not to do

- Don't walk through the repository directory by directory. Lead with problems.
- Don't claim the GCP deployment ran.
- Don't say "best practice" without the reason. Every value in this project has a
  reason; use it.
- Don't oversell the scale. "Two VMs, one service" is a fine, honest starting
  point.
- Don't skip the failures. **The failure lab is the most interesting thing here**
  — it's evidence you've debugged, not just deployed.

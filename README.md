# Kueue Lab — schedule GPU jobs on a laptop (no GPUs required)

**No GPUs needed.** We simulate them: each fake node advertises `nvidia.com/gpu`
capacity, so the scheduler counts and places GPUs for real even though there's no
hardware behind them. The GPUs are fake, but the scheduling is the real thing.

---

## What you'll build

A 2-rack "datacenter" of 4 fake GPU servers (32 fake GPUs total — each node is a
standard 8-GPU HGX H100 box):

```
zone az1
├── rack1   (NVLink domain A)
│   ├── gpu-node-1   8 GPUs
│   └── gpu-node-2   8 GPUs   → 16 GPUs/rack
└── rack2   (NVLink domain B)
    ├── gpu-node-3   8 GPUs
    └── gpu-node-4   8 GPUs
```

Then a handful of jobs, each making one idea concrete:

| Job | What it shows |
|-----|---------------|
| `01-single-gpu`   | The happy path — a job opts into Kueue with one label and gets admitted (1 GPU). |
| `02-topology-gang`| **Gang admission** (all-or-nothing) plus **required topology** — an 8-GPU job, a full node's worth, kept entirely in one rack. |
| `03-over-quota`   | **Queueing** — a 12-GPU job; submit it while the gang holds 8 (8+12 is over the 16 cap), watch it wait, then get admitted on its own when the gang frees up. |
| `04-team-b`       | **Multi-tenancy** — a second team's 16-GPU job that claims its whole quota (a full rack). Run it alongside team-a and watch both go in parallel on separate racks, each capped at its own 16-GPU pool. |
| `05`+`06`         | **Priority & preemption** — a low-priority batch fills team-a's pool, then a high-priority job evicts part of it to get GPUs now. The batch drops back to waiting and resumes once the urgent job finishes. |
| `07`+`07a`        | **Preferred vs required topology** — a job that *prefers* one rack but spills across both rather than wait, the soft counterpart to job 2's strict rule. (`07a` fragments the cluster first so there's a reason to spill.) |

---

## Prerequisites

Install these before class (all free, all run locally):

- **Docker** — Docker Desktop, Rancher Desktop, OrbStack, or native Docker. Must be running.
- **[kind](https://kind.sigs.k8s.io/)** ≥ 0.27 — runs Kubernetes nodes as containers.
- **kubectl** ≥ 1.30.
- *(optional)* **[k9s](https://k9scli.io/)** — a nicer terminal UI for watching the cluster.

Quick check:
```bash
docker info >/dev/null && echo "docker ok"
kind version && kubectl version --client
```

Tested with: kind v0.30, kubectl v1.34, Kueue **v0.18.1**, on macOS (Rancher Desktop)
and Linux. ~2 GB free RAM for Docker is plenty.

---

## Run it

The fastest path — one command brings the whole lab up:

```bash
cd kueue-lab
./scripts/up.sh
```

…but you'll learn more running the four numbered steps yourself and reading what
each prints:

```bash
./scripts/01-create-cluster.sh   # multi-node kind cluster
./scripts/02-label-nodes.sh      # fake topology labels + fake GPUs
./scripts/03-install-kueue.sh    # install Kueue + enable topology-aware scheduling
./scripts/04-apply-kueue.sh      # Topology, ResourceFlavor, ClusterQueue, LocalQueue
```

Then submit jobs and watch. **Open a second terminal for the watcher** — the
visual one shows the datacenter filling up live:

```bash
# terminal 2 — the live datacenter view (GPU slots, quota bar, queue)
./scripts/watch-viz.sh
```
```text
  FAKE GPU DATACENTER   (● used   ○ free)

  rack1  ·  one NVLink domain
  ┌─ gpu-node-1 ──────┐  ┌─ gpu-node-2 ──────┐
  │ ● ● ● ● ● ○ ○ ○   │  │ ● ● ● ○ ○ ○ ○ ○   │
  │ topo-gang         │  │ topo-gang         │
  └───────────────────┘  └───────────────────┘
  ...
  RUNNING NOW
    ● topo-gang       8 GPU   ████████  (rack1)

  WAITING IN LINE          free now: 8 GPU
    #1 big-batch      12 GPU   needs 4 more ⏳

  QUOTA  nvidia.com/gpu  [████████░░░░░░░░] 8/16
```

The board has two lanes: **RUNNING NOW** (admitted jobs, with the rack they
landed in) and **WAITING IN LINE** (ordered, each showing how many more GPUs it
needs before it can be admitted). Watch a job jump from the waiting lane to the
running lane the instant the gang ahead of it finishes — that's Kueue admitting
it automatically.

```bash
# terminal 1 — submit jobs and watch terminal 2 react
kubectl apply -f jobs/01-single-gpu.yaml      # a slot fills on one node
kubectl delete -f jobs/01-single-gpu.yaml     # it frees again

kubectl apply -f jobs/02-topology-gang.yaml   # 8 slots fill — all in one rack
kubectl apply -f jobs/03-over-quota.yaml       # team-a queues behind itself: WAITING, then auto-ADMITTED

# multi-tenancy: a second team, running in parallel on the other rack
kubectl apply -f jobs/04-team-b.yaml           # team-b fills rack2 while team-a is on rack1

# priority + preemption: urgent work evicts a running batch to get GPUs
kubectl apply -f jobs/05-low-priority.yaml     # fills team-a at low priority
kubectl apply -f jobs/06-high-priority.yaml    # preempts part of it, runs now

# preferred vs required topology: a job that spills across racks instead of waiting
kubectl apply -f jobs/07a-fragmenter.yaml      # busy one node per rack
kubectl apply -f jobs/07-topology-spill.yaml   # 10 GPU — board shows "split: rack1+rack2"
```

The board shows each team as its own block with its own quota bar. Run job 2
(team-a, 8 GPU on rack1) and job 4 (team-b, 16 GPU filling rack2) together: both
go green at once, on different racks — team-a at 8/16, team-b at 16/16 of its own
pool. Add job 3 (team-a, 12 GPU) on top and watch it *wait* — team-a is queuing
behind itself — while team-b keeps running untouched. That's the key lesson:
team-a can't borrow team-b's idle GPUs; each slice is fixed.

Prefer raw Kubernetes objects over the diagram? `./scripts/watch.sh` shows the
same thing as plain `kubectl get workloads / clusterqueue / pods` tables.

Compare what you see to [`expected/expected-outputs.txt`](expected/expected-outputs.txt).

Tear it all down (nothing persists afterward):
```bash
./scripts/down.sh
```

---

## Suggested teaching sequence

Work through these as five beats, watching `./scripts/watch-viz.sh` in a second
terminal the whole time. Reset between beats with `kubectl delete job --all -n
default` unless the beat says to stack jobs.

| Beat | Run | Together? | What they see |
|---|---|---|---|
| 1 · admission | `01` | solo | One label opts the job into Kueue; it's admitted and a Workload appears. The "hello world." |
| 2 · gang + topology | `02` | solo | All 8 pods admitted at once (gang) and packed into one rack (required topology). Leave it running — it sets up beat 3. |
| 3 · queueing | `03` on top of `02` | **stacked, same team** | `03` (12 GPU) can't fit team-a's 8 free, so it waits — "needs 4 more." Do nothing; when `02` finishes, `03` is admitted automatically. |
| 4 · multi-tenancy | `02` + `04`, then add `03` | **parallel, two teams** | `02` (team-a) and `04` (team-b) go green at once on different racks. Then `03` waits in team-a's lane while team-b keeps running — fixed slices, no borrowing. |
| 5a · preemption | `05`, let it admit, then `06` | sequential | The low-priority batch fills team-a; the high-priority job evicts part of it to run now. The batch drops back to waiting and reclaims when `06` finishes. |
| 5b · preferred topology | `07a`, let it admit, then `07` | sequential | `07a` busies one node per rack; `07` then can't fit any single rack, so (being *preferred*) it spills — the board shows `split: rack1+rack2`. Contrast with beat 2's strict single-rack rule. |

Two rules worth stressing:
- **Reset between beats** (`kubectl delete job --all -n default`) except beats 3 and 4, where stacking *is* the lesson.
- **In beat 5, let the first job fully admit before submitting the second.** Race them and the scheduler may just slot the second into free space — you won't see the eviction (5a) or the spill (5b).

---

## The pieces (and the files that create them)

| Kueue object | File | In one line |
|---|---|---|
| **Topology** | `manifests/02-topology.yaml` | The physical hierarchy: zone → rack → host (named by node labels). |
| **ResourceFlavor** | `manifests/03-resourceflavor.yaml` | A hardware class ("an H100 node"); points at the Topology. |
| **ClusterQueue** | `manifests/04-clusterqueue.yaml` | A quota pool. We make **two** — `gpu-team-a` and `gpu-team-b`, **16 GPUs each** — so two tenants split the 32-GPU cluster, each hard-capped at its half. |
| **LocalQueue** | `manifests/05-localqueue.yaml` | A team's entry point (`team-a`, `team-b`) in their namespace → each forwards to its own ClusterQueue. |
| **Workload** | *(auto-created)* | Kueue's internal record of each Job, waiting for admission. |
| **WorkloadPriorityClass** | `manifests/06-priority-classes.yaml` | `low-priority` / `high-priority` — Kueue's own priority levels, used for queue order and preemption (jobs 5 + 6). |

A Job joins all this with **one label**: `kueue.x-k8s.io/queue-name: team-a`
(or `team-b`). It can add `kueue.x-k8s.io/priority-class: high-priority` to set
its priority.

---

## How the simulation works (the two tricks)

1. **Fake GPUs.** `scripts/02-label-nodes.sh` patches each worker's
   `status.capacity` to advertise `nvidia.com/gpu: 8` (an *extended resource*).
   The scheduler treats it like any countable resource — a pod requesting a GPU
   only lands where one is free. No device, no driver, real accounting.
   *(This capacity resets if a node restarts; just re-run step 2.)*

2. **Fake topology.** The same script applies plain node labels
   (`topology.kubernetes.io/zone`, `lab.gpu/rack`). The Topology object lists
   those label keys as its levels, so Kueue knows which nodes are "close."

In production, a **device plugin** advertises real GPUs and the cloud/provider
sets real topology labels — but Kueue reads them exactly the same way.

---

## Troubleshooting

- **Only the control-plane node shows up; workers never become Ready.**
  This is the inotify limit ("too many open files" in worker kubelet logs).
  `scripts/01-create-cluster.sh` raises it automatically in the Docker VM; if you
  created the cluster another way, run:
  ```bash
  docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_instances=8192
  ```
  then re-create the cluster. On native Linux: `sudo sysctl -w fs.inotify.max_user_instances=8192`.

- **Job stays Pending forever (not just waiting for quota).**
  Check the Workload's message:
  `kubectl describe workload -n default <name> | grep -i message`.
  Usually a label mismatch (the flavor's `nodeLabels` don't match your nodes) or
  the queue name typo'd in the Job.

- **`kubectl get workloads` is empty after applying a Job.**
  The Job is missing the `kueue.x-k8s.io/queue-name` label, so Kueue ignored it.

- **Topology gang won't admit.** A `podset-required-topology` of `lab.gpu/rack`
  needs the whole gang to fit in one rack (16 GPUs/rack here). Asking for >16 with a
  *required* rack constraint can never be satisfied — switch to
  `podset-preferred-topology` to allow spilling across racks.

- **Start over clean:** `./scripts/down.sh && ./scripts/up.sh`.

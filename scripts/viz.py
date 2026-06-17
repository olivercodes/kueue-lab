#!/usr/bin/env python3
"""Live datacenter view of the Kueue lab.

Draws the fake GPU datacenter the way the slides draw it: racks side by side,
each node a box of GPU slots that fill in as pods land. Shows the quota pool and
which Workloads are admitted vs waiting. Re-reads everything from the cluster on
each tick, so it stays correct even if you change the topology or quota.

Run:  ./scripts/watch-viz.sh      (wrapper that loops this)
      python3 scripts/viz.py      (single frame)
"""
import json
import os
import subprocess
import sys

NS = "default"

# ANSI — disabled automatically when output isn't a TTY (e.g. piped to a file).
_C = sys.stdout.isatty()
def c(code, s): return f"\033[{code}m{s}\033[0m" if _C else s
def bold(s):   return c("1", s)
def dim(s):    return c("2", s)
def green(s):  return c("32", s)
def yellow(s): return c("33", s)
def cyan(s):   return c("36", s)
def red(s):    return c("31", s)

# A distinct color per job so the same job's pods are easy to track across nodes.
JOB_COLORS = ["32", "36", "33", "35", "34", "31"]


def kubectl_json(args):
    try:
        out = subprocess.run(
            ["kubectl", *args, "-o", "json"],
            capture_output=True, text=True, timeout=15,
        )
        if out.returncode != 0:
            return None
        return json.loads(out.stdout)
    except Exception:
        return None


def get_nodes():
    """Return GPU worker nodes as {name, alias, rack, gpus}, skipping the
    control-plane and any node with no fake GPUs."""
    data = kubectl_json(["get", "nodes"])
    nodes = []
    if not data:
        return nodes
    for n in data.get("items", []):
        labels = n["metadata"].get("labels", {})
        cap = n.get("status", {}).get("capacity", {})
        gpus = int(cap.get("nvidia.com/gpu", 0) or 0)
        if gpus == 0:
            continue  # control-plane / unlabeled nodes don't appear
        nodes.append({
            "name": n["metadata"]["name"],
            "alias": labels.get("lab.gpu/alias", n["metadata"]["name"]),
            "rack": labels.get("lab.gpu/rack", "?"),
            "gpus": gpus,
        })
    nodes.sort(key=lambda x: (x["rack"], x["alias"]))
    return nodes


def get_pod_usage():
    """Map node-name -> list of (job, gpu_count) for Running/Pending-scheduled
    pods that request GPUs."""
    data = kubectl_json(["get", "pods", "-n", NS])
    usage = {}
    if not data:
        return usage
    for p in data.get("items", []):
        spec = p.get("spec", {})
        node = spec.get("nodeName")
        if not node:
            continue
        phase = p.get("status", {}).get("phase", "")
        if phase not in ("Running", "Pending", "Succeeded"):
            continue
        # only count pods that actually hold a GPU
        gpu = 0
        for ctr in spec.get("containers", []):
            req = ctr.get("resources", {}).get("requests", {})
            gpu += int(req.get("nvidia.com/gpu", 0) or 0)
        if gpu == 0:
            continue
        job = p["metadata"].get("labels", {}).get("job-name", p["metadata"]["name"])
        # Succeeded pods have released their GPU — show node as free again.
        if phase == "Succeeded":
            continue
        usage.setdefault(node, []).append((job, gpu))
    return usage


def get_workloads():
    """Return the live workloads as [(name, queue, admitted_bool, gpu, reason)].

    A workload that has finished keeps Admitted=True forever, so we treat
    Finished=True as no longer running and drop it — otherwise completed jobs
    would linger in the "running" lane and the per-team totals wouldn't match
    the GPUs actually in use."""
    data = kubectl_json(["get", "workloads", "-n", NS])
    out = []
    if not data:
        return out
    for w in data.get("items", []):
        name = w["metadata"]["name"]
        spec = w.get("spec", {})
        queue = spec.get("queueName", "?")
        # total GPU requested across pod sets
        gpu = 0
        for ps in spec.get("podSets", []):
            count = ps.get("count", 1)
            tmpl = ps.get("template", {}).get("spec", {})
            for ctr in tmpl.get("containers", []):
                req = ctr.get("resources", {}).get("requests", {})
                gpu += int(req.get("nvidia.com/gpu", 0) or 0) * count
        conds = {cnd["type"]: cnd for cnd in w.get("status", {}).get("conditions", [])}
        if conds.get("Finished", {}).get("status") == "True":
            continue  # done — not holding GPUs anymore
        admitted = conds.get("Admitted", {}).get("status") == "True"
        reason = ""
        if not admitted:
            qr = conds.get("QuotaReserved", {})
            reason = qr.get("message", "") or conds.get("Admitted", {}).get("message", "")
        out.append((name, queue, admitted, gpu, reason))
    return out


def job_color(job, order):
    if job not in order:
        order[job] = JOB_COLORS[len(order) % len(JOB_COLORS)]
    return order[job]


def render_node(node, used_jobs, order):
    """Return a list of text lines for one node box. Every line is exactly
    INNER characters of *visible* content between the borders, so colored
    (ANSI) text never throws the alignment off."""
    INNER = 17                      # visible chars between "│ " and " │"
    # 8 GPU dots render as "● ● ● ● ● ● ● ●" = 15 visible chars; INNER=17 leaves
    # a little breathing room and fits node aliases like "gpu-node-1".
    total = node["gpus"]
    used = sum(g for _, g in used_jobs)

    # GPU dots — filled ones colored by the first job on the node.
    col = job_color(used_jobs[0][0], order) if used_jobs else None
    raw_dots, vis = [], []
    for i in range(total):
        if i < used:
            raw_dots.append(c(col, "●") if col else "●")
            vis.append("●")
        else:
            raw_dots.append(dim("○"))
            vis.append("○")
    dot_raw = " ".join(raw_dots)
    dot_vis_len = len(" ".join(vis))

    # job label line
    if used_jobs:
        names = ",".join(sorted({j for j, _ in used_jobs}))[:INNER]
        label_raw = c(col, names)
        label_vis_len = len(names)
    else:
        names, label_raw, label_vis_len = "idle", dim("idle"), 4

    title = node["alias"][:INNER]
    return [
        "┌─ " + title + " " + "─" * max(0, INNER - len(title) - 1) + "┐",
        "│ " + dot_raw + " " * max(0, INNER - dot_vis_len) + " │",
        "│ " + label_raw + " " * max(0, INNER - label_vis_len) + " │",
        "└" + "─" * (INNER + 2) + "┘",
    ]


def main():
    nodes = get_nodes()
    if not nodes:
        print(red("No GPU nodes found — is the cluster up and step 2 applied?"))
        print(dim("Try: ./scripts/01-create-cluster.sh && ./scripts/02-label-nodes.sh"))
        return
    usage = get_pod_usage()
    workloads = get_workloads()
    order = {}  # job -> color, assigned in render order

    # group nodes by rack
    racks = {}
    for n in nodes:
        racks.setdefault(n["rack"], []).append(n)

    print(bold("  FAKE GPU DATACENTER") + dim("   (● used   ○ free)"))
    print()

    # render each rack's node boxes side by side
    for rack in sorted(racks):
        rnodes = racks[rack]
        print("  " + bold(cyan(rack)) + dim("  ·  one NVLink domain"))
        boxes = [render_node(n, usage.get(n["name"], []), order) for n in rnodes]
        for row in range(4):  # each box is 4 lines
            print("  " + "  ".join(b[row] for b in boxes))
        print()

    # --- the queue, as a per-tenant two-lane board --------------------------
    total_gpu = sum(n["gpus"] for n in nodes)
    quotas = get_quotas()            # {team -> gpu quota}, via LocalQueue->ClusterQueue

    # which rack each admitted job landed in (from where its pods sit)
    node_rack = {n["name"]: n["rack"] for n in nodes}
    # collect every rack a job's pods touch; "split" if it spans more than one
    job_racks = {}
    for node_name, jobs_on in usage.items():
        for jname, _ in jobs_on:
            job_racks.setdefault(jname, set()).add(node_rack.get(node_name, "?"))
    job_rack = {}
    for jname, rset in job_racks.items():
        job_rack[jname] = next(iter(rset)) if len(rset) == 1 else "split: " + "+".join(sorted(rset))

    def short(name):  # job-foo-12345 -> foo
        s = name.replace("job-", "")
        return s.rsplit("-", 1)[0] if "-" in s else s

    # teams to show: every team with a quota, plus any team that has a workload
    teams = sorted(set(quotas) | {w[1] for w in workloads})
    if not teams:
        print(dim("  Submit a job:  kubectl apply -f jobs/01-single-gpu.yaml"))
        return

    for ti, team in enumerate(teams):
        tw = [w for w in workloads if w[1] == team]
        quota = quotas.get(team)
        used = sum(g for (_, _, adm, g, _) in tw if adm)
        free = max(0, (quota or 0) - used)
        running = sorted((w for w in tw if w[2]), key=lambda x: -x[3])
        waiting = sorted((w for w in tw if not w[2]), key=lambda x: x[0])

        # team header + its own quota bar
        bar_w = 16
        if quota:
            filled = max(0, min(bar_w, int(round(bar_w * min(used, quota) / quota))))
        else:
            filled = 0
        qbar = green("█" * filled) + dim("░" * (bar_w - filled))
        qtxt = f"{min(used, quota or used)}/{quota}" if quota else f"{used}/?"
        print("  " + bold(cyan(team.upper())) + "   [" + qbar + "] " + qtxt + dim(" GPU quota"))

        # running
        if running:
            for (name, _q, _adm, gpu, _r) in running:
                nm = short(name)
                rack = job_rack.get(nm)
                where = dim(f"  ({rack})") if rack else ""
                print(f"    {green('● running')} {nm:<14} {gpu:>2} GPU   "
                      + green("█" * min(gpu, 16)) + where)
        # waiting
        for pos, (name, _q, _adm, gpu, reason) in enumerate(waiting, start=1):
            nm = short(name)
            gap = gpu - free
            why = red(f"needs {gap} more") if gap > 0 else dim("ready — admitting…")
            print(f"    {yellow('◌ waiting')} {nm:<14} {gpu:>2} GPU   {why} ⏳"
                  + dim(f"  (#{pos} in {team}'s line)" if len(waiting) > 1 else ""))
        if not running and not waiting:
            print(dim("    — idle —"))
        print()

    print(dim(f"  cluster: {total_gpu} GPU across 4 nodes · each team capped at its own quota (no borrowing)"))


def get_quotas():
    """Map team (LocalQueue name) -> nvidia.com/gpu quota of the ClusterQueue it
    points at. Returns {} if nothing is set up yet."""
    cq_gpu = {}
    cqs = kubectl_json(["get", "clusterqueue"])
    if cqs:
        for cq in cqs.get("items", []):
            try:
                for rg in cq["spec"]["resourceGroups"]:
                    for fl in rg["flavors"]:
                        for r in fl["resources"]:
                            if r["name"] == "nvidia.com/gpu":
                                cq_gpu[cq["metadata"]["name"]] = int(r["nominalQuota"])
            except Exception:
                pass
    out = {}
    lqs = kubectl_json(["get", "localqueue", "-n", NS])
    if lqs:
        for lq in lqs.get("items", []):
            team = lq["metadata"]["name"]
            cq = lq.get("spec", {}).get("clusterQueue")
            if cq in cq_gpu:
                out[team] = cq_gpu[cq]
    return out


if __name__ == "__main__":
    main()

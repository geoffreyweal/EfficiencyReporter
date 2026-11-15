"""A made-up but realistic set of Slurm jobs for testing the app locally.

The mock sacct and profile_plot in bin/ both read their jobs from here. The
jobs are generated from a fixed seed and anchored to the start of today, so
every process sees the same jobs, with the same IDs and times, all day.

The set covers what the app has to cope with: completed jobs of every kind of
efficiency, job arrays, GPU jobs, multi-node MPI jobs with several steps,
out-of-memory, timed-out and failed jobs, a failed job that ran for no time
(which seff cannot report on), jobs cancelled before they started, running and
pending jobs, profiled jobs, and job names that need escaping.
"""

import datetime as _dt
import os
import random

# Every job belongs to whoever asks (the mock sacct ignores --user). Set
# ER_TEST_USER to show another name, e.g. for screenshots.
USER = os.environ.get("ER_TEST_USER") or os.environ.get("USER", "user")
ACCOUNT = "nesi99999"
CLUSTER = "mahuika"
# As NeSI's seff counts them for the genoa partition.
GPU_MEM_GB = {"l4": 23, "a100": 40, "h100": 94}


def _anchor():
    today = _dt.date.today()
    return int(_dt.datetime(today.year, today.month, today.day).timestamp())


def _fmt(epoch):
    """A time as sacct prints it: as SLURM_TIME_FORMAT says, if it is set to
    anything but "standard" (some sites set it for everyone), and otherwise
    as year-month-dateThour:minute:second."""
    if epoch is None:
        return "Unknown"
    fmt = os.environ.get("SLURM_TIME_FORMAT", "") or "standard"
    if fmt == "standard":
        fmt = "%Y-%m-%dT%H:%M:%S"
    elif fmt == "relative":
        fmt = "%d %b %H:%M"
    return _dt.datetime.fromtimestamp(epoch).strftime(fmt)


def _dur(seconds):
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    text = f"{hours:02}:{minutes:02}:{secs:02}"
    return f"{days}-{text}" if days else text


def _mem_text(mb):
    return f"{mb // 1024}G" if mb % 1024 == 0 else f"{mb}M"


SCRIPT_HEAD = "#!/bin/bash -e\n#SBATCH --job-name={name}\n#SBATCH --account={account}\n#SBATCH --time={time}\n#SBATCH --cpus-per-task={cpus}\n#SBATCH --mem={mem}\n"


def _job(rng, raw, name, start, elapsed, *, state="COMPLETED", cpus=4, mem_mb=8192, limit_min=None,
         cpu_eff=0.8, mem_eff=0.5, partition="genoa", nodes=1, ntasks=1, steps=1, gpus=None,
         gpu_util=None, gpu_mem_eff=None, profile=None, array=None, exit_code="0:0", submit_line=None,
         script=True, submit_delay=300):
    limit_min = limit_min or max(15, int(elapsed / 60 * rng.uniform(1.2, 4)) // 15 * 15 + 15)
    submit = start - submit_delay if start else _anchor() - 1800
    end = start + elapsed if (start is not None and state not in ("RUNNING", "PENDING")) else None
    job_id = f"{array[0]}_{array[1]}" if array else str(raw)
    script_text = None
    if script:
        script_text = SCRIPT_HEAD.format(name=name, account=ACCOUNT, time=_dur(limit_min * 60),
                                         cpus=cpus, mem=_mem_text(mem_mb))
        if gpus:
            script_text += f"#SBATCH --gpus-per-node={gpus[0]}:{gpus[1]}\n"
        if profile == "script":
            script_text += "#SBATCH --profile task\n#SBATCH --acctg-freq=1\n"
        if array:
            script_text += "#SBATCH --array=1-40\n"
        script_text += "\nmodule purge\nmodule load Python/3.11.6-foss-2023a\n"
        if ntasks > 1:
            script_text += "srun python simulate.py --input data.h5\n"
        else:
            script_text += "python analyse.py --threads ${SLURM_CPUS_PER_TASK}\n"
    if submit_line is None:
        submit_line = "sbatch job.sl" if script else f"srun --cpus-per-task={cpus} --pty bash"
        if profile == "submit":
            submit_line = "sbatch --profile=task job.sl"
    return {
        "raw": raw, "id": job_id, "array": array, "name": name, "state": state, "partition": partition,
        "cpus": cpus if state != "NEVER_STARTED" else 0, "mem_mb": mem_mb, "limit_min": limit_min,
        "submit": submit, "start": start, "end": end, "elapsed": elapsed if start is not None else 0,
        "cpu_eff": cpu_eff, "mem_eff": mem_eff, "nodes": nodes, "ntasks": ntasks, "steps": steps,
        "gpus": gpus, "gpu_util": gpu_util, "gpu_mem_eff": gpu_mem_eff, "profile": profile,
        "exit_code": exit_code, "submit_line": submit_line, "script": script_text,
        "workdir": f"/nesi/project/{ACCOUNT}/{USER}/runs/{name.split()[0] if name.split() else 'run'}",
    }


def build():
    rng = random.Random(20261115)
    now = _anchor()
    day = 86400
    jobs = []
    raw = 4_100_000

    def nxt(step=1):
        nonlocal raw
        raw += step
        return raw

    names = ["md_equilibrate", "align_reads", "train_resnet", "postprocess", "assemble_genome",
             "climate_ens", "blast_search", "fem_solver", "dft_relax", "render_frames"]

    # Ordinary jobs spread over the last ~95 days, oldest first.
    for i in range(150):
        start = now - int(rng.uniform(1, 95) * day)
        elapsed = int(rng.choice([45, 300, 900, 1800, 3600, 7200, 14400, 43200]) * rng.uniform(0.6, 1.4))
        cpus = rng.choice([1, 2, 4, 8, 16, 32])
        mem_mb = rng.choice([1024, 2048, 4096, 8192, 16384, 32768])
        name = rng.choice(names) + (f"_{i}" if rng.random() < 0.3 else "")
        jobs.append(_job(rng, nxt(rng.randint(3, 900)), name, start, elapsed, cpus=cpus, mem_mb=mem_mb,
                         cpu_eff=rng.betavariate(2, 1.6), mem_eff=rng.betavariate(1.3, 2.5)))

    # A profiled job array of 40 tasks, a few of them failed. Like a real
    # array, every task runs the same script.
    array_raw = nxt(500)
    start = now - 20 * day
    for task in range(1, 41):
        state = "FAILED" if task in (7, 23) else "COMPLETED"
        jobs.append(_job(rng, array_raw + task - 1, "bootstrap_sample", start + task * 60, int(rng.uniform(500, 900)),
                         state=state, cpus=2, mem_mb=4096, cpu_eff=rng.uniform(0.85, 0.99),
                         mem_eff=rng.uniform(0.1, 0.25), array=(array_raw, task),
                         exit_code="1:0" if state == "FAILED" else "0:0", profile="script", limit_min=30))
    raw = array_raw + 40

    # GPU jobs.
    for gpu, util, mem_eff, days_ago in (("a100", 0.92, 0.61, 3), ("h100", 0.18, 0.05, 12), ("l4", 0.43, 0.02, 40)):
        jobs.append(_job(rng, nxt(77), f"train_{gpu}", now - days_ago * day, 5400, cpus=8, mem_mb=65536,
                         partition="genoa", gpus=(gpu, 1), gpu_util=util, gpu_mem_eff=mem_eff,
                         cpu_eff=0.11, mem_eff=0.3, profile="script" if gpu == "a100" else None))

    # A multi-node MPI job with several job steps.
    jobs.append(_job(rng, nxt(50), "lammps_scaling", now - 6 * day, 10800, cpus=256, mem_mb=512000, nodes=2,
                     ntasks=128, steps=3, cpu_eff=0.71, mem_eff=0.44, partition="milan"))

    # Profiled jobs: one from #SBATCH in the script, one from the sbatch line,
    # one profiled too long ago for the profile to still be there.
    jobs.append(_job(rng, nxt(9), "profile_me", now - 2 * day, 3000, cpus=4, mem_mb=8192, cpu_eff=0.55,
                     mem_eff=0.8, profile="script"))
    jobs.append(_job(rng, nxt(9), "profile_cli", now - 5 * day, 1500, cpus=2, mem_mb=4096, cpu_eff=0.97,
                     mem_eff=0.33, profile="submit"))
    jobs.append(_job(rng, nxt(9), "old_profiled_run", now - 60 * day, 4000, cpus=8, mem_mb=16384, cpu_eff=0.6,
                     mem_eff=0.4, profile="script"))

    # Jobs that ended badly.
    jobs.append(_job(rng, nxt(30), "big_matrix", now - 1 * day, 1300, state="OUT_OF_MEMORY", cpus=4, mem_mb=4096,
                     cpu_eff=0.93, mem_eff=1.0, exit_code="0:125"))
    jobs.append(_job(rng, nxt(30), "long_sim", now - 4 * day, 7200, state="TIMEOUT", cpus=16, mem_mb=32768,
                     limit_min=120, cpu_eff=0.88, mem_eff=0.36, exit_code="0:0"))
    jobs.append(_job(rng, nxt(30), "typo_in_script", now - 8 * day, 0, state="FAILED", cpus=1, mem_mb=1024,
                     exit_code="127:0"))
    # Ran for a second, but none of its steps did: seff stops with an error
    # on this one, part-way through a call that covers many jobs.
    broken = _job(rng, nxt(30), "node_glitch", now - 11 * day, 1, state="FAILED", cpus=2, mem_mb=2048,
                  exit_code="1:0")
    broken["broken_steps"] = True
    jobs.append(broken)
    jobs.append(_job(rng, nxt(30), "cancelled_early", None, 0, state="NEVER_STARTED", cpus=0, mem_mb=2048))
    jobs.append(_job(rng, nxt(30), "cancelled_midway", now - 9 * day, 2400, state="CANCELLED", cpus=8,
                     mem_mb=16384, cpu_eff=0.4, mem_eff=0.2, exit_code="0:15"))

    # Names that must be shown as text, never as HTML.
    jobs.append(_job(rng, nxt(30), "<b>not bold</b> & <i>plain</i>", now - 3 * day, 600, cpus=2, mem_mb=2048,
                     cpu_eff=0.5, mem_eff=0.5))
    jobs.append(_job(rng, nxt(30), "café | naïve run", now - 7 * day, 900, cpus=1, mem_mb=1024, cpu_eff=0.97,
                     mem_eff=0.08, script=False,
                     submit_line="sbatch --wrap 'echo start\npython run.py | tee log.txt'"))

    # Still going.
    jobs.append(_job(rng, nxt(30), "still_running", now - 7200, 7200, state="RUNNING", cpus=8, mem_mb=8192,
                     profile="script"))
    jobs.append(_job(rng, nxt(30), "waiting_in_queue", None, 0, state="PENDING", cpus=0, mem_mb=8192))

    for job in jobs:
        if job["state"] == "NEVER_STARTED":
            job["state"] = "CANCELLED"
            job["start"] = None
            job["end"] = now - 10 * day
            job["exit_code"] = "0:0"
    return jobs


JOBS = build()
BY_ID = {}
for _j in JOBS:
    BY_ID[_j["id"]] = _j
    BY_ID[str(_j["raw"])] = _j


def find(job_id):
    """A job by the ID sacct shows (123_4) or its raw ID (125)."""
    return BY_ID.get(str(job_id))


def alloc_tres(job):
    if not job["cpus"]:
        return ""
    parts = [f"billing={job['cpus']}", f"cpu={job['cpus']}"]
    if job["gpus"]:
        kind, count = job["gpus"]
        parts += [f"gres/gpu:{kind}={count}", f"gres/gpu={count}"]
    parts += [f"mem={_mem_text(job['mem_mb'])}", f"node={job['nodes']}"]
    return ",".join(parts)


def step_records(job):
    """The steps of a job: (name, ntasks, cpu_seconds, max_rss_bytes, start, end)."""
    if not job["start"] or job["state"] == "PENDING":
        return []
    start = job["start"]
    end = job["end"] or (_anchor() + 3600)
    if job.get("broken_steps"):
        end = start
    elapsed = max(0, end - start)
    cores = (job["cpus"] + 1) // 2
    cpu_total = elapsed * cores * job["cpu_eff"]
    mem_peak = job["mem_mb"] * 1024 * 1024 * job["mem_eff"]
    steps = [("extern", 1, 0.0, 1_000_000, start, end)]
    if job["script"]:
        if job["ntasks"] > 1:
            steps.append(("batch", 1, cpu_total * 0.01, 50_000_000, start, end))
            per = elapsed / job["steps"]
            for n in range(job["steps"]):
                s = start + int(per * n)
                steps.append((str(n), job["ntasks"], cpu_total * 0.99 / job["steps"], mem_peak, s, s + int(per)))
        else:
            steps.append(("batch", 1, cpu_total, mem_peak, start, end))
    else:
        steps.append(("0", 1, cpu_total, mem_peak, start, end))
    return steps


def iso(epoch):
    return _fmt(epoch)


def duration(seconds):
    return _dur(seconds)


def mem_text(mb):
    return _mem_text(mb)


def anchor():
    return _anchor()

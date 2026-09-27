# Fork-Worker Cluster Mode [Experimental]

Puma 5 introduces an experimental new cluster-mode configuration option, `fork_worker` (`--fork-worker` from the CLI). This mode causes Puma to fork additional workers from worker 0, instead of directly from the master process:

```
10000   \_ puma 4.3.3 (tcp://0.0.0.0:9292) [puma]
10001       \_ puma: cluster worker 0: 10000 [puma]
10002           \_ puma: cluster worker 1: 10000 [puma]
10003           \_ puma: cluster worker 2: 10000 [puma]
10004           \_ puma: cluster worker 3: 10000 [puma]
```

The `fork_worker` option allows your application to be initialized only once for copy-on-write memory savings, and it has two additional advantages:

1. **Compatible with phased restart.** Because the master process itself doesn't preload the application, this mode works with phased restart (`SIGUSR1` or `pumactl phased-restart`). When worker 0 reloads as part of a phased restart, it initializes a new copy of your application first, then the other workers reload by forking from this new worker already containing the new preloaded application.

   This allows a phased restart to complete as quickly as a hot restart (`SIGUSR2` or `pumactl restart`), while still minimizing downtime by staggering the restart across cluster workers.

2. **'Refork' for additional copy-on-write improvements in running applications.** Fork-worker mode introduces a new `refork` command that re-loads all nonzero workers by re-forking them from worker 0.

   This command can potentially improve memory utilization in large or complex applications that don't fully pre-initialize on startup, because the re-forked workers can share copy-on-write memory with a worker that has been running for a while and serving requests.

   You can trigger a refork by sending the cluster the `SIGURG` signal or running the `pumactl refork` command at any time. A refork will also automatically trigger once, after a certain number of requests have been processed by worker 0 (default 1000). To configure the number of requests before the auto-refork, pass a positive integer argument to `fork_worker` (e.g., `fork_worker 1000`), or `0` to disable.

### Usage Considerations

- `fork_worker` introduces new `before_refork` and `after_refork` configuration hooks. Note the following:
    - When initially forking the parent process to the worker 0 child, `before_fork` will trigger on the parent process and `before_worker_boot` will trigger on the worker 0 child as normal.
    - When forking the worker 0 child to grandchild workers, `before_refork` and `after_refork` will trigger on the worker 0 child, and `before_worker_boot` will trigger on each grandchild worker.
    - For clarity, `before_fork` does not trigger on worker 0, and `after_refork` does not trigger on the grandchild.
- As a general migration guide:
    - Copy any logic within your existing `before_fork` hook to the `before_refork` hook.
    - Consider to copy logic from your `before_worker_boot` hook to the `after_refork` hook, if it is needed to reset the state of worker 0 after it forks.

### Limitations

- This mode is still very experimental so there may be bugs or edge-cases, particularly around expected behavior of existing hooks. Please open a [bug report](https://github.com/puma/puma/issues/new?template=bug_report.md) if you encounter any issues.

- In order to fork new workers cleanly, worker 0 shuts down its server and stops serving requests so there are no open file descriptors or other kinds of shared global state between processes, and to maximize copy-on-write efficiency across the newly-forked workers. This may temporarily reduce total capacity of the cluster during a phased restart / refork.

- In a cluster with `n` workers, a normal phased restart stops and restarts workers one by one while the application is loaded in each process, so `n-1` workers are available serving requests during the restart. In a phased restart in fork-worker mode, the application is first loaded in worker 0 while `n-1` workers are available, then worker 0 remains stopped while the rest of the workers are reloaded one by one, leaving only `n-2` workers to be available for a brief period of time. Reloading the rest of the workers should be quick because the application is preloaded at that point, but there may be situations where it can take longer (slow clients, long-running application code, slow worker-fork hooks, etc).

### PR_SET_CHILD_SUBREAPER

Where available from the OS (Linux 3.4+), if you are using `fork_worker` or `mold_worker` Puma will mark the cluster parent automatically as a "child subreaper", so that if worker 0 or a mold exits, its child processes are reparented to the cluster parent instead of to init.

### Mold-Worker Cluster Mode [Experimental] [Alternative]

`mold_worker` is similar in concept to `fork_worker` except that before a worker process reforks, it permanently stops handling requests and converts to a "mold" process, effectively an idle worker template. This provides some stability advantages over the standard fork_worker mode, as you no longer have to coordinate reforks with a request server stopping and restarting, and are at much lower risk of losing the reforking process to termination via OOM, timeouts, or other external mechanisms.

### Mold-Worker Important Differences

- `mold_worker` triggers a refork at each of the request thresholds you pass it, in order. The default is one refork at 1000 requests. Workers forked from a mold start counting requests from zero, so each threshold is the number of requests that one worker of the current generation must serve. For example, with `mold_worker 400, 800, 1600`:
  1. When a worker has served 400 requests, it is promoted to mold and stops serving requests. Puma forks a replacement from the mold, then replaces the other workers one at a time with forks of the mold.
  2. When one of those workers has served 800 requests, it is promoted to be the new mold, the previous mold exits, and all workers are replaced again.
  3. The same happens at 1600 requests. After the last threshold, Puma only forks from the mold to replace workers that exit.
- During a refork, the new mold is promoted first, and Puma stops an old worker only after the previous replacement has booted. At most one worker is unavailable at a time, which is one fewer than a `fork_worker` refork.
- SIGURG, or `pumactl refork`, promotes the worker with the highest request count to mold and replaces all workers with forks of it.
- SIGUSR1, or `pumactl phased-restart`, stops the current mold and replaces each worker with a fresh fork of the cluster parent, so that the workers load new application code. Like any phased restart, this requires `preload_app! false`. After the restart, the thresholds start again from the first one.
- Puma forks workers directly from the cluster parent at boot. If a worker exits before any mold exists, the worker with the highest request count is promoted to mold and the replacement is forked from it.
- A mold does not serve requests, so it does not warm up further. To fork from a more warmed-up process later, add another threshold or send SIGURG.

### Mold-Worker Migration Guide (From Fork-Worker)

- Move logic in your `before_refork` hook that shuts down worker resources to the `on_mold_promotion` hook. Remove any other logic, or move it to a `before_worker_boot` hook.
- Remove your `after_refork` hook. Puma does not call it in `mold_worker` mode.
- A mold does not run `before_worker_shutdown`. Copy logic from that hook that finishes serving requests to `on_mold_promotion`, and logic that runs at process exit to `on_mold_shutdown`.
- Replace `fork_worker` with `mold_worker` in either your CLI invocation or config file; consider adding extra intervals with some kind of exponential period to increase the efficiency of shared memory and warmed caches.

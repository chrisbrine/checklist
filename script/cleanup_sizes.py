"""Shared allocated-byte sizing for cleanup previews.

The size report and held candidate rows use one partition of the filesystem,
so a large retained qualification folder is never scanned again for each row.
"""
from concurrent.futures import ThreadPoolExecutor
from functools import cache
import os
import threading
from pathlib import Path


def background_sizes(groups, targets=(), *, size_reader, workers=8, chunk=16):
    """Return a cached ``sizer(paths)`` backed by bounded background du calls.

    Split group roots two levels deep for parallelism (stopping at target
    boundaries), then split only along nested requested target boundaries. Each resulting leaf is passed to
    ``size_reader`` exactly once. Ancestor sizes sum those same leaf results and
    the allocated blocks of partition directories; no ancestor du scan repeats
    a descendant's work. Directory symlinks are leaves, never traversed.

    As with cleanup's previous parallel du implementation, hard links shared
    across du batches can count twice. Missing roots are absent from results.
    """
    if workers < 1 or chunk < 1:
        raise ValueError('sizing workers and chunk must be positive')
    roots = {Path(path) for paths in groups.values() for path in paths}
    wanted = roots | {Path(path) for path in targets}
    existing = {path for path in wanted if os.path.lexists(path)}
    forest = [path for path in sorted(existing)
              if not any(parent in existing for parent in path.parents)]
    # A plan is either a leaf (None), or (own allocated bytes, child paths).
    plans = {}

    def partition(path, split_depth=0):
        descendants = [target for target in existing if path in target.parents]
        if split_depth or descendants:
            try:
                if path.is_symlink() or not path.is_dir():
                    raise NotADirectoryError(path)
                own = path.lstat().st_blocks * 512
                parts = sorted(path.iterdir())
            except OSError:
                plans[path] = None
                return
            plans[path] = (own, parts)
            for child in parts:
                child_depth = max(0, split_depth - 1) if child not in existing else 0
                if child in roots:
                    child_depth = max(1, child_depth)
                if child_depth or any(child in target.parents for target in descendants):
                    partition(child, child_depth)
                else:
                    plans[child] = None
        else:
            plans[path] = None

    for root in forest:
        partition(root, split_depth=2 if root in roots else 1)
    leaves = [path for path, plan in plans.items() if plan is None]
    # Directory scans get independent jobs: one slow directory cannot serialize
    # fifteen others inside a single du call. Batch only files and symlinks.
    directories, files = [], []
    for path in leaves:
        (directories if not path.is_symlink() and path.is_dir() else files).append(path)
    batches = iter([[path] for path in directories] +
                   [files[index:index + chunk] for index in range(0, len(files), chunk)])
    condition = threading.Condition()
    sizes, failures = {}, {}

    def worker():
        while True:
            with condition:
                batch = next(batches, None)
            if batch is None:
                return
            try:
                result = size_reader(batch)
            except Exception as error:
                with condition:
                    failures.update((path, error) for path in batch)
                    condition.notify_all()
            else:
                with condition:
                    sizes.update((path, result.get(path, 0)) for path in batch)
                    condition.notify_all()

    pool = ThreadPoolExecutor(max_workers=workers)
    for _ in range(min(workers, len(leaves))):
        pool.submit(worker)
    pool.shutdown(wait=False)

    @cache
    def total(path):
        plan = plans[path]
        if plan is None:
            with condition:
                condition.wait_for(lambda: path in sizes or path in failures)
                if path in failures:
                    raise failures[path]
                return sizes[path]
        own, children = plan
        return own + sum(total(child) for child in children)

    def sizer(paths):
        return {Path(path): total(Path(path)) for path in paths if Path(path) in plans}

    return sizer

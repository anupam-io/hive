# In-process TTL cache. The whole UI fits behind this — every endpoint
# returns a cached blob computed at most once per CACHE_TTL seconds.
#
# Per-key locks prevent the thundering-herd: when many requests hit a
# stale key at once, only ONE rebuilds while the rest block on the lock
# and read the freshened value.

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable

CACHE_TTL = float(os.environ.get("AGENT_UI_CACHE_TTL", "10"))  # seconds

_cache: dict[str, tuple[float, Any]] = {}
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _lock_for(key: str) -> threading.Lock:
    # Lazy lock creation under a guard so two threads can't both create
    # one for the same key.
    if key in _locks:
        return _locks[key]
    with _locks_guard:
        if key not in _locks:
            _locks[key] = threading.Lock()
        return _locks[key]


def cached(key: str, builder: Callable[[], Any]) -> Any:
    now = time.monotonic()
    hit = _cache.get(key)
    if hit and (now - hit[0]) < CACHE_TTL:
        return hit[1]
    lock = _lock_for(key)
    with lock:
        # Re-check after acquiring the lock — another request may have
        # already refreshed while we were waiting.
        hit = _cache.get(key)
        if hit and (time.monotonic() - hit[0]) < CACHE_TTL:
            return hit[1]
        val = builder()
        _cache[key] = (time.monotonic(), val)
        return val

"""High-concurrency primitives for Penguin Store (100+ simultaneous shoppers).

Provides:
  1. `SingleFlightAsyncCache`: per-key `asyncio.Lock` double-checked TTL cache
     preventing cache stampedes (200 concurrent misses -> 1 DB fetch).
  2. `BoundedLRUDict`: thread-safe size-bounded + optional TTL LRU dictionary
     preventing unbounded RAM growth on Render's 512 MB tier.
  3. `KeyedLockPool`: bounded striped/keyed locks for per-resource serialization.
"""

from __future__ import annotations

import asyncio
import time
from collections import OrderedDict
from threading import Lock
from typing import Any, Awaitable, Callable, Generic, Hashable, Optional, TypeVar

T = TypeVar("T")


class BoundedLRUDict(Generic[T]):
    """Thread-safe LRU map with strict max_size and optional TTL expiration."""

    def __init__(self, max_size: int = 512, ttl_seconds: Optional[float] = None) -> None:
        self._max_size = max(16, int(max_size))
        self._ttl = float(ttl_seconds) if ttl_seconds is not None else None
        self._lock = Lock()
        self._data: OrderedDict[Hashable, tuple[T, float]] = OrderedDict()

    def get(self, key: Hashable, default: Optional[T] = None) -> Optional[T]:
        now = time.monotonic()
        with self._lock:
            entry = self._data.get(key)
            if entry is None:
                return default
            val, ts = entry
            if self._ttl is not None and (now - ts) > self._ttl:
                self._data.pop(key, None)
                return default
            self._data.move_to_end(key)
            return val

    def set(self, key: Hashable, value: T) -> None:
        now = time.monotonic()
        with self._lock:
            self._data[key] = (value, now)
            self._data.move_to_end(key)
            while len(self._data) > self._max_size:
                self._data.popitem(last=False)

    def pop(self, key: Hashable, default: Optional[T] = None) -> Optional[T]:
        with self._lock:
            entry = self._data.pop(key, None)
            return entry[0] if entry is not None else default

    def contains(self, key: Hashable) -> bool:
        return self.get(key, None) is not None

    def values_snapshot(self) -> list[T]:
        now = time.monotonic()
        with self._lock:
            if self._ttl is not None:
                expired = [k for k, (_, ts) in self._data.items() if (now - ts) > self._ttl]
                for k in expired:
                    self._data.pop(k, None)
            return [v for v, _ in self._data.values()]

    def clear(self) -> None:
        with self._lock:
            self._data.clear()

    def __len__(self) -> int:
        with self._lock:
            return len(self._data)


class SingleFlightAsyncCache:
    """Async single-flight TTL cache with per-key `asyncio.Lock` double-checked locking.

    If 200 coroutines request an expired key simultaneously, exactly 1 executes
    `loader` while the remaining 199 await the per-key lock and share the fresh result.
    """

    def __init__(self, max_entries: int = 256, default_ttl: float = 90.0) -> None:
        self._max_entries = max(16, int(max_entries))
        self._default_ttl = float(default_ttl)
        self._store_lock = Lock()
        self._entries: OrderedDict[str, tuple[Any, float]] = OrderedDict()
        self._key_locks: OrderedDict[str, asyncio.Lock] = OrderedDict()

    def _peek(self, key: str) -> tuple[bool, Any]:
        now = time.monotonic()
        with self._store_lock:
            item = self._entries.get(key)
            if item is None:
                return False, None
            val, expires_at = item
            if now >= expires_at:
                return False, None
            self._entries.move_to_end(key)
            return True, val

    def _put(self, key: str, value: Any, ttl: float) -> None:
        expires_at = time.monotonic() + max(0.5, ttl)
        with self._store_lock:
            self._entries[key] = (value, expires_at)
            self._entries.move_to_end(key)
            while len(self._entries) > self._max_entries:
                self._entries.popitem(last=False)

    def _get_async_lock(self, key: str) -> asyncio.Lock:
        with self._store_lock:
            lk = self._key_locks.get(key)
            if lk is None:
                lk = asyncio.Lock()
                self._key_locks[key] = lk
                while len(self._key_locks) > self._max_entries * 2:
                    # Only evict unlocked entries
                    first_key, first_lock = next(iter(self._key_locks.items()))
                    if not first_lock.locked():
                        self._key_locks.pop(first_key, None)
                    else:
                        break
            else:
                self._key_locks.move_to_end(key)
            return lk

    async def get_or_load(
        self,
        key: str,
        loader: Callable[[], Awaitable[T]],
        ttl: Optional[float] = None,
    ) -> T:
        hit, val = self._peek(key)
        if hit:
            return val

        key_lock = self._get_async_lock(key)
        async with key_lock:
            # Double-check after acquiring single-flight lock
            hit2, val2 = self._peek(key)
            if hit2:
                return val2

            fresh = await loader()
            self._put(key, fresh, ttl if ttl is not None else self._default_ttl)
            return fresh

    async def get_or_load_sync(
        self,
        key: str,
        sync_loader: Callable[[], T],
        ttl: Optional[float] = None,
    ) -> T:
        return await self.get_or_load(
            key,
            lambda: asyncio.to_thread(sync_loader),
            ttl=ttl,
        )

    def invalidate_prefix(self, prefix: str = "") -> None:
        with self._store_lock:
            if not prefix:
                self._entries.clear()
                return
            victims = [k for k in self._entries if k.startswith(prefix)]
            for k in victims:
                self._entries.pop(k, None)


class KeyedLockPool:
    """Striped thread Lock pool (64 stripes) for atomic per-key synchronization."""

    def __init__(self, stripes: int = 64) -> None:
        self._stripes = [Lock() for _ in range(max(8, int(stripes)))]

    def for_key(self, key: Hashable) -> Lock:
        return self._stripes[hash(key) % len(self._stripes)]


# Shared application-wide single-flight cache for catalog, categories, 3D & review insights
global_single_flight = SingleFlightAsyncCache(max_entries=384, default_ttl=90.0)

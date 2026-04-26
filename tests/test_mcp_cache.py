"""
TC-08: MCP shell-proxy cache behaviour
  - wf_state double-call returns cache hit on second call
  - Corrupt cache entry is silently refreshed (miss + re-populate)
  - Cache generation counter invalidation (state scope) causes cache miss
  - Cache TTL expiry causes miss
  - wf_cache_invalidate clears the correct scope

These tests exercise the cache logic extracted from shell-proxy.js, reimplemented
in Python for hermetic testing without requiring Node.js.
"""
import json
import os
import time
from pathlib import Path

import pytest


# ── Python re-implementation of the shell-proxy.js cache logic ────────────────


class ShellProxyCache:
    """Pure-Python mirror of the cacheGet / cacheSet / invalidateAll logic
    from scripts/workflow/mcp/shell-proxy.js.

    Strategies:
      - 'state':  valid while gen.state matches entry.gen
      - 'git':    valid while gen.git   matches entry.gen
      - 'ttl':    valid while now - entry.ts < entry.ttl * 1000 (ms)
      - 'mtime':  valid while target file mtime matches entry.mtime
      - 'static': always valid
    """

    def __init__(self, cache_dir: Path) -> None:
        self._dir = cache_dir
        self._dir.mkdir(parents=True, exist_ok=True)

    # ── generation counter ────────────────────────────────────────────────────

    def _gen_path(self) -> Path:
        return self._dir / "_gen.json"

    def _read_gen(self) -> dict:
        p = self._gen_path()
        if p.exists():
            try:
                return json.loads(p.read_text())
            except Exception:
                pass
        return {"git": 0, "state": 0}

    def _write_gen(self, gen: dict) -> None:
        tmp = Path(str(self._gen_path()) + ".tmp")
        tmp.write_text(json.dumps(gen))
        tmp.rename(self._gen_path())

    # ── public API ────────────────────────────────────────────────────────────

    def cache_get(self, key: str) -> tuple[bool, object]:
        """Return (hit, data). hit=False means cache miss."""
        f = self._dir / f"{key}.json"
        if not f.exists():
            return False, None
        try:
            entry = json.loads(f.read_text())
            gen = self._read_gen()
            now_ms = int(time.time() * 1000)
            strategy = entry.get("strategy", "")

            if strategy == "static":
                return True, entry["data"]
            if strategy == "state" and entry.get("gen") == gen.get("state"):
                return True, entry["data"]
            if strategy == "git" and entry.get("gen") == gen.get("git"):
                return True, entry["data"]
            if strategy == "ttl":
                if now_ms - entry.get("ts", 0) < (entry.get("ttl", 60) * 1000):
                    return True, entry["data"]
            if strategy == "mtime":
                target = Path(entry.get("path", ""))
                if target.exists() and target.stat().st_mtime_ns == entry.get("mtime"):
                    return True, entry["data"]
        except Exception:
            pass  # corrupt cache → miss
        return False, None

    def cache_set(self, key: str, data: object, strategy: str,
                  ttl: int = 60, path: str = "", mtime: int = 0) -> None:
        gen = self._read_gen()
        entry: dict = {"strategy": strategy, "data": data, "ts": int(time.time() * 1000)}
        if strategy == "state":
            entry["gen"] = gen.get("state", 0)
        elif strategy == "git":
            entry["gen"] = gen.get("git", 0)
        elif strategy == "ttl":
            entry["ttl"] = ttl
        elif strategy == "mtime":
            entry["path"] = path
            entry["mtime"] = mtime
        (self._dir / f"{key}.json").write_text(json.dumps(entry))

    def invalidate(self, scope: str = "all") -> dict:
        gen = self._read_gen()
        if scope in ("all", "state"):
            gen["state"] = gen.get("state", 0) + 1
        if scope in ("all", "git"):
            gen["git"] = gen.get("git", 0) + 1
        self._write_gen(gen)
        return gen


# ── TC-08 tests ───────────────────────────────────────────────────────────────


class TestMCPCacheHitMiss:

    def test_second_call_is_cache_hit(self, tmp_path: Path) -> None:
        """wf_state called twice: first miss, second hit (state gen unchanged)."""
        cache = ShellProxyCache(tmp_path / "cache")
        payload = {"current_step": 3, "status": "active"}

        # First call → miss
        hit, data = cache.cache_get("wf_state")
        assert not hit

        # Populate (simulates what the tool does after a miss)
        cache.cache_set("wf_state", payload, strategy="state")

        # Second call → hit
        hit, data = cache.cache_get("wf_state")
        assert hit, "Second call must be a cache hit"
        assert data == payload

    def test_corrupt_cache_entry_treated_as_miss(self, tmp_path: Path) -> None:
        """A corrupt (non-JSON) cache file must silently yield a miss."""
        cache = ShellProxyCache(tmp_path / "cache")
        (tmp_path / "cache" / "wf_state.json").write_text("{corrupt:json", encoding="utf-8")

        hit, _ = cache.cache_get("wf_state")
        assert not hit, "Corrupt cache entry must be a miss, not an exception"

    def test_state_invalidation_causes_miss(self, tmp_path: Path) -> None:
        """After invalidate(state), a previously hit key must become a miss."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_state", {"step": 1}, strategy="state")

        hit, _ = cache.cache_get("wf_state")
        assert hit, "Should be a hit before invalidation"

        cache.invalidate(scope="state")

        hit, _ = cache.cache_get("wf_state")
        assert not hit, "Should be a miss after state invalidation"

    def test_git_invalidation_does_not_affect_state_cache(self, tmp_path: Path) -> None:
        """invalidate(git) must not invalidate strategy='state' entries."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_state", {"step": 2}, strategy="state")

        cache.invalidate(scope="git")

        hit, data = cache.cache_get("wf_state")
        assert hit, "State cache must survive git invalidation"
        assert data == {"step": 2}

    def test_state_invalidation_does_not_affect_git_cache(self, tmp_path: Path) -> None:
        """invalidate(state) must not invalidate strategy='git' entries."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_git", {"branch": "main"}, strategy="git")

        cache.invalidate(scope="state")

        hit, data = cache.cache_get("wf_git")
        assert hit, "Git cache must survive state invalidation"

    def test_ttl_cache_expires(self, tmp_path: Path) -> None:
        """A TTL=1s cache entry must expire after 1 second."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_files", {"entries": []}, strategy="ttl", ttl=1)

        hit, _ = cache.cache_get("wf_files")
        assert hit, "Should be a hit immediately after set"

        # Backdating the ts to simulate expiry
        f = tmp_path / "cache" / "wf_files.json"
        entry = json.loads(f.read_text())
        entry["ts"] = int(time.time() * 1000) - 2000  # 2s ago
        f.write_text(json.dumps(entry))

        hit, _ = cache.cache_get("wf_files")
        assert not hit, "TTL entry must be a miss after expiry"

    def test_invalidate_all_clears_both_scopes(self, tmp_path: Path) -> None:
        """invalidate(all) must bump both git and state generations."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_state", {"step": 1}, strategy="state")
        cache.cache_set("wf_git",   {"branch": "main"}, strategy="git")

        cache.invalidate(scope="all")

        hit_state, _ = cache.cache_get("wf_state")
        hit_git, _   = cache.cache_get("wf_git")
        assert not hit_state, "State cache must be invalidated by invalidate(all)"
        assert not hit_git,   "Git cache must be invalidated by invalidate(all)"

    def test_mtime_cache_invalidated_when_file_changes(self, tmp_path: Path) -> None:
        """strategy='mtime' must yield miss when file mtime changes."""
        cache = ShellProxyCache(tmp_path / "cache")
        target = tmp_path / "flowctl-state.json"
        target.write_text('{"step": 1}', encoding="utf-8")
        mtime = int(target.stat().st_mtime_ns)

        cache.cache_set("wf_read_state", {"content": "..."}, strategy="mtime",
                        path=str(target), mtime=mtime)

        hit, _ = cache.cache_get("wf_read_state")
        assert hit, "Should hit when mtime matches"

        # Simulate file change by overwriting
        time.sleep(0.01)
        target.write_text('{"step": 2}', encoding="utf-8")

        # Entry has stale mtime
        hit, _ = cache.cache_get("wf_read_state")
        assert not hit, "Should miss after file mtime changes"

    def test_static_strategy_always_hits(self, tmp_path: Path) -> None:
        """strategy='static' must always return hit regardless of generations."""
        cache = ShellProxyCache(tmp_path / "cache")
        cache.cache_set("wf_env", {"os": "Linux"}, strategy="static")

        cache.invalidate(scope="all")

        hit, data = cache.cache_get("wf_env")
        assert hit, "Static cache must always hit"
        assert data == {"os": "Linux"}

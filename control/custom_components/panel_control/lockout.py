"""Per-IP lockout for bad tokens (pure Python, no Home Assistant imports).

Rules: failures count in a sliding window of `window_s`. The `max_failures`-th
failure inside the window locks the IP for `window_s` and clears its failure
list. A success changes nothing. Entries with no live failures and no active lock are
pruned at most once per second; at most 1024 IPs are tracked (oldest unlocked evicted).
"""
import time

MAX_IPS = 1024


class Lockout:
    def __init__(self, now=time.time, max_failures=10, window_s=300):
        self._now = now
        self._max = max_failures
        self._window = window_s
        self._state = {}  # ip -> [failure_times, locked_until], insertion ordered
        self._last_prune = float("-inf")

    def _prune(self, t):
        for ip in list(self._state):
            fails, until = self._state[ip]
            fails[:] = [f for f in fails if t - f < self._window]
            if not fails and until <= t:
                del self._state[ip]

    def _maybe_prune(self, t):
        if t - self._last_prune >= 1:
            self._last_prune = t
            self._prune(t)

    def is_locked(self, ip):
        t = self._now()
        self._maybe_prune(t)
        return ip in self._state and self._state[ip][1] > t

    def record_failure(self, ip):
        t = self._now()
        self._maybe_prune(t)
        if ip not in self._state and len(self._state) >= MAX_IPS:
            victim = next((k for k, v in self._state.items() if v[1] <= t), None)
            if victim is None:
                return  # every slot is a live lock
            del self._state[victim]
        fails, _ = self._state.setdefault(ip, [[], 0.0])
        fails[:] = [f for f in fails if t - f < self._window]
        fails.append(t)
        if len(fails) >= self._max:
            fails.clear()
            self._state[ip][1] = t + self._window

    def record_success(self, ip):
        """A success must not clear failures: failures expire by the window only."""

"""Per-IP lockout for bad tokens (pure Python, no Home Assistant imports).

Rules: failures count in a sliding window of `window_s`. The `max_failures`-th
failure inside the window locks the IP for `window_s` and clears its failure
list. A success clears the failures but never lifts an active lock (the view
refuses locked IPs before checking the token anyway). Entries with no live
failures and no active lock are pruned on every call, bounding memory.
"""
import time


class Lockout:
    def __init__(self, now=time.time, max_failures=10, window_s=300):
        self._now = now
        self._max = max_failures
        self._window = window_s
        self._state = {}  # ip -> [failure_times, locked_until]

    def _prune(self, t):
        for ip in list(self._state):
            fails, until = self._state[ip]
            fails[:] = [f for f in fails if t - f < self._window]
            if not fails and until <= t:
                del self._state[ip]

    def is_locked(self, ip):
        t = self._now()
        self._prune(t)
        return ip in self._state and self._state[ip][1] > t

    def record_failure(self, ip):
        t = self._now()
        self._prune(t)
        fails, until = self._state.setdefault(ip, [[], 0.0])
        fails.append(t)
        if len(fails) >= self._max:
            fails.clear()
            self._state[ip][1] = t + self._window

    def record_success(self, ip):
        self._prune(self._now())
        if ip in self._state:
            self._state[ip][0].clear()
            self._prune(self._now())

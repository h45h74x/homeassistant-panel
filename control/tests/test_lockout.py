from custom_components.panel_control.lockout import Lockout


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def make():
    c = Clock()
    return c, Lockout(now=c)


def fail(lo, ip, n):
    for _ in range(n):
        lo.record_failure(ip)


def test_locks_after_ten_failures():
    _, lo = make()
    fail(lo, "1.1.1.1", 9)
    assert not lo.is_locked("1.1.1.1")
    lo.record_failure("1.1.1.1")
    assert lo.is_locked("1.1.1.1")


def test_unlocks_after_five_minutes():
    c, lo = make()
    fail(lo, "1.1.1.1", 10)
    c.t += 299
    assert lo.is_locked("1.1.1.1")
    c.t += 1
    assert not lo.is_locked("1.1.1.1")
    # counter restarted: 9 more failures do not lock again
    fail(lo, "1.1.1.1", 9)
    assert not lo.is_locked("1.1.1.1")


def test_success_does_not_reset_failures():
    _, lo = make()
    fail(lo, "1.1.1.1", 9)
    lo.record_success("1.1.1.1")
    fail(lo, "1.1.1.1", 9)
    assert lo.is_locked("1.1.1.1")


def test_hard_cap_evicts_oldest_unlocked_never_locked():
    c, lo = make()
    fail(lo, "9.9.9.9", 10)
    for i in range(1500):
        lo.record_failure("10.%d.%d.1" % (i // 250, i % 250))
    assert len(lo._state) <= 1024
    assert lo.is_locked("9.9.9.9")
    assert "10.0.0.1" not in lo._state  # oldest unlocked evicted


def test_prunes_at_most_once_per_second():
    c, lo = make()
    lo.record_failure("1.1.1.1")
    calls = []
    orig = lo._prune
    lo._prune = lambda t: (calls.append(t), orig(t))
    for _ in range(50):
        lo.is_locked("1.1.1.1")
    assert len(calls) == 0
    c.t += 1
    lo.is_locked("1.1.1.1")
    assert len(calls) == 1


def test_success_does_not_unlock():
    _, lo = make()
    fail(lo, "1.1.1.1", 10)
    lo.record_success("1.1.1.1")
    assert lo.is_locked("1.1.1.1")


def test_ips_independent():
    _, lo = make()
    fail(lo, "1.1.1.1", 10)
    assert lo.is_locked("1.1.1.1")
    assert not lo.is_locked("2.2.2.2")
    fail(lo, "2.2.2.2", 9)
    assert not lo.is_locked("2.2.2.2")


def test_failures_slide_out_of_window():
    c, lo = make()
    fail(lo, "1.1.1.1", 9)
    c.t += 300  # those 9 are now outside the window
    fail(lo, "1.1.1.1", 9)
    assert not lo.is_locked("1.1.1.1")
    lo.record_failure("1.1.1.1")
    assert lo.is_locked("1.1.1.1")


def test_slow_trickle_never_locks():
    c, lo = make()
    for _ in range(100):
        lo.record_failure("1.1.1.1")
        c.t += 40  # <= 8 failures per 300 s
    assert not lo.is_locked("1.1.1.1")


def test_prunes_expired_entries():
    c, lo = make()
    for i in range(50):
        lo.record_failure("10.0.0.%d" % i)
    fail(lo, "9.9.9.9", 10)
    assert len(lo._state) == 51
    c.t += 301
    lo.record_failure("3.3.3.3")
    assert set(lo._state) == {"3.3.3.3"}
    # is_locked prunes too
    c.t += 301
    assert not lo.is_locked("3.3.3.3")
    assert lo._state == {}

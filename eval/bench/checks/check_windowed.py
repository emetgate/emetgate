import more_itertools as mi


def test_reported_case():
    assert list(mi.windowed([1, 2, 3, 4, 5, 6], 3, step=2)) == [(1, 2, 3), (3, 4, 5), (5, 6, None)]


def test_aligned():
    assert list(mi.windowed([1, 2, 3, 4, 5], 3, step=2)) == [(1, 2, 3), (3, 4, 5)]


def test_large_step_fill():
    assert list(mi.windowed(range(10), 5, step=4)) == [(0, 1, 2, 3, 4), (4, 5, 6, 7, 8), (8, 9, None, None, None)]


def test_fillvalue():
    assert list(mi.windowed("abcdefg", 3, step=2, fillvalue="_")) == [("a", "b", "c"), ("c", "d", "e"), ("e", "f", "g")]
    assert list(mi.windowed(range(1, 8), 4, step=3, fillvalue="!")) == [(1, 2, 3, 4), (4, 5, 6, 7)]
    assert list(mi.windowed(range(1, 9), 4, step=3, fillvalue="!")) == [(1, 2, 3, 4), (4, 5, 6, 7), (7, 8, "!", "!")]


def test_step_one_and_ge_n():
    assert list(mi.windowed([1, 2, 3, 4], 2)) == [(1, 2), (2, 3), (3, 4)]
    assert list(mi.windowed([1, 2, 3, 4, 5], 2, step=3)) == [(1, 2), (4, 5)]
    assert list(mi.windowed([1, 2, 3, 4, 5, 6], 2, step=3)) == [(1, 2), (4, 5)]
    assert list(mi.windowed([1, 2, 3, 4, 5, 6, 7], 2, step=3)) == [(1, 2), (4, 5), (7, None)]

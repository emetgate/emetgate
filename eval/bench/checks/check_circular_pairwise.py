import more_itertools as mi


def test_basic():
    assert list(mi.circular_pairwise("abcd")) == [("a", "b"), ("b", "c"), ("c", "d"), ("d", "a")]


def test_single():
    assert list(mi.circular_pairwise("a")) == [("a", "a")]


def test_empty():
    assert list(mi.circular_pairwise([])) == []


def test_two():
    assert list(mi.circular_pairwise([1, 2])) == [(1, 2), (2, 1)]


def test_one_shot_iterator():
    it = iter(range(5))
    assert list(mi.circular_pairwise(it)) == [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)]
    assert list(it) == []


def test_exported():
    import more_itertools.more as more
    assert "circular_pairwise" in more.__all__
    from more_itertools.more import circular_pairwise
    assert circular_pairwise is mi.circular_pairwise

import itertools

import more_itertools as mi


def test_slices_match_list():
    data = list(range(12))
    bounds = [None, -15, -12, -7, -1, 0, 1, 3, 6, 11, 12, 20]
    for start, stop, step in itertools.product(bounds, bounds, [None, 1, 2, 3, -1, -2, -5]):
        p = mi.peekable(iter(data))
        assert p[start:stop:step] == data[start:stop:step], (start, stop, step)
        assert list(p) == data


def test_partial_cache_then_slice():
    p = mi.peekable(iter(range(10)))
    assert p[2] == 2
    assert p[1:-1] == list(range(1, 9))
    assert p[-3:] == [7, 8, 9]
    assert next(p) == 0
    assert p[0:-2] == list(range(1, 8))

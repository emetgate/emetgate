import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import jcs
from emetgate_verify import blake3_128
from pure_blake3 import Hasher

VECTORS = os.path.join(HERE, "..", "..", "vendor", "blake3-test-vectors", "test_vectors.json")


def check_blake3():
    with open(VECTORS, encoding="utf-8") as f:
        cases = json.load(f)["cases"]
    for case in cases:
        data = bytes(i % 251 for i in range(case["input_len"]))
        hasher = Hasher()
        hasher.update(data)
        out = hasher.finalize(len(case["hash"]) // 2).hex()
        if out != case["hash"]:
            raise SystemExit("blake3 differs from the official vector at input_len %d" % case["input_len"])
        if blake3_128(data) != case["hash"][:32]:
            raise SystemExit("blake3-128 is not the first 16 bytes of the output")
    return len(cases)


def check_jcs():
    cases = [
        ('{ "b": 1, "a": [true, null, "x", {"z": false, "y": -3}] }', '{"a":[true,null,"x",{"y":-3,"z":false}],"b":1}'),
        ('{"\\u20ac":1,"\\r":2,"\\ufb33":3,"1":4,"\\ud83d\\ude00":5,"\\u0080":6,"\\u00f6":7}', '{"\\r":2,"1":4,"\u0080":6,"\u00f6":7,"\u20ac":1,"\U0001f600":5,"\ufb33":3}'),
        ('["a\\"b\\\\c\\u0001\\u001f\\n\\t\\u00e9\\u2028"]', '["a\\"b\\\\c\\u0001\\u001f\\n\\t\u00e9\u2028"]'),
    ]
    for source, expected in cases:
        out = jcs.canonicalize(jcs.parse(source))
        if out != expected.encode("utf-8"):
            raise SystemExit("jcs mismatch: %r != %r" % (out, expected))
    for bad in ["[1.5]", "[1e3]", "[9007199254740993]", '{"a":1,"a":2}', '["\\ud800"]']:
        try:
            jcs.canonicalize(jcs.parse(bad))
        except jcs.NotCanonical:
            continue
        raise SystemExit("jcs accepted " + bad)
    return len(cases)


if __name__ == "__main__":
    vectors = check_blake3()
    jcs_cases = check_jcs()
    print("ok: %d blake3 vectors, %d jcs cases" % (vectors, jcs_cases))

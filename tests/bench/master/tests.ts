import { test } from "node:test";
import assert from "node:assert/strict";
import { add, sub, mul, clamp, sum, label } from "./calc.ts";

test("add", () => assert.equal(add(2, 3), 5));
test("sub", () => assert.equal(sub(5, 2), 3));
test("mul", () => assert.equal(mul(4, 3), 12));
test("clamp", () => { assert.equal(clamp(5, 0, 10), 5); assert.equal(clamp(-1, 0, 10), 0); assert.equal(clamp(99, 0, 10), 10); });
test("sum", () => assert.equal(sum([1, 2, 3, 4]), 10));
test("label", () => { assert.equal(label(1), "pos"); assert.equal(label(-1), "neg"); });

import { test } from "node:test";
import assert from "node:assert/strict";
import { abs1, grade, render } from "./engine.ts";

test("abs1", () => { assert.equal(abs1(-5), 5); assert.equal(abs1(3), 3); });
test("grade", () => { assert.equal(grade(95), "A"); assert.equal(grade(72), "C"); assert.equal(grade(50), "F"); });
test("render", () => assert.equal(render([1, -2, 30]), "   1| (2)|  30"));

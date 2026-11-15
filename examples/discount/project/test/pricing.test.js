const test = require('node:test');
const assert = require('node:assert');
const { roundCents, formatPrice } = require('../src/pricing.js');

test('roundCents keeps whole cents', () => assert.strictEqual(roundCents(12.5), 12.5));
test('roundCents rounds up from half a cent', () => assert.strictEqual(roundCents(2.346), 2.35));
test('roundCents rounds down below half a cent', () => assert.strictEqual(roundCents(2.344), 2.34));
test('formatPrice shows two decimals', () => assert.strictEqual(formatPrice(85), '$85.00'));
test('formatPrice rounds to cents', () => assert.strictEqual(formatPrice(25.4745), '$25.47'));
test('formatPrice of zero', () => assert.strictEqual(formatPrice(0), '$0.00'));

const test = require('node:test');
const assert = require('node:assert');
const { memberPrice, cartTotal } = require('../src/checkout.js');

test('15% discount on 100 gives 85', () => assert.strictEqual(memberPrice(100), 85));
test('15% discount on 200 gives 170', () => assert.strictEqual(memberPrice(200), 170));
test('discount on 0 is 0', () => assert.strictEqual(memberPrice(0), 0));
test('empty cart totals 0', () => assert.strictEqual(cartTotal([]), 0));
test('cart total discounts every item', () => assert.strictEqual(cartTotal([{ price: 100, qty: 2 }, { price: 20, qty: 1 }]), 187));
test('cart total rounds to cents', () => assert.strictEqual(cartTotal([{ price: 9.99, qty: 3 }]), 25.47));

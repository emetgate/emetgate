const { applyDiscount, roundCents } = require('./pricing.js');

function memberPrice(price) {
  return applyDiscount(price, 15);
}

function cartTotal(items) {
  const sum = items.reduce((total, item) => total + memberPrice(item.price) * item.qty, 0);
  return roundCents(sum);
}

module.exports = { memberPrice, cartTotal };

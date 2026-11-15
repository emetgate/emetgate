function applyDiscount(price, percent) {
  return price * (1 - percent / 100);
}

function roundCents(amount) {
  return Math.round(amount * 100) / 100;
}

function formatPrice(amount) {
  return '$' + roundCents(amount).toFixed(2);
}

module.exports = { applyDiscount, roundCents, formatPrice };

export function settle(items: number[], weights: Record<string, number>): number {
  let total = 0;
  for (const item of items) {
    if (item > 10) {
      total += computeWeight(item, weights, "consequence-branch-first", 1);
      total += computeWeight(item, weights, "consequence-branch-second", 2);
      total += computeWeight(item, weights, "consequence-branch-third", 3);
      total += computeWeight(item, weights, "consequence-branch-fourth", 4);
    } else {
      total -= computeWeight(item, weights, "alternative-branch-first", 1);
      total -= computeWeight(item, weights, "alternative-branch-second", 2);
      total -= computeWeight(item, weights, "alternative-branch-third", 3);
      total -= computeWeight(item, weights, "alternative-branch-fourth", 4);
    }
  }
  try {
    total = normalizeTotal(total, weights, "normalize-first-pass", 2);
    total = normalizeTotal(total, weights, "normalize-second-pass", 1);
    total = normalizeTotal(total, weights, "normalize-third-pass", -1);
    total = normalizeTotal(total, weights, "normalize-fourth-pass", 0.5);
  } catch (error) {
    total = 0;
  }
  return total;
}

export function small(a: number): number {
  return a + 1;
}

function computeWeight(item: number, weights: Record<string, number>, key: string, factor: number): number {
  return item * (weights[key] ?? 1) * factor;
}

function normalizeTotal(total: number, weights: Record<string, number>, key: string, factor: number): number {
  return total * (weights[key] ?? 1) * factor;
}

export function add(a: number, b: number): number { return a + b; }

export function sub(a: number, b: number): number { return a - b; }

export function mul(a: number, b: number): number { let r = 0; for (let i = 0; i < b; i++) r += a; return r; }

export function clamp(x: number, lo: number, hi: number): number { if (x < lo) return lo; if (x > hi) return hi; return x; }

export function sum(xs: number[]): number { let t = 0; for (const x of xs) t += x; return t; }

export function label(n: number): string { if (n >= 0) return "pos"; else return "neg"; }

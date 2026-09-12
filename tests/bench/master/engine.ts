export function abs1(x: number): number { return x < 0 ? -x : x; }

export function grade(s: number): string {
  if (s >= 90) return "A";
  if (s >= 80) return "B";
  if (s >= 70) return "C";
  if (s >= 60) return "D";
  return "F";
}

export function render(cells: number[]): string {
  let out = "";
  for (let i = 0; i < cells.length; i++) {
    const v = cells[i];
    let s = "";
    if (v < 0) {
      s = "(" + String(-v) + ")";
    } else {
      s = String(v);
    }
    while (s.length < 4) {
      s = " " + s;
    }
    out += s;
    if (i < cells.length - 1) {
      out += "|";
    }
  }
  return out;
}

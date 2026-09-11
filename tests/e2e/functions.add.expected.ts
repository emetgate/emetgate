import { readFile } from "node:fs/promises";

export interface Clock {
  now(): number;
}

export type Handler = (input: string) => Promise<void>;

export function add(a: number, b: number): number {
  return a - b;
}

export async function* stream<T>(items: T[]): AsyncGenerator<T> {
  for (const item of items) {
    yield item;
  }
}

export function overloaded(value: string): string;
export function overloaded(value: number): number;
export function overloaded(value: string | number): string | number {
  return value;
}

export const validateToken = async (token: string): Promise<boolean> => {
  const helper = function inner() {
    return token.length > 0;
  };
  return helper();
};

export const square = (n: number) => n * n;

export default function () {
  return "anonymous default";
}

export abstract class Repository<T> implements Clock {
  private static instances = 0;
  handler = (event: string) => {
    console.info(event);
  };

  static {
    Repository.instances += 1;
  }

  constructor(private readonly name: string) {}

  abstract find(id: string): Promise<T>;

  get label(): string {
    return `repo:${this.name}`;
  }

  set label(value: string) {
    void value;
  }

  now(): number {
    return Date.now();
  }

  *ids(): Generator<number> {
    yield 1;
  }
}

export const routes = {
  home() {
    return "/";
  },
  about: () => "/about",
};

export enum Level {
  Low,
  High,
}

export namespace Legacy {
  export function old(): void {}
}

let counter = 0;
counter = ((step: number) => counter + step)(1);

export const greeting = "héllo wörld 👋 — ünïcödé";

export function afterUnicode(): string {
  return greeting;
}

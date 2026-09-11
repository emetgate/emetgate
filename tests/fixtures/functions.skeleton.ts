import { readFile } from "node:fs/promises";

export interface Clock {
  now(): number;
}

export type Handler = (input: string) => Promise<void>;

export function add(a: number, b: number): number;

export async function* stream<T>(items: T[]): AsyncGenerator<T> {}

export function overloaded(value: string): string;
export function overloaded(value: number): number;
export function overloaded(value: string | number): string | number;

export const validateToken = async (token: string): Promise<boolean> => {};

export const square = (n: number) => n * n;

export default function () {}

export abstract class Repository<T> implements Clock {
  private static instances = 0;
  handler = (event: string) => {};

  static {}

  constructor(private readonly name: string);

  abstract find(id: string): Promise<T>;

  get label(): string;

  set label(value: string);

  now(): number;

  *ids(): Generator<number>;
}

export const routes = {
  home() {},
  about: () => "/about",
};

export enum Level {
  Low,
  High,
}

export namespace Legacy {
  export function old(): void;
}

let counter = 0;
counter = ((step: number) => counter + step)(1);

export const greeting = "héllo wörld 👋 — ünïcödé";

export function afterUnicode(): string;

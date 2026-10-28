import React from "react";
import { afterEach, describe, expect, it } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Counter } from "./Counter";

afterEach(() => cleanup());

const count = () => (screen.getByTestId("count").textContent ?? "").trim();

describe("hidden Counter", () => {
  it("starts at 0 and moves both ways", () => {
    render(React.createElement(Counter));
    expect(count()).toBe("0");
    fireEvent.click(screen.getByRole("button", { name: "Increment" }));
    fireEvent.click(screen.getByRole("button", { name: "Increment" }));
    expect(count()).toBe("2");
    fireEvent.click(screen.getByRole("button", { name: "Decrement" }));
    expect(count()).toBe("1");
  });

  it("honours initial", () => {
    render(React.createElement(Counter, { initial: 5 }));
    expect(count()).toBe("5");
    fireEvent.click(screen.getByRole("button", { name: "Decrement" }));
    expect(count()).toBe("4");
  });
});

import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { SigningExpiry } from "./SigningExpiry";

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-11-14T12:00:00Z"));
});
afterEach(() => vi.useRealTimers());

it.each([
  ["2026-11-21T12:00:00Z", "7 days remaining"],
  ["2026-11-15T12:00:00Z", "1 day remaining"],
  ["2026-11-15T11:59:59Z", "Less than 1 day remaining"],
  ["2026-11-14T12:00:00Z", "Expired"],
  ["2026-11-13T12:00:00Z", "Expired"],
])("shows read-only expiry for %s", (expiresAt, label) => {
  const { container } = render(<SigningExpiry expiresAt={expiresAt} />);
  expect(screen.getByText(label)).toBeVisible();
  expect(container.querySelector("time")).toHaveAttribute("datetime", expiresAt);
  expect(container.querySelector("time")).toHaveTextContent(new Date(expiresAt).toLocaleString());
  expect(container.querySelector("input, button, select")).toBeNull();
});

it.each([null, undefined, "invalid"])("handles an unavailable date: %s", (expiresAt) => {
  render(<SigningExpiry expiresAt={expiresAt} />);
  expect(screen.getByText("The signing expiry date is unavailable for this installation.")).toBeVisible();
});

it("updates while Settings stays open and after returning from the background", () => {
  const { unmount } = render(<SigningExpiry expiresAt="2026-11-15T12:00:00Z" />);
  act(() => vi.advanceTimersByTime(60_000));
  expect(screen.getByText("Less than 1 day remaining")).toBeVisible();
  vi.setSystemTime(new Date("2026-11-15T12:00:00Z"));
  act(() => document.dispatchEvent(new Event("visibilitychange")));
  expect(screen.getByText("Expired")).toBeVisible();
  unmount();
  expect(vi.getTimerCount()).toBe(0);
});

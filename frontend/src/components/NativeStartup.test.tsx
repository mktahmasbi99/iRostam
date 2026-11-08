import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { NativeStartup } from "./NativeStartup";

const startup = vi.hoisted(() => vi.fn());
vi.mock("@capacitor/core", () => ({ registerPlugin: () => ({ startup }) }));

it("opens local storage and initializes it only on request", async () => {
  const device = { today: "2026-11-08", timezone: "Europe/Warsaw" };
  startup.mockResolvedValueOnce({ ...device, initialized: false })
    .mockResolvedValueOnce({ ...device, initialized: true });

  render(<NativeStartup />);
  const button = await screen.findByRole("button", { name: "Create local database" });
  expect(startup).toHaveBeenCalledExactlyOnceWith({ create: false });
  await userEvent.click(button);
  expect(await screen.findByText("Local database ready.")).toBeVisible();
  expect(screen.getByText("2026-11-08 · Europe/Warsaw")).toBeVisible();
  expect(startup).toHaveBeenLastCalledWith({ create: true });
});

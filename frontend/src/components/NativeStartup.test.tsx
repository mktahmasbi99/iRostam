import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { expect, it, vi } from "vitest";
import { NativeStartup } from "./NativeStartup";

const { startup, importBackup } = vi.hoisted(() => ({ startup: vi.fn(), importBackup: vi.fn() }));
vi.mock("@capacitor/core", () => ({ registerPlugin: () => ({ startup, importBackup }) }));

it("opens local storage and initializes it only on request", async () => {
  const device = { today: "2026-11-08", timezone: "Europe/Warsaw" };
  startup.mockResolvedValueOnce({ ...device, state: "missing" })
    .mockResolvedValueOnce({ ...device, state: "empty" });

  render(<NativeStartup />);
  const button = await screen.findByRole("button", { name: "Create local database" });
  expect(startup).toHaveBeenCalledExactlyOnceWith({ create: false });
  await userEvent.click(button);
  expect(await screen.findByText("Local database ready.")).toBeVisible();
  expect(screen.getByText("2026-11-08 · Europe/Warsaw")).toBeVisible();
  expect(startup).toHaveBeenLastCalledWith({ create: true });
});

it("keeps the local setup after a rejected import and shows counts after a valid import", async () => {
  const device = { today: "2026-11-08", timezone: "Europe/Warsaw" };
  startup.mockResolvedValueOnce({ ...device, state: "empty" })
    .mockResolvedValueOnce({ ...device, state: "imported", workouts: 4, sets: 12, photos: 2 });
  importBackup.mockRejectedValueOnce(new Error("Choose a Rostam backup."))
    .mockResolvedValueOnce({ imported: true });

  render(<NativeStartup />);
  const button = await screen.findByRole("button", { name: "Import Rostam backup" });
  await userEvent.click(button);
  expect(await screen.findByRole("alert")).toHaveTextContent("Choose a Rostam backup.");
  expect(screen.getByText("Local database ready.")).toBeVisible();

  await userEvent.click(button);
  expect(await screen.findByText("4 workouts · 12 sets · 2 progress photos")).toBeVisible();
  expect(screen.queryByRole("button", { name: "Import Rostam backup" })).not.toBeInTheDocument();
});

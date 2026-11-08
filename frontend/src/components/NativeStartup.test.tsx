import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { NativeStartup } from "./NativeStartup";

const { startup, importBackup, history, exportBackup } = vi.hoisted(() => ({
  startup: vi.fn(), importBackup: vi.fn(), history: vi.fn(), exportBackup: vi.fn(),
}));
vi.mock("@capacitor/core", () => ({ Capacitor: { isNativePlatform: () => true }, registerPlugin: () => ({ startup, importBackup, history, exportBackup }) }));

beforeEach(() => vi.clearAllMocks());

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

it("opens the imported calendar without fetching from the server", async () => {
  startup.mockResolvedValueOnce({
    today: "2026-11-08", timezone: "Europe/Warsaw", state: "imported", workouts: 0, sets: 12, photos: 0,
  });
  history.mockResolvedValueOnce({ date: "2026-11-08", sections: [], workouts: [] })
    .mockResolvedValueOnce({ month: "2026-11", activeDates: ["2026-11-07"] });

  render(<NativeStartup />);
  await userEvent.click(await screen.findByRole("button", { name: "Open workout history" }));
  expect(await screen.findByText("No activity recorded")).toBeVisible();
  expect(screen.getByRole("button", { name: "Add to day" })).toBeVisible();
  await userEvent.click(screen.getByRole("button", { name: "Choose a day" }));
  expect(await screen.findByText("November 2026")).toBeVisible();
  expect(history.mock.calls).toEqual([
    [{ path: "/api/days/2026-11-08" }],
    [{ path: "/api/calendar/2026-11" }],
  ]);
});

it("exports to Files and opens restore only after confirmation", async () => {
  const user = userEvent.setup();
  const state = { today: "2026-11-08", timezone: "Europe/Warsaw", state: "imported", workouts: 1, sets: 4, photos: 0 };
  startup.mockResolvedValueOnce(state);
  exportBackup.mockResolvedValueOnce({ saved: true });
  importBackup.mockResolvedValueOnce({ imported: false });

  render(<NativeStartup />);
  await user.click(await screen.findByRole("button", { name: "Back Up Now" }));
  expect(await screen.findByText("Backup saved to Files.")).toBeVisible();
  await user.click(screen.getByRole("button", { name: "Restore from Files" }));
  let dialog = screen.getByRole("dialog", { name: "Replace the local ledger?" });
  await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
  expect(importBackup).not.toHaveBeenCalled();

  await user.click(screen.getByRole("button", { name: "Restore from Files" }));
  dialog = screen.getByRole("dialog", { name: "Replace the local ledger?" });
  await user.click(within(dialog).getByRole("button", { name: "Choose Backup" }));
  expect(importBackup).toHaveBeenCalledExactlyOnceWith({ replacing: true });
  expect(screen.getByText("1 workouts · 4 sets · 0 progress photos")).toBeVisible();
});

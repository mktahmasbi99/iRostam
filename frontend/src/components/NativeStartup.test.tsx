import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { NativeStartup } from "./NativeStartup";

const { startup, importBackup, history, exportBackup, automaticBackupStatus, listAutomaticBackups, chooseBackupFolder, setAutomaticBackup } = vi.hoisted(() => ({
  startup: vi.fn(), importBackup: vi.fn(), history: vi.fn(), exportBackup: vi.fn(), automaticBackupStatus: vi.fn(), listAutomaticBackups: vi.fn(), chooseBackupFolder: vi.fn(), setAutomaticBackup: vi.fn(),
}));
vi.mock("@capacitor/core", () => ({ Capacitor: { isNativePlatform: () => true }, registerPlugin: () => ({ startup, importBackup, history, exportBackup, automaticBackupStatus, listAutomaticBackups, chooseBackupFolder, setAutomaticBackup }) }));

beforeEach(() => {
  vi.clearAllMocks();
  automaticBackupStatus.mockResolvedValue({ enabled: false, retention: 3, lastSaved: null, error: null, hasFolder: false, folderName: null });
  listAutomaticBackups.mockResolvedValue({ files: [] });
  chooseBackupFolder.mockResolvedValue({ enabled: false, retention: 3, lastSaved: null, error: null, hasFolder: true, folderName: "Documents" });
  setAutomaticBackup.mockImplementation(async (options) => ({ ...options, lastSaved: "2026-11-11T10:00:00Z", error: null, hasFolder: true, folderName: "Documents" }));
  history.mockResolvedValue({ date: "2026-11-08", sections: [], workouts: [] });
});

it("chooses a folder before enabling automatic backups and saves the retention choice", async () => {
  startup.mockResolvedValue({ today: "2026-11-11", timezone: "Europe/Warsaw", state: "imported", workouts: 1, sets: 2, photos: 0 });
  const user = userEvent.setup();
  render(<NativeStartup />);
  await user.click(await screen.findByRole("button", { name: "Settings" }));
  expect(screen.getByRole("button", { name: "Increase backup retention" })).toBeDisabled();
  await user.click(await screen.findByRole("switch", { name: "Automatic backups" }));
  expect(chooseBackupFolder).toHaveBeenCalledOnce();
  expect(setAutomaticBackup).toHaveBeenCalledWith({ enabled: true, retention: 3 });
  expect(await screen.findByText("Folder saved")).toBeVisible();
  expect(await screen.findByText("Folder: Documents", {}, { timeout: 2500 })).toBeVisible();
  expect(await screen.findByText(/Saved to folder/)).toBeVisible();
  await user.click(screen.getByRole("button", { name: "Decrease backup retention" }));
  expect(setAutomaticBackup).toHaveBeenLastCalledWith({ enabled: true, retention: 2 });
  await user.click(screen.getByRole("button", { name: "Increase backup retention" }));
  expect(setAutomaticBackup).toHaveBeenLastCalledWith({ enabled: true, retention: 3 });
});

it("labels direct backup files and lists them without traversing folders", async () => {
  startup.mockResolvedValue({ today: "2026-11-11", timezone: "Europe/Warsaw", state: "imported", workouts: 1, sets: 2, photos: 0 });
  listAutomaticBackups.mockResolvedValue({ files: [
    { name: "iRostam-auto-install-20261111.sqlite3", category: "Automatic", modifiedAt: null, sizeBytes: 1024 },
    { name: "iRostam-20261111T100000-ABC.sqlite3", category: "On-demand", modifiedAt: null, sizeBytes: 1024 },
  ] });
  render(<NativeStartup />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  expect(await screen.findByText("Auto")).toBeVisible();
  expect(screen.queryByText("iRostam-auto-install-20261111.sqlite3")).not.toBeInTheDocument();
  expect(screen.queryByText("iRostam-20261111T100000-ABC.sqlite3")).not.toBeInTheDocument();
  expect(screen.getByText("On-demand")).toBeVisible();
});

it("offers fresh setup or backup restore before opening Today", async () => {
  const device = { today: "2026-11-08", timezone: "Europe/Warsaw" };
  startup.mockResolvedValueOnce({ ...device, state: "missing" }).mockResolvedValueOnce({ ...device, state: "imported", workouts: 0, sets: 0, photos: 0 });
  render(<NativeStartup />);
  expect(await screen.findByRole("heading", { name: "Welcome to iRostam" })).toBeVisible();
  expect(screen.queryByRole("dialog", { name: "Welcome to iRostam" })).not.toBeInTheDocument();
  expect(screen.getByRole("button", { name: "Start fresh" })).toBeVisible();
  expect(screen.getByRole("button", { name: "Restore backup" })).toBeVisible();
  expect(startup).toHaveBeenCalledExactlyOnceWith({ create: false });
  await userEvent.click(screen.getByRole("button", { name: "Start fresh" }));
  expect(await screen.findByRole("button", { name: "Today" })).toBeVisible();
  expect(startup.mock.calls).toEqual([[{ create: false }], [{ create: true }]]);

  await userEvent.click(screen.getByRole("button", { name: "Settings" }));
  expect(await screen.findByRole("heading", { name: "Backups and local storage" })).toBeVisible();
  expect(screen.getByRole("button", { name: "Restore from Files" })).toBeVisible();
});

it("keeps both setup choices visible when fresh database initialization fails", async () => {
  startup.mockResolvedValueOnce({ today: "2026-11-08", timezone: "Europe/Warsaw", state: "missing" })
    .mockRejectedValueOnce(new Error("Could not open the local iRostam database."));
  render(<NativeStartup />);
  await userEvent.click(await screen.findByRole("button", { name: "Start fresh" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("Could not open the local iRostam database.");
  expect(screen.getByRole("button", { name: "Start fresh" })).toBeVisible();
  expect(screen.getByRole("button", { name: "Restore backup" })).toBeVisible();
  expect(screen.queryByRole("button", { name: "Retry" })).not.toBeInTheDocument();
});

it("restores a backup directly from first-run setup", async () => {
  const device = { today: "2026-11-08", timezone: "Europe/Warsaw" };
  startup.mockResolvedValueOnce({ ...device, state: "missing" }).mockResolvedValueOnce({ ...device, state: "imported", workouts: 2, sets: 5, photos: 1 });
  importBackup.mockResolvedValueOnce({ imported: true });
  render(<NativeStartup />);
  await userEvent.click(await screen.findByRole("button", { name: "Restore backup" }));
  expect(importBackup).toHaveBeenCalledExactlyOnceWith({ replacing: false });
  expect(await screen.findByRole("button", { name: "Today" })).toBeVisible();
});

it("keeps backup import and restore actions in Settings", async () => {
  const state = { today: "2026-11-08", timezone: "Europe/Warsaw", state: "imported", workouts: 1, sets: 4, photos: 0, hasRecoveryBackup: true };
  startup.mockResolvedValue(state);
  exportBackup.mockResolvedValue({ saved: true });
  importBackup.mockResolvedValue({ imported: false });
  const user = userEvent.setup();
  render(<NativeStartup />);

  await user.click(await screen.findByRole("button", { name: "Settings" }));
  await user.click(screen.getByRole("button", { name: "Back Up Now" }));
  expect(await screen.findByText("Backup saved to Files.")).toBeVisible();
  await user.click(screen.getByRole("button", { name: "Restore from Files" }));
  const dialog = screen.getByRole("dialog", { name: "Replace the local ledger?" });
  await user.click(within(dialog).getByRole("button", { name: "Choose Backup" }));
  expect(importBackup).toHaveBeenCalledExactlyOnceWith({ replacing: true });
});

it("shows the installed signing profile expiry in Settings", async () => {
  const expiresAt = "2026-11-21T12:00:00Z";
  startup.mockResolvedValue({ today: "2026-11-14", timezone: "Europe/Warsaw", state: "imported", signingExpiresAt: expiresAt });
  const { container } = render(<NativeStartup />);
  await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
  expect(screen.getByRole("heading", { name: "App expiry" })).toBeVisible();
  expect(container.querySelector("time")).toHaveAttribute("datetime", expiresAt);
});

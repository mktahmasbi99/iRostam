import { registerPlugin } from "@capacitor/core";

export interface NativeStartupState {
  state: "missing" | "empty" | "imported";
  workouts?: number;
  sets?: number;
  photos?: number;
  hasRecoveryBackup?: boolean;
  today: string;
  timezone: string;
  signingExpiresAt?: string | null;
}
export interface AutomaticBackupStatus { enabled: boolean; retention: number; lastSaved: string | null; error: string | null; hasFolder: boolean; folderName: string | null; }
export interface NativeBackupFile { name: string; category: "Automatic" | "On-demand"; modifiedAt: string | null; sizeBytes: number; }

export const nativeLedger = registerPlugin<{
  startup(options: { create: boolean }): Promise<NativeStartupState>;
  importBackup(options?: { replacing: boolean }): Promise<{ imported: boolean }>;
  exportBackup(): Promise<{ saved: boolean }>;
  restoreRecovery(): Promise<{ imported: boolean }>;
  automaticBackupStatus(): Promise<AutomaticBackupStatus>;
  listAutomaticBackups(): Promise<{ files: NativeBackupFile[] }>;
  restoreListedBackup(options: { name: string }): Promise<{ imported: boolean }>;
  deleteListedBackup(options: { name: string }): Promise<{ deleted: boolean }>;
  chooseBackupFolder(): Promise<AutomaticBackupStatus>;
  setAutomaticBackup(options: { enabled: boolean; retention: number }): Promise<AutomaticBackupStatus>;
  checkAutomaticBackup(): Promise<AutomaticBackupStatus>;
  changeWorkout<T>(options: { path: string; method: string; payload: unknown }): Promise<T>;
  history<T>(options: { path: string }): Promise<T>;
}>("LocalLedger");

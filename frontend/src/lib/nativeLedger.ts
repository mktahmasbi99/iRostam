import { registerPlugin } from "@capacitor/core";

export interface NativeStartupState {
  state: "missing" | "empty" | "imported";
  workouts?: number;
  sets?: number;
  photos?: number;
  hasRecoveryBackup?: boolean;
  today: string;
  timezone: string;
}

export const nativeLedger = registerPlugin<{
  startup(options: { create: boolean }): Promise<NativeStartupState>;
  importBackup(options?: { replacing: boolean }): Promise<{ imported: boolean }>;
  exportBackup(): Promise<{ saved: boolean }>;
  restoreRecovery(): Promise<{ imported: boolean }>;
  changeWorkout<T>(options: { path: string; method: string; payload: unknown }): Promise<T>;
  history<T>(options: { path: string }): Promise<T>;
}>("LocalLedger");

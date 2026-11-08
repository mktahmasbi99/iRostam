import { registerPlugin } from "@capacitor/core";

export interface NativeStartupState {
  state: "missing" | "empty" | "imported";
  workouts?: number;
  sets?: number;
  photos?: number;
  today: string;
  timezone: string;
}

export const nativeLedger = registerPlugin<{
  startup(options: { create: boolean }): Promise<NativeStartupState>;
  importBackup(): Promise<{ imported: boolean }>;
  changeWorkout<T>(options: { path: string; method: string; payload: unknown }): Promise<T>;
  history<T>(options: { path: string }): Promise<T>;
}>("LocalLedger");

import { useEffect, useState } from "react";
import { Backdrop, Logo } from "../App";
import { nativeLedger, type NativeStartupState } from "../lib/nativeLedger";
import { applyThemePreference, readThemePreference, saveThemePreference, systemThemeQuery, type ThemePreference } from "../lib/theme";
import { NativeHistory } from "./NativeHistory";
import { Modal } from "./Modal";

type BackupAction = "import" | "export" | "restore" | "recovery" | "create";

export function NativeStartup() {
  const [request, setRequest] = useState({ create: false });
  const [result, setResult] = useState<NativeStartupState | string | null>(null);
  const [setupRequired, setSetupRequired] = useState(false);

  const [backupAction, setBackupAction] = useState<BackupAction | null>(null);
  const [backupError, setBackupError] = useState("");
  const [backupNotice, setBackupNotice] = useState("");
  const [confirmRestore, setConfirmRestore] = useState<"restore" | "recovery" | null>(null);
  const [themePreference, setThemePreference] = useState<ThemePreference>(readThemePreference);
  useEffect(() => {
    const systemTheme = systemThemeQuery();
    const apply = () => applyThemePreference(themePreference);
    apply();
    if (themePreference !== "system") return;
    systemTheme.addEventListener("change", apply);
    return () => systemTheme.removeEventListener("change", apply);
  }, [themePreference]);

  const changeThemePreference = (preference: ThemePreference) => {
    saveThemePreference(preference);
    setThemePreference(preference);
  };

  useEffect(() => {
    let active = true;
    let busy = false;
    const load = async (create: boolean) => {
      if (busy) return;
      busy = true;
      try {
        const startup = await nativeLedger.startup({ create });
        if (active) {
          setResult(startup);
          setSetupRequired(startup.state !== "imported");
        }
      } catch {
        if (active) setResult("Could not open the local iRostam database.");
      } finally {
        if (create && active) setBackupAction(null);
        busy = false;
      }
    };
    const refresh = () => {
      if (!document.hidden) void load(false);
    };
    void load(request.create);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      active = false;
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [request]);

  const load = (create: boolean) => {
    setResult(null);
    setRequest({ create });
  };

  const runBackupAction = async (action: BackupAction) => {
    setBackupError("");
    setBackupNotice("");
    setBackupAction(action);
    setConfirmRestore(null);
    try {
      if (action === "export") {
        if ((await nativeLedger.exportBackup()).saved) setBackupNotice("Backup saved to Files.");
        return;
      }
      const { imported } = action === "recovery" ? await nativeLedger.restoreRecovery()
        : await nativeLedger.importBackup({ replacing: action === "restore" });
      if (imported) {
        if (action !== "import") setBackupNotice("Backup restored. The previous ledger was kept as a recovery copy.");
        load(false);
      }
    } catch (error) {
      setBackupError(error instanceof Error ? error.message : "Could not complete the backup action.");
    } finally {
      setBackupAction(null);
    }
  };

  if (result && typeof result !== "string" && result.state === "imported") {
    return <><Backdrop /><NativeHistory today={result.today} timezone={result.timezone} settingsContent={<main className="page">
      <header className="section-title"><h1>Settings</h1><p>Backups and local storage</p></header>
      <p>{result.workouts} workouts · {result.sets} sets · {result.photos} progress photos</p>
      <div className="stack">
        <section className="settings-card appearance-settings"><div><h2>Appearance</h2><p>Choose how iRostam looks.</p></div><div className="segmented appearance-options" role="group" aria-label="Theme">
          {(["system", "light", "dark"] as const).map((preference) => <button key={preference} type="button" className={themePreference === preference ? "selected" : ""} aria-pressed={themePreference === preference} onClick={() => changeThemePreference(preference)}>{preference[0].toUpperCase() + preference.slice(1)}</button>)}
        </div></section>
        <section className="settings-card"><h2>Backups and local storage</h2>
          <div className="native-backup-actions">
            <button className="primary" disabled={backupAction !== null} onClick={() => void runBackupAction("export")}>Back Up Now</button>
            <button className="secondary" disabled={backupAction !== null} onClick={() => setConfirmRestore("restore")}>Restore from Files</button>
            {result.hasRecoveryBackup && <button className="secondary" disabled={backupAction !== null} onClick={() => setConfirmRestore("recovery")}>Restore Previous Ledger</button>}
          </div>
          {backupAction && <p role="status">{backupAction === "export" ? "Preparing backup for Files…" : "Reading backup…"}</p>}
          {backupNotice && <p role="status">{backupNotice}</p>}
          {backupError && <p className="error" role="alert">{backupError}</p>}
        </section>
      </div>
    </main>} />
      {confirmRestore && <Modal title={confirmRestore === "recovery" ? "Restore the previous ledger?" : "Replace the local ledger?"} onClose={() => setConfirmRestore(null)}>
        <p>{confirmRestore === "recovery" ? "Restore the ledger saved before your last restore. The current ledger will be kept as a new recovery copy."
          : "Choose a backup in Files to replace the current ledger."} iRostam will keep a recovery copy of the current ledger.</p>
        <div className="draft-actions">
          <button onClick={() => setConfirmRestore(null)}>Cancel</button>
          <button className="primary" onClick={() => void runBackupAction(confirmRestore)}>
            {confirmRestore === "recovery" ? "Restore Previous Ledger" : "Choose Backup"}
          </button>
        </div>
      </Modal>}
    </>;
  }

  if (setupRequired) {
    return <><Backdrop /><main className="startup setup-startup">
      <Logo className="app-logo startup-logo" sizes="112px" />
      <h1>Welcome to iRostam</h1>
      <p className="setup-copy">Start with a fresh ledger and the standard exercises, or restore an existing Rostam backup.</p>
      {typeof result === "string" && <p className="error" role="alert">{result}</p>}
      {backupError && <p className="error" role="alert">{backupError}</p>}
      {backupAction && <p role="status">{backupAction === "create" ? "Preparing your fresh ledger…" : "Reading backup…"}</p>}
      <div className="setup-actions">
        <button className="primary" disabled={backupAction !== null} onClick={() => { setBackupError(""); setBackupAction("create"); setRequest({ create: true }); }}>Start fresh</button>
        <button className="secondary" disabled={backupAction !== null} onClick={() => void runBackupAction("import")}>Restore backup</button>
      </div>
    </main></>;
  }

  return <>
    <Backdrop />
    <main className="startup">
      <Logo className="app-logo startup-logo" sizes="112px" />
      <h1>iRostam</h1>
      {result === null ? <p role="status">Opening Today…</p> :
        typeof result === "string" ? <>
          <p className="error" role="alert">{result}</p>
          <button onClick={() => load(false)}>Retry</button>
        </> : null}
    </main>
    {confirmRestore && <Modal title={confirmRestore === "recovery" ? "Restore the previous ledger?" : "Replace the local ledger?"} onClose={() => setConfirmRestore(null)}>
      <p>{confirmRestore === "recovery" ? "Restore the ledger saved before your last restore. The current ledger will be kept as a new recovery copy."
        : "Choose a backup in Files to replace the current ledger."} iRostam will keep a recovery copy of the current ledger.</p>
      <div className="draft-actions">
        <button onClick={() => setConfirmRestore(null)}>Cancel</button>
        <button className="primary" onClick={() => void runBackupAction(confirmRestore)}>
          {confirmRestore === "recovery" ? "Restore Previous Ledger" : "Choose Backup"}
        </button>
      </div>
    </Modal>}
  </>;
}

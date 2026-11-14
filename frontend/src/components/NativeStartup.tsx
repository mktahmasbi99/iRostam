import { useEffect, useState } from "react";
import { Check, Minus, Plus, RotateCcw, Trash2 } from "lucide-react";
import { Backdrop, Logo } from "../App";
import { nativeLedger, type AutomaticBackupStatus, type NativeBackupFile, type NativeStartupState } from "../lib/nativeLedger";
import { applyThemePreference, readThemePreference, saveThemePreference, systemThemeQuery, type ThemePreference } from "../lib/theme";
import { NativeHistory } from "./NativeHistory";
import { Modal } from "./Modal";
import { SigningExpiry } from "./SigningExpiry";

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
  const [autoBackup, setAutoBackup] = useState<AutomaticBackupStatus | null>(null);
  const [autoError, setAutoError] = useState("");
  const [autoFiles, setAutoFiles] = useState<NativeBackupFile[]>([]);
  const [folderSaved, setFolderSaved] = useState(false);
  const [pendingFileAction, setPendingFileAction] = useState<{ kind: "restore" | "delete"; file: NativeBackupFile } | null>(null);
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
          if (startup.state === "imported") {
            void nativeLedger.automaticBackupStatus().then(setAutoBackup).catch(() => {});
            void nativeLedger.listAutomaticBackups().then((list) => setAutoFiles(list.files)).catch((error) => setAutoError(error instanceof Error ? error.message : "Could not list backups in the selected folder."));
          }
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
        if ((await nativeLedger.exportBackup()).saved) { setBackupNotice("Backup saved to Files."); if (autoBackup?.hasFolder) setAutoFiles((await nativeLedger.listAutomaticBackups()).files); }
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

  const confirmFolder = (status: AutomaticBackupStatus) => {
    setAutoBackup(status);
    if (status.hasFolder) { setFolderSaved(true); window.setTimeout(() => setFolderSaved(false), 1800); }
  };
  const refreshAutoFiles = async () => setAutoFiles((await nativeLedger.listAutomaticBackups()).files);
  const retryAutomatic = async () => {
    setAutoError("");
    try { setAutoBackup(await nativeLedger.checkAutomaticBackup()); await refreshAutoFiles(); }
    catch (error) { setAutoError(error instanceof Error ? error.message : "Could not access automatic backups."); }
  };
  const runFileAction = async () => {
    if (!pendingFileAction) return;
    try {
      if (pendingFileAction.kind === "restore") {
        await nativeLedger.restoreListedBackup({ name: pendingFileAction.file.name });
        setBackupNotice("Backup restored. The previous ledger was kept as a recovery copy.");
        setPendingFileAction(null); load(false);
      } else {
        await nativeLedger.deleteListedBackup({ name: pendingFileAction.file.name });
        setPendingFileAction(null); await refreshAutoFiles();
      }
    } catch (error) { setAutoError(error instanceof Error ? error.message : "Could not complete this backup action."); setPendingFileAction(null); }
  };
  const chooseAutoFolder = async () => { setAutoError(""); try { confirmFolder(await nativeLedger.chooseBackupFolder()); await refreshAutoFiles(); } catch (error) { setAutoError(error instanceof Error ? error.message : "Could not choose a folder."); } };
  const updateAuto = async (enabled: boolean, retention = autoBackup?.retention ?? 3) => {
    setAutoError("");
    try {
      if (enabled && !autoBackup?.hasFolder) { const selected = await nativeLedger.chooseBackupFolder(); confirmFolder(selected); if (!selected.hasFolder) return; }
      setAutoBackup(await nativeLedger.setAutomaticBackup({ enabled, retention }));
      await refreshAutoFiles();
    } catch (error) { setAutoError(error instanceof Error ? error.message : "Automatic backup could not be updated."); }
  };

  if (result && typeof result !== "string" && result.state === "imported") {
    return <><Backdrop /><NativeHistory today={result.today} timezone={result.timezone} settingsContent={<main className="page">
      <header className="section-title"><h1>Settings</h1><p>Backups and local storage</p></header>
      <p>{result.workouts} workouts · {result.sets} sets · {result.photos} progress photos</p>
      <div className="stack">
        <section className="settings-card appearance-settings"><div><h2>Appearance</h2><p>Choose how iRostam looks.</p></div><div className="segmented appearance-options" role="group" aria-label="Theme">
          {(["system", "light", "dark"] as const).map((preference) => <button key={preference} type="button" className={themePreference === preference ? "selected" : ""} aria-pressed={themePreference === preference} onClick={() => changeThemePreference(preference)}>{preference[0].toUpperCase() + preference.slice(1)}</button>)}
        </div></section>
        <SigningExpiry expiresAt={result.signingExpiresAt} />
        <section className="settings-card"><h2>Backups and local storage</h2>
          {autoBackup && <div className="stack"><label className={`native-auto-backup-toggle${autoBackup.enabled ? " is-enabled" : ""}`}><input type="checkbox" role="switch" aria-checked={autoBackup.enabled} checked={autoBackup.enabled} onChange={(event) => void updateAuto(event.target.checked)} /> Automatic backups</label>
            <div className="native-backup-folder-row"><div className={`native-backup-folder-status${folderSaved ? " folder-saved" : autoBackup.hasFolder ? " folder-set" : ""}`} role="status" aria-live="polite">{folderSaved ? <><Check aria-hidden="true" />Folder saved</> : autoBackup.folderName ? `Folder: ${autoBackup.folderName}` : "No automatic backup folder selected"}</div><button className="secondary" onClick={() => void chooseAutoFolder()}>{autoBackup.hasFolder ? "Change folder" : "Choose folder"}</button></div>
            <div className={`native-backup-retention${autoBackup.enabled ? "" : " disabled"}`} aria-label="Automatic backup retention"><span>Keep {autoBackup.retention} daily automatic backup{autoBackup.retention === 1 ? "" : "s"}</span><div><button aria-label="Decrease backup retention" disabled={!autoBackup.enabled || autoBackup.retention <= 1} onClick={() => void updateAuto(true, autoBackup.retention - 1)}><Minus aria-hidden="true" /></button><button aria-label="Increase backup retention" disabled={!autoBackup.enabled} onClick={() => void updateAuto(true, autoBackup.retention + 1)}><Plus aria-hidden="true" /></button></div></div>
            <h3>Available backups</h3>
            {autoFiles.length ? <ul className="native-backup-file-list">{autoFiles.map((file) => { const date = file.modifiedAt ? new Date(file.modifiedAt) : null; const time = date ? `${date.toLocaleDateString()} · ${date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : "Date unavailable"; const label = `${file.category} backup ${time}`; return <li key={file.name}><div className="native-backup-file-info"><span className={`backup-type-tag ${file.category === "Automatic" ? "automatic" : "on-demand"}`}>{file.category === "Automatic" ? "Auto" : "On-demand"}</span><strong>{time}</strong></div><div className="native-backup-file-actions"><button aria-label={`Restore ${label}`} onClick={() => setPendingFileAction({ kind: "restore", file })}><RotateCcw aria-hidden="true" /></button><button className="delete-backup" aria-label={`Delete ${label}`} onClick={() => setPendingFileAction({ kind: "delete", file })}><Trash2 aria-hidden="true" /></button></div></li>; })}</ul> : <p>No backup files found in this folder.</p>}
            {autoBackup.lastSaved && <p>Saved to folder · {new Date(autoBackup.lastSaved).toLocaleString()}</p>}
            {(autoBackup.error || autoError) && <><p className="error" role="alert">{autoBackup.error || autoError}</p><button className="secondary" onClick={() => void retryAutomatic()}>Retry backup access</button></>}
            <p>Backups run when iRostam is used. Cloud upload depends on the folder provider.</p>
          </div>}
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
      {pendingFileAction && <Modal title={pendingFileAction.kind === "restore" ? "Restore this backup?" : "Delete this backup?"} onClose={() => setPendingFileAction(null)}><p>{pendingFileAction.kind === "restore" ? "This replaces the current ledger. iRostam will keep a recovery copy." : "This permanently deletes this backup file."} <strong>{pendingFileAction.file.modifiedAt ? new Date(pendingFileAction.file.modifiedAt).toLocaleString() : "Date unavailable"}</strong></p><div className="draft-actions"><button onClick={() => setPendingFileAction(null)}>Cancel</button><button className={pendingFileAction.kind === "delete" ? "danger-button" : "secondary"} onClick={() => void runFileAction()}>{pendingFileAction.kind === "restore" ? "Restore backup" : "Delete backup"}</button></div></Modal>}
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

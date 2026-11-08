import { useEffect, useState } from "react";
import { Backdrop, Logo } from "../App";
import { nativeLedger, type NativeStartupState } from "../lib/nativeLedger";
import { NativeHistory } from "./NativeHistory";
import { Modal } from "./Modal";

type BackupAction = "import" | "export" | "restore" | "recovery";

export function NativeStartup() {
  const [request, setRequest] = useState({ create: false });
  const [result, setResult] = useState<NativeStartupState | string | null>(null);

  const [backupAction, setBackupAction] = useState<BackupAction | null>(null);
  const [backupError, setBackupError] = useState("");
  const [backupNotice, setBackupNotice] = useState("");
  const [confirmRestore, setConfirmRestore] = useState<"restore" | "recovery" | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);

  useEffect(() => {
    let active = true;
    let busy = false;
    const load = async (create: boolean) => {
      if (busy) return;
      busy = true;
      try {
        const startup = await nativeLedger.startup({ create });
        if (active) setResult(startup);
      } catch {
        if (active) setResult("Could not open the local iRostam database.");
      } finally {
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

  if (historyOpen && result && typeof result !== "string") {
    return <><Backdrop /><NativeHistory today={result.today} timezone={result.timezone} onClose={() => { setHistoryOpen(false); load(false); }} /></>;
  }

  return <>
    <Backdrop />
    <main className="startup">
      <Logo className="app-logo startup-logo" sizes="112px" />
      <h1>iRostam</h1>
      {result === null ? <p role="status">Checking local storage…</p> :
        typeof result === "string" ? <>
          <p className="error" role="alert">{result}</p>
          <button onClick={() => load(false)}>Retry</button>
        </> : <>
          <p>{result.state === "imported" ? "Rostam backup imported." : result.state === "empty" ? "Local database ready." : "Set up local storage for iRostam."}</p>
          <p>{result.today} · {result.timezone}</p>
          {result.state === "imported" ? <>
            <p>{result.workouts} workouts · {result.sets} sets · {result.photos} progress photos</p>
            <button disabled={backupAction !== null} onClick={() => setHistoryOpen(true)}>Open workout history</button>
            <button disabled={backupAction !== null} onClick={() => void runBackupAction("export")}>Back Up Now</button>
            <button disabled={backupAction !== null} onClick={() => setConfirmRestore("restore")}>Restore from Files</button>
            {result.hasRecoveryBackup && <button disabled={backupAction !== null}
              onClick={() => setConfirmRestore("recovery")}>Restore Previous Ledger</button>}
          </> : <>
            <button disabled={backupAction !== null} onClick={() => void runBackupAction("import")}>Import Rostam backup</button>
            {result.state === "missing" && <button disabled={backupAction !== null} onClick={() => load(true)}>Create local database</button>}
          </>}
          {result.state !== "imported" && <p>Import a Rostam backup to start logging workouts.</p>}
        </>}
      {backupAction && <p role="status">{backupAction === "export" ? "Preparing backup for Files…" : "Reading backup…"}</p>}
      {backupNotice && <p role="status">{backupNotice}</p>}
      {backupError && <p className="error" role="alert">{backupError}</p>}
    </main>
    {confirmRestore && <Modal title="Replace the local ledger?" onClose={() => setConfirmRestore(null)}>
      <p>{confirmRestore === "recovery" ? "Restore the ledger saved before the last replacement."
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

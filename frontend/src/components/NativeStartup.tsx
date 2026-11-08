import { useEffect, useState } from "react";
import { Backdrop, Logo } from "../App";
import { nativeLedger, type NativeStartupState } from "../lib/nativeLedger";
import { NativeHistory } from "./NativeHistory";

export function NativeStartup() {
  const [request, setRequest] = useState({ create: false });
  const [result, setResult] = useState<NativeStartupState | string | null>(null);

  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState("");
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

  const importBackup = async () => {
    setImportError("");
    setImporting(true);
    try {
      if ((await nativeLedger.importBackup()).imported) load(false);
    } catch (error) {
      setImportError(error instanceof Error ? error.message : "Could not import the Rostam backup.");
    } finally {
      setImporting(false);
    }
  };

  if (historyOpen && result && typeof result !== "string") {
    return <><Backdrop /><NativeHistory today={result.today} onClose={() => setHistoryOpen(false)} /></>;
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
            <button onClick={() => setHistoryOpen(true)}>Open workout history</button>
          </> : <>
            <button disabled={importing} onClick={() => void importBackup()}>Import Rostam backup</button>
            {result.state === "missing" && <button disabled={importing} onClick={() => load(true)}>Create local database</button>}
            {importing && <p role="status">Waiting for a backup from Files…</p>}
            {importError && <p className="error" role="alert">{importError}</p>}
          </>}
          <p>Workout logging is planned for a later test build.</p>
        </>}
    </main>
  </>;
}

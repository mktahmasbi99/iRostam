import { registerPlugin } from "@capacitor/core";
import { useEffect, useState } from "react";
import { Backdrop, Logo } from "../App";

interface Startup {
  initialized: boolean;
  today: string;
  timezone: string;
}

const ledger = registerPlugin<{ startup(options: { create: boolean }): Promise<Startup> }>("LocalLedger");

export function NativeStartup() {
  const [request, setRequest] = useState({ create: false });
  const [result, setResult] = useState<Startup | string | null>(null);

  useEffect(() => {
    let active = true;
    let busy = false;
    const load = async (create: boolean) => {
      if (busy) return;
      busy = true;
      try {
        const startup = await ledger.startup({ create });
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
          <p>{result.initialized ? "Local database ready." : "Set up local storage for iRostam."}</p>
          <p>{result.today} · {result.timezone}</p>
          {!result.initialized && <button onClick={() => load(true)}>Create local database</button>}
          <p>Backup import and workout logging are planned for later test builds.</p>
        </>}
    </main>
  </>;
}

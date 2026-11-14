import { useEffect, useState } from "react";

export function SigningExpiry({ expiresAt }: { expiresAt?: string | null }) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const refresh = () => setNow(Date.now());
    const timer = window.setInterval(refresh, 60_000);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);

  const expiry = expiresAt ? new Date(expiresAt) : null;
  const remaining = expiry ? expiry.getTime() - now : NaN;
  const days = Math.ceil(remaining / 86_400_000);

  return <section className="settings-card">
    <h2>App expiry</h2>
    {Number.isFinite(remaining) && expiry ? <>
      <dl>
        <div><dt>Time remaining</dt><dd>{remaining <= 0 ? "Expired" : remaining < 86_400_000 ? "Less than 1 day remaining" : `${days} ${days === 1 ? "day" : "days"} remaining`}</dd></div>
        <div><dt>Expires</dt><dd><time dateTime={expiresAt ?? undefined}>{expiry.toLocaleString()}</time></dd></div>
      </dl>
      <p>To renew, connect your iPhone to your Mac and run iRostam from Xcode using the same signing team and bundle identifier.</p>
    </> : <p>The signing expiry date is unavailable for this installation.</p>}
  </section>;
}

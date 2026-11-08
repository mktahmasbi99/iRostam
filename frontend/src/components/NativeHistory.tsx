import { lazy, Suspense, useState } from "react";
import { DayPage } from "./DayPage";

const CalendarPage = lazy(() => import("./CalendarPage").then((module) => ({ default: module.CalendarPage })));

export function NativeHistory({ today, onClose }: { today: string; onClose: () => void }) {
  const [selected, setSelected] = useState<string | null>(null);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const day = selected ?? today;
  const shift = (amount: number) => {
    const date = new Date(`${day}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + amount);
    setSelected(date.toISOString().slice(0, 10));
  };

  return <div data-rostam-app className="app-shell native-history">
    <div className="brand">
      <button className="secondary" onClick={onClose}>Back to local storage</button>
    </div>
    <div className="content">
      <DayPage key={day} day={day} today={today} readOnly
        onOpenCalendar={() => setCalendarOpen(true)}
        onPreviousDay={() => shift(-1)}
        onNextDay={() => shift(1)}
        onChooseDay={setSelected} />
    </div>
    {calendarOpen && <Suspense fallback={<div role="status">Loading calendar…</div>}><CalendarPage today={today}
      onChooseDay={(date) => { setSelected(date); setCalendarOpen(false); }}
      onClose={() => setCalendarOpen(false)} /></Suspense>}
  </div>;
}

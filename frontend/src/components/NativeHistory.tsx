import { lazy, Suspense, useState } from "react";
import { DayPage } from "./DayPage";

const ExercisesPage = lazy(() => import("./ExercisesPage").then((module) => ({ default: module.ExercisesPage })));
const CalendarPage = lazy(() => import("./CalendarPage").then((module) => ({ default: module.CalendarPage })));

export function NativeHistory({ today, timezone, onClose }: { today: string; timezone: string; onClose: () => void }) {
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const day = selected ?? today;
  const shift = (amount: number) => {
    const date = new Date(`${day}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + amount);
    setSelected(date.toISOString().slice(0, 10));
  };

  return <div data-rostam-app className="app-shell native-history">
    <div className="native-history-controls content">
      <button className="secondary" onClick={onClose}>Backups and local storage</button>
      <button className="secondary" onClick={() => setLibraryOpen(!libraryOpen)}>
        {libraryOpen ? "Workout history" : "Exercise library"}
      </button>
    </div>
    <div className="content">
      {libraryOpen ? <Suspense fallback={<div role="status">Loading exercises…</div>}><ExercisesPage /></Suspense>
        : <DayPage key={day} day={day} today={today} timezone={timezone} offline
        onOpenCalendar={() => setCalendarOpen(true)}
        onPreviousDay={() => shift(-1)}
        onNextDay={() => shift(1)}
        onChooseDay={setSelected} />}
    </div>
    {calendarOpen && <Suspense fallback={<div role="status">Loading calendar…</div>}><CalendarPage today={today}
      onChooseDay={(date) => { setSelected(date); setCalendarOpen(false); }}
      onClose={() => setCalendarOpen(false)} /></Suspense>}
  </div>;
}

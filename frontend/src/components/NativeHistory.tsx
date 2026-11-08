import { lazy, Suspense, useState } from "react";
import { DayPage } from "./DayPage";

const ExercisesPage = lazy(() => import("./ExercisesPage").then((module) => ({ default: module.ExercisesPage })));
const RotationsPage = lazy(() => import("./RotationsPage").then((module) => ({ default: module.RotationsPage })));
const CalendarPage = lazy(() => import("./CalendarPage").then((module) => ({ default: module.CalendarPage })));
const PhotosPage = lazy(() => import("./PhotosPage").then((module) => ({ default: module.PhotosPage })));

export function NativeHistory({ today, timezone, onClose }: { today: string; timezone: string; onClose: () => void }) {
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [rotationsOpen, setRotationsOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [photosOpen, setPhotosOpen] = useState(false);
  const day = selected ?? today;
  const shift = (amount: number) => {
    const date = new Date(`${day}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + amount);
    setSelected(date.toISOString().slice(0, 10));
  };

  return <div data-rostam-app className="app-shell native-history">
    <div className="native-history-controls content">
      <button className="secondary" onClick={onClose}>Backups and local storage</button>
      <button className="secondary" onClick={() => { setLibraryOpen(!libraryOpen); setRotationsOpen(false); }}>
        {libraryOpen || rotationsOpen ? "Workout history" : "Exercise library"}
      </button>
      <button className="secondary" onClick={() => { setRotationsOpen(!rotationsOpen); setLibraryOpen(false); }}>
        {rotationsOpen ? "Workout history" : "Rotations"}
      </button>
      <button className="secondary" onClick={() => { setPhotosOpen(!photosOpen); setLibraryOpen(false); setRotationsOpen(false); }}>
        {photosOpen ? "Workout history" : "Photos"}
      </button>
    </div>
    <div className="content">
      {photosOpen ? <Suspense fallback={<div role="status">Loading photos…</div>}><PhotosPage today={today} onChooseDay={(date) => { setSelected(date); setPhotosOpen(false); }} /></Suspense>
        : rotationsOpen ? <Suspense fallback={<div role="status">Loading rotations…</div>}><RotationsPage /></Suspense>
        : libraryOpen ? <Suspense fallback={<div role="status">Loading exercises…</div>}><ExercisesPage /></Suspense>
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

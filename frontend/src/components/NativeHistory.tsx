import { Activity, Dumbbell, Images, ListChecks, NotebookPen, RotateCw, Ruler, Settings } from "lucide-react";
import { lazy, Suspense, useState, type ReactNode } from "react";
import { DayPage } from "./DayPage";

const ExercisesPage = lazy(() => import("./ExercisesPage").then((module) => ({ default: module.ExercisesPage })));
const ActivitiesPage = lazy(() => import("./ActivitiesPage").then((module) => ({ default: module.ActivitiesPage })));
const RotationsPage = lazy(() => import("./RotationsPage").then((module) => ({ default: module.RotationsPage })));
const CalendarPage = lazy(() => import("./CalendarPage").then((module) => ({ default: module.CalendarPage })));
const PhotosPage = lazy(() => import("./PhotosPage").then((module) => ({ default: module.PhotosPage })));
const NotesPage = lazy(() => import("./NotesPage").then((module) => ({ default: module.NotesPage })));
const MeasurementsPage = lazy(() => import("./MeasurementsPage").then((module) => ({ default: module.MeasurementsPage })));

type View = "today" | "exercises" | "activities" | "rotations" | "notes" | "photos" | "measurements" | "settings";

export function NativeHistory({ today, timezone, settingsContent }: { today: string; timezone: string; settingsContent: ReactNode }) {
  const [view, setView] = useState<View>("today");
  const [selected, setSelected] = useState<string | null>(null);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const day = selected ?? today;
  const shift = (amount: number) => {
    const date = new Date(`${day}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() + amount);
    setSelected(date.toISOString().slice(0, 10));
  };
  const navigate = (next: View) => { setView(next); setCalendarOpen(false); };

  return <div data-rostam-app className="app-shell native-history">
    <div className="content">
      {view === "settings" ? settingsContent
        : view === "photos" ? <Suspense fallback={<div role="status">Loading photos…</div>}><PhotosPage today={today} onChooseDay={(date) => { setSelected(date); navigate("today"); }} /></Suspense>
        : view === "notes" ? <Suspense fallback={<div role="status">Loading notes…</div>}><NotesPage /></Suspense>
        : view === "measurements" ? <Suspense fallback={<div role="status">Loading measurements…</div>}><MeasurementsPage today={today} /></Suspense>
        : view === "rotations" ? <Suspense fallback={<div role="status">Loading rotations…</div>}><RotationsPage /></Suspense>
        : view === "activities" ? <Suspense fallback={<div role="status">Loading activities…</div>}><ActivitiesPage /></Suspense>
        : view === "exercises" ? <Suspense fallback={<div role="status">Loading exercises…</div>}><ExercisesPage /></Suspense>
        : <DayPage key={day} day={day} today={today} timezone={timezone} offline
          onOpenCalendar={() => setCalendarOpen(true)} onPreviousDay={() => shift(-1)}
          onNextDay={() => shift(1)} onChooseDay={setSelected} />}
    </div>
    {calendarOpen && <Suspense fallback={<div role="status">Loading calendar…</div>}><CalendarPage today={today}
      onChooseDay={(date) => { setSelected(date); setCalendarOpen(false); }} onClose={() => setCalendarOpen(false)} /></Suspense>}
    <nav className="bottom-nav" aria-label="Primary navigation">
      <button aria-label="Today" title="Today" className={view === "today" ? "active" : ""} onClick={() => navigate("today")}><ListChecks /></button>
      <button aria-label="Exercises" title="Exercises" className={view === "exercises" ? "active" : ""} onClick={() => navigate("exercises")}><Dumbbell /></button>
      <button aria-label="Activities" title="Activities" className={view === "activities" ? "active" : ""} onClick={() => navigate("activities")}><Activity /></button>
      <button aria-label="Rotations" title="Rotations" className={view === "rotations" ? "active" : ""} onClick={() => navigate("rotations")}><RotateCw /></button>
      <button aria-label="Notes" title="Notes" className={view === "notes" ? "active" : ""} onClick={() => navigate("notes")}><NotebookPen /></button>
      <button aria-label="Photos" title="Photos" className={view === "photos" ? "active" : ""} onClick={() => navigate("photos")}><Images /></button>
      <button aria-label="Measurements" title="Measurements" className={view === "measurements" ? "active" : ""} onClick={() => navigate("measurements")}><Ruler /></button>
      <button aria-label="Settings" title="Settings" className={view === "settings" ? "active" : ""} onClick={() => navigate("settings")}><Settings /></button>
    </nav>
  </div>;
}

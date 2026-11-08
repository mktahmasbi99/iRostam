import { Plus, Trash2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../lib/api";
import type { PhotoGroup } from "../lib/types";
import { ReadState } from "./ReadState";
import { DailyJournal } from "./DailyJournal";
import { PhotoImageLink } from "./PhotoImageLink";

export function PhotosPage({ today, onChooseDay }: { today: string; onChooseDay: (day: string) => void }) {
  const [uploadDay, setUploadDay] = useState<string | null>(null);
  const [groups, setGroups] = useState<PhotoGroup[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [nextBeforeDate, setNextBeforeDate] = useState<string | null>(null);
  const [olderLoading, setOlderLoading] = useState(false);
  const [olderError, setOlderError] = useState("");
  const [deleteError, setDeleteError] = useState("");
  const failedCursor = useRef<string | null>(null);
  const galleryVersion = useRef(0);
  const load = useCallback(async (signal?: AbortSignal) => {
    const version = ++galleryVersion.current;
    setLoading(true);
    setOlderLoading(false);
    setError("");
    try {
      const result = await api.photos({ signal });
      if (signal?.aborted || version !== galleryVersion.current) return;
      failedCursor.current = null;
      setOlderError("");
      setGroups(result.items);
      setNextBeforeDate(result.nextBeforeDate);
      setLoaded(true);
    } catch (caught) {
      if (!signal?.aborted && version === galleryVersion.current) setError(caught instanceof Error ? caught.message : "Could not load photos.");
    } finally {
      if (!signal?.aborted && version === galleryVersion.current) setLoading(false);
    }
  }, []);
  const loadOlder = async (cursor = failedCursor.current ?? nextBeforeDate) => {
    if (!cursor || loading || olderLoading) return;
    const version = galleryVersion.current;
    setOlderLoading(true);
    setOlderError("");
    failedCursor.current = cursor;
    try {
      const result = await api.photos({ beforeDate: cursor });
      if (version !== galleryVersion.current) return;
      setGroups((current) => [...current, ...result.items]);
      setNextBeforeDate(result.nextBeforeDate);
      failedCursor.current = null;
    } catch (caught) {
      if (version === galleryVersion.current) setOlderError(caught instanceof Error ? caught.message : "Could not load older photos.");
    } finally { if (version === galleryVersion.current) setOlderLoading(false); }
  };
  function chooseDay(day: string) {
    onChooseDay(day);
    requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: "auto" }));
  }
  async function removePhoto(id: number) {
    if (!window.confirm("Delete this photo? This cannot be undone.")) return;
    setDeleteError("");
    try {
      await api.deletePhoto(id);
      setGroups((current) => current.flatMap((group) => {
        const photos = group.photos.filter((photo) => photo.id !== id);
        return photos.length ? [{ ...group, photos }] : [];
      }));
    } catch (caught) {
      setDeleteError(caught instanceof Error ? caught.message : "Could not delete photo.");
    }
  }
  useEffect(() => {
    const controller = new AbortController();
    void load(controller.signal);
    return () => controller.abort();
  }, [load]);
  return <main className="page"><header className="section-title"><h1>Photos</h1><p>Private daily photos, newest first.</p></header><div className="page-create-action"><button className="rotation-create-icon" aria-label="Add photos for today" title="Add photos for today" disabled={!loaded || loading} onClick={() => setUploadDay(today)}><Plus /></button></div>{uploadDay && <DailyJournal key={uploadDay} day={uploadDay} today={today} note={null} photoCount={groups.find((group) => group.date === uploadDay)?.photos.length ?? 0} onChanged={() => void load()} initialMode="photos" hideActions onClose={() => setUploadDay(null)} />}<ReadState loading={loading} error={error} hasData={loaded} onRetry={() => void load()} loadingText="Loading photos…" />{deleteError && <p className="error" role="alert">{deleteError}</p>}{loaded && groups.length ? groups.map((group) => <section className="photo-history" key={group.date}><button className="photo-date activity-time-trigger" onClick={() => chooseDay(group.date)}>{group.date}</button><div className="photo-grid">{group.photos.map((photo) => <figure key={photo.id}><PhotoImageLink photo={photo}><img loading="lazy" src={photo.thumbnailUrl} alt={`Photo from ${group.date}`} /></PhotoImageLink><button className="icon-button danger" aria-label={`Delete photo from ${group.date}`} title="Delete photo" onClick={() => void removePhoto(photo.id)}><Trash2 /></button></figure>)}</div></section>) : loaded && !error ? <p className="empty-copy">No daily photos yet.</p> : null}{loaded && nextBeforeDate && <div className="load-older"><button className="secondary" disabled={loading || olderLoading} onClick={() => void loadOlder()}>{olderLoading ? "Loading older photos…" : "Load older photos"}</button>{olderError && <p className="error" role="alert">{olderError} <button className="text-button" onClick={() => void loadOlder(failedCursor.current)}>Retry</button></p>}</div>}</main>;
}

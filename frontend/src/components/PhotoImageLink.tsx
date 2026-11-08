import { Capacitor } from "@capacitor/core";
import { useState } from "react";
import type { MouseEvent, ReactNode } from "react";
import { api } from "../lib/api";
import type { DailyPhoto } from "../lib/types";
import { Modal } from "./Modal";

export function PhotoImageLink({ photo, children }: { photo: DailyPhoto; children: ReactNode }) {
  const [image, setImage] = useState<string | null>(null);
  const [error, setError] = useState("");
  async function open(event: MouseEvent<HTMLAnchorElement>) {
    if (!Capacitor.isNativePlatform()) return;
    event.preventDefault();
    setError("");
    try { setImage(await api.photoImage(photo.id)); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Could not open photo."); }
  }
  return <><a href={photo.url} target="_blank" rel="noreferrer" onClick={(event) => void open(event)}>{children}</a>{image && <Modal title={`Photo from ${photo.date}`} onClose={() => setImage(null)}><img className="photo-full-view" src={image} alt={`Photo from ${photo.date}`} /></Modal>}{error && <p className="error" role="alert">{error}</p>}</>;
}

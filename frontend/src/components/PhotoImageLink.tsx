import { Capacitor } from "@capacitor/core";
import { useRef, useState } from "react";
import type { MouseEvent, ReactNode, TouchEvent } from "react";
import { api } from "../lib/api";
import type { DailyPhoto } from "../lib/types";
import { Modal } from "./Modal";

export function PhotoImageLink({ photo, children }: { photo: DailyPhoto; children: ReactNode }) {
  const [image, setImage] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [zoom, setZoom] = useState(1);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const gesture = useRef<{ kind: "pinch"; distance: number; zoom: number; x: number; y: number; midX: number; midY: number } | { kind: "pan"; x: number; y: number; offsetX: number; offsetY: number } | null>(null);
  async function open(event: MouseEvent<HTMLAnchorElement>) {
    if (!Capacitor.isNativePlatform()) return;
    event.preventDefault();
    setError("");
    try { setImage(await api.photoImage(photo.id)); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Could not open photo."); }
  }
  function touchStart(event: TouchEvent<HTMLDivElement>) {
    if (event.touches.length >= 2) {
      const [a, b] = [event.touches[0], event.touches[1]];
      gesture.current = { kind: "pinch", distance: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), zoom, ...offset, midX: (a.clientX + b.clientX) / 2, midY: (a.clientY + b.clientY) / 2 };
    } else if (zoom > 1) {
      gesture.current = { kind: "pan", x: event.touches[0].clientX, y: event.touches[0].clientY, offsetX: offset.x, offsetY: offset.y };
    }
  }
  function touchMove(event: TouchEvent<HTMLDivElement>) {
    const current = gesture.current;
    if (current?.kind === "pinch" && event.touches.length >= 2) {
      const [a, b] = [event.touches[0], event.touches[1]];
      const distance = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
      const next = Math.min(4, Math.max(1, current.zoom * distance / Math.max(1, current.distance)));
      setZoom(next);
      setOffset(next === 1 ? { x: 0, y: 0 } : { x: current.x + (a.clientX + b.clientX) / 2 - current.midX, y: current.y + (a.clientY + b.clientY) / 2 - current.midY });
    } else if (current?.kind === "pan" && event.touches.length === 1) {
      setOffset({ x: current.offsetX + event.touches[0].clientX - current.x, y: current.offsetY + event.touches[0].clientY - current.y });
    }
  }
  function touchEnd(event: TouchEvent<HTMLDivElement>) {
    if (event.touches.length === 1 && zoom > 1) {
      gesture.current = { kind: "pan", x: event.touches[0].clientX, y: event.touches[0].clientY, offsetX: offset.x, offsetY: offset.y };
    } else if (event.touches.length === 0) gesture.current = null;
  }
  return <><a href={photo.url} target="_blank" rel="noreferrer" onClick={(event) => void open(event)}>{children}</a>{image && <Modal title={`Photo from ${photo.date}`} fullScreen onClose={() => { setImage(null); setZoom(1); setOffset({ x: 0, y: 0 }); }}><div className="photo-zoom-viewport" onTouchStart={touchStart} onTouchMove={touchMove} onTouchEnd={touchEnd} onTouchCancel={touchEnd}><img className="photo-full-view" src={image} alt={`Photo from ${photo.date}`} style={{ transform: `translate3d(${offset.x}px, ${offset.y}px, 0) scale(${zoom})` }} /></div></Modal>}{error && <p className="error" role="alert">{error}</p>}</>;
}

import { Capacitor } from "@capacitor/core";
import { useEffect, useState } from "react";
import { nativeLedger } from "../lib/nativeLedger";
import versions from "../generated/exercise-artwork-versions.json";

interface Props {
  imageKey: string | null;
  name: string;
  size?: "small" | "large";
}

export function ExerciseImage({ imageKey, name, size = "small" }: Props) {
  const nativeCustom = Boolean(imageKey?.startsWith("custom:") && Capacitor.isNativePlatform());
  const [local, setLocal] = useState<{ key: string; src: string } | null>(null);
  useEffect(() => {
    if (!nativeCustom || !imageKey) return;
    let active = true;
    void nativeLedger.history<{ image: string }>({ path: `/api/exercise-images/${encodeURIComponent(imageKey)}` })
      .then(({ image }) => { if (active) setLocal({ key: imageKey, src: `data:image/jpeg;base64,${image}` }); })
      .catch(() => { if (active) setLocal(null); });
    return () => { active = false; };
  }, [imageKey, nativeCustom]);

  if (!imageKey || (nativeCustom && local?.key !== imageKey)) return <div className={`exercise-image image-fallback ${size}`}>{name.slice(0, 1).toUpperCase()}</div>;
  const custom = imageKey.startsWith("custom:");
  const src = nativeCustom ? local?.src : custom
    ? `/api/exercise-images/${encodeURIComponent(imageKey)}`
    : `/exercise-assets/${imageKey}/frame-1.${versions[imageKey as keyof typeof versions] ?? "missing"}.png`;
  return (
    <div className={`exercise-image ${size}`}>
      <img className={custom ? "custom-exercise-art" : "bundled-exercise-art"} src={src} alt="" loading="lazy" />
    </div>
  );
}

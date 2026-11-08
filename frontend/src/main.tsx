import { StrictMode } from "react";
import { Capacitor } from "@capacitor/core";
import { createRoot } from "react-dom/client";
import App from "./App";
import { NativeStartup } from "./components/NativeStartup";
import "./styles.css";
import { startUpdateClient } from "./lib/updateClient";

createRoot(document.getElementById("root")!).render(<StrictMode>{Capacitor.isNativePlatform() ? <NativeStartup /> : <App />}</StrictMode>);

if (!Capacitor.isNativePlatform() && "serviceWorker" in navigator && import.meta.env.PROD) {
  startUpdateClient();
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js").catch((error: unknown) => {
      console.error("Could not register Rostam's service worker.", error);
    });
  });
}

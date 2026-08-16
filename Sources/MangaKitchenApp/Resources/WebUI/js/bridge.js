import { t } from "./i18n.js";

const pending = new Map();
const stateListeners = new Set();
let sequence = 0;

export function invoke(method, params = {}) {
  const id = `web-${Date.now()}-${sequence++}`;
  const handler = window.webkit?.messageHandlers?.mangakitchen;
  if (!handler) return Promise.reject(new Error(t("bridgeUnavailable")));

  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    handler.postMessage({ id, method, params });
  });
}

export function onState(listener) {
  stateListeners.add(listener);
  return () => stateListeners.delete(listener);
}

window.MangaKitchenNative = {
  receive(message) {
    if (message?.kind !== "response" || !message.id) return;
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.ok) request.resolve(message.payload);
    else request.reject(new Error(message.error || t("nativeCommandFailed")));
  },

  receiveState(state) {
    stateListeners.forEach((listener) => listener(state));
  },
};

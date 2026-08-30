"use client";

import { Toaster as Sonner, type ToasterProps } from "sonner";

/**
 * Toast host, mounted once in the root layout. Kept deliberately understated
 * (per spec: "Toasts بشكل معتدل") — short confirmations, not a notification
 * feed.
 */
function Toaster(props: ToasterProps) {
  return (
    <Sonner
      theme="light"
      position="top-center"
      dir="rtl"
      toastOptions={{
        classNames: {
          toast: "font-[var(--font-app-sans)] shadow-elevated border border-border",
        },
      }}
      {...props}
    />
  );
}

export { Toaster };

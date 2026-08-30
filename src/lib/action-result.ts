/**
 * Standard return shape for every Server Action in this codebase. Keeping
 * this consistent lets every form (useActionState) render errors the same
 * way, and keeps raw exceptions/stack traces from ever reaching the client
 * — server actions must catch and translate errors into this shape instead
 * of letting Next.js serialize a thrown Error to the client.
 */
export type ActionResult<T = undefined> =
  | { success: true; data: T; message?: string }
  | { success: false; error: string; fieldErrors?: Record<string, string[]> };

export function actionSuccess<T>(data: T, message?: string): ActionResult<T> {
  return { success: true, data, message };
}

export function actionError(error: string, fieldErrors?: Record<string, string[]>): ActionResult<never> {
  return { success: false, error, fieldErrors };
}

/** Generic Arabic message for unexpected server errors — never leak internals to the client. */
export const GENERIC_ERROR_MESSAGE_AR = "حدث خطأ غير متوقع. الرجاء المحاولة مرة أخرى.";

/**
 * Every intentional, user-facing exception raised by this project's own
 * triggers/functions (privilege-escalation guards, column locks, store-scope
 * rules, Super Admin protection, ...) uses `errcode = 'P0001'` (a handful of
 * exceptions use '42501'/'P0002' for permission/not-found specifically —
 * see supabase/migrations/0016, 0019). Their message text is already
 * written in Arabic for end users, unlike a generic driver/network error, so
 * it is safe (and much more useful) to show directly instead of collapsing
 * everything to GENERIC_ERROR_MESSAGE_AR. Anything else (an unexpected
 * Postgres error code, a network failure, ...) still falls back to the
 * generic message so internals never leak to the client.
 */
const SAFE_TO_SHOW_ERROR_CODES = new Set(["P0001", "P0002", "42501"]);

export function dbErrorMessage(error: { code?: string; message?: string } | null | undefined, fallback = GENERIC_ERROR_MESSAGE_AR): string {
  if (error?.code && SAFE_TO_SHOW_ERROR_CODES.has(error.code) && error.message) {
    return error.message;
  }
  return fallback;
}

import "server-only";

import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import type { Database } from "@/types/database";

/**
 * Server-side Supabase client bound to the current request's auth cookies.
 * Every query made through this client runs AS the signed-in user (their
 * JWT), so Postgres RLS policies apply exactly as they would for that user
 * — this is the client Server Components, Route Handlers, and Server
 * Actions should use for almost everything.
 *
 * NOTE: `setAll` can be called from a Server Component render, where Next.js
 * disallows mutating cookies — that's expected and safe to ignore there
 * because the middleware (src/middleware.ts) already refreshes the session
 * on every request.
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component — safe to ignore, middleware
            // handles session refresh.
          }
        },
      },
    },
  );
}

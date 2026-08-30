import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { ROUTES } from "@/lib/constants";

const PUBLIC_PATHS = [ROUTES.login];

/**
 * Refreshes the Supabase auth session on every request (required for
 * server-rendered auth with @supabase/ssr) and enforces the baseline
 * "must be signed in AND active" gate for everything outside PUBLIC_PATHS.
 *
 * Fine-grained per-page permission checks (e.g. "needs stores.view") happen
 * again server-side in each route's layout/page — this middleware only
 * handles the coarse authenticated/anonymous/suspended split, which is the
 * cheapest and earliest place to redirect.
 *
 * Foundation Hardening 1.3, item 7 (redirect-loop fix): the previous version
 * of this function redirected `user && pathname === login` straight to
 * /dashboard based purely on `user` (the Supabase Auth JWT) being truthy,
 * with no check of profiles.status at all. requireSession() (guard.ts)
 * separately redirects a non-active user from /dashboard (or any other
 * authenticated page) to `/login?suspended=1` — so a user suspended
 * mid-session would bounce forever: guard.ts sends them to /login, this
 * middleware immediately bounces them back to /dashboard because `user` is
 * still truthy (the JWT itself is still valid; only profiles.status
 * changed), and repeat. This version fetches profiles.status for every
 * authenticated request and treats a non-active account as "not really
 * signed in" for routing purposes: it signs the session out (so the loop
 * cannot recur on the next request either) and sends them to
 * /login?suspended=1 directly, and only redirects login→dashboard when the
 * account is genuinely active.
 */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value);
          }
          response = NextResponse.next({ request });
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;
  const isPublicPath = PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`));
  const isAsset = pathname.startsWith("/_next") || pathname.startsWith("/api/health");

  if (!user && !isPublicPath && !isAsset) {
    const loginUrl = new URL(ROUTES.login, request.url);
    loginUrl.searchParams.set("next", pathname);
    return NextResponse.redirect(loginUrl);
  }

  // A JWT can still be valid (not expired, not signed out) for a user whose
  // profiles.status has since changed to suspended — status lives in our
  // own table, not in the JWT, and nothing invalidates the JWT the moment an
  // admin disables the account. Check it explicitly here rather than
  // trusting `user` truthy to mean "may use the app".
  if (user && !isAsset) {
    const { data: profile } = await supabase.from("profiles").select("status").eq("id", user.id).maybeSingle();
    const isActive = profile?.status === "active";

    if (!isActive) {
      if (isPublicPath) {
        // Already headed to /login (or already there) — let it through as
        // anonymous; no redirect loop risk since we are not bouncing them
        // toward a protected page.
        return response;
      }

      // Terminate the session explicitly rather than merely redirecting:
      // otherwise the next request still carries a "valid" JWT for `user`
      // and this same branch (not the login-redirect branch below) would
      // just run again — which is fine on its own (it always lands on
      // /login?suspended=1, never bounces to /dashboard), but signing out
      // also clears the session cookies so any other tab/request stops
      // treating this as an authenticated session immediately instead of
      // only on next contact with a protected route.
      await supabase.auth.signOut();

      const suspendedUrl = new URL(ROUTES.login, request.url);
      suspendedUrl.searchParams.set("suspended", "1");
      const redirect = NextResponse.redirect(suspendedUrl);
      // supabase.auth.signOut()'s cookie mutations were applied to
      // `response` (via the setAll callback's cookies.set calls above), not
      // to this freshly-constructed redirect response — copy them across so
      // the browser actually receives the cleared session cookies instead
      // of them being silently dropped.
      for (const cookie of response.cookies.getAll()) {
        redirect.cookies.set(cookie.name, cookie.value, cookie);
      }
      return redirect;
    }
  }

  if (user && pathname === ROUTES.login) {
    return NextResponse.redirect(new URL(ROUTES.dashboard, request.url));
  }

  return response;
}

import { type NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";

// Next.js 16 renamed the `middleware.ts` convention to `proxy.ts` (and the
// exported function to `proxy`) to better reflect that this runs at the
// network-boundary layer. See node_modules/next/dist/docs — "middleware to
// proxy". Functionally identical to what used to be `middleware()`.
export async function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: [
    /*
     * Match all request paths except:
     * - static files (_next/static, _next/image, favicon, images...)
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};

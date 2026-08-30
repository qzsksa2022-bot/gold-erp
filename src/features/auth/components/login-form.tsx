"use client";

import { useActionState, useState } from "react";
import { Eye, EyeOff, Loader2, Lock, Mail } from "lucide-react";
import { loginAction } from "@/features/auth/actions";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Checkbox } from "@/components/ui/checkbox";

export function LoginForm() {
  const [state, formAction, isPending] = useActionState(loginAction, null);
  const [showPassword, setShowPassword] = useState(false);

  return (
    <form action={formAction} className="flex flex-col gap-5" noValidate>
      {state && !state.success && (
        <div
          role="alert"
          className="rounded-md border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive"
        >
          {state.error}
        </div>
      )}

      <div className="flex flex-col gap-2">
        <Label htmlFor="email">البريد الإلكتروني</Label>
        <div className="relative">
          <Mail className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="email"
            name="email"
            type="email"
            autoComplete="username"
            placeholder="name@store.sa"
            className="ps-9"
            required
            disabled={isPending}
            aria-invalid={!state?.success && !!state?.fieldErrors?.email}
          />
        </div>
        {!state?.success && state?.fieldErrors?.email && (
          <p className="text-xs font-medium text-destructive">{state.fieldErrors.email[0]}</p>
        )}
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="password">كلمة المرور</Label>
        <div className="relative">
          <Lock className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            id="password"
            name="password"
            type={showPassword ? "text" : "password"}
            autoComplete="current-password"
            placeholder="••••••••"
            className="ps-9 pe-9"
            required
            disabled={isPending}
            aria-invalid={!state?.success && !!state?.fieldErrors?.password}
          />
          <button
            type="button"
            onClick={() => setShowPassword((v) => !v)}
            className="absolute end-3 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
            tabIndex={-1}
            aria-label={showPassword ? "إخفاء كلمة المرور" : "إظهار كلمة المرور"}
          >
            {showPassword ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
          </button>
        </div>
        {!state?.success && state?.fieldErrors?.password && (
          <p className="text-xs font-medium text-destructive">{state.fieldErrors.password[0]}</p>
        )}
      </div>

      <div className="flex items-center gap-2">
        <Checkbox id="rememberMe" name="rememberMe" disabled={isPending} />
        <Label htmlFor="rememberMe" className="cursor-pointer font-normal text-muted-foreground">
          تذكرني على هذا الجهاز
        </Label>
      </div>

      <Button type="submit" size="lg" disabled={isPending} className="mt-2">
        {isPending ? (
          <>
            <Loader2 className="size-4 animate-spin" />
            جارٍ تسجيل الدخول...
          </>
        ) : (
          "تسجيل الدخول"
        )}
      </Button>
    </form>
  );
}

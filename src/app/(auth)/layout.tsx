export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen w-full items-center justify-center bg-gradient-to-b from-secondary/60 to-background px-4 py-10">
      {children}
    </div>
  );
}

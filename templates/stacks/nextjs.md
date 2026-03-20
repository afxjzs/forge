# Stack: Next.js

Append to project CLAUDE.md when stack is Next.js.

## Commands

```bash
pnpm dev                    # Development server
pnpm build                  # Production build
pnpm test                   # Run tests (vitest or jest — check package.json)
pnpm lint                   # ESLint
pnpm db:push                # Push schema (if using Prisma)
pnpm db:migrate             # Run migrations (if using Prisma)
```

## Conventions

- App Router (not Pages Router) unless project explicitly requires Pages
- Server Components by default; `"use client"` only when needed (event handlers, hooks, browser APIs)
- UI components: shadcn/ui + Tailwind unless spec overrides
- Validation: Zod schemas — never trust raw types from forms or API
- API routes: `app/api/` with proper error responses (not just 500)
- Environment: `.env.local` for local, `.env` for defaults, never commit secrets
- Database: Prisma or Drizzle — whichever project chooses. Never raw SQL in route handlers.

## Known Issues

<!-- Populated by agents. Append-only. -->

- Server Components cannot use `onClick`, `useState`, `useEffect` — these need `"use client"`
- `redirect()` in Server Components throws — it's intentional, don't try-catch it
- Prisma: run `pnpm db:generate` after schema changes before building
- `next/image`: always set width/height or use `fill` — missing dimensions = build error
- Middleware runs on Edge runtime — no Node.js APIs (fs, path, etc.)
- `cookies()` and `headers()` are async in Next.js 15+ — must `await` them

# Stack: React SPA

Append to project CLAUDE.md when stack is a standalone React SPA (Vite).

## Commands

```bash
pnpm dev                    # Development server (Vite)
pnpm build                  # Production build
pnpm test                   # Run tests (vitest)
pnpm lint                   # ESLint
pnpm preview                # Preview production build locally
```

## Conventions

- Vite for bundling — not CRA (deprecated)
- React Router v6+ for routing — `createBrowserRouter` pattern
- State: React Query (TanStack Query) for server state, Zustand or context for client state
- Forms: React Hook Form + Zod resolver — never uncontrolled forms for complex inputs
- Styling: Tailwind or CSS Modules — no inline styles except for truly dynamic values
- API calls: centralize in `src/api/` — components never call fetch directly
- Error boundaries: wrap route-level components, not every component
- TypeScript strict mode always

## Known Issues

<!-- Populated by agents. Append-only. -->

- Vite env vars must start with `VITE_` — others are silently excluded from client bundle
- `useEffect` cleanup: always return cleanup function for subscriptions/timers
- React Router: `<Navigate>` in render causes re-render loops if not conditional
- TanStack Query: `staleTime` defaults to 0 — every component mount refetches without it
- Zustand: don't destructure store selectors — causes unnecessary re-renders. Use `useStore(s => s.field)`
- Build output goes to `dist/` not `build/` (Vite convention)

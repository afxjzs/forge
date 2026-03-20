# Stack: TypeScript Library

Append to project CLAUDE.md when stack is a TypeScript library/package.

## Commands

```bash
pnpm build                  # Build (tsup or tsc)
pnpm test                   # Run tests (vitest)
pnpm lint                   # ESLint
pnpm typecheck              # tsc --noEmit
pnpm changeset              # Create changeset for versioning
```

## Conventions

- `tsup` for bundling — outputs CJS + ESM dual package
- `tsconfig.json` with `strict: true` — no exceptions
- Zod for runtime validation at public API boundaries — TypeScript types aren't enough
- Export types explicitly from `src/index.ts` — never rely on auto-export
- `package.json` exports field with proper ESM/CJS paths
- Tests: colocate with source (`foo.test.ts` next to `foo.ts`)
- Semver + changesets for versioning — never manual version bumps
- Document public API with JSDoc — consumers need this for IDE hints

## Known Issues

<!-- Populated by agents. Append-only. -->

- `tsup` needs `clean: true` in config or stale output files accumulate
- ESM/CJS dual output: ensure `"type": "module"` in package.json matches tsup config
- `Zod.infer<typeof schema>` for deriving types from schemas — don't duplicate types manually
- `exactOptionalPropertyTypes` in strict mode catches `undefined` vs missing — may need adjustment
- `peerDependencies` not auto-installed — document clearly in README
- Test mocking: `vi.mock()` must be at top level, not inside describe/it blocks

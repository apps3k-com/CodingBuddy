# CodingBuddy — Documentation

**Single source of truth for all CodingBuddy documentation.** The wiki is generated: pages live in the main repo under [`docs/wiki/`](https://github.com/apps3k-com/CodingBuddy/tree/main/docs/wiki) and are synced here automatically on every merge to `main`. **Do not edit wiki pages directly — changes get overwritten.**

## How this is organized

- **Technical documentation — English** (the development language).
- **User documentation — Deutsch + English.**
- Navigation: see the **sidebar** →

## Conventions

- Edit via pull request against `docs/wiki/` in the main repo; the `Sync wiki` action publishes on merge.
- CI requires user-visible app changes to ship with documentation updates (EN **and** DE) in the same PR.
- Agent-runtime instructions stay in the repo (`CLAUDE.md`) and stay slim; they point here for depth.
- Page naming: technical = `Topic`; user docs = `User-Guide-EN` / `Benutzerhandbuch-DE`.

# Working in this repository

## What this repository is

A data generator, not an application. It builds the dictionaries of the Kartomed Android
application (`/home/alx/AndroidStudioProjects/kartomed/`, package `com.foleks.kartomed`) from
official open sources and publishes them, so the application can update them between its
releases. Read `README.md` first: layout, checks, hosts, the Russian edition, secrets.

## General requirements

- Always follow SOLID and KISS principles. Clean, efficient and maintainable code.
- If the task is unclear, ask clarifying questions.
- Always answer in Russian, simply, without abbreviations or slang: the owner is not a programmer.
- Write all code comments in English.
- Temporary files go into `tmp/` of this repository; delete it when done.
- Use Context7 MCP for the documentation of Dart packages and GitHub Actions.
- Format only the files you changed (`dart format <file>`), never whole folders.
- Never commit or push: the owner does it. Never run the workflow, upload to Cloudflare or change
  the secrets without the owner's explicit consent.

## The published format — CRITICAL

`public/dictionaries/` is read by every installed version of the application. Its layout
(`manifest.json` fields, file names, the JSON of entries, groups and labels) is described in
`README.md` and in `dictionaries/src/publication.dart`.

- Never change the layout without the owner's agreement. A change the old application cannot read
  needs a new `manifestFormat` and a matching change of the application (`DictionaryManifest`).
- Adding a field is allowed but must be reported to the owner: the application may need it.
- The checks of `check()` (no source, other format, count or translations down by more than 10 %,
  mixed alphabets) protect the users from a broken source: never weaken them to make a run pass.
  Fix the script instead.

## Checks before «done»

```bash
dart analyze --fatal-infos
dart test
./build_dictionaries.sh   # when a build script or data changed: real sources, real check
```

Then, in the application project: `tool/dictionaries/sync_from_site.dart --from=../kartomed_packages/public/dictionaries`
and `flutter test test/data/dictionaries/` — the application's own checks of the real dictionaries.

## Comments in code

CRITICAL! Write all code comments on English.



Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

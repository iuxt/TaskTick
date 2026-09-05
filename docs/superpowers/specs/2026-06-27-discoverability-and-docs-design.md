# Discoverability & Docs Design

## Goal

Give TaskTick's advanced / hidden features a place to be documented, and a funnel
for users to actually discover them. Triggered by the upcoming **script notify
directive** (`@tasktick:notify {…}`, see
`2026-06-27-script-notify-directive-design.md`): a feature users cannot discover
on their own today, because nothing in the app or on the site explains it.

## Decisions

- **Layered, not merged**: `index.html` stays marketing. A separate **docs area**
  carries the deep usage docs. The two never compete for the same page.
- **Same-site, hand-written static page**: new `docs/guide/index.html`, served at
  `/guide/` on GitHub Pages. Reuses `index.html`'s visual language and i18n
  mechanism. No framework, no build step, no new dependency — matches how the
  site is maintained today.
- **Two languages, EN + 简中.** Translate prose only; commands / code / syntax /
  examples stay verbatim (they are language-neutral).
- **Discovery touchpoints (chosen)**: site nav entry, in-editor inline hint
  (notify snippet), release What's New. **Not** a standalone in-app help entry —
  the editor hint's "view docs" deep-link is the one necessary app→docs entry,
  delivered precisely when the user is writing a script.

## Decomposition & sequencing

The "docs page + three touchpoints" idea is **four independent work items** with
different dependencies. Each ships on its own; do not treat them as one task.

| Item | Nature | Depends on | Standalone now |
|------|--------|-----------|----------------|
| **A. Docs page (EN/ZH) + site nav entry** | static frontend | — | ✅ |
| **B. Editor inline hint (notify snippet)** | Swift app | D | ❌ |
| **C. Release What's New panel** | Swift app + release flow | — | ✅ |
| **D. notify directive feature** | Swift app | — | spec done, pending impl |

This spec **fully designs A**, and gives **direction + dependencies for B and C**
(each gets its own later spec). D already has its own spec.

---

## A. Docs page + site nav entry (this spec's deliverable)

### File & URL

- New file `docs/guide/index.html`, served at `/guide/`. Keeps `index.html` from
  growing further; the docs page can grow freely without touching marketing.
- Edits to `index.html` are limited to **adding links** (nav + notification-card
  deep-links). No structural changes to the marketing page.

### Structure

- **Single long page + sticky TOC** (anchor navigation). All sections scroll in
  one page; jump via the TOC; search via the browser's Ctrl+F. Simplest for the
  current medium volume. Split into multiple pages only if it later balloons.

### First sections

1. **Script Notifications** (`#notifications`) — notification directive grammar,
   examples, and fault-tolerance notes.
2. Future features can add their own sections when they ship.

### i18n

- Reuse `index.html`'s `data-i18n` + localStorage approach; read the **same**
  localStorage key so the chosen language carries over when the user clicks
  「Docs」from the site.
- The language selector on the guide page shows **EN + 简中 only** (only these two
  have translations).
- **Code blocks are never translated**: Notification JSON and shell examples
  live in `<code>` / `<pre>` **without** `data-i18n`. This avoids mangling code
  and avoids double-maintaining code blocks — the key reason EN + 简中 stays
  sustainable as the docs grow.

### Site entry (part of A)

- `index.html` nav bar: add **「Docs」** → `/guide/`.
- Features grid: the notification card deep-links to `/guide/#notifications`.

### Visual / technical constraints

- Pure static, zero new dependencies, zero build step; light/dark follows the
  system, same as `index.html`.
- **No CSS extraction**: the guide page carries its own styles (copy
  `index.html`'s CSS variables + base typography). Do **not** refactor the
  marketing page just to share styles — keep `index.html` changes to links only,
  which is the lowest-risk edit. Extract a `shared.css` later only if the two
  pages visibly drift. (YAGNI)

---

## B. Editor inline hint — direction (own spec later)

After D ships, give the script editor a snippet entry that inserts the
`@tasktick:notify {"title":"…"}` template, plus a "view docs" deep-link to
`/guide/#notifications`. This is the app→docs entry that **replaces** a
standalone help entry. It picks up the snippet button that the notify spec
marked out-of-scope. Exact UI placement (toolbar vs. snippet menu) is decided in
B's own spec. **Depends on D.**

## C. Release What's New — direction (own spec later)

On the first launch after a version upgrade, show a "what's new" panel: this
version's new features + "learn more" deep-links into the guide. Can reuse the
existing `UpdateChecker` / version comparison to detect "first time seeing this
version." First use: announce the notify directive. Form (modal vs. menu-bar
badge vs. settings) is decided in C's own spec. Independent of the other items.

## Maintenance & anti-stale

- Section ↔ feature is one-to-one; a new feature = a new section (fill a reserved
  slot).
- The notification grammar is kept in sync with the code
  **by hand** (a static page can't auto-sync) → add an "update `/guide/`" item to
  the release checklist.
- New or changed docs: edit EN + 简中 **together**, following the project's
  existing `Localizable.strings` bilingual rule.

## Out of scope

- A standalone in-app help window / entry (deliberately rejected; the editor
  deep-link suffices).
- A docs-site framework (VitePress / Docusaurus), multipage split, or search
  index.
- 11-language docs (EN + 简中 only).
- The detailed UI of B and C (each has its own spec).

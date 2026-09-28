# Development guide — adding & ordering blog posts

This site is **Astro + Starlight**. Blog posts are Markdown files under `src/content/docs/blogs/`. The custom landing page (`src/pages/index.astro`) is separate from Starlight; the Blogs sidebar is Starlight-managed.

---

## 1. Add a new blog page (minimum path)

### Step A — Create the Markdown file

1. Add a new file under:

```text
src/content/docs/blogs/<slug>.md
```

2. Use a **kebab-case** filename. That becomes the URL slug:

| File | URL |
|------|-----|
| `src/content/docs/blogs/my-new-post.md` | `/blogs/my-new-post/` |

3. Start the file with Starlight frontmatter (required):

```md
---
title: Your post title (shown in sidebar + page H1)
description: One-line summary for SEO / social cards.
---

Your content here…

## Secondary heading

Body text…
```

**Notes:**

- `title` and `description` must both be strings (never leave `description:` empty).
- Use `##` for secondary headings. Site CSS draws a full-width underline under each `h2` automatically.
- No need to register the file in `content.config.ts` — Starlight’s `docsLoader` picks up every `.md` / `.mdx` under `src/content/docs/`.

### Step B — Confirm it appears in the Starlight sidebar

In `astro.config.mjs`, Blogs uses **autogenerate**:

```js
{
  label: 'Blogs',
  items: [{ autogenerate: { directory: 'blogs' } }],
}
```

So a new `.md` in `blogs/` shows up in the left sidebar **automatically**. You do **not** need to add a sidebar entry for every post unless you want a custom order (see §3).

### Step C — (Optional) Feature it on the landing page

The homepage **§ II. Blogs** list is **hand-written** in `src/pages/index.astro`. Autogenerate does **not** update that section.

To feature the new post on the landing page:

1. Open `src/pages/index.astro`.
2. Find the block under `§ II. Blogs` (the `<div class="ej-works">` with `ej-work` links).
3. Copy an existing `<a class="ej-work" …>` card and edit:

| Field | What to set |
|-------|-------------|
| `href` | `/blogs/<slug>/` (match the filename without `.md`) |
| `.ej-work-no` | `№ 01`, `№ 02`, … (display order) |
| `.ej-work-title` | Display title (can use `<em>` for a subtitle) |
| `.ej-work-blurb` | Short teaser |
| `.chip` tags | Optional topic chips |

4. Also update the masthead / footer “Blogs” link if you want the primary entry point to be the newest post:

```html
<a href="/blogs/<slug>/">Blogs</a>
<!-- footer -->
<a href="/blogs/<slug>/">Blogs →</a>
```

### Step D — Verify locally

```sh
npm run dev      # http://localhost:4321
# or
npm run build && npm run preview
```

Check:

- `/blogs/<slug>/` renders
- Sidebar lists the new title under **Blogs**
- Landing cards / nav links (if you edited them) resolve (no 404)

---

## 2. CSS, HTML & Astro — what you usually do *not* need to change

For a normal new blog post, **you only add/edit the Markdown file** (and optionally `index.astro` if it should appear on the landing page).

| File | Change for a new post? | Why |
|------|------------------------|-----|
| `src/content/docs/blogs/<slug>.md` | **Yes** | The post itself |
| `src/pages/index.astro` | **Only if** you want it on the homepage Blogs section / nav | Landing list is manual |
| `astro.config.mjs` | **Usually no** | Autogenerate already includes `blogs/` |
| `src/styles/custom.css` | **No** | Heading underlines, typography, and landing styles are global |
| `src/content.config.ts` | **No** | Collection already covers all docs |
| `package.json` / deploy workflow | **No** | Unrelated to content |

### When you *would* touch CSS / HTML / Astro

| Goal | Where |
|------|--------|
| Change landing Blogs card layout / chips / section labels | `src/pages/index.astro` (+ rarely `custom.css` if new classes) |
| Change blog page typography, `h2` underlines, tables, code | `src/styles/custom.css` (rules under `.sl-markdown-content`) |
| Rename sidebar group, add Projects back, change social links | `astro.config.mjs` |
| Site-wide fonts / OG meta for landing only | `src/pages/index.astro` `<head>` and/or `astro.config.mjs` `head` |

**Do not** put post-specific styles in `custom.css` unless the design needs a new reusable pattern. Prefer Markdown + existing Starlight components.

### Heading underline note (already handled)

Starlight wraps headings in `.sl-heading-wrapper` and makes `h2` `display: inline`. Site CSS puts the section rule on `.sl-heading-wrapper.level-h2`, not on `h2` itself. New posts inherit that — no per-post CSS.

---

## 3. Re-order blog posts

There are **two independent lists**. Change each where you want the new order to show up.

### A. Landing page (“heading page”) — § II. Blogs

**File:** `src/pages/index.astro`

**How:** Physically reorder the `<a class="ej-work" …>` blocks inside the Blogs `ej-works` section. Also renumber `№ 01`, `№ 02`, …

Example — to put progressive-delivery first:

1. Move that card above the others in the HTML.
2. Set its `ej-work-no` to `№ 01`, and renumber the rest.
3. Optionally point the top nav / footer Blogs link at the first post’s URL.

No Markdown rename required for landing order.

### B. Starlight sidebar under **Blogs**

**Default today:** `autogenerate: { directory: 'blogs' }` orders posts **alphabetically by filename**.

Ways to change sidebar order:

#### Option 1 — Rename files (simple, if alphabetical order is fine)

Rename so alphabetical order matches the order you want:

```text
src/content/docs/blogs/01-arc-zonal-shift-eks-blog.md
src/content/docs/blogs/02-progressive-delivery-part1.md
src/content/docs/blogs/03-progressive-delivery-part2.md
```

**Important:** Renaming changes the URL (`/blogs/01-arc-…/`). Update any `href`s in `index.astro` (and external links) to match.

#### Option 2 — Explicit sidebar list in `astro.config.mjs` (recommended for fixed order)

Replace autogenerate with an ordered `items` list:

```js
{
  label: 'Blogs',
  items: [
    { label: 'ARC zonal shift on Amazon EKS', slug: 'blogs/arc-zonal-shift-eks-blog' },
    { label: 'Argo Rollouts + AnalysisTemplates ~ Release with Confidence', slug: 'blogs/progressive-delivery-part1' },
    { label: 'Kubevela the Abstraction…', slug: 'blogs/progressive-delivery-part2' },
    // add new posts here in the order you want
  ],
},
```

- **Reorder** = rearrange these objects.
- **Add a post** = add a `{ label, slug }` line (slug = `blogs/<filename-without-md>`).
- Filenames/URLs stay stable; no need to rename Markdown files.

#### Option 3 — Frontmatter `sidebar.order` (if you keep autogenerate)

In each post’s frontmatter:

```md
---
title: …
description: …
sidebar:
  order: 1
---
```

Lower numbers appear first. Use `2`, `3`, … for the rest. See [Starlight sidebar docs](https://starlight.astro.build/guides/sidebar/) for the exact schema for your Starlight version.

### Quick reference — “which file do I edit?”

| Where the order should change | File(s) to edit |
|-------------------------------|-----------------|
| Landing § II. Blogs cards | `src/pages/index.astro` |
| Landing nav / footer “Blogs” target | `src/pages/index.astro` |
| Left sidebar under Blogs (keep autogenerate) | Rename files **or** set `sidebar.order` in each `.md` |
| Left sidebar under Blogs (fixed manual list) | `astro.config.mjs` only |
| Post URL / content | `src/content/docs/blogs/<slug>.md` |

---

## 4. Checklist for a new featured post

```text
[ ] Create src/content/docs/blogs/<slug>.md with title + description
[ ] npm run dev → open /blogs/<slug>/
[ ] Confirm sidebar shows it under Blogs
[ ] If featured on home: add/reorder card in src/pages/index.astro
[ ] If using manual sidebar: add slug to astro.config.mjs items
[ ] Update nav/footer Blogs href if the “first” post changed
[ ] npm run build  (fix before push)
```

---

## 5. Related layout (for orientation)

```text
src/
├── pages/index.astro              # Landing: nav, § II Blogs cards, footer
├── content/docs/
│   ├── blogs/*.md                 # Blog posts → /blogs/<slug>/
│   ├── techstack.md
│   └── about.md
├── styles/custom.css              # Global + Starlight + landing styles
└── content.config.ts              # Docs collection (leave as-is)

astro.config.mjs                   # Starlight sidebar (Blogs autogenerate / manual)
```

Projects remain commented out in `astro.config.mjs` and on the landing page until re-enabled.

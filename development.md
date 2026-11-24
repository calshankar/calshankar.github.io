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
├── integrations/publishContentArtifacts.mjs   # artefact URLs (see §6)
├── content/
│   ├── docs/
│   │   ├── blogs/*.md             # Blog posts → /blogs/<slug>/
│   │   ├── techstack.md
│   │   └── about.md
│   ├── skills/                    # → /skills/ (§6)
│   ├── workflow/                  # → /workflow/
│   ├── scripts/                   # → /blog-scripts/
│   └── manifests/                 # → /manifests/
├── styles/custom.css              # Global + Starlight + landing styles
└── content.config.ts              # Docs collection (leave as-is)

astro.config.mjs                   # Starlight sidebar (Blogs autogenerate / manual)
public/scripts/                    # Site JS only (e.g. mermaid-expand) → /scripts/
```

Projects remain commented out in `astro.config.mjs` and on the landing page until re-enabled.

---

## 6. Link blog posts to artefacts (`skills`, `workflow`, `scripts`, `manifests`)

Blog Markdown lives under `src/content/docs/blogs/`. Downloadable or linkable files that posts reference live in **sibling folders** under `src/content/` (not inside `docs/`, so Starlight does not treat them as pages).

### Layout

```text
src/content/
├── docs/blogs/*.md          # Starlight pages → /blogs/<slug>/
├── skills/                  # e.g. agent SKILL.md packs
├── workflow/                # workflow YAML, checklists, diagrams
├── scripts/                 # scripts *referenced by posts* (not site JS)
└── manifests/               # sample K8s manifests for posts & CI examples
```

| Folder on disk | Published URL | Example link in a post |
|----------------|---------------|-------------------------|
| `src/content/skills/…` | `/skills/…` | `[checklist](/skills/argocd-appset/SKILL.md)` |
| `src/content/workflow/…` | `/workflow/…` | `[promotion flow](/workflow/argo-rollout-promote.yaml)` |
| `src/content/scripts/…` | `/blog-scripts/…` | `[helper script](/blog-scripts/audit-appsets.sh)` |
| `src/content/manifests/…` | `/manifests/…` | `[PushSecret sample](/manifests/eso/pushsecret.yaml)` |

**Do not** prefix links with `/public/` — Astro copies `public/` to the site root, but these artefacts are **not** in `public/`.

**Site runtime JS** (loaded on every page) stays in `public/scripts/` (e.g. `mermaid-expand.js` → `/scripts/mermaid-expand.js`). That path is separate from `src/content/scripts/` → `/blog-scripts/…`.

### How it works

The Astro integration `src/integrations/publishContentArtifacts.mjs`:

1. **Dev** (`npm run dev`) — Vite middleware serves each folder at the URL prefix above.
2. **Build** (`npm run build`) — copies each folder into `dist/<urlPath>/` so GitHub Pages serves the same URLs in production.

Mount table is exported as `ARTIFACT_MOUNTS` in that file — extend the array to add another artefact category.

### Steps when you add or change an artefact

1. Put the file under the right folder (keep stable paths; posts link by URL).
2. In the blog `.md`, add a **root-relative** link: `/skills/...`, `/workflow/...`, `/blog-scripts/...`, or `/manifests/...`.
3. Run `npm run dev` and open the URL directly (e.g. `http://localhost:4321/skills/argocd-appset/SKILL.md`) to confirm it loads.
4. Run `npm run build` before push (artefacts must appear under `dist/skills/`, `dist/manifests/`, etc.).

You do **not** register artefacts in `content.config.ts` or the Starlight sidebar.

### Adding a new artefact category

Use this checklist whenever you introduce another folder under `src/content/` that should be linkable from posts (not a Starlight page).

| Step | Action |
|------|--------|
| 1 | Create `src/content/<new-folder>/` and add files (keep paths stable — posts link by URL). |
| 2 | In `src/integrations/publishContentArtifacts.mjs`, append to `ARTIFACT_MOUNTS`: `{ subdir: '<new-folder>', urlPath: '<url-segment>' }`. `subdir` is the folder name; `urlPath` is the site URL prefix (often the same string, unless you need to avoid a collision — see `scripts` → `blog-scripts`). |
| 3 | Confirm `publishContentArtifacts()` is listed in `astro.config.mjs` `integrations` (already required for existing artefact types). |
| 4 | Add `src/content/<new-folder>/README.md` with the published URL prefix and a pointer to this section. |
| 5 | Update this §6: layout diagram, mount table, and link examples. |
| 6 | `npm run dev` — hit `http://localhost:4321/<url-segment>/…` for a sample file. |
| 7 | `npm run build` — confirm `dist/<url-segment>/` contains the tree before push. |

**`urlPath` constraints:** must not collide with Starlight routes (`/blogs/`, `/about/`, `/techstack/`, …) or with `public/` assets (`/scripts/` is site JS only).

**MIME types:** unknown extensions are served as `application/octet-stream`. Add entries to the `MIME` map in `publishContentArtifacts.mjs` if browsers should render a new text type inline.

**Out of scope for this pattern:** Starlight docs belong under `src/content/docs/` only. Do not register artefact folders in `content.config.ts` or the sidebar unless you deliberately want them as pages.

### Alternative hosting options

| Approach | Pros | Cons |
|----------|------|------|
| **`src/content/{skills,workflow,scripts,manifests}` (current)** | Co-located with blog content; versioned with the site; same URLs in dev and prod | Requires the publish integration; not editable as Starlight pages |
| **`public/skills/`, etc.** | Zero config; Astro copies as-is | Mixes “source” with static assets; easy to confuse with site `public/scripts/` |
| **GitHub links** (`github.com/.../blob/main/...`) | Good for very large files or repos readers should fork | Off-site; raw view vs HTML; breaks if repo moves |
| **Separate repo + releases** | Clear ownership for skills/tooling | Two places to update; cross-linking discipline |
| **Starlight doc per artefact** (`src/content/docs/skills/...`) | Rendered in theme, search, sidebar | Sidebar noise unless you hide the tree; heavy for raw `.sh` / `.yaml` |

For this site, **`src/content/` + static publish** keeps posts and artefacts in one repo without polluting the blog sidebar.

---

## 7. Deploy to GitHub Pages (homepage / index)

Local builds write the real homepage to `dist/index.html` via `src/pages/index.astro`. There is **no** `index.html` in the git repo root — and that is correct.

### Required GitHub setting (most common breakage)

If Pages is set to **Deploy from a branch**, GitHub runs **Jekyll** on the `main` branch. With no root `index.html`, Jekyll serves `README.md` as `/` and every Astro route (`/about/`, `/blogs/…`) 404s. The live HTML will contain `meta name="generator" content="Jekyll …"`.

**Fix:**

1. Repo → **Settings** → **Pages**
2. Under **Build and deployment** → **Source**, choose **GitHub Actions** (not “Deploy from a branch”)
3. Push to `main` (or run the **Deploy to GitHub Pages** workflow manually under **Actions**)
4. Confirm the workflow succeeds, then hard-refresh `https://calshankar.github.io/`

You should then see the Astro landing (“Platform as a product”), not the README.

### What `astro.config.mjs` must have

For this **user site** (`calshankar.github.io`):

```js
site: 'https://calshankar.github.io',
// do NOT set `base` — user/org sites publish at the domain root
```

`base` is only for project sites like `https://user.github.io/repo-name/`.

### What `.github/workflows/deploy.yml` does

Uses the official `withastro/action` to install, `npm run build`, and upload `./dist`, then `actions/deploy-pages` publishes that artifact. It only takes effect after Pages **Source** is **GitHub Actions**.

`public/.nojekyll` is copied into `dist/` so GitHub does not treat `_astro/` as a Jekyll special folder if anything ever falls back to Jekyll processing.


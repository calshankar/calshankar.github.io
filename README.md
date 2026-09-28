# calshankar.github.io

Source for **Shankar Ramanathan** — platform engineering notes, blogs, and portfolio.

I'm a **Platform Engineering Leader and SRE Architect** with 11+ years scaling cloud-native infrastructure and building high-performing platform teams. Recent work: self-service Kubernetes environments for large SaaS platforms — 100+ microservices, 100 Kubernetes clusters, and 2k+ compute instances. I treat the internal platform as a product and align roadmaps with reliability, security, and FinOps.

Built with [Astro](https://astro.build) + [Starlight](https://starlight.astro.build). Deployed to GitHub Pages on every push to `main` via `.github/workflows/deploy.yml`.

## Develop locally

```sh
npm install
npm run dev      # serves at http://localhost:4321
```

## Build

```sh
npm run build    # outputs to ./dist
npm run preview  # serves the built ./dist locally
```

## Layout

```
src/
├── assets/                    # logo, images
├── pages/index.astro          # custom landing page
├── content/docs/
│   ├── blogs/                 # blog posts
│   ├── projects/              # (commented out for now)
│   ├── techstack.md           # tech stack reference
│   └── about.md               # bio + contact
└── styles/custom.css          # Starlight + landing theme
```

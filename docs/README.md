# nimgent documentation

The nimgent docs use [Astro Starlight](https://starlight.astro.build) with the
[Starlight Black](https://starlight-theme-black.vercel.app/) theme.

## Development

```sh
npm install
npm run dev
```

Open the local URL printed by Astro. Production builds use `npm run build`.

Documentation pages live in `src/content/docs/`. The sidebar is configured in
`astro.config.mjs`.

The site documents the current nimgent API; update the relevant page when an
example or public API changes.

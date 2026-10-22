# Development

## Updating the app image

Put the new jvm tag and its digest in [`marola-image`](https://github.com/marola-dev/marola-site/blob/main/marola-image) (the tag is
`jvm-<short sha>` from the app's `docker.yml`; `docker buildx imagetools inspect <ref>` prints the
digest), then run `just board-schema --update` and commit both files together. `board-schema.yml`
fails a PR whose vendored schema differs from the image's, and `site.yml` checks the page against
the image's own schema before every deploy. The jvm image is required: the schema is read out of
`/app/marola.jar`, which the native image does not have. A board schema change in the app is two
PRs: the app's first, then this bump.

## The build and deploy (`site.yml`)

Runs only on `workflow_dispatch` for now (one area, or `all`, the default), on the self-hosted
runner [below](#the-self-hosted-runner-in-brazil); no schedule, push or `repository_dispatch`. `concurrency: site` queues a run rather
than cancelling one that is already building.

The job: pull the pinned image (two tries) → check the harness and the page against the image's
own board schema → restore the beach lists → build every area's boards (or one, with an area input) → copy the static page
into `site/dist` → write the Mapbox token and style into `mapbox-config.js` → cache-bust
`index.html`'s script/style tags with `?v=<sha>` (Pages caches each file independently) → add the
`site-data` branch's panels → a required-files check (a half-built site must never reach Pages) →
the publish allowlist (only the page, its assets and `data/`, `smoke/`, `coverage/`, `stats/` go
out) → a `CNAME` file → deploy to GitHub Pages, and the same `site/dist` to the Cloudflare Worker
`marola` (static assets only, `wrangler.jsonc`), which serves marola.dev since 2026-10-07. GitHub
Pages keeps the same deploy as a fallback, and a Cloudflare failure does not fail the run
(MIP-0078). Its secrets are `CLOUDFLARE_API_TOKEN` (Edit Cloudflare Workers) and
`CLOUDFLARE_ACCOUNT_ID`.

### Beach lists and Overpass

The app keeps each area's beach list in `site/beaches/<lat>_<lon>_r<radius>_n<limit>.json` and asks
Overpass only for an area without one, writing the file when the query succeeds. `site.yml` keeps
that directory in the Actions cache (`beaches-<hash>`, restored newest first, saved after every
run, a failed one included), so once every area has a list the build no longer depends on the
public Overpass mirrors, whose timeouts used to fail whole builds (#63). Trails still come from
Overpass, but a failure there only leaves them off the board. A list refreshes when its area's
`lat`, `lon`, `radius_km` or `beach_limit` changes (that is the file name); to refetch otherwise,
delete the `beaches-` entries under Actions → Caches. OSM beaches change over years, not hours.

### The self-hosted runner in Brazil

INEA (Rio) and INEMA (Bahia) answer only Brazilian addresses, and GitHub's runners are not in
Brazil. So `site.yml`'s build job runs on a self-hosted runner labelled `marola-br`, on a machine in
Brazil, and reaches both directly: no proxy and no open port, since the runner only connects out to
GitHub. The deploy job stays on GitHub's runners.

`site.yml` runs only by hand for now, from the Actions tab or `gh workflow run site.yml` (pick an
area, or `all`, the default). With the runner off, a run waits in the queue and marola.dev keeps
the last deployed site. Only an owner (a repo admin) can run it: the `owner` job, on GitHub's
runner, fails the run before the build job reaches the self-hosted one. Registering the runner,
from the devkit:

```bash
MAROLA_RUNNER_REPO=marola-dev/marola-site MAROLA_RUNNER_PREFIX=marola-site \
  MAROLA_RUNNER_LABELS=marola-br just runners 1
```

A public repo's self-hosted runner runs whatever a workflow in a pull request asks it to, so keep
Settings → Actions → "Approval for running fork pull request workflows" on *all external
contributors*. `just site-build` works the same from any machine in Brazil.

## The `site-data` branch layout

An orphan branch, never deployed by the workflows that write it: `coverage/` and `smoke/` (the
app's CI and `docker-smoke.yml`), `stats/` (the umbrella). Each writer pushes with
`scripts/site-data-push.sh` (retries on a rejected push, replaying its one commit onto the new
tip) and then sends `repository_dispatch: site-data-updated`, which `site.yml` ignores while it runs
only by hand: the panels refresh on the next manual run. A directory missing from the branch just means no panel for it;
a missing branch means none of the three.

## Health checks

`site-health.yml` runs `python3 scripts/site_live_check.py` against the live site every six hours,
separate from `site.yml` on purpose: a red run here means upstream data is missing (a bulletin
gone stale, a provider down), not that the build is broken, so it must never block a deploy.

## i18n bundling

`site/i18n/*.json` (`pt-BR` is the source locale, `en` is translated, `x-pseudo` is generated,
never translated) are checked and bundled into `site/static/i18n.js` by `scripts/i18n_bundle.py`
(MIP-0054 §5.8): every locale has exactly `pt-BR`'s keys with no empty value, every message parses
in the ICU subset `ui.js` implements and names the same arguments as `pt-BR`'s, and every key has a
note in `context.json`. Edit the catalogs, never `i18n.js`; `--check` fails a stale committed
bundle.

## News posts

A post is `site/content/news/YYYY-MM-DD-<slug>.pt-BR.md` plus its `.en.md`, in the format
[`site/content/news/README.md`](../site/content/news/README.md) gives, listed in that file's index.
`python3 scripts/news_build.py` writes every post into the marked block of
`site/static/news.html`, newest first; `--check` fails a stale page, a post missing a language and
any Markdown outside the format. Edit the posts, never the block. Each post shows its reading time,
its words over 200 a minute, rounded up; the `news-post` skill has the rule.

## The `MIP:` trailer

A commit touching `site/static/**` carries `MIP: MIP-NNNN` or `MIP: none — <reason>`.
`scripts/mip-trailer-check.sh` enforces it; `just prepush` runs it over the commits about to be
pushed.

# Cuekeeper website

Static, dependency-free site for `https://cuekeeper.arjunakankipati.com`.
The support guide and privacy policy are complete content pages. The homepage is
an intentionally small branded shell for the later marketing pass; it makes no
claim of App Store availability and has no inactive download button.

## Build and check

Requires Python 3. No npm install, JavaScript runtime, server functions or secrets.
From the repository root:

```sh
python3 website/build.py
python3 -m unittest discover -s website/tests
```

The deployable folder is `website/dist`. Only deploy that folder, never the whole
repository. It contains HTML, one stylesheet, the approved SVG mark, a sitemap,
robots.txt and Cloudflare security headers. Its size is well below Pages Free
limits. Domain registration and email hosting are separate from Pages hosting.

- `content/support.json`: editable guide sections, steps, notes and topic labels.
- `content/privacy.json`: public policy including the website-hosting disclosure.
- `build.py`: shared header/footer and page templates, metadata and output files.
- `assets/site.css`: responsive light/dark and print styles using app brand tokens.
- `assets/mark.svg`: existing approved mark with its viewBox cropped, not redrawn.
- `DESIGN.md`: web surface contract; native app design files remain authoritative.

The JSON files are the only maintained source for the support guide and privacy
policy; App Store Connect links to these pages rather than taking their text. Revise
the policy date whenever the policy changes.

## Cloudflare Pages: recommended Git integration

Perform these steps yourself in Cloudflare; no browser or account setup was
performed by the agent. This path suits continued homepage work tomorrow.

1. Commit and push the website to the repository/branch you want Cloudflare to
   deploy. In Cloudflare, create a **Pages** project and connect that Git repository
   (choose Pages rather than a Worker requiring runtime code).
2. Set framework preset to **None**, root directory to the repository root,
   build command to `python3 website/build.py`, and build output directory to
   `website/dist`. Choose your intended production branch. No environment variables
   or secrets are required. Use a build environment with Python 3 available.
3. Deploy. Confirm the assigned `*.pages.dev` address opens the homepage,
   `/support` and `/privacy`, and a nonexistent path returns the 404 page.
4. In that Pages project's **Custom domains**, add
   `cuekeeper.arjunakankipati.com`. Complete this association before changing DNS.
5. If your domain is managed outside Cloudflare, create the requested CNAME for
   `cuekeeper` pointing to the actual assigned `PROJECT.pages.dev` hostname.
   Do not use a made-up project hostname. If the zone is already managed by
   Cloudflare, follow its offered DNS setup. Wait for domain/certificate activation.
6. Verify HTTPS on all three public routes and verify that HTTP redirects to
   HTTPS. Confirm that `cuekeeper@arjunakankipati.com` can receive and reply to mail;
   Pages does not create the mailbox.

Root-level `support.html` and `privacy.html` use Pages' built-in extensionless
routing; the iOS app's `/support` and `/privacy` URLs are unchanged. An explicit
`404.html` prevents treating unknown routes as an SPA. No catch-all redirect is
needed. Keep the Cloudflare response-header file `_headers` in the upload.

## Manual upload alternative

After building, create an upload archive:

```sh
(cd website/dist && zip -r ../cuekeeper-pages.zip .)
```

Use Cloudflare Pages **Direct Upload**, uploading that ZIP or the `dist` folder.
The archive must contain `index.html` at its root. Then add the custom domain as
above. Cloudflare currently does not support switching a Direct Upload project
into a Git-integrated project; create a new project if changing that choice.
Git integration is recommended for this site's ongoing edits.

## Local human preview

To review without deploying, run:

```sh
python3 website/preview.py
```

Open `http://127.0.0.1:8080` yourself. The preview helper serves `/support` and
`/privacy` just like the intended Pages routes and returns the custom 404 page for
unknown paths. It binds only to localhost and never opens a browser. Stop it with
Ctrl-C. It does not apply Cloudflare's `_headers`; local preview does not prove
live headers or custom-domain setup. No preview browser was opened or controlled
by the agent.

## Verification and final visual review

Automated checks cover internal links and anchor targets, unique IDs, one main
landmark and h1 per page, named navigation, skip links, JSON section coverage,
sitemap URLs, core text contrast pairs, output size and absence of scripts,
iframes and forms. All content is accessible without JavaScript.

The website follows system light/dark preference. Desktop uses a sticky topic
index with its own scrolling when needed; mobile puts a full index before the
content. Keyboard focus and reduced-motion/print modes are explicitly styled.

Browser/computer-control tools are prohibited for this repository. No rendered
screenshots or browser interaction checks were performed. Before launch, review
these yourself on a narrow phone and desktop, in light and dark appearance:

- Header/nav wrapping, body readability, topic index, anchors, and bottom footer.
- Keyboard Tab order, visible focus, skip link and zoom to 200%.
- Email opens a draft without sending automatically; support/privacy links work.
- Print preview is readable and long policy/support text is not clipped.
- The support wording matches the final app build, and policy/support handling
  accurately describes how you operate the mailbox.

Keep Cloudflare Web Analytics, injected widgets and third-party scripts disabled
unless deliberately adding them and updating the privacy statement/CSP. This
build uses no cookies or browser storage. Cloudflare processes request metadata
to deliver/protect the site; its policy is linked from the website privacy section.

## Official hosting references

Checked October 15, 2026 using terminal HTTP requests:

- [Static HTML build settings](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/)
- [Pages Free plan limits](https://developers.cloudflare.com/pages/platform/limits/)
- [Custom domains and CNAME association](https://developers.cloudflare.com/pages/configuration/custom-domains/)
- [Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/)
- [Serving Pages and HTML routes](https://developers.cloudflare.com/pages/configuration/serving-pages/)

# Breaths: a private cat breathing tracker

A small web app for logging a cat's breathing rate (breaths per minute), made for
monitoring a cat with HCM. Add it to an iPhone Home Screen and it behaves like an app.

- **Count**: tap once per breath; the 1-minute timer starts with the first tap.
- **Log**: every reading by day; add past readings or edit/delete any reading.
- **Trends**: asleep and awake readings charted separately, with an alert line
  (default 30/min; set your vet's number under More).
- **Import / export**: paste an old text log or a CSV; export CSV to back up or send to the vet.

## Privacy

There is no server and no account. Readings are stored only in the app's storage on your
phone. This repository contains only the app's code, never your data.

## Install on iPhone

1. Open the GitHub Pages address in **Safari**.
2. Tap **Share**, then **Add to Home Screen**.
3. Open it from the Home Screen icon from then on. (Safari and the Home Screen app keep
   separate data, so enter readings in the Home Screen app.)

Back up now and then with **More → Export CSV**.

## Files

`index.html`, `styles.css`, `app.js` are the app. `sw.js` makes it work offline
(bump `CACHE` in it when releasing changes). `manifest.webmanifest` and `icons/` are for the
Home Screen icon.

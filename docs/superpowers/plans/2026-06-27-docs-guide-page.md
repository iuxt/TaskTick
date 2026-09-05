# Docs Guide Page Maintenance

The guide lives at `docs/guide/index.html` and documents script notifications.
The marketing site links to it from the navigation and the Notifications card.

## Structure

- Keep the guide as standalone static HTML, CSS, and JavaScript.
- Keep the notification section at `#notifications` so existing app and site
  links continue to work.
- Document the current directive syntax, required fields, examples, output
  stripping, global notification setting, and per-run notification limit.
- Keep the visual style consistent with the marketing page, including dark mode
  and responsive navigation.

## Localization

- Maintain English and Simplified Chinese prose together.
- Keep notification JSON and shell examples verbatim in code blocks.
- Use textContent for guide translations.
- Share the `tasktick-lang` preference with the marketing site. If the saved
  language is unsupported by the guide, render English without overwriting it.

## Verification

- Check the site's Docs navigation and Notifications card links.
- Check the guide's table of contents and Home link.
- Switch between English and Simplified Chinese; verify prose translations and
  unchanged code samples.
- Check JavaScript syntax, translation keys, and internal anchors.
- Verify that an unsupported saved language survives a visit to the guide.

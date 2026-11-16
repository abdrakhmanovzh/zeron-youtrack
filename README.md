# YouTrack for Zeron

A Zeron plugin that puts your YouTrack issues on a page of their own in
Zeron's sidebar, laid out like a Linear list.

- **List**: issues grouped by state, in your project's own state order
  (Backlog, Blocked and Ready to go first), each group folding; one dense row
  per issue: priority, id, title, tags, assignee, last update. Three tabs:
  *Assigned to me*, *Reported by me*, *All*. A filter field searches as you
  type. Only the rows in view are drawn, so long lists scroll lightly.
- **Issue view**: click an issue and it opens beside the list, in the page's
  panel: its properties, its description and comments as markdown, with
  attached pictures shown.
- **Changes**: state, priority, type and assignee are pickers, and tags come
  off with their × and go on from a picker. A change shows at once; if
  YouTrack refuses it, it goes back and a toast says why. Nothing else is
  ever written to YouTrack.
- **Cache**: lists you've seen open at once (also after a restart) and
  refresh quietly behind; they're asked again every five minutes.

## Install

In Zeron: **Settings → Plugins → Install…** and paste this repository's
link. Zeron checks the plugin's signature and shows what it asks for:

| Permission | Why |
|---|---|
| Pages | its page in the sidebar |
| Panel tabs | an issue opening beside the list |
| Network | YouTrack's REST API, only on the hosts below |
| Links | "Open in YouTrack", and links in issues, in your browser |

## Set up

1. In YouTrack: **Profile → Account Security → New token…**, scope
   **YouTrack**. The plugin works as you: it can change only what you can.
2. In Zeron: **Settings → Plugins → YouTrack**: your YouTrack's address
   (`https://yourteam.youtrack.cloud`, without `/api`) and the token.
   Optionally a project's short name, and an extra query (default
   `#Unresolved`).

The token is kept by Zeron for this plugin alone; it's never in the plugin's
files.

### Self-hosted YouTrack

Zeron sends the token only to hosts the plugin's manifest names. YouTrack
Cloud (`*.youtrack.cloud`, `*.myjetbrains.com`) is named. For a YouTrack on
your own domain, add its host to `network.hosts` in `zeron-plugin.json`:

```json
"network": { "hosts": ["*.youtrack.cloud", "*.myjetbrains.com", "youtrack.example.com"] }
```

That makes it a copy of your own (Zeron signs it as yours), so it no longer
takes this repository's updates.

## Notes

- A state gets a group only when the list has issues in it. Resolved states
  (Done, and the like) are left out by the default `#Unresolved` query.
- Lists hold the 200 most recently updated issues.
- People are drawn as their initials: YouTrack's avatars need the token,
  which a picture can't send. Attached pictures load from YouTrack's signed
  attachment addresses, which don't.

## Files

| File | What |
|---|---|
| `init.luau` | registers the page and the issue tab |
| `board.luau` | the list |
| `viewer.luau` | the issue view |
| `api.luau` | YouTrack's REST API |
| `cache.luau` | lists kept between runs (the plugin's own SQLite) |
| `look.luau` | states' hues, priority bars, initials, dates |
| `bus.luau` | the issue view telling the list it changed something |
| `locales/en.json` | the words |
| `zeron.luau` | Zeron's plugin helpers (Zeron's own file, MIT) |
| `zeron-plugin.json` | the manifest, signed by Zeron |

## License

MIT, see `LICENSE`. `zeron.luau` is Zeron's helper file, shipped in every
plugin under Zeron's own MIT license.

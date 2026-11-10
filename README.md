<div align="center">
  <img src="Assets/TreluneMark.png" alt="Trelune logo" width="72" />
  <h1>Trelune</h1>
  <p><strong>Your creative space, from draft to publish.</strong></p>
  <p>Plan, create, and track content for your social channels in a native macOS app.</p>
  <p>
    <a href="#get-started">Get started</a> ·
    <a href="#one-workflow-for-your-channels">Explore the app</a> ·
    <a href="#channels-and-integrations">Integrations</a> ·
    <a href="#documentation">Documentation</a>
  </p>
  <p><sub>macOS 14+ &nbsp;·&nbsp; Apple silicon & Intel &nbsp;·&nbsp; <a href="README.pt-BR.md">Português do Brasil</a></sub></p>
</div>

<br />

<p align="center">
  <img src="docs/images/overview-dark.png" alt="Trelune overview in dark mode" width="100%" />
</p>

## One workflow for your channels

Creating content already involves enough decisions. Trelune brings your calendar, posts, media, and metrics together in an interface made for Mac. Prepare an idea for one or several channels, tailor the details for each destination, and review everything before publishing.

<table>
  <tr>
    <td width="50%"><img src="docs/images/new-post-dark.png" alt="Choosing destinations for a new post" /></td>
    <td width="50%"><img src="docs/images/calendar-light.png" alt="Monthly content calendar" /></td>
  </tr>
  <tr>
    <td><strong>One idea, multiple destinations</strong><br />Choose your channels and tailor content and options for each one.</td>
    <td><strong>Your plans at a glance</strong><br />Organize posts on the calendar and check their date, time, and time zone.</td>
  </tr>
</table>

### From creation to follow-up

- **Prepare:** organize images and videos, build carousels, choose a cover, and reorder your media.
- **Review:** check content, privacy, conflicts, and scheduling before confirming.
- **Track:** see results and failures by channel, retry when needed, and explore metrics and recent activity.
- **Work your way:** import local media, export posts to CSV, and choose light, dark, or system appearance. The app follows your macOS language: Brazilian Portuguese or English.

## Get started

### Requirements

- A Mac running **macOS 14 Sonoma or later**, with Apple silicon or an Intel processor.
- An internet connection to download the app and use connected channels.
- Your own developer credentials for each channel you choose to connect. You can install and explore the app without configuring integrations.
- To build from source: Xcode 16 or later, command-line tools, and Swift 6.

### Install with the DMG

1. Open [the latest release](https://github.com/giovannibraaga/trelune/releases/latest) and download `Trelune-<version>.dmg`.
2. Open the downloaded file and drag **Trelune** into **Applications**.
3. Open **Trelune** from Applications. The current release is not notarized by Apple, so macOS may block its first launch. If this happens, dismiss the warning, then go to **System Settings → Privacy & Security** and choose **Open Anyway** next to Trelune.
4. Open **Connections** to set up the channels you want to use.

The release also includes a `Trelune-<version>.pkg` installer. Open it and follow its instructions to install into Applications; macOS may similarly warn about its signature.

### Verify a download

Download the `.sha256` file corresponding to the DMG or PKG into the same folder as the installer. In Terminal, go to that folder and run, replacing the example filename with the downloaded checksum file:

```bash
cd ~/Downloads
shasum -a 256 -c Trelune-1.0.0.dmg.sha256
```

A successful check prints `OK`. This verifies the file matches the checksum provided in the release; it does not establish the publisher's identity.

### Install or update from Terminal

If you prefer Terminal, first inspect [`install.sh`](install.sh), then run:

```bash
curl -fsSL https://raw.githubusercontent.com/giovannibraaga/trelune/main/install.sh | bash
```

The script downloads the latest DMG and checksum, verifies the download, replaces any existing Trelune app in `/Applications` (or uses `~/Applications` if that folder is not writable), and opens it. It closes a running Trelune instance first. Only run a downloaded script after reviewing and trusting its source.

### Build from source

```bash
git clone https://github.com/giovannibraaga/trelune.git
cd trelune
./script/build_and_run.sh
```

The script builds `dist/Trelune.app` and opens it. To compile without opening the app, run `swift build -c release`. Nothing in [`.env.example`](.env.example) is required for a normal build; copy it to `.env` only if you need to change the optional settings. Keep `BUNDLE_ID` stable after connecting accounts because it also identifies Keychain items and preferences. Without an Apple Development certificate the build uses ad-hoc signing, so Keychain may ask for permission again after rebuilding.

### Create your first post

1. Open **Connections** and choose a channel. Create the required developer credentials and connect your account using the [connection guide](docs/CONNECTIONS.md).
2. Create a post, select one or more connected destinations, and add your text and media.
3. Adjust each destination's options and review the preview, privacy, and any validation messages.
4. Confirm an immediate post, or choose a date, time, and time zone and confirm the schedule. Check the result in **Posts** or the calendar.

Some channels require publicly accessible HTTPS media URLs, API permissions, app review, or a particular account type. See the integration table and guides below.

### Updating and uninstalling

To update, install the latest release over the existing app, or rerun the Terminal installer. Close Trelune before replacing it. Your workspace data is kept separately from the app; make a backup before changing or removing it.

To uninstall, quit Trelune and move `Trelune.app` from Applications to the Trash. This does **not** remove your workspace data in `~/Library/Application Support/Trelune/`, credentials in macOS Keychain, or any optional AWS resources. Remove those separately only if you no longer need them.

## Channels and integrations

| Channel | What you can prepare | Before connecting |
|:--|:--|:--|
| **YouTube** | Videos, title, tags, privacy, thumbnail, and metrics | Desktop OAuth and resumable uploads. |
| **Instagram** | Photos, carousels, and Reels; authorized metrics | A professional account linked to a Meta Page and media hosted at a public HTTPS URL. |
| **Facebook Pages** | Text, photo albums, and Reels; authorized metrics | Publishes to Pages you manage; permissions may require review. |
| **TikTok** | Video or photo carousel; inbox draft or direct publishing | The API and test mode may restrict formats and visibility. |
| **Threads** | Text, images, videos, and carousels | Features depend on account permissions and media configuration. |
| **X** | Text and up to four images or one GIF | This integration does not upload videos. |

Capabilities depend on approved scopes and each platform's API. See [Connections](docs/CONNECTIONS.md) and [TikTok](docs/TIKTOK.md) for details.

## Made for your space

**Local data.** Posts and preferences are stored in `~/Library/Application Support/Trelune/`; OAuth tokens and secrets are stored in macOS Keychain. You use your own credentials to connect channels.

**Flexible scheduling.** Without cloud configuration, the app must be open at the scheduled time. To publish while your Mac is off, set up publishing in your own AWS account using the [cloud guide](docs/CLOUD.md).

**Assistants, if you want them.** The optional [MCP](mcp/) server lets an authorized assistant read and manage posts. The app can also start in MCP mode with `Trelune --mcp`. Configure only the tools and permissions you want to grant.

The project does not include a hosted service or subscription plan provided by the maintainer. Do not share or commit tokens, secrets, credential files, or private data. If a credential is exposed, revoke it with the provider and create a new one.

## Troubleshooting

- **macOS will not open the app:** follow the first-launch steps above and verify you downloaded the release from this repository.
- **A connection or publication fails:** check the channel's credentials, account type, permissions, API access and any platform review requirements in [Connections](docs/CONNECTIONS.md). For media requiring an HTTPS URL, check your hosting configuration.
- **A scheduled post was not sent:** check the date and time zone. Without cloud publishing, Trelune must remain running at the scheduled time; with it, check your AWS configuration and permissions.
- **A locally built app repeatedly asks for Keychain access:** use a stable Apple Development signing identity and keep the same `BUNDLE_ID`.

For other problems, [open an issue](https://github.com/giovannibraaga/trelune/issues) with your macOS and Trelune versions and reproduction steps. Never include tokens, passwords or private content.

## Documentation

| Guide | What it's for |
|:--|:--|
| [Connections](docs/CONNECTIONS.md) | Set up accounts and credentials for each channel. |
| [TikTok](docs/TIKTOK.md) | Learn about the TikTok integration. |
| [Cloud](docs/CLOUD.md) | Configure media hosting and publishing in your AWS account. |
| [MCP](mcp/) | Set up the server for assistants. |

## Development

```bash
swift build
swift test
```

To create an installer:

```bash
VERSION=1.0.0 ./script/release.sh
```

The script creates `dist/release/Trelune-<version>.dmg` with a universal app for Apple silicon and Intel. With a **Developer ID Application** certificate in Keychain, it signs the app with the hardened runtime. With `NOTARY_PROFILE` (a profile created by `xcrun notarytool store-credentials`), it also notarizes the DMG, removing the first-launch warning.

The app code lives in `Sources/Trelune/`, tests in `Tests/`, and scripts in `script/`. Issues and pull requests are welcome. When reporting a problem, include your macOS version, steps to reproduce, and affected channels, but leave out credentials and private data.

## Security

Report suspected vulnerabilities privately using the instructions in [SECURITY.md](SECURITY.md). Do not post security details, credentials, or tokens in a public issue.

## License

Trelune is available under the [MIT License](LICENSE).

---

<div align="center">
  Made to give your ideas room to grow.<br /><br />
  <a href="https://github.com/giovannibraaga/trelune/issues">Report an issue</a> ·
  <a href="https://github.com/giovannibraaga/trelune/releases">Releases</a>
</div>

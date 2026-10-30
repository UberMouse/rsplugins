# Submitting to Mod.io

Plugins are distributed through <https://mod.io/g/runescape>. You need a Mod.io account. Using a
name the RS community already knows you by is optional. Everything on the listing must follow
RuneScape's language rules.

## Upload steps ("Add plugin")

1. **Profile**
   - Name: 1–50 chars, ASCII. Summary: 10–250 chars, ASCII.
   - Listing image: 16:9, at least 512×288.
   - Optional homepage (e.g. this GitHub repo). Profile URL.
   - Toggles: comments, **allow dependents** (once anything depends on your plugin you can't
     delete it), collections.
   - Description: up to 50k chars. It **must** contain the required sections below.
   - **Tags**: any number, but every permission you request needs its matching permission tag.
   - **Visibility**: visible as soon as you create it (even before files) unless you set it
     hidden. Approval makes it visible.
2. **Media**: up to 10 images per upload (jpg/png or a zip), YouTube links. Sketchfab doesn't
   apply.
3. **Dependencies**: declare every manifest `requiredDependencies` entry as a Mod.io dependency.
   Don't declare optional ones. Only approved plugins that allow dependents are listed.
4. **Files**: one zip (max 20 GB) with `main.lua` + `plugin.json` **at the zip root**, plus
   everything else except declared dependencies.
   - Platforms: tick **all** of Windows, Linux, Android, iOS **and** Source, or the upload is
     rejected. Plugins are expected to work on every platform.
   - Version: digits and `.` only. The changelog is optional for v1. Metadata blob is unused.

## Required description sections

Every listing needs **four** sections: Email, EULA, Permissions, Data protection.

- **Email**: a real email address (no other contact method) where users can request access to or
  deletion of their data. It's public, so use a dedicated address. Under data-protection case 1
  you can ask for it to be hidden; moderators move it into hidden metadata.
- **EULA**: the fixed acknowledgement text linking to <https://legal.jagex.com/docs/terms/eula>
  (template below).
- **Permissions**: one paragraph per requested permission saying what it's used for, plus how
  combined permissions work together. If the plugin requests none, say so explicitly.
- **Data protection**: what data the plugin uses and where it goes, under one of three cases:

| Case | Data goes… | You must provide |
|---|---|---|
| 1 | Nowhere: stays in the plugin/device | Data used. Can request the email be hidden |
| 2 | To an endpoint in the UK/EEA or a country with UK adequacy | Data used, endpoints, security measures, **and a privacy notice** (ICO generator: <https://ico.org.uk/create-your-own-privacy-notice>) |
| 3 | To an endpoint *without* UK adequacy (**including the USA**) | Everything in case 2, **plus** the Airtable form after submitting: name, address (at least country), data-protection email. Form: <https://airtable.com/embed/appwYtnpdqb57zdn8/shrXVpUX3ChiIEAHX> (password `RS3API`) |

UK adequacy as of Sept 2026, outside the UK/EEA. Full: Andorra, Argentina, Faroe Islands,
Gibraltar, Guernsey, Isle of Man, Israel, Jersey, New Zealand, South Korea, Switzerland, Uruguay.
Partial (relevant): Canada, Japan. **The USA doesn't count.** Most cloud hosting defaults
(US regions) are therefore case 3, so pick a UK/EU region to stay in case 2.

A privacy notice needs at least: name and contact details, purposes, lawful basis, legitimate
interests, data categories, recipients, transfers, retention, and user rights.

### Description template

```markdown
## Email
The contact email address for this plugin is <address>.

## EULA
By submitting a Plugin (as defined in Schedule 4 of the EULA), you acknowledge that you agree to the terms of the Jagex End User License Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it be reference) and acknowledge that such terms are legally binding on you. If you do not agree to the terms of the EULA, you must not submit a Plugin or use the Plugin functionality anyway. In such circumstances, Jagex does not licence the software to you, or grant you any of the relevant rights relating to the submission of Plugins set out in the EULA and you will not be permitted to access or use the Plugin functionality in any way whatsoever.

## Permissions
This plugin requests no permissions.
<!-- or, per permission: "This plugin requests the httpAccess permission for <site>. It is used to send <data> to that website, where it is used for <purpose>." Then a paragraph on any permissions used together. -->

## Data Protection
<!-- Case 1 -->
This plugin uses the following information: <data>.
This information is not transmitted outside of the plugin under any circumstances.
<What, if anything, is stored between sessions (e.g. settings in PersistentDB).>
For Jagex: I request that the supplied email is hidden from public view.   <!-- optional -->

<!-- Case 2/3: replace the "not transmitted" line with: transmitted to <endpoint> in <UK/EEA/adequate country | a country without adequacy, with safeguards agreed with Jagex>; the privacy notice is at <url>; the endpoint secures data by <measures>; it can be accessed by <who>; data-rights requests go to the email above. -->
```

The EULA paragraph is Jagex's required wording (including its typos). Copy it verbatim.

## Preparing the zip from this repo

A plugin in `plugins/` may carry dev opt-ins (the `dev/` link to `lib/dev/`, the recorder and tee
lines, `urls.rsdev`, `httpAccess`). Build the upload from a copy, never from the dev tree:

1. Copy the plugin without `dev/`, inside the repo so the lint configs apply. `dumps/` is
   gitignored:

   ```sh
   mkdir -p dumps/submission/plugins
   rsync -a --exclude dev plugins/<name> dumps/submission/plugins/
   ```

   The dev shell has neither `rsync` nor `zip`. Without rsync, use
   `cp -rP plugins/<name> dumps/submission/plugins/` (`-P` copies the `dev` symlink as a link,
   not its target) and then `rm dumps/submission/plugins/<name>/dev`.
2. Strip the rest of the opt-in from the copy's `main.lua` and `plugin.json`: the
   `require("dev/...")` lines, `tee.install`/`tee.shutdown` and `recorder.install`/`shutdown`
   calls with their comments, `"httpAccess"` from `optionalPermissions` (unless a feature of the
   plugin needs it), and `urls.rsdev`. The plugin's README lists its own pieces (Chore Tracker:
   "Before submitting").
3. Run `scripts/check-submission.sh <name> --root dumps/submission`. It must exit 0; it names
   every dev piece left. Then run `scripts/check.sh dumps/submission/plugins/<name>`: it runs
   luac, the manifest, selene and stylua checks on the copy (then the whole suite). LuaLS ignores
   `dumps/`, so type checking only happens on the dev tree.
4. Zip from inside the plugin folder, so `main.lua` and `plugin.json` sit at the zip root. Any
   zip tool works if the plugin's files are at the archive root; with Info-ZIP:

   ```sh
   cd dumps/submission/plugins/<name> && zip -r ../<name>.zip .
   ```

## Moderation

- You can keep editing the listing or uploading files **until a moderator starts**. They will then
  ask for a **submission freeze**: no Mod.io changes until moderation finishes (your own repo is
  fine).
- Moderators read all the code and run the plugin in a closed environment. **This isn't QA.**
  Submit working, tested code; other devs on the Discord can help test.
- The listing is checked for misleading content and language, usually in the same pass.
- The report says which items are hard requirements and which are suggestions. Outcomes:
  - **Pass**
  - **Minor corrections**: fix and resubmit
  - **Major corrections**: discussion with the moderator. Also the result when the code can't be
    moderated, e.g. unreadable code
  - **Fail**: fundamentally against the guidelines

## Updating

- Edit the listing with the pencil icon (creator and added contributors). After approval, Jagex is
  notified of every edit.
- Upload new versions as **new files on the same Mod.io plugin**, never as a new plugin. Each
  version is moderated again. The previous approved files stay live until then, and the new
  files go live when approved.

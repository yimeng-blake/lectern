# Lectern guide

This guide tells you how to install, use and remove Lectern. The [README](../README.md) gives the short procedures.

This guide has CAUTION notices. Read each CAUTION before you do the step that follows it.

## Contents

- [Before you start](#before-you-start)
- [Necessary items](#necessary-items)
- [Install the CLIs](#install-the-clis)
  - [Install Claude Code](#install-claude-code)
  - [Install Codex (for ChatGPT)](#install-codex-for-chatgpt)
- [Install Lectern](#install-lectern)
  - [Option A: Download the app](#option-a-download-the-app)
  - [Let macOS open Lectern](#let-macos-open-lectern)
  - [Option B: Build from source](#option-b-build-from-source)
- [Sign in](#sign-in)
  - [Sign in to Claude](#sign-in-to-claude)
  - [Select Isolated or Shared (ChatGPT)](#select-isolated-or-shared-chatgpt)
  - [Sign in to ChatGPT](#sign-in-to-chatgpt)
  - [Questions before you sign in](#questions-before-you-sign-in)
- [Use the viewer](#use-the-viewer)
  - [Open a PDF](#open-a-pdf)
  - [Go to a page](#go-to-a-page)
  - [Use the sidebar](#use-the-sidebar)
  - [Zoom and page layout](#zoom-and-page-layout)
  - [Search the PDF](#search-the-pdf)
  - [Highlights and notes](#highlights-and-notes)
  - [Print the PDF](#print-the-pdf)
  - [Change the appearance](#change-the-appearance)
  - [What Lectern keeps for each PDF](#what-lectern-keeps-for-each-pdf)
- [Use the chat pane](#use-the-chat-pane)
  - [Ask a question](#ask-a-question)
  - [Use more than one conversation](#use-more-than-one-conversation)
  - [Ask about a selection](#ask-about-a-selection)
  - [Presets](#presets)
  - [Fast](#fast)
  - [Protect purchased credits](#protect-purchased-credits)
  - [Citations](#citations)
  - [Citation check badges](#citation-check-badges)
  - [Save a table as CSV](#save-a-table-as-csv)
  - [Context](#context)
  - [Scanned PDFs (OCR) and table pages](#scanned-pdfs-ocr-and-table-pages)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Settings](#settings)
- [Privacy and usage](#privacy-and-usage)
  - [Remove all conversations](#remove-all-conversations)
- [Problems and remedies](#problems-and-remedies)
- [Install a new version or remove Lectern](#install-a-new-version-or-remove-lectern)
  - [Install a new version (Option A)](#install-a-new-version-option-a)
  - [Install a new version (Option B)](#install-a-new-version-option-b)
  - [Remove Lectern](#remove-lectern)
- [For developers](#for-developers)

## Before you start

Read this information before you use Lectern.

- **Not from Anthropic or OpenAI.** Lectern is an open-source project of one person. Anthropic and OpenAI did not make
  Lectern. Lectern is not a product of Anthropic or OpenAI, and these companies do not give money to the project.
- **Your plans, through the CLIs from Anthropic and OpenAI.** Lectern uses your Claude and ChatGPT plans. It runs the
  `claude` and `codex` command-line tools (CLIs) from Anthropic and OpenAI as child processes, without changes.
  Lectern sends your questions and the text of the PDF only to the provider that you use, through the CLI of that
  provider. Lectern has no server, no analytics and no telemetry.
- **No credentials in Lectern.** Lectern never reads, keeps or sends your passwords, tokens or API keys. You sign in
  with the sign-in procedures of Anthropic and OpenAI, and the CLIs keep these sign-ins. In Isolated mode (the
  default), Codex keeps a separate Lectern sign-in for ChatGPT in the Lectern folder
  (`~/Library/Application Support/Lectern`). Refer to [Privacy and usage](#privacy-and-usage).
- **Read-only.** Lectern never changes your PDFs. It keeps your conversations, the last page and the zoom in the
  Lectern folder, never in the PDF.
- **Plan terms.** Lectern is for personal, non-commercial use of your Claude and ChatGPT plans. Read the terms of your
  plans before you use Lectern. Each message uses part of the usage limits of your plan, the same as in the Claude and
  ChatGPT apps.

## Necessary items

| Item | What is necessary |
| --- | --- |
| Mac | A Mac with Apple Silicon and macOS 14 or later. |
| For Claude | A Claude plan with Claude Code (for example Pro or Max), and Claude Code on your Mac. |
| For ChatGPT | A ChatGPT plan with Codex, and the ChatGPT desktop app or the Codex CLI from npm. |

The author tested Lectern only on macOS 26. If you use Lectern on macOS 14 or 15, send a report to the author. To send
a report, write an issue on the [Issues page](https://github.com/yimeng-blake/lectern/issues) of Lectern on GitHub.

## Install the CLIs

**Commands.** This guide tells you to run commands in Terminal (Applications > Utilities > Terminal). To run a
command, type the command in Terminal. Then press Return.

Do these steps to install the CLIs:

1. If Lectern is open, quit Lectern.
2. Install only the CLIs for the providers that you use. Refer to the next two sections.
3. After the installation, open Lectern.

### Install Claude Code

1. Open Terminal.
2. Run this command:

   ```sh
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   If you use Homebrew, you can run `brew install --cask claude-code` instead. For more information, refer to the
   [Claude Code setup guide](https://code.claude.com/docs/en/setup).

Lectern finds `claude` if it is in one of these folders: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` or
`~/.claude/local`.

If you used npm to install an old version of Claude Code, your `claude` can be a Node.js script. Lectern cannot run a
Node.js script. To install the native build, run `claude install` one time.

### Install Codex (for ChatGPT)

Use one of these methods:

- Install the [ChatGPT desktop app](https://openai.com/chatgpt/desktop/). The app contains a copy of `codex`, and the
  app installs new versions of it automatically. Lectern finds this copy if the app is in `/Applications` or in
  `~/Applications`.
- Run `npm i -g @openai/codex`.

Lectern finds a Codex from npm automatically if you installed Node.js with Homebrew, with nvm or with the installer
from nodejs.org. If you use fnm, volta, asdf or a different Node.js version manager, refer to
[Problems and remedies](#problems-and-remedies).

## Install Lectern

### Option A: Download the app

1. Open the [Releases](https://github.com/yimeng-blake/lectern/releases) page.
2. Download `Lectern-<version>-arm64.zip`.
3. Optional: do a check of the download. Before you open the zip file, do these steps:
   1. Also download `Lectern-<version>-arm64.zip.sha256`.
   2. If Safari opened the zip file and moved it to the Trash, move it to Downloads again.
   3. Run this command:
      `cd ~/Downloads && shasum -a 256 -c Lectern-<version>-arm64.zip.sha256`
   4. Make sure that Terminal shows `OK`.
   5. If Terminal does not show `OK`, do not open the zip file. Download the zip file again.
4. Double-click the zip file. macOS puts `Lectern.app` in the same folder.
5. Move `Lectern.app` to your Applications folder.
6. Open Lectern. macOS does not let Lectern open the first time.
7. Do the procedure in [Let macOS open Lectern](#let-macos-open-lectern) for your macOS version.

### Let macOS open Lectern

macOS (Gatekeeper) does not let Lectern open the first time, because Lectern does not have Apple notarization. Apple
gives notarization only to developers with an Apple Developer ID. An Apple Developer ID has a cost each year, and this
project of one person does not have one. Use one of these procedures.

**macOS 15 and later**

After macOS does not let Lectern open, System Settings shows **Open Anyway** for approximately one hour only.

1. Open Lectern one time. macOS shows a dialog about Lectern.
2. Close the dialog. Do not move Lectern to the Trash.
3. Open **System Settings > Privacy & Security**.
4. Find the **Security** section.
5. Click **Open Anyway** for Lectern.
6. When macOS asks for your password, type your password.

**macOS 14**

1. In Finder, hold the Control key and click `Lectern.app`.
2. Select **Open** in the menu.
3. Click **Open** in the dialog.

On macOS 14, you can also use **Open Anyway** in System Settings, as for macOS 15.

**All macOS versions (Terminal)**

> [!CAUTION]
> Use this command only on the `Lectern.app` from the Lectern Releases page. This command removes the quarantine
> attribute, a macOS safety check.

1. Run this command:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Lectern.app
   ```

2. Open Lectern.

### Option B: Build from source

1. If you do not have the Command Line Tools, run `xcode-select --install`. The Command Line Tools contain Swift and
   git.
2. Run these commands, one at a time:

   ```sh
   git clone https://github.com/yimeng-blake/lectern.git
   cd lectern
   bash scripts/build-app.sh --install    # builds and copies Lectern.app to ~/Applications
   ```

3. Open Lectern from the Applications folder in your home folder (`~/Applications`). You can also use Spotlight
   (⌘Space) to find Lectern.

Notes:

- If you do not have git, do these steps instead of the `git clone` and `cd lectern` commands:
  1. Open the [Lectern page on GitHub](https://github.com/yimeng-blake/lectern).
  2. Click **Code > Download ZIP**.
  3. Open the zip file.
  4. Run `cd ~/Downloads/lectern-main`.
- The first build is complete after approximately 1 or 2 minutes. During the build, Terminal shows only a small
  quantity of text.
- The script puts the app in `~/Applications`, not in `/Applications`.
- An app that you build on your Mac does not have the quarantine attribute. Because of this, macOS lets it open.
- The full Xcode app is not necessary for the build.
- If possible, use Swift 6.0 or later. The author built Lectern only with Swift 6.3 (Command Line Tools for macOS 26).
  The script can use Swift 5.10 or later, but the author did not test older toolchains.
- If Terminal shows an error during the build, write an issue on the
  [Issues page](https://github.com/yimeng-blake/lectern/issues) of Lectern on GitHub. Attach the Terminal output to
  the issue.

## Sign in

The chat pane has a banner at the top. The banner shows sign-in problems, installation problems and questions about
purchased credits for the provider that you selected. You can also sign in from Settings > Accounts.

### Sign in to Claude

Claude uses the sign-in of Claude Code on your Mac. Install Claude Code first (refer to
[Install Claude Code](#install-claude-code)). If you use `claude` in Terminal and you signed in there, no more steps
are necessary.

If you did not sign in to Claude Code, use one of these procedures.

**Sign in from Terminal**

1. Run `claude` in Terminal.
2. Do the sign-in steps in Claude Code.

**Sign in from Lectern**

1. When the banner shows that you are signed out, click **Log in in Terminal**. Terminal opens and runs
   `claude auth login --claudeai`, the sign-in command of Claude Code.
2. Do the sign-in steps in Terminal.
3. Click the Lectern window. Lectern finds the new sign-in automatically.
4. If the banner continues to show that you are signed out, click **Check again**.

Lectern does a check for the new sign-in every 3 seconds, for a maximum of 5 minutes. If Lectern does not find the
sign-in in this time, it shows "The Claude login timed out. Try again."

After this error, click **Check again** or do this procedure again.

**Log in in Terminal** is also in Settings > Accounts.

### Select Isolated or Shared (ChatGPT)

The **Codex home** setting (Settings > Advanced) has two values. This guide uses the short names **Isolated** and
**Shared** for them.

- **Isolated — separate sign-in, no plugins, standard tier** (default): Lectern has a separate ChatGPT sign-in, with
  separate Codex settings. This sign-in does not change the sign-in of your Codex CLI or of the ChatGPT app.
- **Shared — uses ~/.codex login and your plugins**: Lectern uses the sign-in, the plugins and most of the settings in
  `~/.codex`. Lectern does not use the `notify` and `service_tier` settings. It sets the model and the reasoning
  effort for each message.

In Shared mode, a ChatGPT sign-in in Lectern also changes the sign-in of your Codex CLI.

To use the sign-in and settings in `~/.codex`, select **Shared** in Settings > Advanced.

### Sign in to ChatGPT

In Isolated mode (the default), you must sign in to ChatGPT in Lectern one time. Lectern uses the browser sign-in of
Codex. In Shared mode, Lectern uses the sign-in of your Codex CLI. If your Codex CLI is signed in, no more steps are
necessary.

If you must sign in, use one of these procedures.

> [!CAUTION]
> If your Codex CLI must keep its ChatGPT sign-in, do not sign in to ChatGPT in Lectern in Shared mode. In Shared
> mode, a ChatGPT sign-in in Lectern also changes the sign-in of your Codex CLI.

**Sign in with the browser**

1. In the banner or in Settings > Accounts, click **Sign in with ChatGPT**. Lectern opens the ChatGPT sign-in page in
   your web browser.
2. Do the sign-in steps in the browser.

**Sign in with a device code**

1. In the banner or in Settings > Accounts, click **Use a device code**. Lectern shows a code. Lectern also opens the
   sign-in page in your web browser.
2. Click **Copy** to copy the code.
3. If the browser does not show the sign-in page, click **Open sign-in page**. (In Settings, the link is
   **Open the sign-in page**.)
4. Paste the code on the sign-in page.

### Questions before you sign in

If you ask a question before you sign in, Lectern keeps the question. The chat pane shows "Waiting for you to log
in — will send automatically". Lectern sends the question after you sign in. If you close the window before the
sign-in is complete, Lectern does not send the question.

## Use the viewer

### Open a PDF

If you open Lectern without a PDF, Lectern shows the Open panel. Select a PDF to open it.

You can also use one of these methods:

- In Finder, hold the Control key and click the PDF. Then select **Open With > Lectern**.
- Drag the PDF to the Lectern icon in the Dock.
- In Lectern, select **File > Open…** (⌘O).
- Select **File > Open Recent**. This menu shows the PDFs that you opened last (a maximum of 10). **Clear Menu**
  removes all PDFs from the list.

Each PDF opens in a separate window. If the macOS setting **Prefer tabs when opening documents** (System Settings >
Desktop & Dock) is **Always**, each PDF opens as a tab in one window. If you open a PDF that is open in a window,
Lectern shows that window in front of the other windows.

If the PDF has a password, do these steps:

1. Type the password in the **Password** field.
2. Click **Unlock**. Lectern opens the PDF.

If the password is not correct, Lectern shows "That password didn't open it."

### Go to a page

The toolbar shows the page box, for example "12 of 340". In this guide, the current page is the page that the page
box shows. Some PDFs have page labels, for example "iv" for a page of the introduction. For these PDFs, the page box
shows the label, and the page number follows it, for example "iv (16 of 340)".

1. Click the page box, or select **Go > Go to Page…** (⌥⌘G).
2. Type a page number or a page label.
3. Press Return. Lectern shows that page.

If the PDF has page labels, Lectern first compares your text with the page labels. For example, if you type "12",
Lectern shows the page with the label "12". This page can be different from page 12 of the PDF. If no page label is
the same as your text, Lectern uses your number as a page number.

If Lectern cannot find that page number or page label, Lectern stays on the same page.

The **Go** menu has these commands:

| Command | Shortcut | Result |
| --- | --- | --- |
| Go to Page… | ⌥⌘G | Moves the cursor to the page box. |
| Previous Page | ⌥⌘↑ | Shows the page before the current page. |
| Next Page | ⌥⌘↓ | Shows the page after the current page. |
| First Page | ⌥⌘Home | Shows the first page. |
| Last Page | ⌥⌘End | Shows the last page. |
| Back | ⌘[ | Goes to the location before the last jump. |
| Forward | ⌘] | Goes to the location where you were before the last **Back**. |

Lectern records a jump when you go to a different page in one of these ways:

- You click a citation in the chat pane.
- You use the page box or **Go to Page…**.
- You select **First Page** or **Last Page**.
- You click an entry in the table of contents.
- You start a search, and the first match that Lectern shows is on a different page.

**Previous Page** and **Next Page** are not jumps. Lectern also does not record a jump when you go to a different
match with ⌘G, ⇧⌘G, Return or the list of matches.

### Use the sidebar

The sidebar shows small images of the pages (thumbnails), the table of contents of the PDF or your highlights. During
a search, the sidebar shows the search results.

| Command (View menu) | Shortcut | Result |
| --- | --- | --- |
| Hide Sidebar / Show Sidebar | ⌥⌘1 | Removes the sidebar from the window, or shows it again. |
| Thumbnails | ⌥⌘2 | Shows the page thumbnails. Click a thumbnail to go to that page. |
| Table of Contents | ⌥⌘3 | Shows the table of contents. Click an entry to go to it. You can use this command only if the PDF has a table of contents. |
| Highlights | ⌥⌘4 | Shows your highlights and notes. Refer to [Highlights and notes](#highlights-and-notes). |

### Zoom and page layout

When you open a PDF for the first time, Lectern shows the full width of the page in the window (**Zoom to Width**).
You can also zoom with two fingers on the trackpad (pinch).

| Command (View menu) | Shortcut | Result |
| --- | --- | --- |
| Hide Chat / Show Chat | ⌃⌘C | Removes the chat pane from the window, or shows it again. |
| Actual Size | ⌘0 | Shows the page at 100%. |
| Zoom to Fit | ⌘9 | Shows the full page in the window. |
| Zoom to Width | — | Shows the full width of the page in the window. |
| Zoom In | ⌘+ or ⌘= | Makes the page larger. |
| Zoom Out | ⌘- | Makes the page smaller. |
| Single Page | — | Shows one page at a time. |
| Single Page Continuous | — | Shows the pages in one continuous column. This is the default layout. |
| Two Pages | — | Shows two pages next to each other, two pages at a time. |
| Two Pages Continuous | — | Shows two pages next to each other, in one continuous column. |

The **Scale** menu in the toolbar also has **Actual Size**, **Zoom to Fit** and **Zoom to Width**.

### Search the PDF

1. Press ⌘F, or select **Edit > Find > Find…**. Lectern moves the cursor to the search field in the toolbar.
2. Type a word or some words. Lectern starts the search approximately 0.25 seconds after you type the last letter.

Lectern shows the results:

- Lectern shows all matches on the pages in yellow.
- Lectern shows one match in orange. After a new search, this is the first match on or after the current page. If
  no match is on or after the current page, this is the first match in the PDF.
- The toolbar shows a counter, for example "3 of 27". The first number is the number of the orange match.
- Before Lectern finds the first match, the counter shows "Searching…". If no match is orange, the counter shows only
  the number of matches, for example "27 found". If there are no matches, it shows "No results".
- The sidebar shows a list of all matches, with some text around each match. Click a match in the list to go to it.

To move between the matches, or to stop the search:

- To go to the next match, press ⌘G. In the search field, you can also press Return.
- To go to the previous match, press ⇧⌘G. In the search field, you can also press ⇧Return.
- To stop the search, press Esc in the search field or in the PDF. Lectern removes the colors and the list of
  matches. The sidebar shows the same content as before the search. Esc in the message field of the chat pane does not
  stop the search.

To search for the text that you marked in the PDF, select **Edit > Find > Use Selection for Find** (⌘E).

Notes:

- For the search, uppercase and lowercase letters are the same. Letters with and without accents are also the same.
- Lectern shows a maximum of 5,000 matches. If there are more matches, the counter shows "5000+", for example
  "1 of 5000+".
- The search colors do not mark text in the PDF. Lectern does not send the matches to the provider as marked text.

### Highlights and notes

You can mark text in the PDF with a color (a highlight). You can also add a note to a highlight. Lectern keeps
highlights and notes in the Lectern folder, not in the PDF. The PDF file does not change.

To highlight text, do these steps:

1. Select the text in the PDF.
2. Hold the Control key and click the selected text.
3. Select **Highlight**, and then select a color.
   - You can also select **Edit > Highlight Selection** (⌃⌘H). This command uses yellow.

To add a note, do these steps:

1. Select the text in the PDF.
2. Hold the Control key and click the selected text.
3. Select **Add Note…**.
   - You can also select **Edit > Add Note to Selection…**.
4. Type the note.
5. Click **Save**. Lectern highlights the text in yellow and adds the note.

To change a highlight, hold the Control key and click it. Then select **Add Note…** (or **Edit Note…**), **Change
Color** or **Remove Highlight**.

To see all highlights, select **View > Highlights** (⌥⌘4). The sidebar shows the page, the text and the note of each
highlight. Click a highlight to go to it. To change or delete a highlight in the list, hold the Control key and click
it.

To export the highlights to a Markdown file, do these steps:

1. Select **File > Export Highlights…** (⇧⌘E).
2. Select a folder.
3. Click **Save**.

The file contains the text, the page number and the note of each highlight. If the PDF has no highlights, **Export
Highlights…** is gray.

Notes:

- The thumbnails and the printed pages also show the highlights.
- Lectern does not send highlights to Claude or ChatGPT. The page images that Lectern sends do not show highlights.
- If two windows show the same PDF, the two windows show the same highlights.

### Print the PDF

To print the PDF, select **File > Print…** (⌘P). macOS shows the Print dialog.

If the PDF does not let you print it, **Print…** is gray in the File menu. You cannot print this PDF with Lectern.

### Change the appearance

Lectern can use a light appearance or a dark appearance. Lectern can also show the pages with inverted colors
(**Dark Pages**). The PDF file does not change.

1. In the toolbar, click the **Appearance** button (the circle that is half black).
   - You can also select **View > Appearance**.
2. Select **System**, **Light** or **Dark**.
   - **System** uses the appearance of macOS.
3. To show the pages with inverted colors, select **Dark Pages**.
4. To show the pages with their usual colors, select **Dark Pages** again.

**Dark Pages** does not change the page images that Lectern sends to Claude or ChatGPT. Lectern keeps these settings
when you quit Lectern. You can also change them in Settings > Advanced > **Appearance**.

To change the text size of the messages, refer to [Use more than one conversation](#use-more-than-one-conversation).

### What Lectern keeps for each PDF

For each PDF, Lectern keeps these settings and uses them again when you open the PDF:

- the last page
- the zoom
- the page layout
- the sidebar: shown or not shown, and Thumbnails, Table of Contents or Highlights
- the chat pane: shown or not shown
- the conversations: their order, titles, colors and collapsed conversations
- the highlights and notes

Lectern keeps these settings in the Lectern folder (refer to [Privacy and usage](#privacy-and-usage)), never in the
PDF. Lectern uses the contents of the PDF, not the file name, to find these settings. Because of this, a copy of the
PDF with a different name or folder gets the same settings and conversations. Lectern does not keep search results.

## Use the chat pane

The chat pane can have 1 to 4 conversations about the PDF, in 1 or 2 columns. Refer to
[Use more than one conversation](#use-more-than-one-conversation). In each conversation, you can select a different
provider at any time. Lectern keeps the messages of both providers. When you open the PDF again, Lectern shows the
conversations again.

### Ask a question

1. Type your question in the message field at the bottom of the chat pane. The empty field shows "Ask about this
   document…".
2. Press Return to send the question. To start a new line in the question, press ⇧Return or ⌥Return.
3. To stop an answer, click the Stop button or press ⌘. (Command-period). ⌘. stops only the focused conversation.

The chat pane has these controls:

| Control | Location | Result |
| --- | --- | --- |
| Title bar | Top of each conversation | Shows the color dot, the title, the arrow that collapses the conversation, the **Show this conversation alone** button (⤢) and the **Conversation** menu (⋯ button). |
| **New Conversation** | Bottom of the chat pane | Adds a conversation after the others. |
| Provider picker (Claude or ChatGPT) | Chat header | Selects the provider. Each provider has a separate conversation about the PDF. |
| Model picker | Chat header | Selects the model. |
| Reasoning effort picker | Chat header | Selects the reasoning effort. |
| **Fast** (ChatGPT only) | Chat header | Uses the priority tier. Refer to [Fast](#fast). |
| **New chat** (pencil button) | Chat header | Starts a new conversation with the provider that you selected. The provider does not see the earlier messages. |
| Account | Chat header | Shows the sign-in status. Click it to open the Settings window. If Settings does not show the Accounts tab, click **Accounts**. |
| Usage | Chat header | Shows the usage windows (for example a 5-hour window and a 7-day window), if the provider reports them. |
| **Attach page image** (photo button) | Below the message field | Sends an image of the current page. Refer to [Context](#context). |
| **Whole document** (magnifier button) | Below the message field | Sends all pages, or the most applicable pages. Refer to [Context](#context). |
| Context text | Below the message field | Shows what Lectern sends with the question, for example "Context: around p. 12 · selection". |
| **+** button (narrow conversations) | Left of the message field | Has **Attach Page Image**, **Whole Document**, **Presets** and the context text. Refer to [Use more than one conversation](#use-more-than-one-conversation). |

For Claude, Lectern sends the model and the reasoning effort with a message only if they are not **Default**. With
**Default**, Claude Code uses the settings in its configuration. For ChatGPT, Lectern always sends the model, the
reasoning effort and the tier with each message. Because of this, ChatGPT messages from Lectern do not use these
settings in your Codex configuration (for example a priority tier).

Settings > Models sets the default values. A change in the chat header also becomes the new default value.

### Use more than one conversation

You can have up to 4 conversations about a PDF, for example one for each topic. Each conversation has a title bar, a
color, a provider, a model and messages. The providers do not see the messages of the other conversations.

The quantity of conversations sets their positions in the chat pane:

- 1 conversation fills the chat pane.
- 2 conversations are one above the other.
- With 3 conversations, the first 2 are side by side, above the third.
- 4 conversations are in 2 rows of 2.

The first conversation is at the top left. The others follow from left to right, then from top to bottom.

With 3 or 4 conversations, the chat pane becomes wider and the PDF becomes narrower. The window keeps its size. With 1
or 2 conversations again, the chat pane gets its earlier width back. If you changed the width of the chat pane, it
keeps your width.

To change the size of the conversations, drag the lines between them. When you open the PDF again, the conversations
have equal sizes.

**Add a conversation**

1. Click **New Conversation** at the bottom of the chat pane.
   - You can also select **File > New Conversation** (⌥⌘N).

Lectern adds the conversation after the others and puts the cursor in its message field. **New Conversation** is gray
when the PDF has 4 conversations.

**Colors**

Each conversation has a color: blue, green, orange or purple. The dot before the title, the line above the title bar
and the title bar have this color. A new conversation gets a color that the other conversations do not have. Lectern
keeps the color of each conversation.

**Focus a conversation**

**Ask Lectern**, ⌘. and **File > Close Conversation** use the focused conversation.

1. Click in the conversation.
   - You can also press ⌃⌘1, ⌃⌘2, ⌃⌘3 or ⌃⌘4 for conversation 1, 2, 3 or 4 (**File > Go to Conversation**).

⌃⌘1 to ⌃⌘4 also put the cursor in the message field of the conversation. When you type in a message field, that
conversation also becomes the focused conversation. If the chat pane shows 2 or more conversations, the focused
conversation has a line around it in its color. The titles of the other conversations are gray.

**Show one conversation alone**

1. In the title bar, click the **Show this conversation alone** button (⤢).

The conversation fills the chat pane and becomes the focused conversation. The other conversations do not change.

To show all conversations again, do one of these steps:

- Click the **Show all conversations** button (⤡) in the title bar.
- Press Esc in the message field. The message field must be empty.

Lectern also shows all conversations again when you add a conversation or go to a different conversation.

**Narrow conversations**

A conversation that is 420 points wide or less has fewer controls, for example in 2 rows of 2. Its text does not
become smaller.

- The chat header has one menu for the provider, the model and the reasoning effort, for example "Claude · Opus ·
  Medium".
- The account is a colored dot, with the usage in percent if the provider reports it. To see the account and the
  usage, put the pointer on the dot.
- The **+** button at the left of the message field has **Attach Page Image**, **Whole Document**, **Presets** and the
  context text.

**Change the text size of the messages**

1. Select **View > Chat Text Size**.
2. Select **Small**, **Medium**, **Large** or **Extra Large**.

Lectern uses this text size for the messages and the message fields in all windows. **Medium** is the usual size. You
can also change it in Settings > Advanced > **Appearance**.

**Change the font of the messages**

1. Select **View > Chat Font**.
2. Select **System**, **Serif** or **Rounded**.

Lectern uses this font for the messages and the message fields in all windows. **System** is the usual font. Code and
math keep a font with equal character widths. You can also change the font in Settings > Advanced > **Appearance**.

**Rename a conversation**

1. Double-click the title.
   - You can also click the **Conversation** menu (⋯ button) in the title bar, and then select **Rename…**.
2. Type the new title.
3. Press Return.

To cancel, press Esc. To use the automatic title again, delete all of the text. Then press Return.

**Collapse or expand a conversation**

You can collapse a conversation only if it is alone in its row, with other conversations in the chat pane. In 2 rows of
2, you cannot collapse a conversation.

1. Click the arrow at the left side of the title bar.

A collapsed conversation shows only its title bar and the name of its provider. Its messages do not change. If a
collapsed conversation moves next to a different conversation, Lectern expands it.

**Move a conversation**

1. Click the **Conversation** menu (⋯ button) in the title bar.
2. Select **Move Earlier** or **Move Later**.

The conversation moves one position in the order. Its color does not change.

**Close a conversation**

> [!CAUTION]
> Close a conversation only if you do not have to keep its messages. After you close it, you cannot get its messages
> again.

1. Click the **Conversation** menu (⋯ button) in the title bar.
   - You can also select **File > Close Conversation** (⌥⌘W). This command closes the focused conversation.
2. Select **Close Conversation**.
3. If the conversation has messages, click **Close Conversation** in the dialog.

You cannot close the last conversation. If an answer is in progress, Lectern stops it. **New Chat** in the
**Conversation** menu removes all messages of the conversation, but keeps the conversation and a title that you typed.

**Automatic titles**

After the first answer, Lectern gives the conversation a short title from the first question. Then Lectern asks the
provider for a title of 2 to 6 words, in the language of the question. For Claude, Lectern uses Haiku. For ChatGPT,
Lectern uses a small model from the model list of Codex, with low reasoning effort. If the provider sends no title in
20 seconds, Lectern keeps the title from the question. A title that you typed does not change.

Each title uses one small message from the included usage of your plan. A ChatGPT title never uses purchased credits.
If Lectern cannot read your ChatGPT usage, or you used all of it, Lectern keeps the title from the question. To use
only titles from the first question, set **AI conversation titles** to off (Settings > Advanced > Conversations).

**Which conversation gets the question**

- **Ask Lectern** sends the question to the focused conversation. If that conversation is collapsed, Lectern expands
  it. If a different conversation is alone in the chat pane, Lectern shows all conversations again.
- The **Presets** button of a conversation sends the preset to that conversation.
- The message field of a conversation sends the question to that conversation.

Lectern keeps the conversations, their order, their titles, their colors and the collapsed conversations for the PDF.

### Ask about a selection

You can send a prepared question about the text that you marked in the PDF.

1. Select the text in the PDF.
2. Hold the Control key and click the selected text.
3. Select **Ask Lectern**, and then select a command.
   - You can also select **Edit > Ask Lectern**.

| Command | Question that Lectern sends |
| --- | --- |
| **Explain** | Explain the text in plain language, in the context of the PDF. |
| **Summarize** | Give a summary of the text in 2 to 4 bullet points, with all numbers. |
| **Define Terms** | Define the technical terms, acronyms and metrics in the text. |
| **Translate to Chinese** | Translate the text into Simplified Chinese. |

Lectern shows the chat pane if it is hidden. The chat pane shows the command and the start of the text, for example
"Explain: “Gross margin for the quarter…”". Lectern sends the question to the focused conversation, with the provider
that you selected in it. If an answer is in progress, Lectern sends the question after that answer.

### Presets

Presets are prepared questions about the PDF. The **Presets** button (the star button) is below the message field.
Lectern sends the preset to the conversation of that button.

1. Click the **Presets** button.
2. Select a preset. Lectern sends its question.

| Group | Preset | Result | Pages |
| --- | --- | --- | --- |
| General | **Summarize This Page** | A summary of the current page in 3 to 6 bullet points | Current page |
| General | **Summarize the Document** | The purpose, the main points and the key numbers of the PDF | Whole document |
| General | **Key Takeaways** | The 5 most important points | Current page |
| General | **Weak Points in the Argument** | Claims without support, and gaps in the evidence | Current page |
| Finance | **KPI Table** | A table of the financial and operational metrics | Whole document |
| Finance | **Guidance vs. Prior Period** | A table that compares the guidance with the results of the prior period | Whole document |
| Finance | **Segment / Region Breakdown** | A table of revenue by segment and by region | Whole document |
| Finance | **Risks and Red Flags** | The risks, one-time items and red flags | Whole document |

"Current page" sends the current page and the pages near it. "Whole document" uses **Whole document** for this
question only. The **Whole document** button does not change. Refer to [Context](#context).

**Presets** is gray when an answer is in progress, or when you are not signed in. It is also gray when Lectern waits
for your decision about purchased credits.

### Fast

**Fast** uses the priority tier of ChatGPT. You get answers more quickly, but each message uses approximately 2.5 times
the usage of a normal message. **Fast** is off by default. Lectern shows **Fast** only if the selected model has a
priority tier.

### Protect purchased credits

**Protect purchased credits** (Settings > Models) is on by default. This setting is only for ChatGPT. If you used all of
your included ChatGPT usage, more messages use purchased credits. If this setting is on, Lectern keeps the question and
asks you first. Lectern also asks if it cannot read your usage. The banner shows **Send anyway** and **Cancel**.

> [!CAUTION]
> Keep **Protect purchased credits** on (Settings > Models). If this setting is off, Lectern does not ask you before a
> message uses purchased credits.

> [!CAUTION]
> If this question must not use purchased credits, do not click **Send anyway**.

- To send the question, click **Send anyway**.
- To keep the question and not send it, click **Cancel**. Lectern moves the question into the message field again.

### Citations

Links such as `[p. N]` in the answers go to that page. Lectern also shows the passage that supports the sentence in
orange for 2.5 seconds. To go to the location before the jump, select **Go > Back** (⌘[).

If the PDF does not have that page, Lectern stays on the same page. Lectern then shows the cause, for example "This
document has no page 400 (it has 340 pages)."

### Citation check badges

When an answer is complete, Lectern examines each citation. Lectern finds the numbers and the "quoted phrases" in the
sentence of the citation. Then Lectern looks for them in the text of the cited pages.

| Badge | Result |
| --- | --- |
| ✓ | Lectern found all numbers and quoted phrases of the sentence on the cited pages. |
| ⚠ | Lectern did not find one or more of them, or the PDF does not have the cited page. |
| No badge | The sentence has no numbers and no quoted phrases. |

To see the items that Lectern did not find, put the pointer on ⚠. Lectern shows them, for example "Not found on
p. 4: 412.9, 63%".

Notes:

- A ✓ does not show that the claim is correct. It shows only that the numbers and phrases are on the cited pages.
- Lectern compares numbers in different forms, for example "$1.2 billion" and "1,200" in a table in millions.
- If Lectern cannot match the badges to the citations, the answer has no badges.
- Lectern examines only new answers. Answers from an earlier version of Lectern have no badges.

### Save a table as CSV

You can copy a table from an answer, or keep it as a CSV file.

1. Put the pointer on the table in the answer. Lectern shows two buttons on the table.
2. Click **Copy CSV** or **Save CSV…**.
   - **Copy CSV** copies the table. Paste it in a spreadsheet.
   - **Save CSV…** opens the Save dialog. The file name is "PDF name - table.csv".
3. For **Save CSV…**, select a folder.
4. Click **Save**.

Lectern removes the text format (for example bold), but it keeps the numbers as the answer shows them. If a cell can
start a spreadsheet formula (for example "=SUM(A1:A3)"), Lectern adds an apostrophe (') before the cell text.

### Context

With each question, Lectern sends:

- the current page and the pages near it (Settings > Advanced > **Context** sets the quantity)
- the text that you marked in the PDF (the text selection), if you marked text
- the table of contents of the PDF, only with the first question of a conversation

Lectern sends each page only one time in each conversation.

**Attach page image** sends an image of the current page. Use it for charts, scans and tables. Lectern attaches the
image automatically if the current page has less than 400 characters of text. Lectern also attaches it for scanned
pages and table pages. Refer to [Scanned PDFs (OCR) and table pages](#scanned-pdfs-ocr-and-table-pages).

If the text of all pages is less than the token limit, **Whole document** sends all pages. The token limit is
approximately 300k tokens for Claude, 140k tokens for Claude Haiku and 150k tokens for ChatGPT. If the PDF is larger,
Lectern sends the pages that are most applicable to the question.

### Scanned PDFs (OCR) and table pages

A scanned page is an image, and it has no text. Lectern finds the text on a scanned page with optical character
recognition (OCR) on your Mac. Lectern uses OCR on a page if the page has almost no text.

- Lectern sends the OCR text with the question. Lectern tells the provider that the text comes from OCR.
- Lectern also sends the image of the current page, one time in each conversation.
- **Whole document** also uses the OCR text.
- Lectern keeps the OCR text in the `cache` folder. Lectern does OCR on each page only one time.

Notes:

- The search field (⌘F) does not find OCR text. You cannot select OCR text in the PDF.
- A citation to a scanned page goes to the page, but Lectern does not show the passage.
- For a large scanned PDF, the first question with **Whole document** can be slow. Lectern does OCR on all pages first.

The text of a PDF does not keep the columns of a table. If most of the current page is a table, Lectern sends an
image of the page with the text. The provider can then read the columns. Lectern sends the image one time in each
conversation.

## Keyboard shortcuts

| Menu or area | Command | Shortcut |
| --- | --- | --- |
| Lectern | Settings… | ⌘, |
| File | Open… | ⌘O |
| File | New Conversation | ⌥⌘N |
| File | Go to Conversation 1, 2, 3 or 4 (also puts the cursor in its message field) | ⌃⌘1, ⌃⌘2, ⌃⌘3 or ⌃⌘4 |
| File | Close | ⌘W |
| File | Close Conversation (the focused conversation) | ⌥⌘W |
| File | Export Highlights… | ⇧⌘E |
| File | Print… | ⌘P |
| Edit > Find | Find… (moves the cursor to the search field) | ⌘F |
| Edit > Find | Find Next | ⌘G (Return in the search field) |
| Edit > Find | Find Previous | ⇧⌘G (⇧Return in the search field) |
| Edit > Find | Use Selection for Find | ⌘E |
| Edit | Ask Lectern (Explain, Summarize, Define Terms, Translate to Chinese) | — |
| Edit | Highlight Selection | ⌃⌘H |
| Edit | Add Note to Selection… | — |
| View | Hide Sidebar / Show Sidebar | ⌥⌘1 |
| View | Thumbnails | ⌥⌘2 |
| View | Table of Contents | ⌥⌘3 |
| View | Highlights | ⌥⌘4 |
| View | Hide Chat / Show Chat | ⌃⌘C |
| View | Actual Size | ⌘0 |
| View | Zoom to Fit | ⌘9 |
| View | Zoom In | ⌘+ or ⌘= |
| View | Zoom Out | ⌘- |
| Go | Previous Page | ⌥⌘↑ |
| Go | Next Page | ⌥⌘↓ |
| Go | First Page | ⌥⌘Home |
| Go | Last Page | ⌥⌘End |
| Go | Back | ⌘[ |
| Go | Forward | ⌘] |
| Go | Go to Page… | ⌥⌘G |
| Search field or PDF | Stop the search | Esc |
| Chat pane | Send the question | Return |
| Chat pane | Start a new line in the question | ⇧Return or ⌥Return |
| Chat pane | Stop the answer (the focused conversation) | ⌘. |
| Chat pane | Show all conversations again (in the empty message field of a conversation that is alone) | Esc |

## Settings

| Tab | Setting | Result | Default |
| --- | --- | --- | --- |
| Accounts | **Status**, **Account**, **CLI** | Shows the sign-in status, the account and plan, and the path and version of the CLI. | — |
| Accounts | Usage rows | Shows how much of each usage window you used, and when the window starts again. | — |
| Accounts (Claude) | **Log in in Terminal** | Opens Terminal and runs `claude auth login --claudeai`. | — |
| Accounts (Claude) | **Verify connection** | Sends one small message with Haiku to test the sign-in. | — |
| Accounts (ChatGPT) | **Sign in with ChatGPT**, **Use a device code** | Starts the Codex sign-in in the browser, or with a device code. | — |
| Accounts (ChatGPT) | **Sign out** | Shows the dialog "Sign out of ChatGPT in Lectern?". **Sign Out** in the dialog removes only the Lectern sign-in. Lectern shows this button only in Isolated mode. | — |
| Models (Claude) | **Model** | Selects the model for your messages. | **Default (your Claude Code setting)** |
| Models (Claude) | **Reasoning effort** | Selects the reasoning effort. | **Default** |
| Models (ChatGPT) | **Model** | Selects the model for your messages. | The default model in the model list of Codex |
| Models (ChatGPT) | **Reasoning effort** | Selects the reasoning effort. | The default effort of that model |
| Models (ChatGPT) | **Fast tier (≈2.5× usage)** | Uses the priority tier. | Off |
| Models | **Protect purchased credits** | Asks you before a ChatGPT message can use purchased credits. | On |
| Advanced (Appearance) | **System**, **Light**, **Dark** | Selects the appearance of all Lectern windows. **System** uses the appearance of macOS. | System |
| Advanced (Appearance) | **Dark Pages** | Shows the pages with inverted colors. The PDF file does not change. | Off |
| Advanced (Appearance) | **Chat font** | Sets the font of the messages and the message fields: **System**, **Serif** or **Rounded**. **View > Chat Font** has the same items. | System |
| Advanced (Appearance) | **Chat text size** | Sets the text size of the messages and the message fields: **Small**, **Medium**, **Large** or **Extra Large**. **View > Chat Text Size** has the same items. | Medium |
| Advanced (Claude Code CLI, Codex) | **Path override** | Sets the path of the CLI. If it is empty, Lectern finds the CLI automatically (**Auto-detect**). | Empty |
| Advanced (Claude Code CLI, Codex) | **Detected** | Shows the CLI that Lectern found. **Reveal in Finder** shows it in Finder. | — |
| Advanced (Codex) | **Codex home** | Selects **Isolated** or **Shared**. Refer to [Select Isolated or Shared](#select-isolated-or-shared-chatgpt). | Isolated |
| Advanced (Context) | **Current page ± N pages** | Sets the quantity of pages on each side of the current page that Lectern sends (0 to 3). | ± 1 page |
| Advanced (Conversations) | **AI conversation titles** | After the first answer, the provider gives the conversation a title with a small model. If it is off, Lectern makes the title from the first question. | On |

## Privacy and usage

- Lectern itself has no cost. Each message uses the included usage of your plan. **Fast**, a high reasoning effort
  and **Whole document** with large PDFs use more of your plan.
- Lectern does not send the PDF file. It gets the text from the PDF on your Mac with PDFKit. It sends only the
  applicable pages to the provider that you selected. If a message has a page image, Lectern also sends that image.
- Lectern does OCR on your Mac with the Vision framework of macOS. It does not send scanned pages to an OCR service.
- Lectern runs Claude with `--safe-mode` and with no tools. Lectern runs Codex in a read-only sandbox. Lectern gives
  the answer "no" to all approval requests. Because of this, Codex cannot change files.
- Lectern keeps conversations in `~/Library/Application Support/Lectern/sessions`. Lectern makes the name of each file
  from a hash of the contents of the PDF. The same file also keeps the viewer settings of that PDF (last page, zoom,
  layout, sidebar and chat pane).
- The CLIs also keep a session history on your Mac, the same as when you use them in Terminal.
- If **AI conversation titles** is on, Lectern sends the first question and the start of the first answer again.
  This separate message asks the provider only for a title. The CLIs do not keep these title messages in their session history.
- In Isolated mode, Codex keeps the Lectern ChatGPT sign-in in `~/Library/Application Support/Lectern/codex-home`.
  Codex uses this folder as it uses `~/.codex` for your Codex CLI. Lectern does not read the sign-in file in this
  folder.
- Lectern keeps highlights and notes in `~/Library/Application Support/Lectern/highlights`, one file for each PDF.
- Lectern keeps page images, OCR text and other temporary files in `~/Library/Application Support/Lectern/cache`.
- Lectern never signs you out of Claude. A Claude sign-out also signs you out of Claude Code in Terminal.
- For ChatGPT, **Sign out** in Settings removes only the Lectern sign-in (Isolated mode). The ChatGPT app and the
  Codex CLI stay signed in.

### Remove all conversations

If Lectern is open, it can make the conversation files again. Because of this, quit Lectern before you remove the
folder.

> [!CAUTION]
> Remove the `sessions` folder only if you do not have to keep your conversations. After you remove it, you cannot get
> the conversations and viewer settings again.

1. Quit Lectern.
2. Remove the `sessions` folder (`~/Library/Application Support/Lectern/sessions`).

## Problems and remedies

### "Claude Code CLI not found" or "Codex not found"

**Cause:** An app that you open from Finder does not use the `PATH` of your shell. Because of this, Lectern does not
find a CLI that is in a different folder.

**Remedy:**

1. Run `which claude` (or `which codex`) in Terminal. Terminal shows the path of the CLI.
2. Copy the path.
3. Paste the path in Settings > Advanced > **Path override** (in the section **Claude Code CLI** or in the section
   **Codex**).
4. Make sure that the **Detected** row shows the path.

Lectern runs only native programs, not Node.js scripts. If Terminal shows a Node.js script, refer to the next two
problems.

### "The Claude Code CLI at … is a Node.js script (an older npm install), which Lectern can't run."

**Cause:** An older npm installation of Claude Code is a Node.js script.

**Remedy:**

1. Run `claude install`. This command installs the native build in `~/.local/bin`, where Lectern finds it.
2. Quit Lectern.
3. Open Lectern again.

### `which codex` shows a Node.js script (Codex from npm)

**Cause:** The `codex` command from npm is a Node.js script. The npm package also contains the native program. Lectern
finds the native program automatically if you installed Node.js with Homebrew, with nvm or with the installer from
nodejs.org. Lectern does not find it if you use fnm, volta or asdf.

**Remedy:**

1. Run this command. Terminal shows the path of the native program.

   ```sh
   find "$(npm root -g)/@openai/codex" -path '*vendor*' -type f -name codex
   ```

2. Copy the path.
3. Paste the path in Settings > Advanced > **Path override** (in the section **Codex**).

### "Your Claude login expired or was revoked. Log in again to continue."

**Cause:** Your Claude sign-in is not valid now. `claude auth status` can show "logged in" for a sign-in that is not
valid. Because of this, Lectern also uses the result of each request to Claude. After a request shows that the
sign-in is not valid, Lectern keeps this status. Lectern removes this status after you sign in again, or after
**Verify connection** shows that the sign-in is valid.

**Remedy:**

1. Click **Log in in Terminal**.
2. Do the sign-in steps in Terminal. Lectern sends your question again after you sign in.
3. To test the sign-in with a request to Claude, click **Verify connection** in Settings > Accounts. Lectern sends
   one small message with Haiku.

### "Your ChatGPT sign-in expired or was revoked. Sign in again to continue."

**Cause:** Your ChatGPT sign-in is not valid now.

**Remedy:**

1. Click **Sign in with ChatGPT**.
2. Do the sign-in steps in the browser. Lectern sends your question again after you sign in.

### ChatGPT does not let you use the model, or says that Codex is too old

**Cause:** The OpenAI servers do not let old Codex clients use the newest models.

**Remedy:** Use one of these methods:

- Install the newest version of the ChatGPT desktop app. The app installs a new Codex with it.
- Run `npm i -g @openai/codex@latest`.

Settings > Accounts shows the Codex version that Lectern uses (in the **CLI** row).

### "Lectern can't be opened" or "Apple could not verify…"

**Cause:** Lectern does not have Apple notarization.

**Remedy:** Do the procedure in [Let macOS open Lectern](#let-macos-open-lectern).

### "Lectern is damaged and can't be opened"

**Cause:** `Lectern.app` has the quarantine attribute from the download, and Lectern does not have Apple notarization.

**Remedy:**

> [!CAUTION]
> Use this command only on the `Lectern.app` from the Lectern Releases page. This command removes the quarantine
> attribute, a macOS safety check.

1. Run this command:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Lectern.app
   ```

2. Open Lectern.
3. If Lectern does not open after step 2, download Lectern again. You can also build it from source
   ([Option B](#option-b-build-from-source)).

### Lectern uses too much of your plan

**Cause:** Some settings use more of your plan: a high reasoning effort, **Fast**, a large context and
**Whole document** with large PDFs.

**Remedy:** Use one or more of these methods:

- Select a lower reasoning effort.
- Set **Fast** to off.
- Decrease the context in Settings > Advanced > **Context**.
- Do not use **Whole document** with large PDFs.

### You cannot select View > Table of Contents

**Cause:** The PDF does not have a table of contents. For this PDF, **Table of Contents** is gray in the View menu.
The sidebar does not show the Table of Contents button.

**Remedy:** Use **Thumbnails** or the search.

### You cannot select File > Print…

**Cause:** The PDF does not let you print it. For this PDF, **Print…** is gray in the File menu.

**Remedy:** Lectern cannot print this PDF.

### "This PDF is also open in another window. …"

**Cause:** Another window shows a PDF with the same contents, for example a second download of the same file.

**Remedy:** Close the second window. Use the first window. Questions in the second window start new conversations, and
Lectern does not keep the conversations of the second window.

### "This document has no page N (it has M pages)."

**Cause:** The answer gives a page number that the PDF does not have, for example a printed page number.

**Remedy:**

1. Type the number in the page box.
2. Press Return. If the PDF has a page label with that number, Lectern shows that page.

## Install a new version or remove Lectern

Lectern keeps your conversations and settings when you install a new version. This version keeps the conversations of
each PDF in a new file format. An older version of Lectern does not show these conversations. If you open the PDF in an
older version, it can remove them.

### Install a new version (Option A)

1. Quit Lectern.
2. Download the new zip file from the [Releases](https://github.com/yimeng-blake/lectern/releases) page.
3. Replace `Lectern.app` in the Applications folder with the new `Lectern.app`.
4. Do the procedure in [Let macOS open Lectern](#let-macos-open-lectern) again.

### Install a new version (Option B)

1. In the `lectern` folder, run `git pull`.
2. Run `bash scripts/build-app.sh --install`. If the Lectern in `~/Applications` is open, the script quits it before
   it replaces the app.

### Remove Lectern

1. Quit Lectern.
2. Move `Lectern.app` to the Trash.

Optional: to also remove the conversations, the settings and the separate ChatGPT sign-in, do step 3.

> [!CAUTION]
> If you must keep your Lectern conversations, settings or ChatGPT sign-in, do not run these commands. After you run
> these commands, you cannot get your conversations, settings or ChatGPT sign-in again.

3. Run these commands:

   ```sh
   rm -rf ~/Library/"Application Support"/Lectern
   defaults delete local.lectern.app
   ```

Claude Code and Codex are separate programs, with separate sign-ins and history. If you do not use one of these
programs, you can remove it. The setup guide of each program tells you how to remove it.

## For developers

```sh
swift build                          # debug build
swift run Lectern                    # run without bundling
bash scripts/build-app.sh            # release build → build/Lectern.app (ad-hoc signed)
bash scripts/build-app.sh --open paper.pdf
bash scripts/package-release.sh      # → dist/Lectern-<version>-arm64.zip + .sha256
swift run lectern-probe              # headless backend and context checks (lists commands)
# end to end, the way a document window asks (never starts a sign-in):
.build/debug/lectern-probe ask --provider claude --pdf doc.pdf --page 2 --model haiku --effort low "question"
.build/debug/lectern-probe ask --provider codex --home shared --pdf doc.pdf --page 2 --effort low "question"
# citation checks, passage search, OCR and table pages:
.build/debug/lectern-probe verify-citations --pdf doc.pdf --answer-file answer.md
.build/debug/lectern-probe locate --pdf doc.pdf --page 2 --claim "Gross margin was 61.3%"
.build/debug/lectern-probe pdf-info --pdf doc.pdf
```

- If `xcode-select` uses an older Xcode, put `DEVELOPER_DIR=/Library/Developer/CommandLineTools` before the `swift`
  commands. `build-app.sh` finds a correct toolchain automatically.
- Do not run single files with `swift file.swift`. The interpreter cannot load PDFKit.
- The `VERSION` file contains the version number.
- If `Sources/Lectern/Resources/AppIcon.icns` is in the project, the build uses it as the app icon.
- [DESIGN.md](../DESIGN.md) describes the architecture. It also describes the CLI protocols (Claude Code stream-json
  and Codex app-server), as the author tested them.
- Lectern uses the MIT license. Refer to [LICENSE](../LICENSE) and [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

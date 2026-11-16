# Set up Claude Code in VS Code on a Mac, from zero

*[Español](install-claude-code-mac.es.md)*

This guide is for someone who has never used a terminal. You will install Claude Code, use it inside
VS Code, and finish by installing CCNotify, which shows a popup when Claude finishes or needs you.

It takes about 30 minutes. Go in order. Each step ends with a line that says when you are done.

## 0. The Terminal in 30 seconds

The Terminal is a window where you type commands instead of clicking.

- **Open it:** press `⌘ Space`, type `Terminal`, press Enter.
- **Run a command:** copy it from this page, click in the Terminal window, paste with `⌘ V`, press Enter.
- **Passwords:** when the Terminal asks for your Mac password, nothing appears as you type. No dots,
  no letters. That is normal. Type it and press Enter.

## 1. A Claude account with a paid plan

Claude Code needs a **Pro or Max** plan. The free plan does not include it.

1. Go to [claude.ai](https://claude.ai) and create an account.
2. Subscribe to Pro or Max.

Tip: use **Sonnet** for daily work. **Opus** is stronger but uses your quota faster.

## 2. Apple Command Line Tools

These bring `python3` and `git`, which you need later.

```bash
xcode-select --install
```

A window opens. Click **Install** and wait. It can take several minutes. When it ends, check it:

```bash
python3 --version
```

**Done when** it prints a version such as `Python 3.9.6`.

## 3. VS Code

1. Download VS Code from [code.visualstudio.com](https://code.visualstudio.com).
2. Open the downloaded file and drag **Visual Studio Code** into the **Applications** folder.
3. Open it from Applications.

Optional: for a Spanish interface, press `⇧⌘X`, search for "Spanish Language Pack", click **Install**,
and restart VS Code when it asks.

**Done when** the menu **Terminal → New Terminal** opens a terminal at the bottom of the window.

## 4. Claude Code

In the Terminal (or the one inside VS Code), run:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Close the terminal and open a new one. Then run:

```bash
claude
```

A browser tab opens. Log in with your Claude account and approve the connection.

**Done when** this prints a version number:

```bash
claude --version
```

### If you see "command not found"

1. Quit Terminal and VS Code completely with `⌘ Q`, then open them again and retry.
2. If that does not work, run this:

   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
   ```

   If your prompt ends in `$` instead of `%`, you are using bash. Use `~/.bash_profile` instead of
   `~/.zshrc`.

## 5. Your first conversation in VS Code

1. In VS Code, choose **File → Open Folder** and pick a folder for your project (create an empty one
   if you like).
2. Choose **Terminal → New Terminal**.
3. Type `claude` and press Enter.
4. Talk to it in plain language, for example: "Create a simple web page with my name on it."

### Essentials

| You type or press | What it does |
|---|---|
| `/model` | Choose the model (Sonnet, Opus...). |
| `Esc` | Stop what Claude is doing. |
| `/clear` | Start a new conversation. |
| `/exit` | Leave Claude Code. |

### Permissions

Claude asks before it creates files or runs commands. Read what it wants to do. You can allow it once,
or allow it for the rest of the session.

### Voice

Type `/voice tap`. The first time, macOS asks for microphone access for VS Code: allow it. Then press
`Space` to talk and press it again to stop.

## 6. Git and GitHub (optional)

Git saves versions of your work. GitHub stores them online. You need both to install this kit from
its repository.

1. Create an account at [github.com](https://github.com).
2. Ask Claude:

   > Configure Git with my name and email, install GitHub's gh tool and help me sign in.

Keep personal data out of your repositories (passwords, keys, client data). Prefer **private**
repositories.

## 7. Install CCNotify (this kit)

In the VS Code terminal (not inside `claude`; type `/exit` first if you are in it):

```bash
git clone https://github.com/Migentetamoenjapon/claude-code-vscode-notifications.git && cd claude-code-vscode-notifications && ./install.sh
```


The installer builds the apps on your Mac, so it takes a minute. When it finishes, you get:

- **A popup** at the top-right when Claude finishes or needs you. It shows Claude's last message.
  Click it to jump to the right terminal in VS Code.
- **A menu bar item** that lists each Claude session and its state.
- **Sounds** that differ by type: done, permission, question, agent.

Start a conversation in `claude` and ask it for something small. When it finishes, the popup appears.

For options (sounds, quiet hours, popup size, the status line), see the [README](../README.md).

## What you don't need

- Python from python.org. The one from the Command Line Tools is enough.
- Node.js, for the current installer.
- An Anthropic API key. You log in with your Claude account.
- The Claude desktop app. It is a good option too; see [why some people prefer VS Code](../README.md#why-vs-code).

## If something fails

Copy the exact error message from the Terminal and paste it to Claude, in a conversation or in the
Claude panel. Say what you were doing when it happened. Claude can usually fix it.

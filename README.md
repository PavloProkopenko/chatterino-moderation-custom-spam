# Custom Spam plugin for Leafyrino

## What is chatterino-moderation-custom-spam?

A Lua plugin for [Leafyrino](https://github.com/leafyzito/leafyrino) (a Chatterino fork) for **channel moderators**. You save a trigger together with a message. Later, when you type the trigger with a number in chat (for example `!тг 10`), the plugin sends the saved message that many times.

- Works only for **you** (the logged-in account). Messages from other people, including other moderators, never start anything.
- Works only in Twitch channels where you are a **moderator or the broadcaster**. In every other channel all `/custom-spam` commands are refused. The rights are re-checked before every message, and a run stops by itself if you lose them.
- Triggers and messages are set with a command and **saved between app restarts** (`data/config.json` inside the plugin folder).
- Built-in safeguards: a limit on the number per run (default 50), a pause between messages (default 0.5 s, minimum 0.1 s), a cooldown per trigger (default 30 s, configurable per trigger), one run per channel at a time, and `/custom-spam stop` to cancel.

Chatterino plugins cannot add windows or settings pages, so everything is configured with the `/custom-spam` chat command. Run `/custom-spam help` for a short topic index, `/custom-spam help <topic>` (e.g. `add`, `set`) for one section, or `/custom-spam help all` for everything; explanations are in Russian.

## Use cases

- **Promote your Telegram.** Save the message once, then fire it with a number:
  ```
  /custom-spam add "!тг" "Подписывайтесь на наш Telegram: t.me/example"
  !тг 10
  ```
  The second line is typed as a normal chat message. Without a number the message is sent once.
- **A different cooldown for a loud trigger.**
  ```
  /custom-spam add "!rules" "Please read the chat rules: example.com/rules" --cooldown 120
  /custom-spam cooldown "!тг" 10
  ```
- **Stop a run that is going wrong.**
  ```
  /custom-spam stop
  ```
- **Tune the limits.**
  ```
  /custom-spam set max 20
  /custom-spam set gap 0.3
  ```
- **Review or clean up.**
  ```
  /custom-spam list
  /custom-spam remove "!тг"
  ```

Note: the trigger itself is a real chat message, so everyone in the channel sees it (and other bots may react to it).

## How to install (mac && windows)

1. **Get the plugin.** Download or clone this repository. The plugin is the `custom-spam` folder; it contains `info.json` and `init.lua`.
2. **Enable plugins in Leafyrino.** Open *Settings → Plugins* and tick **Enable plugins**.
3. **Open the Plugins folder.** Click the "Plugins directory" link on that settings page. If you prefer to find it yourself:
   - **macOS:** `~/Library/Application Support/<app folder>/Plugins` (for stock Chatterino the folder is `chatterino`; in Finder use *Go → Go to Folder…* and paste the path).
   - **Windows:** `%APPDATA%\<app folder>\Plugins` (press `Win + R`, paste the path, press Enter; for stock Chatterino the folder is `Chatterino`).

   The app folder name can differ between builds, so the link in Settings is the most reliable way.
4. **Copy the folder.** Put the whole `custom-spam` folder into `Plugins`. The result must be `Plugins/custom-spam/init.lua`, not a nested `custom-spam/custom-spam`.
5. **Enable and load it.** Back in *Settings → Plugins*, find **Custom Spam**, click **Enable** (or **Reload** if it was already there). Fix any error shown there before continuing.
6. **Set it up** in a channel where you are a moderator:
   ```
   /custom-spam add "!тг" "Your message here"
   /custom-spam list
   ```
   Then type `!тг 3` in chat to test it.

#!/usr/bin/env bash
# Cutover outcome notifier: posts $1 to the Zulip topic below via the pr-sync bot.
# Self-contained (notify-zulip.sh sources its own config) so it works after the
# launching session is gone.
exec bash "$HOME/.archon/.local/pr-sync/notify-zulip.sh" "$1" "Archon - self-upgrade"

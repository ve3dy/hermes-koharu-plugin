"""Hermes plugin for Koharu (manga translation) via a headless runner.

The plugin does not vendor Koharu. It runs ``koharu-batch``, a small CLI built
from Koharu's source (see runner/ and scripts/install.sh).
"""

from __future__ import annotations

from .settings import configure
from .tools import TOOLS

# Added to every new session's system prompt so the agent goes straight to the
# headless tool instead of trying to drive the Koharu desktop app's GUI.
PROMPT_SECTION = """\
## Manga translation (Koharu)
- Translate manga pages only with the `koharu_translate` tool. It runs Koharu headless: no window, no file dialogs, no clicks.
- Never open, click, or drive the Koharu desktop app (or its Import dialogs) to translate. That path doesn't work in the background.
- Pass `paths` (files or folders), plus `target_language` when the user names a language. Otherwise Koharu's configured default is used (`koharu_status` shows it).
- Long chapters return `done: false` with a `job`. Call `koharu_translate` again with that `job` until `done: true`.
- To send results on Telegram, copy the returned `MEDIA:` lines into your reply.
"""


def register(ctx) -> None:
    """Wire the host config reader, register the `koharu` tools and the prompt section."""
    configure(getattr(ctx, "get_config", None))
    for schema, handler, emoji in TOOLS:
        ctx.register_tool(
            name=schema["name"],
            toolset="koharu",
            schema=schema,
            handler=handler,
            description=schema["description"],
            emoji=emoji,
        )
    if hasattr(ctx, "register_system_prompt_section"):
        ctx.register_system_prompt_section("koharu", PROMPT_SECTION)

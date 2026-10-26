"""A taskwarrior-style command line for org-mode's agenda."""

__version__ = "0.5.1"


class OrgwarriorError(Exception):
    """Any orgwarrior failure; the message is fit to show the user as is."""

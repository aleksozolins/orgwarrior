"""orgwarrior(1), made from the help (help.py): the main page's examples,
then every topic, so the man page and `orgwarrior help` never disagree.
`orgwarrior help --man` prints it; docs/orgwarrior.1 is it, committed (a
test keeps the two the same)."""

import re

from orgwarrior import __version__, help as helpmod

URL = "https://github.com/aleksozolins/orgwarrior"


def esc(text: str) -> str:
    """TEXT as roff: backslashes and minus signs escaped (a - is a minus,
    so an option copied from the page works), a leading dot or quote kept
    from reading as a request, anything not ASCII as its \\[uXXXX] (the
    file plain ASCII, for any man)."""
    text = text.replace("\\", "\\e").replace("-", "\\-")
    text = "".join(c if ord(c) < 128 else f"\\[u{ord(c):04X}]" for c in text)
    return re.sub(r"^([.'])", r"\\&\1", text, flags=re.M)


def block(text: str) -> list[str]:
    """A topic's text as roff: prose lines a paragraph (man reflows it),
    indented lines (commands, examples, a table) as written."""
    out = []
    for para in text.split("\n\n"):
        lines = para.split("\n")
        i = 0
        while i < len(lines):
            indented = lines[i].startswith(" ")
            j = i
            while j < len(lines) and lines[j].startswith(" ") == indented:
                j += 1
            run = lines[i:j]
            if indented:
                out += [".RS 2", ".nf", *(esc(l[2:] if l.startswith("  ") else l.lstrip()) for l in run), ".fi", ".RE"]
            else:
                out += [".PP", esc(" ".join(l.strip() for l in run))]
            i = j
    return out


def synopsis_and_body(topic: str) -> tuple[list[str], str]:
    """A topic's command lines (its first paragraph) and the rest."""
    head, _, body = topic.partition("\n\n")
    return head.splitlines(), body


def main_sections() -> list[str]:
    """The main help's views, tasks and adding as tagged lists: each
    example, then what it does."""
    out, section = [], None
    for line in helpmod.MAIN.splitlines()[1:]:
        if not line.strip():
            continue
        if not line.startswith(" "):
            name = line.split(" (")[0].rstrip(":")
            if name in ("views", "tasks", "adding"):
                section = name
                out += [f".SS {name.capitalize()}"] + ([".PP", "c1 is the ID beside each task.", ".sp"] if name == "tasks" else [])
            else:
                section = None
            continue
        if section:
            command, _, what = line.strip().partition("   ")
            # Indented to the help's own column, so most descriptions sit beside their command.
            out += [".TP 32", f".B {esc(command.strip())}", esc(what.strip()) if what.strip() else ""]
    return [l for l in out if l != ""]


def render() -> str:
    topics = helpmod.MAIN.split("or --help after a command\n")[1].split("options:")[0].split()
    lines = [
        # No hyphens (org-warrior), ragged right: commands and names read whole.
        # groff's man macros reset .nh and .ad at each section, so their own
        # register and string, before .TH; other mans ignore them.
        ".nr HY 0", ".ds AD l",
        f'.TH ORGWARRIOR 1 "" "orgwarrior {__version__}" "User Commands"',
        ".SH NAME",
        "orgwarrior \\- the Org agenda from the command line, through your running Emacs",
        ".SH SYNOPSIS",
        ".B orgwarrior", "[\\fIVIEW\\fR]", ".br",
        ".B orgwarrior", "\\fIID\\fR... \\fIVERB\\fR [\\fIARGS\\fR]", ".br",
        ".B orgwarrior add", "[\\fIKEYWORD\\fR] \\fItitle\\fR [\\fI:tag:\\fR] [\\fIs:DATE\\fR] [\\fId:DATE\\fR]", ".br",
        ".B orgwarrior help", "[\\fITOPIC\\fR | \\fB\\-\\-man\\fR]",
        ".SH DESCRIPTION",
        ".PP",
        esc("A taskwarrior-style command line for Org mode's agenda. Every task gets a short "
            "ID, and orgwarrior ID VERB acts on it. orgwarrior never parses your files: it "
            "sends each command to your running Emacs daemon with emacsclient, where Org does "
            "the work (org-agenda, org-todo, org-schedule, org-read-date), so your agenda "
            "files, TODO keywords, custom agenda commands, logging and habits apply as in "
            "Emacs. It loads its own elisp into the daemon; nothing goes in your init file."),
        ".PP",
        esc("IDs are short hashes of a task's file and title: the same in every view and "
            "from one day to the next. Changing a keyword, tags or dates keeps the ID; "
            "renaming or refiling changes it, and the new one is printed."),
        ".SH EXAMPLES",
        ".PD 0",  # one example a line, as the help has them
        *main_sections(),
        ".PD",
        ".SH COMMANDS",
    ]
    for name in topics:
        synopsis, body = synopsis_and_body(helpmod.TOPICS[name])
        lines += [f".SS {name}", ".nf", *(f".B {esc(s)}" for s in synopsis), ".fi", *block(body)]
    lines += [
        ".SH OPTIONS",
        ".TP", ".BI \\-m \" NOTE\"", "The note, for done, wait and the other keywords (help notes).",
        ".TP", ".BI \\-s \" SOCKET\"", "The Emacs server socket's name, if not the default (also socket in the config, or ORGWARRIOR_SOCKET).",
        ".TP", ".B \\-\\-help", "This help, or after a command its own: orgwarrior add \\-\\-help.",
        ".TP", ".B \\-\\-version", "The version.",
        ".SH FILES",
        ".TP", ".I $XDG_CONFIG_HOME/orgwarrior/config.toml",
        "The config, all of it optional (default ~/.config/orgwarrior/config.toml); see the config topic above.",
        ".SH ENVIRONMENT",
        ".TP", ".B ORGWARRIOR_CONFIG", "The config file, instead of the default.",
        ".TP", ".B ORGWARRIOR_SOCKET", "The Emacs server socket's name.",
        ".TP", ".B NO_COLOR", "No color, as color = \"never\" does.",
        ".SH EXIT STATUS",
        "0 on success; 1 when Emacs or Org refuses (an unknown ID, a bad date), or no daemon answers; 2 for a command line orgwarrior can't read.",
        ".SH SEE ALSO",
        ".BR emacs (1),", ".BR emacsclient (1);",
        f"orgwarrior-web, the same agenda as a web page: {esc(URL)}\\-web",
        ".SH BUGS",
        f"Reported at {esc(URL)}/issues.",
    ]
    return "\n".join(lines) + "\n"

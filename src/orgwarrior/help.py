"""`orgwarrior help [TOPIC]`.  Every line fits an 80-column terminal (WIDTH)."""

import textwrap

from orgwarrior.config import ROLES

WIDTH = 78

MAIN = """\
orgwarrior: the org agenda from the command line, through your running Emacs

views
  orgwarrior                      the default view (today)
  orgwarrior week                 this week; week +1w, week 2026-11-02
  orgwarrior fri                  one day: +2d, 2026-10-15
  orgwarrior all                  every open TODO
  orgwarrior wait                 by TODO state; next +@phone with a tag
  orgwarrior +@phone              a tag search: +a-b, '+a|b'
  orgwarrior flu shot             a text search ('"fri"' for a date word)
  orgwarrior inbox                a [views] entry from your config
  orgwarrior projects.org         an agenda file's outline
  orgwarrior clocked week         the time clocked
  orgwarrior closed week          what was done, archived too
  orgwarrior --archive flu shot   a search or match of the archives too

tasks (c1: the ID beside each task)
  orgwarrior c1                   show it
  orgwarrior c1 done              any TODO keyword; nokeyword for none
  orgwarrior c1 sched fri         due DATE too; none removes it
  orgwarrior c1 when fri 14:00    an event's date
  orgwarrior c1 +@home -someday   tags
  orgwarrior c1 pri A             up, down, none
  orgwarrior c1 note TEXT         a note; done -m NOTE with a state
  orgwarrior c1 refile projects   under a heading; refile alone lists them
  orgwarrior c1 up | down         among its siblings; promote, demote
  orgwarrior c1 rename NEW TITLE
  orgwarrior c1 effort 0:30       prop NAME VALUE for any property
  orgwarrior c1 clock in          clock out; clock: what's running
  orgwarrior c1 clocks            its clocks; clocks add: time already spent
  orgwarrior c1 archive | kill
  orgwarrior c1 edit | open       in Emacs, in this terminal; its links
  orgwarrior c1 c2 done           several at once

adding
  orgwarrior add NEXT call mom :@phone: s:fri d:+2w
  orgwarrior add event Dentist @fri 14:00-15:00

more: orgwarrior help TOPIC, or --help after a command
  views show keywords dates tags priority rename refile up archive kill
  edit open clock clocked closed properties add notes config colors
options: -m NOTE, -s SOCKET (emacsclient's), --version; help --man: man page
help --skill: a SKILL.md teaching an AI agent (Claude Code) to use orgwarrior"""

TOPICS = {
    "views": """\
orgwarrior [VIEW]

  orgwarrior             the default view: default_view in config, else today
  orgwarrior today       today's agenda
  orgwarrior week        this week's agenda
  orgwarrior week DATE   the week of DATE: week +1w, week 2026-11-02
  orgwarrior all         every open TODO
  orgwarrior DATE        one day's agenda: fri, +2d, 2026-10-15 (help dates)
  orgwarrior +@phone     a tag/property search, in org's syntax:
  orgwarrior +a-b        a and not b
  orgwarrior '+a|b'      a or b (quote the |)
  orgwarrior KEYWORD...  tasks in those TODO states (wait; done; next active)
  orgwarrior next +@phone
                         a state and a tag search
  orgwarrior WORDS       anything else: a text search of headings and bodies,
                         any case, part of a word too (C-c a s)
  orgwarrior '"fri"'     quoted: always a text search, for words that are
                         dates
  orgwarrior todo -SCHEDULED={.+}-DEADLINE={.+}
                         TODOs with no date: properties match too
  orgwarrior NAME        a [views] entry, NAME = "KEY": that org-agenda custom
                         command
  orgwarrior projects.org
                         an agenda file's outline: its top-level headings,
                         done ones too, in file order (a file in a folder of
                         org-directory: work/notes.org, or notes.org if
                         it's the only one)

Each task shows a short ID on the left; tasks commands take it.  IDs stay the
same across views and over time; a renamed task gets a new one.

--archive takes in the archive files too, as org's agenda does with v A:
  orgwarrior --archive flu shot      a search of everything ever archived
  orgwarrior --archive '+@phone'     a match; clocked --archive week too
An archived task's ID shows it (orgwarrior ID); actions take only tasks in
the agenda files.

A habit (org-habit's STYLE: habit) has org's consistency graph on the line
under it: a day per cell, * when it was done, ! today, colored by its state
as your Emacs theme draws it (help colors).""",

    "show": """\
orgwarrior ID...

Show the task as org opens it: where it is (file › outline path), the
heading, the planning line, the body with each drawer (LOGBOOK, PROPERTIES)
folded to one line, then its notes, newest first (help notes), and its
child headings with their IDs, to show or act on in turn.  Links read as
Emacs shows them; orgwarrior ID open lists and opens them (help open).
Several IDs show one after another.

  orgwarrior ID --drawers   the drawers unfolded, notes and all, as in the
                            file""",

    "priority": """\
orgwarrior ID... pri A
orgwarrior ID... pri up
orgwarrior ID... pri none

Set the priority cookie ([#A]) with org-priority, so the range is yours:
org-priority-highest to org-priority-lowest, letters (A B C by default) or
numbers.  up and down step it as S-up and S-down do in org, which
removes it past either end.  none removes it.""",

    "keywords": """\
orgwarrior ID... KEYWORD [-m NOTE]

Set a TODO keyword, any of yours (the task's file's, if it has a #+TODO
line), in any case: orgwarrior c1 done, orgwarrior c1 7f next.  Any heading
takes one, a plain heading or an event too; nokeyword takes it off again
(C-c C-t SPC), leaving a plain heading.

Logging follows your Emacs settings; where org would ask for a note,
orgwarrior asks (orgwarrior help notes).  Repeating tasks repeat as in Emacs.""",

    "dates": """\
orgwarrior ID... sched DATE
orgwarrior ID... due DATE

DATE is anything org-read-date reads:
  fri, mon          the next such day
  +2d, +1w, +3m     from today
  today, tomorrow
  2026-10-15
  15                the next 15th
  fri 14:00         with a time
  fri 14:00-15:30   a range (or fri 14:00+1:30)
  none              remove it

After the date, a repeater and a warning period, as org writes them:
  fri .+1w          repeat (+1w, .+1w, ++1w)
  2026-11-01 -3d    warn 3 days before
Alone, +1w is a date (a week from today).  A new date keeps the repeater
already there, as in Emacs; a whole timestamp is taken as written, so sched
"<2026-10-16 14:00>" drops it.

orgwarrior ID... when DATE

An event's date: its plain timestamp, alone on the line under the heading
(after any planning line and drawers), where add event writes it.  Changed
there, or added there if it has none; none removes it.  A timestamp
further down is the text's, left alone.  The same DATE as sched, a repeater
too (a warning means nothing on a plain timestamp).

The same dates work for views (orgwarrior fri) and add (s:fri d:+2w).""",

    "tags": """\
orgwarrior ID... +TAG -TAG
orgwarrior ID... tag +TAG -TAG

Add and remove tags: orgwarrior c1 +@phone -someday.  A tag from a #+tags: { }
group replaces the others in it, as C-c C-q does: +@home drops @work.

After an ID, +/- change tags; first on the line, they search (orgwarrior
+@phone; help views). Tags from the file's #+filetags belong to the file:
refile the task to change them.""",

    "rename": """\
orgwarrior ID rename NEW TITLE

Change the title; the keyword, priority, tags and [1/3] cookies stay.
Everything after rename is the title, no quotes needed (but quote shell
characters).  The ID changes with the title, so the new one is printed:
  6a → 91  TODO call mom about the trip
A title can't start with a keyword or end in :tags: (org would read them as
such): use those verbs.""",

    "refile": """\
orgwarrior ID... refile [TARGET]

Move the tasks under a heading from your org-refile-targets, as C-c C-w does,
or to the top level of a file it names (TARGET projects.org: up to level 1).
TARGET is the heading's name, or any unique part of it or of its "file ›
path"; a heading wins over a file of the same name.  With no TARGET, the
targets are listed.

The ID changes with the file, so the new one is printed:
  6a → 91  TODO call mom  → tasks.org › Tasks
A task already there is left alone; the others move.  Set keywords, dates and
tags first, while the ID on screen still works.

  orgwarrior ID... refile --new TITLE [WHERE]
makes a plain heading TITLE first (a project, say), as the last child of
WHERE, and refiles into it.  WHERE is a file from your org-refile-targets
(the heading goes at its top level) or one of the targets; with none,
config's [refile] new_in, and without that the places are listed.
[refile] new_suffix goes after the title (" [/]": a count of its tasks).

A shell function makes a shortcut that keeps the IDs first:
  owr() { orgwarrior "$@" refile tasks; }""",

    "up": """\
orgwarrior ID up
orgwarrior ID down

Move the task one place up or down among its siblings (the headings at its
level under the same parent), with its subtree, as M-up and M-down do in
Emacs.  It stays under the same parent: to move it elsewhere, refile.

orgwarrior ID demote
orgwarrior ID promote

Demote puts the task, with its subtree, under the heading just above it
at its level, as its last child (M-S-right).  Promote takes it out of its
parent, to right after it.  Org's M-S-left promotes in place, so the
headings after it at its level would become its children; promote moves
it below them first, so only the task and its subtree move.""",

    "archive": """\
orgwarrior ID... archive
orgwarrior archive ID...

Archive the entries, each with its subtree, as C-c C-x C-s does: to
org-archive-location (or an ARCHIVE property), by default FILE.org_archive.
Archived tasks leave the agenda, so their IDs stop working; orgwarrior
--archive WORDS finds them again, and the ID it shows reads one (nothing
changes it).  To bring one back, open the archive file in Emacs.

A shortcut: alias owar='orgwarrior archive'""",

    "kill": """\
orgwarrior ID... kill [--yes]
orgwarrior kill ID... [--yes]

Delete the entries, each with its subtree, like C-k in the agenda.  There's no
undo, so it shows what goes and asks first; --yes skips the question, and is
needed when not at a terminal.

For "not doing this", use a done keyword (skip, if you have one): kill is for
junk.""",

    "edit": """\
orgwarrior ID edit
orgwarrior edit ID

Open the task in Emacs, in this terminal: a frame of the daemon
(emacsclient -t) narrowed to the task and its subtree.  Edit the body, tick
checkboxes (C-c C-c), anything.

  C-x C-s    save
  C-x C-c    close (asks to save first)

Changes you don't save are discarded.""",

    "add": """\
orgwarrior add [KEYWORD] title :tag: s:DATE d:DATE

  orgwarrior add call the dentist
  orgwarrior add NEXT call dentist :@phone: s:fri d:+2w

KEYWORD defaults to the target file's first open keyword (TODO, as org
comes).  :a:b: adds tags; s: and d: set SCHEDULED and
DEADLINE (orgwarrior help dates).  Lines after the first are the body:
orgwarrior add "$(printf 'pack :travel:\\n- [ ] socks\\n- [ ] charger')".
A heading there (* book flights) becomes a child, its levels kept.  A
time, range, repeater or warning right after one goes with it:
s:fri 14:00-15:00 +1w.  They may go anywhere.  Quote a
title with shell characters in it: orgwarrior add "why?"

Where it goes is [add] in config (orgwarrior help config); by default, the end
of org-default-notes-file.  --to PLACE puts it elsewhere: under a heading from
your refile targets, or at a file's top level, named as refile names them;
--under ID under any heading, by its ID:
  orgwarrior add buy paint --to reno
  orgwarrior add order tiles --under 4d

orgwarrior add event title @DATE [:tags:]

  orgwarrior add event Dentist @fri 14:00-15:00
  orgwarrior add event Mom's birthday @2026-11-03 +1y

An event: no keyword, the date as a plain timestamp.  @DATE takes what sched
does, ranges and repeaters too.  It goes to [add.event] in config, else where
tasks go.  orgwarrior ID when DATE changes it after (help dates).""",

    "open": """\
orgwarrior ID open [N]
orgwarrior open ID [N]

Open a link in the task (heading or body) in your browser: the only one at
once, else pick from the list, or give its number:
  [1] the order  https://shop.example/123
  [2] https://tracking.example/abc
Over SSH (or with no graphical session) the list is printed instead, nothing
opened: most terminals make the URLs clickable.  file: and other Emacs-only
links are listed; orgwarrior ID edit opens them in Emacs.  A shortcut:
alias owo='orgwarrior open'""",

    "clocked": """\
orgwarrior clocked [SPAN] [MATCH]

The time clocked in SPAN, as org's clocktable (C-c C-x C-r) counts it,
over the agenda files: each file, its headings by depth, the time each
holds, and the clocked time against an Effort where there is one.
  orgwarrior clocked                 today
  orgwarrior clocked week            this week; lastweek too
  orgwarrior clocked month           this month; lastmonth, year
  orgwarrior clocked 2026-10-20      a day; 2026-W43 a week, 2026-10 a month
  orgwarrior clocked 2026-10-01..2026-10-15
  orgwarrior clocked week +@phone    a tag match after the span

A [views] entry or a page's tab can be one: clocked week.  --archive counts
the archive files too.""",

    "closed": """\
orgwarrior closed [SPAN]

What was done in SPAN: each task closed with its time (its CLOSED stamp,
set by a done state), day by day, as org's agenda shows it in log mode
(C-u C-u l).  The archive files are always included: what's done is mostly
archived.  SPAN as clocked takes it:
  orgwarrior closed                  today
  orgwarrior closed week             this week; lastweek too
  orgwarrior closed month            this month; lastmonth, year
  orgwarrior closed 2026-10-20       a day; 2026-W43 a week, 2026-10 a month
  orgwarrior closed 2026-10-01..2026-10-15

A repeating task marked done gets no CLOSED stamp (org reschedules it), so
it isn't here.  A [views] entry or a page's tab can be one: closed week.""",

    "properties": """\
orgwarrior ID... prop NAME VALUE
orgwarrior ID... prop NAME none
orgwarrior ID... effort DURATION | none

Set a property in the task's drawer, as C-c C-x p does, or remove it
(none).  The value is everything after the name:
  orgwarrior k3 prop LOCATION the bank
  orgwarrior k3 prop STYLE habit
Org's own (TODO, SCHEDULED, TAGS...) have their verbs instead.

Effort is the estimate, as C-c C-x e sets it: a duration org reads (0:30,
1:15, 2h), one of Effort_ALL's where that's set.  Clocked time shows
against it.  orgwarrior ID shows the drawer.""",

    "clock": """\
orgwarrior ID clock in [TIME]
orgwarrior [ID] clock out [TIME]
orgwarrior clock [--short]

Clock in on a task, as I does in org's agenda: org writes the CLOCK line
(where org-clock-into-drawer says) and closes any clock running.  clock
shows what's running and since when; --short is one line for a status bar,
nothing when no clock runs (tmux: #(orgwarrior clock --short)).

TIME, when a start or stop was forgotten: a time of day, how long ago, or
a date and a time.  Without one, now.  A clock out may be later than now
(+10m), a clock in not: it would run before it began.
  orgwarrior k3 clock in 9:40          orgwarrior clock out 17:30
  orgwarrior k3 clock in -15m          orgwarrior clock out +10m
  orgwarrior clock out yesterday 5:30pm

What's running is the open CLOCK line in your files, not Emacs's memory: a
restart loses nothing, and a clock started on another machine shows once
your files sync.  One running past 4 hours is flagged "still on it?".  Two
running (two machines): clock lists both, ID clock out closes one.
orgwarrior [ID] clock cancel removes a clock started by mistake.

orgwarrior ID clocks
orgwarrior ID clocks N START-END | N START- | N -END | N rm
orgwarrior ID clocks add START-END | START DURATION

The task's clocks, newest first, numbered, then a change to one: its start,
its end or both, or rm.  A time of day is on that clock's own date, an end
before the start (overnight) the next day's; a date first goes with both.  Org
recomputes the => total, as after S-up on a CLOCK line in Emacs.  add logs
time already spent, a running clock left alone (clock in at a past time
would close it then).
  orgwarrior k3 clocks 2 9:30-12:20
  orgwarrior k3 clocks 1 -17:45
  orgwarrior k3 clocks 2 2026-10-19 9:30-12:20
  orgwarrior k3 clocks add yesterday 14:00-15:30
  orgwarrior k3 clocks add 9:00 1h30m""",

    "notes": """\
orgwarrior ID... note TEXT
orgwarrior ID... done [-m NOTE]

A note on its own, whenever: org's "Note taken on", where org-log-into-drawer
puts it.  Everything after note is the text, no quotes needed; with none, it
asks on the terminal.  Several IDs get the same note.

Where Emacs would ask for a note (@ in org-todo-keywords, org-log-done set to
note, a LOGGING property), orgwarrior asks on the terminal:

  Note (blank for none):

Blank logs just the timestamp, Ctrl-C cancels and changes nothing, and -m NOTE
answers up front.  Not at a terminal: no question, no note.  The note goes
through org, so org-after-note-stored-hook runs as in Emacs.""",

    "config": """\
$XDG_CONFIG_HOME/orgwarrior/config.toml (default ~/.config/orgwarrior/, or
ORGWARRIOR_CONFIG).  All optional:

  default_view = "today"   view for bare orgwarrior
  socket = "server"        emacsclient socket
  prefix_format = "..."    org-agenda-prefix-format for orgwarrior only
  tags = "inline"          or "right", as in Emacs
  time_grid = false        org's agenda time grid
  color = "auto"           or "always", "never"

  [views]                  name = "agenda key"
  dash = "d"

  [add]                    where orgwarrior add writes
  file = "~/org/inbox.org" default: org-default-notes-file
  heading = "Tasks"        file under it (default: top level)
  captured = true          add a :CAPTURED: time

  [add.event]              where add event writes: file, heading and captured
  file = "~/org/calendar.org"
  heading = "Events"       as for [add]; default: [add]'s file

  [refile]                 refile --new, and a front end's first choice
  new_in = "projects.org"  where refile --new makes its heading
  new_suffix = " [/]"      after its title
  usual = "tasks"          offered first, as refile matches it

  [colors]                 orgwarrior help colors

  [web]                    orgwarrior-web's (orgwarrior itself ignores it):
  name = "Sam"             whose list; [web.tabs] its tab row, label = query;
                           [web.calendar] its calendar feed""",

    "colors": """\
[colors] in config maps a role or TODO keyword to words from: bold dim italic
underline, black red green yellow blue magenta cyan white, bright-red and the
like, #rrggbb (24-bit), on-green or on-#rrggbb for a background, or "none".

  NEXT = "bold cyan"
  id = "blue"
  todo = "bold #ff8f88"

Plain colors follow your terminal's theme.  Color is off when piped, with
NO_COLOR set, or with color = "never".

Roles:
""" + textwrap.fill(" ".join(ROLES), WIDTH, initial_indent="  ", subsequent_indent="  ",
                 break_on_hyphens=False),
}

# Other words that find a topic: `orgwarrior help done`, `orgwarrior help sched`.
ALIASES = {"sched": "dates", "due": "dates", "when": "dates", "date": "dates", "tag": "tags", "event": "add",
           "view": "views", "note": "notes", "pri": "priority", "keyword": "keywords",
           "color": "colors", "search": "views", "down": "up", "promote": "up", "demote": "up",
           "clocks": "clock", "report": "clocked", "reports": "clocked", "prop": "properties", "effort": "properties", "property": "properties"}


def topic(name: str, keywords: list[str] = ()) -> str | None:
    name = name.lower()
    if name in keywords:
        name = "keywords"
    return TOPICS.get(ALIASES.get(name, name))


def paint_topic(text: str, painter) -> str:
    """The synopsis (the lines before the first blank one) as a header."""
    head, sep, body = text.partition("\n\n")
    return "\n".join(painter.wrap(l, "header") for l in head.splitlines()) + sep + body


def main(painter) -> str:
    """The main help, with section names as headers."""
    return "\n".join(l if l.startswith(" ") else painter.wrap(l, "header") for l in MAIN.splitlines())

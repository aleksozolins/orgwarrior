"""`orgwarrior help [TOPIC]`.  Every line fits an 80-column terminal (WIDTH)."""

import textwrap

from orgwarrior.config import ROLES

WIDTH = 78

MAIN = """\
orgwarrior: your org agenda from the command line, run by your Emacs daemon

views
  orgwarrior                      the default view (today)
  orgwarrior week                 this week; week +1w, week 2026-11-02
  orgwarrior fri                  one day; +2d, 2026-10-15
  orgwarrior all                  every open TODO
  orgwarrior wait                 tasks in a state; next +@phone with a tag
  orgwarrior +@phone              tasks with a tag; +a-b, '+a|b'
  orgwarrior flu shot             search the text ('"fri"' for a date word)
  orgwarrior inbox                a view from [views] in your config
  orgwarrior projects.org         a file's outline
  orgwarrior clocked week         time clocked
  orgwarrior closed week          what you finished, archived tasks included
  orgwarrior --archive flu shot   search the archives too

tasks (c1 is the ID shown beside each task)
  orgwarrior c1                   show the task
  orgwarrior c1 done              set any TODO keyword; nokeyword removes it
  orgwarrior c1 sched fri         schedule it; due DATE sets a deadline
  orgwarrior c1 when fri 14:00    move an event
  orgwarrior c1 +@home -someday   add and remove tags
  orgwarrior c1 pri A             set the priority; up, down, none
  orgwarrior c1 note TEXT         add a note; done -m NOTE with a state
  orgwarrior c1 refile projects   refile under a heading; alone, lists them
  orgwarrior c1 up | down         move among its siblings; promote, demote
  orgwarrior c1 rename NEW TITLE
  orgwarrior c1 effort 0:30       set the effort; prop NAME VALUE for others
  orgwarrior c1 clock in          start the clock; clock out stops it
  orgwarrior c1 clocks            list its clocks; clocks add logs past time
  orgwarrior c1 archive | kill
  orgwarrior c1 edit | open       open it in Emacs in this terminal, or a link
  orgwarrior c1 c2 done           act on several tasks at once

adding
  orgwarrior add NEXT call mom :@phone: s:fri d:+2w
  orgwarrior add event Dentist @fri 14:00-15:00

more: orgwarrior help TOPIC, or --help after a command
  views show keywords dates tags priority rename refile up archive kill
  edit open clock clocked closed properties add notes config colors
options: -m NOTE, -s SOCKET (emacsclient's), --version; help --man: man page
help --skill: a SKILL.md that teaches an AI agent (Claude Code) orgwarrior"""

TOPICS = {
    "views": """\
orgwarrior [VIEW]

  orgwarrior             the default view (default_view in config, or today)
  orgwarrior today       today's agenda
  orgwarrior week        this week's agenda
  orgwarrior week DATE   the week of DATE: week +1w, week 2026-11-02
  orgwarrior all         every open TODO
  orgwarrior DATE        one day's agenda: fri, +2d, 2026-10-15 (help dates)
  orgwarrior +@phone     a tag or property search, in org's syntax
  orgwarrior +a-b        tagged a and not b
  orgwarrior '+a|b'      tagged a or b (quote the |)
  orgwarrior KEYWORD...  tasks in those TODO states (wait; done; next active)
  orgwarrior next +@phone
                         a state and a tag together
  orgwarrior WORDS       anything else searches headings and text, ignoring
                         case and matching parts of words (org's C-c a s)
  orgwarrior '"fri"'     in quotes, always a search, for words that are
                         also dates
  orgwarrior todo -SCHEDULED={.+}-DEADLINE={.+}
                         TODOs with no date (properties match too)
  orgwarrior NAME        a view from [views] in your config (NAME = "KEY"
                         runs that org-agenda custom command)
  orgwarrior projects.org
                         a file's outline: its top-level headings in file
                         order, done ones included.  For a file in a folder
                         of org-directory, use work/notes.org, or just
                         notes.org if there's only one.

Each task has a short ID on the left, and task commands take it.  IDs stay
the same in every view and from day to day.  Renaming a task gives it a new
one.

--archive includes the archive files, like v A in org's agenda:
  orgwarrior --archive flu shot      search everything ever archived
  orgwarrior --archive '+@phone'     a tag match; clocked --archive week too
You can show an archived task by its ID, but you can't change it.

A habit (STYLE: habit, from org-habit) shows org's consistency graph on the
line below it.  Each cell is a day: * when it was done, ! for today, colored
the way your Emacs theme colors it (help colors).""",

    "show": """\
orgwarrior ID...

Shows the task the way org opens it.  First where it is (file › outline
path), then the heading, the planning line, and the text, with each drawer
(LOGBOOK, PROPERTIES) folded to one line.  Then its notes, newest first
(help notes), and its child headings with their IDs, so you can show or
change those next.  Links look the way Emacs shows them, and orgwarrior ID
open lists and opens them (help open).  Several IDs show one after another.

  orgwarrior ID --drawers   unfold the drawers and show everything as it is
                            in the file

A task in a file that isn't writable (chmod a-w) is read only, and its
location line says so.  This is meant for a calendar that a script exports
to org, where the next export would overwrite your changes anyway.  It's
shown everywhere, but every change is refused, and it's never offered as a
place to refile or add to.""",

    "priority": """\
orgwarrior ID... pri A
orgwarrior ID... pri up
orgwarrior ID... pri none

Sets the priority cookie ([#A]) with org-priority, so it uses your range,
from org-priority-highest to org-priority-lowest (A B C by default, or
numbers).  up and down step it like S-up and S-down in org, which removes
it past either end.  none removes it.""",

    "keywords": """\
orgwarrior ID... KEYWORD [-m NOTE]

Sets a TODO keyword, any of yours, in any case: orgwarrior c1 done,
orgwarrior c1 7f next.  If the task's file has its own #+TODO line, those
keywords apply.  Any heading can take one, including a plain heading or an
event.  nokeyword removes it (like C-c C-t SPC), leaving a plain heading.

Logging follows your Emacs settings.  Where org would ask for a note,
orgwarrior asks too (help notes).  Repeating tasks repeat as they do in
Emacs.""",

    "dates": """\
orgwarrior ID... sched DATE
orgwarrior ID... due DATE

DATE is anything org-read-date understands:
  fri, mon          the next Friday, Monday
  +2d, +1w, +3m     counted from today
  today, tomorrow
  2026-10-15
  15                the next 15th
  fri 14:00         with a time
  fri 14:00-15:30   a time range (or fri 14:00+1:30)
  none              remove the date

After the date, you can add a repeater and a warning period, as org writes
them:
  fri .+1w          repeat (+1w, .+1w, ++1w)
  2026-11-01 -3d    warn 3 days before
On its own, +1w is a date (a week from today).  A new date keeps the
repeater that's already there, as in Emacs.  A whole timestamp is used as
written, so sched "<2026-10-16 14:00>" drops the repeater.

orgwarrior ID... when DATE

Sets an event's date.  That's the plain timestamp on its own line under the
heading (after any planning line and drawers), which is where add event
puts it.  when changes it, or adds one if there isn't one, and none removes
it.  A timestamp further down belongs to the text and is left alone.  DATE
works the same as for sched, repeaters included.  A warning period does
nothing on a plain timestamp.

The same dates work for views (orgwarrior fri) and for add (s:fri d:+2w).""",

    "tags": """\
orgwarrior ID... +TAG -TAG
orgwarrior ID... tag +TAG -TAG

Adds and removes tags: orgwarrior c1 +@phone -someday.  Tags in a #+tags:
{ } group exclude each other, like with C-c C-q, so +@home removes @work.

After an ID, +/- change tags.  At the start of the line, they search
(orgwarrior +@phone, see help views).  Tags from the file's #+filetags
belong to the file, so refile the task to change those.""",

    "rename": """\
orgwarrior ID rename NEW TITLE

Changes the title.  The keyword, priority, tags and [1/3] cookies stay.
Everything after rename is the title, and you don't need quotes (except
around characters your shell treats specially).  The ID changes with the
title, so the new one is printed:
  6a → 91  TODO call mom about the trip
A title can't start with a keyword or end in :tags:, since org would read
them as a keyword and tags.  Use those commands instead.""",

    "refile": """\
orgwarrior ID... refile [TARGET]

Moves the tasks under a heading from your org-refile-targets, like C-c C-w,
or to the top level of a file (TARGET projects.org, for files with targets
up to level 1).  TARGET can be the heading's name, or any unique part of it
or of its "file › path".  A heading wins over a file with the same name.
With no TARGET, it lists the targets.

The ID changes with the file, so the new one is printed:
  6a → 91  TODO call mom  → tasks.org › Tasks
A task that's already there stays put, and the others move.  Set keywords,
dates and tags first, while the ID on your screen still works.

  orgwarrior ID... refile --new TITLE [WHERE]
first makes a plain heading called TITLE (a new project, say) as the last
child of WHERE, then refiles into it.  WHERE is a file from your
org-refile-targets (the heading goes at its top level) or one of the
targets.  Without WHERE, it uses [refile] new_in from the config, and
without that it lists the places.  [refile] new_suffix is added after the
title (" [/]" gives a count of its tasks).

A shell function makes a shortcut that keeps the IDs first:
  owr() { orgwarrior "$@" refile tasks; }""",

    "up": """\
orgwarrior ID up
orgwarrior ID down

Moves the task, with its subtree, one place up or down among its siblings
(the headings at its level under the same parent), like M-up and M-down in
Emacs.  It stays under the same parent.  To move it somewhere else, refile
it.

orgwarrior ID demote
orgwarrior ID promote

demote puts the task and its subtree under the heading just above it, as
that heading's last child (M-S-right).  promote takes it out of its parent
and puts it right after the parent.  Org's M-S-left promotes in place, which
would turn the headings after it into its children.  promote moves it below
them first, so only the task and its subtree move.""",

    "archive": """\
orgwarrior ID... archive
orgwarrior archive ID...

Archives the tasks, each with its subtree, like C-c C-x C-s.  They go to
org-archive-location (or an ARCHIVE property), FILE.org_archive by default.
Archived tasks leave the agenda, so their IDs stop working.  orgwarrior
--archive WORDS finds them again, and you can show one by the ID it prints,
but not change it.  To bring one back, open the archive file in Emacs.

A shortcut: alias owar='orgwarrior archive'""",

    "kill": """\
orgwarrior ID... kill [--yes]
orgwarrior kill ID... [--yes]

Deletes the tasks, each with its subtree, like C-k in the agenda.  There's
no undo, so it shows what will be deleted and asks first.  --yes skips the
question, and you need it when you're not at a terminal.

For tasks you're not going to do, use a done keyword (like SKIP, if you
have one) instead.  kill is for junk.""",

    "edit": """\
orgwarrior ID edit
orgwarrior edit ID

Opens the task in Emacs, in this terminal: a frame of the daemon
(emacsclient -t), narrowed to the task and its subtree.  Edit the text, tick
checkboxes (C-c C-c), anything you like.

  C-x C-s    save
  C-x C-c    close (asks to save first)

Changes you don't save are thrown away.""",

    "add": """\
orgwarrior add [KEYWORD] title :tag: s:DATE d:DATE

  orgwarrior add call the dentist
  orgwarrior add NEXT call dentist :@phone: s:fri d:+2w

KEYWORD defaults to the first open keyword of the file it's going to (TODO,
out of the box).  :a:b: adds tags, and s: and d: set SCHEDULED and DEADLINE
(help dates).  They can go anywhere on the line.  A time, range, repeater
or warning right after a date goes with it: s:fri 14:00-15:00 +1w.

Lines after the first become the text:
  orgwarrior add "$(printf 'pack :travel:\\n- [ ] socks\\n- [ ] charger')"
A heading in the text (* book flights) becomes a child heading, keeping its
level.  Put quotes around a title with shell characters in it:
orgwarrior add "why?"

Where it goes is set by [add] in the config (help config).  By default it's
the end of org-default-notes-file.  --to PLACE puts it somewhere else:
under a heading from your refile targets, or at a file's top level, named
the way refile names them.  --under ID puts it under any heading, by its ID:
  orgwarrior add buy paint --to reno
  orgwarrior add order tiles --under 4d

orgwarrior add event title @DATE [:tags:]

  orgwarrior add event Dentist @fri 14:00-15:00
  orgwarrior add event Mom's birthday @2026-11-03 +1y

An event has no keyword, and its date is a plain timestamp.  @DATE takes
anything sched does, including ranges and repeaters.  Events go where
[add.event] in the config says, or where tasks go.  orgwarrior ID when DATE
changes the date later (help dates).""",

    "open": """\
orgwarrior ID open [N]
orgwarrior open ID [N]

Opens a link from the task (its heading or text) in your browser.  With
only one link, it opens right away.  Otherwise pick from the list, or give
the link's number:
  [1] the order  https://shop.example/123
  [2] https://tracking.example/abc
Over SSH, or without a graphical session, it prints the list instead of
opening anything.  Most terminals make the URLs clickable.  file: links and
other links only Emacs can open are listed, and orgwarrior ID edit opens
them in Emacs.

A shortcut: alias owo='orgwarrior open'""",

    "clocked": """\
orgwarrior clocked [SPAN] [MATCH]

Shows the time clocked in SPAN across your agenda files, counted the way
org's clocktable (C-c C-x C-r) counts it.  It lists each file, its headings
by depth, and the time in each, against the Effort where there is one.
  orgwarrior clocked                 today
  orgwarrior clocked week            this week; lastweek too
  orgwarrior clocked month           this month; lastmonth, year
  orgwarrior clocked 2026-10-20      a day; 2026-W43 a week, 2026-10 a month
  orgwarrior clocked 2026-10-01..2026-10-15
  orgwarrior clocked week +@phone    only tasks matching a tag

A [views] entry or a tab on the web page can be a report: clocked week.
--archive counts the archive files too.""",

    "closed": """\
orgwarrior closed [SPAN]

Shows what you finished in SPAN: each task with the time it was closed (its
CLOSED stamp, set by a done state), day by day, the way org's agenda shows
it in log mode (C-u C-u l).  The archive files are always included, since
most finished tasks end up there.  SPAN works the same as for clocked:
  orgwarrior closed                  today
  orgwarrior closed week             this week; lastweek too
  orgwarrior closed month            this month; lastmonth, year
  orgwarrior closed 2026-10-20       a day; 2026-W43 a week, 2026-10 a month
  orgwarrior closed 2026-10-01..2026-10-15

A repeating task marked done doesn't get a CLOSED stamp (org reschedules
it instead), so it won't show up here.  A [views] entry or a tab on the web
page can be one: closed week.""",

    "properties": """\
orgwarrior ID... prop NAME VALUE
orgwarrior ID... prop NAME none
orgwarrior ID... effort DURATION | none

Sets a property in the task's drawer, like C-c C-x p, or removes it with
none.  The value is everything after the name:
  orgwarrior k3 prop LOCATION the bank
  orgwarrior k3 prop STYLE habit
Org's own properties (TODO, SCHEDULED, TAGS...) have their own commands.

Effort is your time estimate, like C-c C-x e sets it.  It takes a duration
org can read (0:30, 1:15, 2h), and one of the Effort_ALL values where those
are set.  Clocked time is shown against it.  orgwarrior ID shows the
drawer.""",

    "clock": """\
orgwarrior ID clock in [TIME]
orgwarrior [ID] clock out [TIME]
orgwarrior clock [--short]

clock in starts the clock on a task, like I in org's agenda.  Org writes the
CLOCK line (where org-clock-into-drawer says) and stops any clock that's
running.  clock on its own shows what's running and since when.  --short
prints one line for a status bar, and nothing when no clock is running
(in tmux: #(orgwarrior clock --short)).

TIME is for when you forgot to start or stop the clock.  It can be a time
of day, how long ago, or a date and a time.  Without it, the time is now.
You can clock out later than now (+10m), but not clock in, since the clock
would be running before it started.
  orgwarrior k3 clock in 9:40          orgwarrior clock out 17:30
  orgwarrior k3 clock in -15m          orgwarrior clock out +10m
  orgwarrior clock out yesterday 5:30pm

The running clock is the open CLOCK line in your files, not something
Emacs keeps in memory.  Restarting Emacs loses nothing, and a clock started
on another machine shows up once your files sync.  A clock running longer
than 4 hours is flagged "still on it?".  If two are running (from two
machines), clock lists both, and ID clock out stops one.
orgwarrior [ID] clock cancel removes a clock you started by mistake.

orgwarrior ID clocks
orgwarrior ID clocks N START-END | N START- | N -END | N rm
orgwarrior ID clocks add START-END | START DURATION

clocks lists the task's clocks, newest first and numbered.  With a number,
it changes that clock's start, end or both, or rm deletes it.  A time of
day is on that clock's own date, and an end before the start (overnight)
is on the next day.  A date given first applies to both.  Org recalculates
the => total, as after S-up on a CLOCK line in Emacs.

clocks add logs time you already spent, without touching a running clock.
(clock in at a past time would stop the running clock at that time.)
  orgwarrior k3 clocks 2 9:30-12:20
  orgwarrior k3 clocks 1 -17:45
  orgwarrior k3 clocks 2 2026-10-19 9:30-12:20
  orgwarrior k3 clocks add yesterday 14:00-15:30
  orgwarrior k3 clocks add 9:00 1h30m""",

    "notes": """\
orgwarrior ID... note TEXT
orgwarrior ID... done [-m NOTE]

note adds a note any time, like org's "Note taken on", wherever
org-log-into-drawer puts it.  Everything after note is the text, and you
don't need quotes.  Without text, it asks for it in the terminal.  Several
IDs all get the same note.

Where Emacs would ask for a note (@ in org-todo-keywords, org-log-done set
to note, or a LOGGING property), orgwarrior asks in the terminal:

  Note (blank for none):

Leave it blank to log just the time.  Ctrl-C cancels and changes nothing.
-m NOTE gives the note up front.  When it's not running in a terminal, it
doesn't ask and adds no note.  The note goes through org, so
org-after-note-stored-hook runs as it does in Emacs.""",

    "config": """\
$XDG_CONFIG_HOME/orgwarrior/config.toml (usually ~/.config/orgwarrior/, or
wherever ORGWARRIOR_CONFIG points).  Everything is optional:

  default_view = "today"   the view plain orgwarrior shows
  socket = "server"        the emacsclient socket
  prefix_format = "..."    an org-agenda-prefix-format just for orgwarrior
  tags = "inline"          or "right", as in Emacs
  time_grid = false        show org's agenda time grid
  color = "auto"           or "always", "never"

  [views]                  name = "agenda key"
  dash = "d"

  [add]                    where orgwarrior add writes
  file = "~/org/inbox.org" (default: org-default-notes-file)
  heading = "Tasks"        file under this heading (default: top level)
  captured = true          stamp a :CAPTURED: time

  [add.event]              where add event writes, with the same keys
  file = "~/org/calendar.org"
  heading = "Events"       (default: [add]'s file)

  [refile]                 for refile --new, and a front end's first choice
  new_in = "projects.org"  where refile --new makes its heading
  new_suffix = " [/]"      added after its title
  usual = "tasks"          the target offered first

  [colors]                 see orgwarrior help colors

  [web]                    for orgwarrior-web (orgwarrior ignores it)
  name = "Sam"             whose list it is; [web.tabs] sets the tabs
                           (label = query), [web.calendar] the calendar
                           feed""",

    "colors": """\
[colors] in the config maps a role or a TODO keyword to any of: bold, dim,
italic, underline; black, red, green, yellow, blue, magenta, cyan, white;
bright-red and the like; #rrggbb (24-bit); on-green or on-#rrggbb for a
background; or "none".

  NEXT = "bold cyan"
  id = "blue"
  todo = "bold #ff8f88"

Plain colors follow your terminal's theme.  Color is off when the output
is piped, when NO_COLOR is set, or with color = "never".

Roles:
""" + textwrap.fill(" ".join(ROLES), WIDTH, initial_indent="  ", subsequent_indent="  ",
                 break_on_hyphens=False),
}

# Other words that find a topic: `orgwarrior help done`, `orgwarrior help sched`.
ALIASES = {"sched": "dates", "due": "dates", "when": "dates", "date": "dates", "tag": "tags", "event": "add",
           "view": "views", "note": "notes", "pri": "priority", "keyword": "keywords",
           "color": "colors", "search": "views", "down": "up", "promote": "up", "demote": "up",
           "clocks": "clock", "report": "clocked", "reports": "clocked", "prop": "properties", "effort": "properties", "property": "properties",
           "read-only": "show", "readonly": "show"}


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

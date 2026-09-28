# CVI Readiness Analyzer

Checks whether an ECC customer and vendor landscape is ready for the Customer/Vendor
Integration phase of an S/4HANA conversion, and returns a report you can act on directly
instead of a list of things to go and look at.

Today that phase is done by hand: SAP Notes read one at a time, account groups compared in
Excel, address data spot-checked on a sample. This tool reads the client's configuration and
master data, checks it with rule-based logic plus a judgment layer, and writes a one-click
worklist for every finding.

## Running it

No runtime to install — it is Windows PowerShell 5.1 and .NET only.

```powershell
.\Run-Cvi.ps1                     # analyse, then open the report at http://localhost:8787/
.\Run-Cvi.ps1 -Console            # print the report to the terminal and exit
.\Run-Cvi.ps1 -Console -Export    # also write every worklist and the task list into .\out
.\Run-Cvi.ps1 -Port 9000          # serve on another port
.\Run-Cvi.ps1 -LocalJudge         # skip the Claude call even if a key is present
```

In the web report each finding expands to show why it matters, what to do, the IMG path,
and the affected objects. **Generate fix pack** writes that finding's worklist to `.\out`;
**Generate all fix packs** writes every worklist plus a task list and the full JSON report.

## The master data workbook

**Export master data to Excel** writes `out\CVI_MASTER_DATA.xlsx` — one sheet per extracted
table (`KNA1`, `LFA1`, `ADRC`, `KNVK`, `BUT000`) with the original columns untouched, and four
added at the end: `CHECKS`, `SEVERITY`, `FINDING` and `CHANGE_TO`. A record that failed a check
carries its findings on its own row and is shaded, so the person correcting the data reads the
problem next to the field rather than joining two lists by hand. A record that failed several
checks carries all of them, and `SEVERITY` shows the worst so a sort brings the blockers up.
The `Summary` sheet carries the system, the releases, the score and the gate, how many records
each sheet holds and how many of them are flagged, and the status of every check — including
anything recorded as done rather than verified.

The workbook is written directly as an OOXML package with `System.IO.Compression`, so the export
needs no Excel, no module and no add-in: it works on a machine where Excel was never installed.
Every cell is written as an inline string rather than a number, because SAP keys are zero-padded
and a numeric cell would turn `0000100004` into `100004` — a key that matches nothing.

## Deciding, and recording that you have

Every affected object carries a **Change to** cell — what that object should become. Where the
extract holds the set of valid values the cell is a dropdown built from it, so it can only offer
something the target system would accept: BP groupings come from `TB001`, forms of address from
`TSAD3`, and a one-time account group is offered only groupings flagged one-time. Where the
question is a decision rather than a value — a customer and a vendor that collide on a number,
a record that is probably a duplicate — the dropdown carries the decisions instead. Where there
is no table of valid values at all (a region, a postal code, a tax number) the cell takes a typed
value, because offering a made-up list would be worse than asking. Choices are stored in
`data\config\CVI_DECISIONS.csv`, re-applied on every run, and written into the worklist as a
`CHANGE_TO` column so whoever does the correction works from the decision, not just the problem.

**Generate fix pack** also records that somebody has taken the check on. The card moves to
**on record**, and the check reads `DONE` — which is deliberately not `PASS`:

| | means |
|---|---|
| `PASS` | the extract itself is clean |
| `DONE` | a person said they would handle it; the extract still fails |

A recorded check earns its weight in the score and stops blocking the gate, so the report has to
say how much of the number rests on somebody's word: a banner at the top of the page gives the
count, the gate reads `READY WITH ACTIONS (ON RECORD)`, the card is drawn in its own colour that
is never the green of a passed check, and the console report lists every recorded check with who
recorded it and when. **Reopen check** drops the record and the check goes straight back to
failing. Nothing here reaches an SAP system, and because the record is only an overlay, a fresh
extract that is still wrong fails the check again — a recorded decision can never hide a
regression. **Generate all fix packs** deliberately records nothing: marking twenty checks done
on one click is not something anybody means to do.

The **Number ranges** page (`http://localhost:8787/numbers`) is the second half: every ECC
interval checked against the numbers the master data actually occupies, the BP intervals as
they stand, and a proposed target design with one row per interval to create, edit or move.
**Export proposal** writes it to `.\out` as a CSV to work from and a page to hand over.

## The assistant

Both pages carry a chat panel (**Ask about this report**, bottom right). It answers from the
report that is loaded — findings, affected records, and the number range proposal — and links
its answers back to the findings it used, so a check ID in a reply opens that card.

With `ANTHROPIC_API_KEY` set it is Claude (`claude-opus-5`), given a digest of the report and
told to answer only from it. Without a key a local answerer takes over: it matches the
question against the report and reads real findings back — check IDs (`explain CFG-06`),
record keys (`what is wrong with 0000100004`), topics (`number ranges`, `duplicates`,
`SAP notes`), priority (`what should I fix first`), and the score. It is a lookup, not a
language model, and it says so when it cannot match a question. The panel header always shows
which one answered.

Neither can see or change an SAP system, and neither will tell you what an SAP Note says —
the catalog is an unverified seed and the assistant is instructed to say so.

## The number range proposal

Under a same-number strategy the legacy key becomes the BP key, so a BP interval has to
cover the number band of every account group routed into its grouping. The proposal is built
from the client's **own source intervals** rather than a box drawn round the numbers that
happen to exist today — inheriting DEBITOR/KREDITOR intervals keeps the design inside
something the business already agreed, and leaves the arithmetic checkable by hand.

**Every proposed interval is editable.** Change the range key, the interval or the external
flag on the page and press Save: the edit is stored in `data\config\CVI_BP_RANGE_OVERRIDES.csv`,
re-applied on every run, and then re-checked exactly like a proposed one — an interval that no
longer covers its records is flagged rather than trusted, and the export carries the edit, the
validation result and the value the tool had proposed. **Reset to proposed** clears the edits.

## Sending confirmed intervals to the system

Each interval has a **Confirm** tick. **Build package** takes only the confirmed ones, checks
them, and writes `out\send\`:

| File | Applied with |
|---|---|
| `BU_PARTNER_INTERVALS.csv` | `SNRO`, object `BU_PARTNER` |
| `TB001_GROUPINGS.csv` | `SM30` view `V_TB001` / SPRO groupings |
| `CVI_ACCOUNT_GROUP_MAPPING.csv` | SPRO, number assignment customer/vendor to BP |
| `payload.json` | the same content for an interface |
| `APPLY_RUNBOOK.md` | the order to apply them in, and what to watch for |

The package is only built for a confirmed set that passes its checks: nothing confirmed, a
confirmed interval that no longer covers its records, a range key still left as `(new)`, or two
confirmed intervals that overlap are all blockers and are listed on the page. Number collisions
and unconfirmed changes come back as warnings — they are recorded in the runbook rather than
blocking, because an interval cannot fix them.

**Pushing directly** is off unless `data\config\CVI_TARGET_SYSTEM.csv` names a `BASE_URL` and is
marked `ENABLED`, and `CVI_SAP_USER` / `CVI_SAP_PASSWORD` are set in the environment —
credentials are never written to the config. With a target configured, a **Push to system**
button appears for a ready set and asks for confirmation before posting. Without one the tool
says so plainly: the package is applied by hand from the runbook.

Intervals that touch or overlap are merged. Where a grouping is fed by account groups from
separate bands it gets **one row per band**, because one interval genuinely cannot cover it —
and the page says so, along with the alternative: re-route those account groups to a grouping
of their own. The page also calls out the two things an interval cannot fix on its own:
numbers claimed by both a customer and a vendor, and two groupings whose proposed intervals
would accept the same number.

## The two layers

**Rule layer** (`src/Cvi.Rules.ps1`) — 25 deterministic checks. Configuration: account group
to BP grouping coverage, groupings that do not exist, synchronisation direction, BP number
collisions between customers and vendors, legacy numbers falling outside the external BP
interval, one-time account handling, internal-vs-external numbering, address usage, tax number
mapping, duplicate check, post-processing office. Master data: dangling address references,
country, region where the country demands one, postal-code and tax-number format per country,
name, search term, form of address, language, contact persons, and drift between records that
an earlier trial run already linked to a BP. Plus the SAP Note catalog, filtered to the notes
whose trigger condition is actually true in this system.

**Judgment layer** (`src/Cvi.AiJudge.ps1`) — the questions rules cannot answer. Candidates are
proposed deterministically (shared tax numbers, shared addresses, name similarity, declared
person records, mapping semantics), then each candidate is judged:

- a customer and a vendor that are one legal entity and should become one BP with two roles
- duplicate records inside one object that will otherwise become duplicate BPs
- records the source system treats as natural persons but that are routed to an organisation grouping
- account group to grouping assignments that are complete but do not mean the same thing

If `ANTHROPIC_API_KEY` is set, judging runs through the Claude Messages API
(`claude-opus-5`). Otherwise a bundled local judge produces the same verdict shape, so the
report is never blocked on connectivity. The report header always says which one ran.

## Scoring

The score is the share of the weighted checks that passed — blocker 14, high 7, medium 3,
low 1 — so two systems with different amounts of breakage do not both land on zero. The gate
is separate and blunt: any blocker at all means **NOT READY**.

## Pointing it at a real system

Replace the extracts under `data\` with downloads from the source client — same file names,
same column headers. The tool reads them and nothing else; it never connects to SAP.

| File | Table |
|---|---|
| `data\config\T077D.csv`, `T077K.csv` | customer and vendor account groups |
| `data\config\TB001.csv` | BP groupings |
| `data\config\CVI_CUST_TO_BP1.csv`, `CVI_VEND_TO_BP1.csv` | account group to grouping assignment |
| `data\config\CVI_CUST_LINK.csv`, `CVI_VEND_LINK.csv` | links written by an earlier run |
| `data\config\NRIV.csv` | number ranges for DEBITOR, KREDITOR, BU_PARTNER |
| `data\config\T005.csv`, `TSAD3.csv` | country rules and BP titles |
| `data\config\CVI_SETTINGS.csv` | CVI switches and the project's number strategy |
| `data\config\CVI_NOTE_STATUS.csv` | note confirmations ticked in the report (not an extract) |
| `data\config\CVI_DECISIONS.csv` | per-object choices made in the report (not an extract) |
| `data\config\CVI_CHECK_STATUS.csv` | checks recorded as done in the report (not an extract) |
| `data\master\KNA1.csv`, `LFA1.csv`, `ADRC.csv`, `KNVK.csv`, `BUT000.csv` | master data |
| `data\notes\sap_notes.csv` | the note catalog |

`T005.csv` carries the postal-code and tax-number patterns per country, so tightening a
country rule is a data change rather than a code change. The regexes avoid `{m,n}` quantifiers
because the comma would break the CSV.

## About the SAP Note catalog

`data\notes\sap_notes.csv` ships as a **seed** and every row is marked `VERIFIED=N`. The tool
tells you which notes are relevant to the situation it found — it does not confirm what a note
says. Check each one in SAP ONE Support for the target release before acting on it, and set
`VERIFIED=Y` once the row has been confirmed against the Launchpad.

Each listed note carries a **Mark implemented** tick. It records the confirmation in
`data\config\CVI_NOTE_STATUS.csv` — note number, who confirmed it, when — and the note drops off
the check on the spot. It **does not implement the note**: that happens in `SNOTE`, and the tool
never reaches an SAP system. The catalog under `data\notes` is left as extracted, so a
confirmation someone made here can always be told apart from a status that came with the seed,
and **Reset confirmations** on the same card puts them all back on the list.

A note is listed when its `APPLIES_WHEN` trigger is true in this system **and** the target
release falls inside its `RELEASE_FROM`/`RELEASE_TO` window. Both are S/4HANA release numbers
(`1511`, `1709`, `2023`, `2025`) and either may be left empty for an open end; the feature pack
level in `TARGET_RELEASE` is ignored, because the catalog works at release granularity. Notes
excluded by the window are named in the check so they are visibly filtered rather than silently
dropped. The windows are seed values like the rest of the row — widen one if the Launchpad says
the note still applies to your target release. If no release can be read from `TARGET_RELEASE`
the window is not applied at all and every matching note is listed, so a malformed setting can
never hide a note.

## Layout

```
Run-Cvi.ps1            entry point - console mode and server mode
src\Cvi.Data.ps1       loads the extracts into one normalised dataset
src\Cvi.Rules.ps1      deterministic checks and the score
src\Cvi.AiJudge.ps1    candidate generation, Claude judge, local judge
src\Cvi.Decisions.ps1  the choices offered per object, and the record that a check was taken on
src\Cvi.Analyze.ps1    runs both layers, assembles the report
src\Cvi.Numbers.ps1    number range analysis and the target proposal
src\Cvi.Actions.ps1    worklists, task list, JSON export
src\Cvi.Excel.ps1      the xlsx writer and the master data workbook
src\Cvi.Chat.ps1       the assistant - Claude answerer and local answerer
src\Cvi.Server.ps1     loopback HTTP server (TcpListener - no URL ACL, no admin shell)
web\                   the report UI
data\                  the extracts
out\                   generated worklists and task lists
```

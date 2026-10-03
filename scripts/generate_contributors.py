#!/usr/bin/env python3
"""Rewrite the roster block in CONTRIBUTORS.md from this repository's git history.

The roster is derived, never hand-written: a contributor appears because they
committed code, so it cannot go stale or be forgotten. Run by the Contributors
workflow; safe to run locally.

    python scripts/generate_contributors.py            # rewrite the file
    python scripts/generate_contributors.py --check    # exit 1 if out of date

Two things this has to get right:

* **Identity merging.** One person shows up under several names across years -
  a changed username, a work address, a personal one. Entries are merged on a
  normalised name so somebody who authored 163 commits under one name and 9
  under another is not listed twice as different people.
* **Upstream versus here.** This is a fork, so most commits belong to the
  upstream project's authors. They are counted and credited, and labelled, so
  the roster cannot be misread as "these people work on Inkbound".
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONTRIBUTORS = REPO / "CONTRIBUTORS.md"
START = "<!-- ROSTER:START -->"
END = "<!-- ROSTER:END -->"

# People whose commits belong to a project this repository forked, rather than
# to Inkbound. Keys are the normalised names matched against git identities.
UPSTREAM = {
    "krishna": "Krishna Vishwakarma",
    "nathen": "Nathen Brewer",
    "mo7ammed": "mo7AmMeD64",
    "debjit": "Debjit",
    "potato": "Potato[VIP]",
    "leo": "Leo Camus",
}

EM_DASH = "\u2014"

# Built at import time from an escape rather than typed as a literal. A Windows
# checkout can be read through cp1252, where a literal em dash in this source
# decodes to a replacement character - which then propagates into the generated
# block and makes the workflow open a pull request on every run. An ASCII escape
# decodes identically under any encoding.
ROLES = {
    "apauruseya7866er": f"**Maintainer {EM_DASH} Inkbound's author and sole owner**",
    "krishna": (
        f"Original Zangetsu author {EM_DASH} reader, sources, downloads, "
        "trackers, TTS"
    ),
}


def shortlog() -> list[tuple[str, int]]:
    """Return [(display name, commit count)] for every commit on HEAD."""
    out = subprocess.run(
        ["git", "shortlog", "-sne", "HEAD"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    rows: list[tuple[str, int]] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        # Leading count is padded with spaces, and some locales insert NBSP.
        parts = re.split(r"[\s ]+", line.strip(), maxsplit=1)
        if len(parts) != 2:
            continue
        count, identity = parts
        if not count.isdigit():
            continue
        name = identity.rsplit("<", 1)[0].strip()
        if name:
            rows.append((name, int(count)))
    return rows


def normalise(name: str) -> str:
    """Collapse a display name to a merge key."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def resolve(name: str) -> tuple[str, str | None]:
    """Map a raw git identity to (display name, upstream key or None)."""
    key = normalise(name)
    for upstream_key, display in UPSTREAM.items():
        if key.startswith(upstream_key) or upstream_key in key:
            return display, upstream_key
    return name, None


def merge(rows: list[tuple[str, int]]) -> dict[tuple[str, str | None], int]:
    """Sum commits per (display name, upstream key)."""
    totals: dict[tuple[str, str | None], int] = defaultdict(int)
    for name, count in rows:
        display, upstream_key = resolve(name)
        totals[(display, upstream_key)] += count
    return totals


def render(totals: dict[tuple[str, str | None], int]) -> str:
    def sort_key(item: tuple[tuple[str, str | None], int]) -> tuple[int, str]:
        (_, _), count = item
        return (-count, item[0][0].lower())

    lines = [
        "| Contributor | Commits | Role |",
        "|---|---:|---|",
    ]

    for (name, upstream_key), count in sorted(totals.items(), key=sort_key):
        if upstream_key:
            role = ROLES.get(upstream_key, "Upstream (Zangetsu)")
        else:
            role = ROLES.get(normalise(name), "")
        if not role:
            role = "Contributor"
        bold = "**" if role.startswith("**") else ""
        suffix = "**" if bold else ""
        lines.append(f"| {name} | {bold}{count}{suffix} | {role} |")

    lines += [
        "",
        "Commit counts are total contributions across the full forked history, including",
        "the upstream years. Upstream contributions are credited to their authors and are",
        "not an endorsement of Inkbound; see [`NOTICE.md`](NOTICE.md).",
    ]
    return "\n".join(lines)


def splice(document: str, block: str) -> str:
    """Replace everything between the roster markers, adding markers if absent."""
    if START in document and END in document:
        head, rest = document.split(START, 1)
        _, tail = rest.split(END, 1)
        return f"{head}{START}\n{block}\n{END}{tail}"

    print(
        "::warning::roster markers missing from CONTRIBUTORS.md - appending the block",
        file=sys.stderr,
    )
    return f"{document.rstrip()}\n\n{START}\n{block}\n{END}\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if the file is out of date instead of writing it",
    )
    args = parser.parse_args()

    if not CONTRIBUTORS.exists():
        print(f"error: {CONTRIBUTORS} not found", file=sys.stderr)
        return 1

    block = render(merge(shortlog()))
    current = CONTRIBUTORS.read_text(encoding="utf-8")
    updated = splice(current, block)

    if args.check:
        if current != updated:
            print("CONTRIBUTORS.md is out of date.", file=sys.stderr)
            return 1
        print("CONTRIBUTORS.md is up to date.")
        return 0

    if current != updated:
        CONTRIBUTORS.write_text(updated, encoding="utf-8")
        print(f"Updated {CONTRIBUTORS.relative_to(REPO)}")
    else:
        print("Already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
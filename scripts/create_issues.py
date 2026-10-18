#!/usr/bin/env python3
"""Create the project's labels and initial issues on GitHub using the gh CLI.

Usage:
    python3 scripts/create_issues.py OWNER/REPO [--dry-run]

Safe to re-run: labels are upserted and issues whose exact title already exists are skipped.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKLOG = ROOT / ".github" / "backlog"


def parse_issues(text):
    issues, current = [], None
    for line in text.splitlines():
        if line.startswith("## "):
            if current:
                issues.append(current)
            current = {"title": line[3:].strip(), "labels": [], "body": []}
        elif current is not None and not current["body"] and line.startswith("Labels:"):
            current["labels"] = [l.strip() for l in line[len("Labels:"):].split(",") if l.strip()]
        elif current is not None:
            current["body"].append(line)
    if current:
        issues.append(current)
    for issue in issues:
        issue["body"] = "\n".join(issue["body"]).strip()
    return issues


def gh(args, dry):
    if dry:
        print("DRY:", " ".join(args[:4]), "...")
        return ""
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    repo, dry = sys.argv[1], "--dry-run" in sys.argv
    labels = json.loads((BACKLOG / "labels.json").read_text())
    issues = parse_issues((BACKLOG / "issues.md").read_text())
    known = {l["name"] for l in labels}
    for issue in issues:
        missing = set(issue["labels"]) - known
        if missing:
            sys.exit(f"Unknown labels {missing} in issue: {issue['title']}")

    for l in labels:
        gh(["label", "create", l["name"], "--repo", repo, "--color", l["color"],
            "--description", l["description"], "--force"], dry)

    existing = set()
    if not dry:
        out = gh(["issue", "list", "--repo", repo, "--state", "all", "--limit", "500",
                  "--json", "title"], dry)
        existing = {i["title"] for i in json.loads(out)}

    created = 0
    for issue in issues:
        if issue["title"] in existing:
            print("skip (exists):", issue["title"])
            continue
        args = ["issue", "create", "--repo", repo, "--title", issue["title"], "--body", issue["body"]]
        for l in issue["labels"]:
            args += ["--label", l]
        url = gh(args, dry).strip()
        print("created:", url or issue["title"])
        created += 1
    print(f"{len(labels)} labels, {created} issues created, {len(issues)} in backlog")


if __name__ == "__main__":
    main()

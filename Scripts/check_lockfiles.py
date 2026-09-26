#!/usr/bin/env python3
"""Require identical pinned sources across the portable and app lockfiles.

Compare kind, location and complete revision/version/branch state. Version labels alone cannot
prove the same code was tested. Only the UI editor packages may appear exclusively in Tuist.
"""

import copy
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TUIST_ONLY, ROOT_ONLY = {"codeeditorview", "rearrange"}, set()


def decoded_pins(document):
    if not isinstance(document, dict) or document.get("version") not in {2, 3}:
        raise ValueError("unsupported lockfile format")
    entries = document.get("pins")
    if not isinstance(entries, list) or not entries:
        raise ValueError("lockfile must contain a nonempty pins array")
    result = {}
    for pin in entries:
        if not isinstance(pin, dict):
            raise ValueError("every lockfile pin must be an object")
        identity = pin.get("identity")
        if not isinstance(identity, str) or not identity or identity != identity.strip():
            raise ValueError("every pin must have a nonempty identity")
        if identity in result:
            raise ValueError(f"duplicate pin identity: {identity}")
        for field in ("kind", "location"):
            if not isinstance(pin.get(field), str) or not pin[field]:
                raise ValueError(f"{identity}: missing {field}")
        state = pin.get("state")
        if not isinstance(state, dict) or not state or any(
            not isinstance(value, str) or not value for value in state.values()
        ):
            raise ValueError(f"{identity}: invalid pinned state")
        if pin["kind"].endswith("SourceControl") and not state.get("revision"):
            raise ValueError(f"{identity}: source-control pin has no revision")
        result[identity] = {key: value for key, value in pin.items() if key != "identity"}
    return result


def pins(path):
    try:
        return decoded_pins(json.loads((ROOT / path).read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        raise ValueError(f"{path}: {error}") from error


def disagreements(root, tuist, tuist_only=TUIST_ONLY, root_only=ROOT_ONLY):
    problems = []
    for identity in sorted(root.keys() & tuist.keys()):
        for field in sorted(root[identity].keys() | tuist[identity].keys()):
            left, right = root[identity].get(field), tuist[identity].get(field)
            if left != right:
                problems.append(f"{identity}: {field} differs: Package.resolved={left!r}, "
                                f"Tuist/Package.resolved={right!r}")
    problems += [f"{name}: missing from Tuist/Package.resolved"
                 for name in sorted(root.keys() - tuist.keys() - root_only)]
    problems += [f"{name}: missing from Package.resolved"
                 for name in sorted(tuist.keys() - root.keys() - tuist_only)]
    stale = (tuist_only - (tuist.keys() - root.keys())) | (root_only - (root.keys() - tuist.keys()))
    problems += [f"{name}: one-sided allowlist no longer matches the lockfiles" for name in sorted(stale)]
    return problems


def self_test():
    original = {"version": 3, "pins": [{"identity": "example", "kind": "remoteSourceControl",
        "location": "https://example.com/package.git",
        "state": {"version": "1.0.0", "revision": "1111111111111111111111111111111111111111"}}]}
    root = decoded_pins(original)
    cases = [disagreements(root, root, set(), set()) == []]
    for field, value in (("location", "https://elsewhere.example/package.git"),
                         ("kind", "localSourceControl"),
                         ("state", {"version": "1.0.0", "revision": "2222222222222222222222222222222222222222"}),
                         ("state", {"branch": "main", "revision": "1111111111111111111111111111111111111111"})):
        changed = copy.deepcopy(original)
        changed["pins"][0][field] = value
        cases.append(bool(disagreements(root, decoded_pins(changed), set(), set())))
    cases += [
        bool(disagreements(root, {}, set(), set())),
        disagreements(root, {}, set(), {"example"}) == [],
        bool(disagreements({}, root, set(), {"example"})),
        bool(disagreements(root, root, {"example"}, set())),
    ]
    duplicate = copy.deepcopy(original)
    duplicate["pins"].append(copy.deepcopy(duplicate["pins"][0]))
    missing_revision = copy.deepcopy(original)
    missing_revision["pins"][0]["state"] = {"version": "1.0.0"}
    for malformed in (duplicate, missing_revision, {"version": 3, "pins": []}):
        try:
            decoded_pins(malformed)
        except ValueError:
            cases.append(True)
        else:
            cases.append(False)
    if not all(cases):
        raise AssertionError(f"lockfile parity fixtures failed: {[i for i, passed in enumerate(cases) if not passed]}")
    print(f"{len(cases)} lockfile-parity fixtures passed")


def main():
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif sys.argv[1:]:
            raise ValueError("usage: check_lockfiles.py [--self-test]")
        root, tuist = pins("Package.resolved"), pins("Tuist/Package.resolved")
        problems = disagreements(root, tuist)
    except ValueError as error:
        sys.exit(f"Lockfile parity could not be checked: {error}")
    for line in problems:
        print(line)
    if problems:
        sys.exit(f"{len(problems)} lockfile disagreement(s); resolve both manifests to the same pinned sources")
    print(f"{len(root.keys() & tuist.keys())} shared packages pin identical sources; "
          f"{len(TUIST_ONLY | ROOT_ONLY)} allowlisted as one-sided")


if __name__ == "__main__":
    main()

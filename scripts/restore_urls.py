#!/usr/bin/env python3
"""Replace selected visible URL prefixes with their complete logical lines."""

import json
import sys


def main() -> None:
    with open(sys.argv[1], encoding="utf-8") as handle:
        urls = json.load(handle)
    for line in sys.stdin:
        value = line.rstrip("\n")
        print(urls.get(value, value))


if __name__ == "__main__":
    main()

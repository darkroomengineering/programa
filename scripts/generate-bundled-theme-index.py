"""Index the theme files copied into the signed application bundle."""

import json
import os
from pathlib import Path
import sys


def main():
    resources = Path(sys.argv[1])
    with os.scandir(resources / "themes") as entries:
        names = sorted(
            entry.name
            for entry in entries
            if not entry.name.startswith(".") and entry.is_file(follow_symlinks=False)
        )
    (resources / "theme-index.json").write_text(
        json.dumps(names, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()

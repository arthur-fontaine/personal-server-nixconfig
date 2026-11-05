"""Makes ../hermes-plugin importable as ``sandbox``, its name in Hermes."""

from __future__ import annotations

import atexit
import shutil
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
_root = Path(tempfile.mkdtemp(prefix="sandbox-plugin-"))
(_root / "sandbox").symlink_to(Path(__file__).resolve().parent.parent / "hermes-plugin")
sys.path.insert(0, str(_root))
atexit.register(shutil.rmtree, _root, True)

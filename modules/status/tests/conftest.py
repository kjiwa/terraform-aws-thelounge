"""Sets the environment plugin.py reads at import and puts it on sys.path."""

import os
import sys

os.environ.setdefault("SITE_URL", "https://irc.example.org")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "plugin"))

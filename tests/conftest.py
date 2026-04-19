"""
Pytest configuration and shared fixtures for the k6 portal test suite.
"""

import sys
from pathlib import Path

# Make app/ importable without installing
sys.path.insert(0, str(Path(__file__).parent.parent / "app"))

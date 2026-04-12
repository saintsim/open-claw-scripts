import sys
import os

# Make newsletter_fetcher importable from the tests/ subdirectory without installation.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

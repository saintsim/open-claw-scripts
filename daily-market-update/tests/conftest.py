import sys
import os

# Make market_data importable from the tests/ subdirectory without installation.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

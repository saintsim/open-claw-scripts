#!/usr/bin/env python3
# power-on-newsletter/newsletter_fetcher.py
#
# Fetches Mark Gurman's Bloomberg author RSS feed, locates the latest
# Power On newsletter item, and prints a JSON result to stdout if a new
# one has been published since the last run.
#
# Called by power-on-newsletter.sh; also importable by tests so the
# parsing logic can be exercised without any network access.
#
# Exit codes:
#   0  New newsletter found — JSON printed to stdout
#   2  No new newsletter (none in feed, or already seen)
#   1  Error fetching or parsing the feed (details on stderr)

import json
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from urllib.error import URLError
from urllib.parse import urlparse, urlunparse
from urllib.request import Request, urlopen


AUTHOR_FEED_URL = "https://www.bloomberg.com/authors/AS7Hj1mBMGM/mark-gurman.rss"
STATE_FILE = os.path.expanduser("~/.openclaw/data/power-on-newsletter-last-seen.txt")


def fetch_feed(url: str, timeout: int = 30) -> str:
    """Fetch the RSS feed and return its XML content as a string.

    Uses a browser-like User-Agent so the request is not blocked by
    Bloomberg's CDN, which rejects bare urllib or curl default agents.
    """
    req = Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            "Accept": "application/rss+xml, application/xml, text/xml, */*",
        },
    )
    with urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def find_newsletter_item(feed_xml: str) -> dict | None:
    """Parse the RSS/Atom feed and return the first newsletter item found.

    Looks for the first ``<item>`` (RSS 2.0) or ``<entry>`` (Atom) whose
    link contains ``/news/newsletters/``.

    Returns a dict with keys ``link`` and ``title``, or ``None`` if no
    matching item is found (including on XML parse errors).
    """
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError as exc:
        print(f"XML parse error: {exc}", file=sys.stderr)
        return None

    ns_atom = "http://www.w3.org/2005/Atom"
    items = root.findall(".//item")
    if not items:
        items = root.findall(f".//{{{ns_atom}}}entry")

    for item in items:
        # RSS 2.0: <link> contains text; Atom: <link href="...">
        link_el = item.find("link")
        if link_el is None:
            link_el = item.find(f"{{{ns_atom}}}link")
        if link_el is None:
            continue

        link = (link_el.get("href") or link_el.text or "").strip()
        if "/news/newsletters/" not in link:
            continue

        title_el = item.find("title")
        if title_el is None:
            title_el = item.find(f"{{{ns_atom}}}title")
        title = (title_el.text or "").strip() if title_el is not None else ""

        return {"link": link, "title": title}

    return None


def clean_url(url: str) -> str:
    """Strip query parameters and fragment from a URL."""
    parsed = urlparse(url)
    return urlunparse(parsed._replace(query="", fragment=""))


def extract_article_id(url: str) -> str:
    """Return a stable deduplication key derived from the URL path.

    Uses the cleaned path (no query string, no trailing slash) so that
    any future slug change is treated as a new article.
    """
    parsed = urlparse(url)
    return parsed.path.rstrip("/")


def extract_date(url: str) -> str:
    """Extract the publication date from a Bloomberg newsletter URL.

    Expected structure: /news/newsletters/YYYY-MM-DD/article-slug
    Returns the date string (e.g. ``"2026-04-12"``) or ``""`` if the
    pattern is not found.
    """
    parsed = urlparse(url)
    parts = [p for p in parsed.path.split("/") if p]
    # parts: ["news", "newsletters", "YYYY-MM-DD", "slug"]
    try:
        idx = parts.index("newsletters")
        candidate = parts[idx + 1]
        if len(candidate) == 10 and candidate[4] == "-" and candidate[7] == "-":
            return candidate
    except (ValueError, IndexError):
        pass
    return ""


def format_date(date_str: str) -> str:
    """Convert ``"YYYY-MM-DD"`` to ``"D Month YYYY"`` (e.g. ``"12 April 2026"``).

    Returns the original string unchanged if it cannot be parsed.
    """
    if not date_str:
        return date_str
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
        return f"{dt.day} {dt.strftime('%B %Y')}"
    except ValueError:
        return date_str


def load_last_seen(state_file: str) -> str:
    """Return the last-seen article ID from the state file, or ``""`` if absent."""
    try:
        with open(state_file) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def main() -> None:
    try:
        feed_xml = fetch_feed(AUTHOR_FEED_URL)
    except URLError as exc:
        print(f"Failed to fetch RSS feed: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"Unexpected error fetching feed: {exc}", file=sys.stderr)
        sys.exit(1)

    item = find_newsletter_item(feed_xml)
    if item is None:
        # No newsletter item in feed — caller will retry or give up
        sys.exit(2)

    raw_url = item["link"]
    clean = clean_url(raw_url)
    article_id = extract_article_id(clean)

    last_seen = load_last_seen(STATE_FILE)
    if article_id == last_seen:
        # Same article as last run — nothing new
        sys.exit(2)

    date_str = extract_date(clean)
    date_human = format_date(date_str)
    headline = item["title"]
    archive_url = f"https://archive.md/{clean}"

    result = {
        "archive_url": archive_url,
        "bloomberg_url": clean,
        "article_id": article_id,
        "date": date_str,
        "date_human": date_human,
        "headline": headline,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()

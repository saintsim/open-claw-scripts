"""
Unit tests for newsletter_fetcher.py.

Run from the repo root:
    pytest power-on-newsletter/tests/

No internet access required — all network calls are mocked.
"""

import json
import os
import sys
from unittest.mock import MagicMock, patch

import pytest

import newsletter_fetcher


# ---------------------------------------------------------------------------
# Shared sample data
# ---------------------------------------------------------------------------

_SAMPLE_LINK = (
    "https://www.bloomberg.com/news/newsletters/2026-04-12/"
    "apple-ai-glasses-will-rival-metas-with-several-styles-oval-cameras"
)
# Use a single-param query string to avoid unescaped & in XML test fixtures
_SAMPLE_LINK_WITH_QS = _SAMPLE_LINK + "?srnd=premium"
_SAMPLE_TITLE = "Apple AI Glasses Will Rival Meta's With Several Styles, Oval Cameras"
_SAMPLE_ARTICLE_ID = (
    "/news/newsletters/2026-04-12/"
    "apple-ai-glasses-will-rival-metas-with-several-styles-oval-cameras"
)

_RSS_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Mark Gurman</title>
    {items}
  </channel>
</rss>
"""

_NEWSLETTER_ITEM = f"""\
<item>
  <title>{_SAMPLE_TITLE}</title>
  <link>{_SAMPLE_LINK_WITH_QS}</link>
</item>
"""

_NON_NEWSLETTER_ITEM = """\
<item>
  <title>Some Other Article</title>
  <link>https://www.bloomberg.com/news/articles/2026-04-11/some-other-article</link>
</item>
"""

_OLDER_NEWSLETTER_ITEM = """\
<item>
  <title>Older Power On</title>
  <link>https://www.bloomberg.com/news/newsletters/2026-04-05/older-power-on</link>
</item>
"""


def _make_rss(*items: str) -> str:
    """Build a minimal RSS document containing the given item XML strings."""
    return _RSS_TEMPLATE.format(items="\n".join(items))


def _make_mock_response(content: str) -> MagicMock:
    """Return a context-manager MagicMock that yields the given RSS content."""
    mock_resp = MagicMock()
    mock_resp.__enter__ = MagicMock(return_value=mock_resp)
    mock_resp.__exit__ = MagicMock(return_value=False)
    mock_resp.read.return_value = content.encode("utf-8")
    return mock_resp


# ---------------------------------------------------------------------------
# find_newsletter_item
# ---------------------------------------------------------------------------

class TestFindNewsletterItem:
    def test_finds_newsletter_link(self):
        xml = _make_rss(_NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert result is not None
        assert "/news/newsletters/" in result["link"]

    def test_returns_title(self):
        xml = _make_rss(_NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert result["title"] == _SAMPLE_TITLE

    def test_link_includes_query_string(self):
        """The raw link from the feed may still carry query params; clean_url strips them."""
        xml = _make_rss(_NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert "srnd=premium" in result["link"]

    def test_skips_non_newsletter_items(self):
        xml = _make_rss(_NON_NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert result is None

    def test_returns_first_newsletter_when_multiple(self):
        xml = _make_rss(_NEWSLETTER_ITEM, _OLDER_NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert "2026-04-12" in result["link"]

    def test_finds_newsletter_after_non_newsletter(self):
        xml = _make_rss(_NON_NEWSLETTER_ITEM, _NEWSLETTER_ITEM)
        result = newsletter_fetcher.find_newsletter_item(xml)
        assert result is not None
        assert "/news/newsletters/" in result["link"]

    def test_returns_none_on_empty_feed(self):
        xml = _make_rss()
        assert newsletter_fetcher.find_newsletter_item(xml) is None

    def test_returns_none_on_malformed_xml(self):
        result = newsletter_fetcher.find_newsletter_item("<not valid xml<<<")
        assert result is None

    def test_handles_atom_feed(self):
        atom_xml = """\
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>Power On Atom Entry</title>
    <link href="https://www.bloomberg.com/news/newsletters/2026-04-12/atom-slug"/>
  </entry>
</feed>
"""
        result = newsletter_fetcher.find_newsletter_item(atom_xml)
        assert result is not None
        assert "/news/newsletters/" in result["link"]
        assert result["title"] == "Power On Atom Entry"


# ---------------------------------------------------------------------------
# clean_url
# ---------------------------------------------------------------------------

class TestCleanUrl:
    def test_removes_query_string(self):
        url = _SAMPLE_LINK + "?srnd=premium&utm_source=newsletter"
        assert newsletter_fetcher.clean_url(url) == _SAMPLE_LINK

    def test_removes_fragment(self):
        url = _SAMPLE_LINK + "#section"
        assert newsletter_fetcher.clean_url(url) == _SAMPLE_LINK

    def test_removes_query_and_fragment(self):
        url = _SAMPLE_LINK + "?foo=bar#frag"
        assert newsletter_fetcher.clean_url(url) == _SAMPLE_LINK

    def test_no_change_when_already_clean(self):
        assert newsletter_fetcher.clean_url(_SAMPLE_LINK) == _SAMPLE_LINK

    def test_preserves_path(self):
        result = newsletter_fetcher.clean_url(_SAMPLE_LINK_WITH_QS)
        assert "apple-ai-glasses" in result


# ---------------------------------------------------------------------------
# extract_article_id
# ---------------------------------------------------------------------------

class TestExtractArticleId:
    def test_returns_url_path(self):
        result = newsletter_fetcher.extract_article_id(_SAMPLE_LINK)
        assert result == _SAMPLE_ARTICLE_ID

    def test_strips_trailing_slash(self):
        result = newsletter_fetcher.extract_article_id(_SAMPLE_LINK + "/")
        assert not result.endswith("/")

    def test_different_slugs_give_different_ids(self):
        url_a = "https://www.bloomberg.com/news/newsletters/2026-04-12/article-a"
        url_b = "https://www.bloomberg.com/news/newsletters/2026-04-05/article-b"
        assert newsletter_fetcher.extract_article_id(url_a) != newsletter_fetcher.extract_article_id(url_b)


# ---------------------------------------------------------------------------
# extract_date
# ---------------------------------------------------------------------------

class TestExtractDate:
    def test_standard_bloomberg_url(self):
        assert newsletter_fetcher.extract_date(_SAMPLE_LINK) == "2026-04-12"

    def test_returns_empty_when_no_date_segment(self):
        url = "https://www.bloomberg.com/news/newsletters/no-date-here"
        assert newsletter_fetcher.extract_date(url) == ""

    def test_returns_empty_for_non_newsletter_url(self):
        url = "https://www.bloomberg.com/news/articles/2026-04-12/some-article"
        assert newsletter_fetcher.extract_date(url) == ""

    def test_does_not_treat_non_date_segment_as_date(self):
        url = "https://www.bloomberg.com/news/newsletters/not-a-real-date/slug"
        assert newsletter_fetcher.extract_date(url) == ""

    def test_different_dates_extracted_correctly(self):
        url = "https://www.bloomberg.com/news/newsletters/2026-01-05/title"
        assert newsletter_fetcher.extract_date(url) == "2026-01-05"


# ---------------------------------------------------------------------------
# format_date
# ---------------------------------------------------------------------------

class TestFormatDate:
    def test_standard_date(self):
        assert newsletter_fetcher.format_date("2026-04-12") == "12 April 2026"

    def test_single_digit_day(self):
        assert newsletter_fetcher.format_date("2026-04-05") == "5 April 2026"

    def test_january(self):
        assert newsletter_fetcher.format_date("2026-01-19") == "19 January 2026"

    def test_invalid_date_returns_original(self):
        assert newsletter_fetcher.format_date("not-a-date") == "not-a-date"

    def test_empty_string_returns_empty(self):
        assert newsletter_fetcher.format_date("") == ""


# ---------------------------------------------------------------------------
# load_last_seen
# ---------------------------------------------------------------------------

class TestLoadLastSeen:
    def test_returns_empty_when_file_absent(self, tmp_path):
        path = str(tmp_path / "nonexistent.txt")
        assert newsletter_fetcher.load_last_seen(path) == ""

    def test_returns_stored_id(self, tmp_path):
        path = str(tmp_path / "last-seen.txt")
        with open(path, "w") as f:
            f.write(_SAMPLE_ARTICLE_ID + "\n")
        assert newsletter_fetcher.load_last_seen(path) == _SAMPLE_ARTICLE_ID

    def test_strips_surrounding_whitespace(self, tmp_path):
        path = str(tmp_path / "last-seen.txt")
        with open(path, "w") as f:
            f.write("  /news/newsletters/2026-04-05/slug  \n")
        assert newsletter_fetcher.load_last_seen(path) == "/news/newsletters/2026-04-05/slug"


# ---------------------------------------------------------------------------
# fetch_feed — mocks urllib.request.urlopen
# ---------------------------------------------------------------------------

class TestFetchFeed:
    def test_returns_feed_content(self):
        xml = _make_rss(_NEWSLETTER_ITEM)
        mock_resp = _make_mock_response(xml)
        with patch("newsletter_fetcher.urlopen", return_value=mock_resp):
            result = newsletter_fetcher.fetch_feed("http://example.com/feed.rss")
        assert "<rss" in result
        assert _SAMPLE_TITLE in result

    def test_sends_user_agent_header(self):
        xml = _make_rss(_NEWSLETTER_ITEM)
        mock_resp = _make_mock_response(xml)
        with patch("newsletter_fetcher.urlopen", return_value=mock_resp) as mock_open:
            newsletter_fetcher.fetch_feed("http://example.com/feed.rss")
        request_obj = mock_open.call_args[0][0]
        # urllib.request.Request stores headers title-cased (e.g. "User-agent")
        header_keys_lower = {k.lower() for k in request_obj.headers}
        assert "user-agent" in header_keys_lower

    def test_raises_url_error_on_network_failure(self):
        from urllib.error import URLError
        with patch("newsletter_fetcher.urlopen", side_effect=URLError("connection refused")):
            with pytest.raises(URLError):
                newsletter_fetcher.fetch_feed("http://example.com/feed.rss")


# ---------------------------------------------------------------------------
# main() — integration tests (mocked network + state file)
# ---------------------------------------------------------------------------

class TestMainNewNewsletter:
    """main() exits 0 and prints JSON when a new newsletter is found."""

    def _patch_fetch(self, xml: str):
        return patch("newsletter_fetcher.urlopen", return_value=_make_mock_response(xml))

    def test_prints_valid_json(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        out = capsys.readouterr().out
        data = json.loads(out)
        assert "archive_url" in data

    def test_archive_url_starts_with_archive_md(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        data = json.loads(capsys.readouterr().out)
        assert data["archive_url"].startswith("https://archive.md/https://")

    def test_query_string_stripped_from_archive_url(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        data = json.loads(capsys.readouterr().out)
        assert "?" not in data["archive_url"]
        assert "srnd" not in data["archive_url"]

    def test_headline_extracted(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        data = json.loads(capsys.readouterr().out)
        assert data["headline"] == _SAMPLE_TITLE

    def test_date_extracted(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        data = json.loads(capsys.readouterr().out)
        assert data["date"] == "2026-04-12"

    def test_date_human_formatted(self, tmp_path, capsys):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            newsletter_fetcher.main()
        data = json.loads(capsys.readouterr().out)
        assert data["date_human"] == "12 April 2026"

    def test_exits_2_when_article_already_seen(self, tmp_path):
        xml = _make_rss(_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        with open(state_file, "w") as f:
            f.write(_SAMPLE_ARTICLE_ID + "\n")
        with self._patch_fetch(xml), patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            with pytest.raises(SystemExit) as exc:
                newsletter_fetcher.main()
        assert exc.value.code == 2


class TestMainNoNewsletter:
    """main() exits 2 when no newsletter is present in the feed."""

    def test_exits_2_when_feed_has_no_newsletter(self, tmp_path):
        xml = _make_rss(_NON_NEWSLETTER_ITEM)
        state_file = str(tmp_path / "last-seen.txt")
        mock_resp = _make_mock_response(xml)
        with patch("newsletter_fetcher.urlopen", return_value=mock_resp), \
             patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            with pytest.raises(SystemExit) as exc:
                newsletter_fetcher.main()
        assert exc.value.code == 2

    def test_exits_2_on_empty_feed(self, tmp_path):
        xml = _make_rss()
        state_file = str(tmp_path / "last-seen.txt")
        mock_resp = _make_mock_response(xml)
        with patch("newsletter_fetcher.urlopen", return_value=mock_resp), \
             patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            with pytest.raises(SystemExit) as exc:
                newsletter_fetcher.main()
        assert exc.value.code == 2


class TestMainFetchError:
    """main() exits 1 on network or unexpected errors."""

    def test_exits_1_on_url_error(self, tmp_path):
        from urllib.error import URLError
        state_file = str(tmp_path / "last-seen.txt")
        with patch("newsletter_fetcher.urlopen", side_effect=URLError("connection refused")), \
             patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            with pytest.raises(SystemExit) as exc:
                newsletter_fetcher.main()
        assert exc.value.code == 1

    def test_exits_1_on_unexpected_exception(self, tmp_path):
        state_file = str(tmp_path / "last-seen.txt")
        with patch("newsletter_fetcher.urlopen", side_effect=RuntimeError("unexpected")), \
             patch.object(newsletter_fetcher, "STATE_FILE", state_file):
            with pytest.raises(SystemExit) as exc:
                newsletter_fetcher.main()
        assert exc.value.code == 1

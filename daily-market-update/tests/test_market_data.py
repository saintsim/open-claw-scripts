"""
Unit tests for market_data.py.

Run from the repo root:
    pip3 install pytest pandas yfinance
    pytest daily-market-update/tests/

The yfinance network call is mocked throughout — no internet required.
"""

import sys
from datetime import date, timedelta
from unittest.mock import MagicMock, patch

import pandas as pd
import pytest

import market_data


# ---------------------------------------------------------------------------
# Shared mock data
# ---------------------------------------------------------------------------

_DATES = pd.to_datetime([
    "2025-04-07", "2025-04-08", "2025-04-09", "2025-04-10", "2025-04-11",
])

# Five weekdays of closing prices; iloc[-1] is "today", iloc[-2] is "previous".
_MOCK_CLOSES = pd.DataFrame(
    {
        "JPYGBP=X": [0.005210, 0.005205, 0.005200, 0.005190, 0.005176],
        "GBPJPY=X": [191.94,   192.13,   192.30,   192.70,   193.40  ],
        "USDJPY=X": [150.50,   150.30,   150.10,   150.20,   149.82  ],
        "GS":       [480.00,   481.50,   483.00,   481.70,   485.20  ],
        "AAPL":     [201.00,   200.10,   199.50,   199.65,   198.45  ],
        "^GSPC":    [5220.00,  5225.00,  5228.00,  5221.68,  5234.18 ],
        "GC=F":     [2335.00,  2340.00,  2342.50,  2337.40,  2345.60 ],
        "SI=F":     [29.100,   29.200,   29.350,   29.300,   29.450  ],
        "CL=F":     [80.00,    79.50,    79.20,    79.35,    78.90   ],
    },
    index=_DATES,
)

_TODAY = "Fri 11 Apr 2025"


def _make_download_mock(closes=None):
    """Return a MagicMock that mimics a yfinance multi-ticker download result."""
    if closes is None:
        closes = _MOCK_CLOSES
    mock = MagicMock()
    mock.empty = False
    mock.__getitem__ = MagicMock(return_value=closes)
    return mock


# ---------------------------------------------------------------------------
# _compute_ref_date — partial intra-day bar filtering
# ---------------------------------------------------------------------------

class TestComputeRefDate:
    def test_excludes_partial_intraday_bar_dated_today(self):
        """A FX bar dated today (partial Asian session at 08:00 JST) is excluded.

        Without filtering, ref_date would equal today, making all US instruments
        (whose last close is yesterday) falsely show 'market closed'.
        """
        today = date.today()
        yesterday = today - timedelta(days=1)
        two_days_ago = today - timedelta(days=2)
        dates = pd.to_datetime([two_days_ago, yesterday, today])
        closes = pd.DataFrame(
            {"USDJPY=X": [149.0, 149.8, 150.1]},
            index=dates,
        )
        assert market_data._compute_ref_date(closes) == yesterday

    def test_uses_completed_bar_when_no_intraday(self):
        """When the last FX bar is from yesterday, it is used as-is."""
        today = date.today()
        yesterday = today - timedelta(days=1)
        two_days_ago = today - timedelta(days=2)
        dates = pd.to_datetime([two_days_ago, yesterday])
        closes = pd.DataFrame(
            {"USDJPY=X": [149.0, 149.8]},
            index=dates,
        )
        assert market_data._compute_ref_date(closes) == yesterday

    def test_falls_back_to_yesterday_when_no_fx_data(self):
        """Falls back to yesterday when all FX symbols are NaN.

        This ensures holiday detection remains active even if yfinance has a
        data gap for FX — it does not assume FX absence means equities closed.
        """
        closes = pd.DataFrame({"USDJPY=X": [float("nan")] * 5}, index=_DATES)
        assert market_data._compute_ref_date(closes) == date.today() - timedelta(days=1)


# ---------------------------------------------------------------------------
# _render — pure formatter, no yfinance dependency
# ---------------------------------------------------------------------------

class TestRender:
    def test_positive_change(self):
        result = market_data._render(150.00, 148.00, 2)
        assert "▲" in result
        assert "+2.00" in result
        assert "(+1.35%)" in result  # 2/148*100 = 1.3513… → 1.35

    def test_negative_change(self):
        result = market_data._render(148.00, 150.00, 2)
        assert "▼" in result
        assert "-2.00" in result
        assert "(-1.33%)" in result  # -2/150*100 = -1.3333… → -1.33

    def test_prefix(self):
        result = market_data._render(100.00, 99.00, 2, prefix="$")
        assert result.startswith("$100.00")

    def test_thousands_separator(self):
        result = market_data._render(5234.18, 5221.68, 2)
        assert "5,234.18" in result

    def test_six_decimal_places(self):
        result = market_data._render(0.005176, 0.005190, 6)
        assert "0.005176" in result


# ---------------------------------------------------------------------------
# build_message — uses mock closes, no network
# ---------------------------------------------------------------------------

class TestBuildMessage:
    def test_header_contains_date(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        assert f"**Market Update — {_TODAY}**" in msg

    def test_all_sections_present(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        assert "**FX**" in msg
        assert "**Equities**" in msg
        assert "**Commodities**" in msg

    def test_all_instruments_present(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        for label in [
            "JPY/GBP:", "USD/JPY:",
            "Goldman Sachs (GS):", "Apple (AAPL):", "S&P 500:",
            "Gold ($/oz):", "Silver ($/oz):", "WTI Crude ($/bbl):",
        ]:
            assert label in msg, f"Missing instrument label: {label}"

    def test_footer(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        assert "_Change vs prior close_" in msg

    def test_arrows_present(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        assert "▲" in msg or "▼" in msg

    def test_jpygbp_price_and_direction(self):
        # last=0.005176, prev=0.005190 → fell → ▼
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        jpy_line = next(l for l in msg.splitlines() if "JPY/GBP" in l)
        assert "0.005176" in jpy_line
        assert "▼" in jpy_line

    def test_usdjpy_price(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        usd_line = next(l for l in msg.splitlines() if "USD/JPY" in l)
        assert "149.82" in usd_line

    def test_gs_dollar_prefix(self):
        # last=485.20, prev=481.70 → rose → ▲
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        gs_line = next(l for l in msg.splitlines() if "Goldman Sachs" in l)
        assert "$485.20" in gs_line
        assert "▲" in gs_line

    def test_sp500_thousands_separator(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        sp_line = next(l for l in msg.splitlines() if "S&P 500" in l)
        assert "5,234.18" in sp_line

    def test_silver_three_decimal_places(self):
        msg = market_data.build_message(_MOCK_CLOSES, today=_TODAY)
        si_line = next(l for l in msg.splitlines() if "Silver" in l)
        assert "$29.450" in si_line


# ---------------------------------------------------------------------------
# fmt_jpygbp fallback logic
# ---------------------------------------------------------------------------

class TestJpyGbpFallback:
    def test_falls_back_to_gbpjpy_inversion(self):
        """When JPYGBP=X has no data, 1/GBPJPY=X is used and still formats."""
        closes = _MOCK_CLOSES.copy()
        closes["JPYGBP=X"] = float("nan")
        msg = market_data.build_message(closes, today=_TODAY)
        jpy_line = next(l for l in msg.splitlines() if "JPY/GBP" in l)
        # 1/193.40 ≈ 0.005170 — should still be a ~0.005xxx rate
        assert "N/A" not in jpy_line
        assert "0.005" in jpy_line

    def test_na_when_both_unavailable(self):
        """Returns N/A when neither JPYGBP=X nor GBPJPY=X has usable data."""
        closes = _MOCK_CLOSES.copy()
        closes["JPYGBP=X"] = float("nan")
        closes["GBPJPY=X"] = float("nan")
        msg = market_data.build_message(closes, today=_TODAY)
        jpy_line = next(l for l in msg.splitlines() if "JPY/GBP" in l)
        assert "N/A" in jpy_line


# ---------------------------------------------------------------------------
# Holiday / market-closed detection
# ---------------------------------------------------------------------------

class TestMarketClosed:
    def _closes_with_us_holiday(self):
        """Simulate a US equity holiday: NaN on the last date for equities only."""
        closes = _MOCK_CLOSES.copy()
        for sym in ("GS", "AAPL", "^GSPC"):
            closes.loc[_DATES[-1], sym] = float("nan")
        return closes

    def test_equity_shows_market_closed(self):
        msg = market_data.build_message(self._closes_with_us_holiday(), today=_TODAY)
        gs_line = next(l for l in msg.splitlines() if "Goldman Sachs" in l)
        assert "market closed" in gs_line

    def test_fx_unaffected_by_us_holiday(self):
        """FX still shows live data when only US equities are closed."""
        msg = market_data.build_message(self._closes_with_us_holiday(), today=_TODAY)
        usd_line = next(l for l in msg.splitlines() if "USD/JPY" in l)
        assert "market closed" not in usd_line
        assert "149.82" in usd_line

    def test_commodities_unaffected_by_us_holiday(self):
        msg = market_data.build_message(self._closes_with_us_holiday(), today=_TODAY)
        gold_line = next(l for l in msg.splitlines() if "Gold ($/oz)" in l)
        assert "market closed" not in gold_line


# ---------------------------------------------------------------------------
# fetch_closes — mocks out the yfinance network call
# ---------------------------------------------------------------------------

class TestFetchCloses:
    def _mock_yf(self, closes=None):
        mock_yf = MagicMock()
        mock_yf.download.return_value = _make_download_mock(closes)
        return mock_yf

    def test_returns_close_dataframe(self):
        mock_yf = self._mock_yf()
        with patch.dict(sys.modules, {"yfinance": mock_yf}):
            closes = market_data.fetch_closes()
        mock_yf.download.assert_called_once()
        assert closes is _MOCK_CLOSES

    def test_download_called_with_correct_period(self):
        mock_yf = self._mock_yf()
        with patch.dict(sys.modules, {"yfinance": mock_yf}):
            market_data.fetch_closes()
        kwargs = mock_yf.download.call_args.kwargs
        assert kwargs["period"] == "5d"
        assert kwargs["interval"] == "1d"

    def test_download_called_with_all_symbols(self):
        mock_yf = self._mock_yf()
        with patch.dict(sys.modules, {"yfinance": mock_yf}):
            market_data.fetch_closes()
        kwargs = mock_yf.download.call_args.kwargs
        for sym in ("JPYGBP=X", "GBPJPY=X", "USDJPY=X", "GS", "AAPL",
                    "^GSPC", "GC=F", "SI=F", "CL=F"):
            assert sym in kwargs["tickers"]

    def test_exits_on_empty_data(self):
        mock_yf = MagicMock()
        mock_yf.download.return_value.empty = True
        with patch.dict(sys.modules, {"yfinance": mock_yf}):
            with pytest.raises(SystemExit):
                market_data.fetch_closes()

    def test_exits_on_download_exception(self):
        mock_yf = MagicMock()
        mock_yf.download.side_effect = Exception("network error")
        with patch.dict(sys.modules, {"yfinance": mock_yf}):
            with pytest.raises(SystemExit):
                market_data.fetch_closes()

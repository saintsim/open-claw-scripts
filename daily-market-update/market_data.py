#!/usr/bin/env python3
# daily-market-update/market_data.py
#
# Fetches FX, equity, and commodity closes via yfinance and returns a
# formatted Discord message.  Called by market-update.sh; also importable
# by tests so callers can supply a mock closes DataFrame directly.
#
# Prerequisite: pip3 install yfinance  (see SETUP.md)

import sys
import time
from datetime import date, datetime, timedelta


SYMBOLS = ["JPYGBP=X", "GBPJPY=X", "USDJPY=X", "GS", "AAPL", "^GSPC", "GC=F", "SI=F", "CL=F"]

_DOWNLOAD_TIMEOUT = 60      # seconds — per-request connect+read timeout
_DOWNLOAD_RETRIES = 5       # total attempts before giving up
_DOWNLOAD_RETRY_DELAY = 2   # seconds to wait between attempts


def _log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", file=sys.stderr)


def fetch_closes():
    """Download 5 days of daily closes via yfinance and return the Close DataFrame.

    Each attempt has a _DOWNLOAD_TIMEOUT-second timeout so a hung TCP
    connection cannot stall the launchd job indefinitely.  Retries up to
    _DOWNLOAD_RETRIES times with a _DOWNLOAD_RETRY_DELAY-second pause between
    attempts to ride out transient network hiccups (common at exactly 8 AM JST).

    yfinance is imported here (not at module level) so the module remains
    importable in test environments where the library may be absent.
    """
    try:
        import yfinance as yf
    except ImportError:
        print("ERROR: yfinance not installed — run: pip3 install yfinance", file=sys.stderr)
        sys.exit(1)

    _log(f"Fetching {len(SYMBOLS)} symbols: {', '.join(SYMBOLS)}")
    _log(f"Settings: period=5d, timeout={_DOWNLOAD_TIMEOUT}s, max_retries={_DOWNLOAD_RETRIES}, retry_delay={_DOWNLOAD_RETRY_DELAY}s")

    last_exc = None
    for attempt in range(1, _DOWNLOAD_RETRIES + 1):
        try:
            _log(f"Download attempt {attempt}/{_DOWNLOAD_RETRIES}...")
            data = yf.download(
                tickers=SYMBOLS,
                period="5d",
                interval="1d",
                auto_adjust=True,
                progress=False,
                timeout=_DOWNLOAD_TIMEOUT,
            )
            _log(f"Attempt {attempt}/{_DOWNLOAD_RETRIES} succeeded — shape: {data.shape}")
            break
        except Exception as e:
            last_exc = e
            _log(f"Attempt {attempt}/{_DOWNLOAD_RETRIES} failed: {type(e).__name__}: {e}")
            if attempt < _DOWNLOAD_RETRIES:
                _log(f"Retrying in {_DOWNLOAD_RETRY_DELAY}s...")
                time.sleep(_DOWNLOAD_RETRY_DELAY)
    else:
        print(
            f"ERROR: yfinance download failed after {_DOWNLOAD_RETRIES} attempts: {last_exc}",
            file=sys.stderr,
        )
        sys.exit(1)

    if data.empty:
        print("ERROR: yfinance returned no data", file=sys.stderr)
        sys.exit(1)

    try:
        closes = data["Close"]
        _log(f"Close data extracted — {len(closes.columns)} symbols, {len(closes)} rows")
        _log(f"Date range: {closes.index[0].date()} to {closes.index[-1].date()}")
        return closes
    except KeyError:
        print("ERROR: no Close column in yfinance result", file=sys.stderr)
        sys.exit(1)


def _compute_ref_date(closes):
    """Return the most recent *completed* close date among FX symbols.

    FX trades every weekday, so this date is used as a reference to detect
    per-instrument market closures (e.g. a US holiday closes equities but
    not FX or commodity futures).

    Dates on or after today are excluded: at 08:00 JST, yfinance may include
    a partial Asian-session bar for the current calendar day while US
    instruments only have yesterday's completed close.  Without this filter,
    the partial FX bar causes all US symbols to be falsely flagged as
    'market closed'.
    """
    today_str = date.today().isoformat()
    dates = []
    for sym in ["USDJPY=X", "JPYGBP=X", "GBPJPY=X"]:
        try:
            s = closes[sym].dropna()
            s = s[s.index < today_str]  # exclude partial intra-day bars
            if len(s):
                dates.append(s.index[-1].date())
        except (KeyError, AttributeError):
            pass
    # Fall back to yesterday if no FX data is available (yfinance gap or
    # a global FX closure). Using yesterday ensures holiday detection stays
    # active — it does not assume FX absence implies equities are also closed.
    ref = max(dates) if dates else date.today() - timedelta(days=1)
    _log(f"ref_date={ref} (derived from {len(dates)} FX symbol(s); today={date.today()})")
    return ref


def _render(price, prev, decimals, prefix=""):
    """Format price, directional arrow, absolute change, and pct change."""
    change = price - prev
    pct    = (change / prev * 100) if prev != 0 else 0.0
    arrow  = "▲" if change >= 0 else "▼"
    sign   = "+" if change >= 0 else ""
    return (
        f"{prefix}{price:,.{decimals}f}  "
        f"{arrow} {sign}{change:.{decimals}f} ({sign}{pct:.2f}%)"
    )


def fmt(closes, ref_date, sym, decimals=2, prefix=""):
    """Format a standard quote.

    Returns 'market closed' when the symbol's last data date lags the FX
    reference date, indicating a holiday closure for that instrument.
    """
    try:
        series = closes[sym].dropna()
    except KeyError:
        return "N/A"
    if len(series) < 2:
        return "N/A"
    if ref_date is not None and series.index[-1].date() < ref_date:
        return "market closed"
    return _render(float(series.iloc[-1]), float(series.iloc[-2]), decimals, prefix)


def fmt_jpygbp(closes, ref_date):
    """Format the JPY/GBP rate with a fallback to 1/GBPJPY=X.

    Applies the same staleness check as fmt(): if JPYGBP=X lags ref_date,
    falls back to GBPJPY=X rather than showing a pre-holiday rate alongside
    a current USD/JPY.  If both sources lag ref_date, returns 'market closed'.

    Note: the pct change of 1/x is approximately but not exactly −1× the pct
    change of x (the bases differ; they converge for small daily moves).
    """
    price = prev = None
    any_stale = False

    # Preferred: direct JPYGBP=X quote
    try:
        series = closes["JPYGBP=X"].dropna()
        if len(series) >= 2:
            if ref_date is not None and series.index[-1].date() < ref_date:
                any_stale = True
            else:
                price, prev = float(series.iloc[-1]), float(series.iloc[-2])
    except KeyError:
        pass

    # Fallback: invert GBPJPY=X
    if price is None:
        try:
            series = closes["GBPJPY=X"].dropna()
            if len(series) >= 2:
                if ref_date is not None and series.index[-1].date() < ref_date:
                    any_stale = True
                else:
                    g, g_prev = float(series.iloc[-1]), float(series.iloc[-2])
                    if g != 0 and g_prev != 0:
                        price, prev = 1.0 / g, 1.0 / g_prev
        except KeyError:
            pass

    if price is None or prev is None:
        return "market closed" if any_stale else "N/A"
    return _render(price, prev, 6)


def build_message(closes, today=None):
    """Assemble and return the full Discord market update message.

    Parameters
    ----------
    closes : pd.DataFrame
        Close prices with tickers as columns and a DatetimeIndex.
        Typically the result of fetch_closes(), but can be a mock DataFrame
        for testing.
    today : str, optional
        Date label for the header (e.g. "Fri 11 Apr 2025").  Defaults to
        the current local date — pass a fixed string in tests for
        deterministic output.
    """
    if today is None:
        today = datetime.now().strftime("%a %d %b %Y")

    ref_date = _compute_ref_date(closes)
    _log(f"Building message for {today}")

    lines = [
        f"**Market Update — {today}**",
        "",
        "**FX**",
        f"• JPY/GBP:  {fmt_jpygbp(closes, ref_date)}",
        f"• USD/JPY:  {fmt(closes, ref_date, 'USDJPY=X')}",
        "",
        "**Equities**",
        f"• Goldman Sachs (GS):  {fmt(closes, ref_date, 'GS', prefix='$')}",
        f"• Apple (AAPL):        {fmt(closes, ref_date, 'AAPL', prefix='$')}",
        f"• S&P 500:             {fmt(closes, ref_date, '^GSPC')}",
        "",
        "**Commodities**",
        f"• Gold ($/oz):         {fmt(closes, ref_date, 'GC=F', prefix='$')}",
        f"• Silver ($/oz):       {fmt(closes, ref_date, 'SI=F', 3, prefix='$')}",
        f"• WTI Crude ($/bbl):   {fmt(closes, ref_date, 'CL=F', prefix='$')}",
        "",
        "_Change vs prior close_",
    ]

    for line in lines:
        if line.startswith("•"):
            _log(f"  {line.strip()}")

    result = "\n".join(lines)
    _log(f"Message built — {len(result)} chars")
    return result


def main():
    closes = fetch_closes()
    print(build_message(closes))


if __name__ == "__main__":
    main()

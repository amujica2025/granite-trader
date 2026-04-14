from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

PACIFIC = ZoneInfo("America/Los_Angeles")


def now_pacific() -> dt.datetime:
    return dt.datetime.now(PACIFIC)


def is_weekday(ts: dt.datetime | None = None) -> bool:
    value = ts or now_pacific()
    return value.weekday() < 5  # 0=Mon â€¦ 4=Fri


def is_chain_refresh_window(ts: dt.datetime | None = None) -> bool:
    """
    True during normal Schwab chain-fetch hours:
    Mondayâ€“Friday, 06:30â€“13:15 Pacific (market open to 30 min before close).
    """
    value = ts or now_pacific()
    if not is_weekday(value):
        return False
    start = value.replace(hour=6, minute=30, second=0, microsecond=0)
    stop = value.replace(hour=13, minute=15, second=0, microsecond=0)
    return start <= value <= stop


def is_afterhours_barchart_window(ts: dt.datetime | None = None) -> bool:
    """
    True when we should rely on Barchart processed data instead of live Schwab chains.
    Roughly: after 4 PM Pacific until 5 AM Pacific next day.
    """
    value = ts or now_pacific()
    hour_min = (value.hour, value.minute)
    return hour_min >= (16, 0) or hour_min < (5, 0)


def is_eod_archive_time(ts: dt.datetime | None = None) -> bool:
    """True at or after 4:00 PM Pacific â€” triggers EOD archive/clear."""
    value = ts or now_pacific()
    return (value.hour, value.minute) >= (16, 0)


def is_overnight_refresh_time(ts: dt.datetime | None = None) -> bool:
    """
    True at midnight (00:00) or 3 AM Pacific.
    The scheduler checks once per minute so we only need to match the exact minute.
    """
    value = ts or now_pacific()
    return (value.hour, value.minute) in {(0, 0), (3, 0)}

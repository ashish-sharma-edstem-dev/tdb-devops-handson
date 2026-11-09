"""Booking data access.

The exercise needs sample JSON only, so this returns fixed in-memory data.
Swapping in a PostgreSQL-backed repository later only touches this module.
"""

from datetime import date

from app.models import Booking, BookingStatus

_SAMPLE_BOOKINGS: tuple[Booking, ...] = (
    Booking(
        id="bk_001",
        guest_name="Asha Verma",
        check_in=date(2026, 12, 1),
        check_out=date(2026, 12, 4),
        status=BookingStatus.CONFIRMED,
    ),
    Booking(
        id="bk_002",
        guest_name="Rahul Mehta",
        check_in=date(2026, 12, 10),
        check_out=date(2026, 12, 12),
        status=BookingStatus.PENDING,
    ),
    Booking(
        id="bk_003",
        guest_name="Neha Kapoor",
        check_in=date(2027, 1, 5),
        check_out=date(2027, 1, 9),
        status=BookingStatus.CANCELLED,
    ),
)


def list_bookings() -> list[Booking]:
    return list(_SAMPLE_BOOKINGS)

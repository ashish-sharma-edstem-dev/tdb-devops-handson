"""API response models. These define the public JSON contract."""

from datetime import date
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class BookingStatus(StrEnum):
    CONFIRMED = "confirmed"
    PENDING = "pending"
    CANCELLED = "cancelled"


class Booking(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str = Field(examples=["bk_001"])
    guest_name: str = Field(min_length=1)
    check_in: date
    check_out: date
    status: BookingStatus


class BookingList(BaseModel):
    items: list[Booking]
    count: int = Field(ge=0)


class Health(BaseModel):
    status: str = Field(examples=["ok"])
